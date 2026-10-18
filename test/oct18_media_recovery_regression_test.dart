import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/reply_message_scope.dart';
import 'package:jd_automation/capture/unread_capture_recovery.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'jd_41aeec7741d05';
  DateTime at(int minute, int second) =>
      DateTime.utc(2026, 10, 18, 3, minute, second);
  UnreadCaptureRecovery recovery() => UnreadCaptureRecovery(
      customer: customer,
      unreadEvidence: 1,
      detectedAt: at(7, 28).add(const Duration(microseconds: 537909)),
      knownIncomingIds: {},
      knownOutgoingIds: {},
      sidebarUnreadVerified: true);

  test('11:08:16 video cannot inherit 11:07:28 resend deadline', () {
    final r = recovery()
      ..holdingSent = true
      ..holdingSentAt = at(7, 36);
    expect(
        r.verifyIncomingSignal(
            senderKey: 'video-11:08:16',
            sentAt: at(8, 16),
            capturedAt: at(8, 19)),
        isTrue);
    expect(r.eventAt, at(8, 16));
    expect(r.holdingSent, isFalse);
    expect(r.holdingSentAt, isNull);
    expect(r.noticeRevision, 1);
    expect(r.resendDue(at(8, 20)), isFalse);
    expect(r.holdingDue(at(8, 35)), isFalse);
    expect(r.holdingDue(at(8, 36)), isTrue);
    r.holdingSent = true;
    r.holdingSentAt = at(8, 38);
    expect(r.resendDueAt, at(9, 8)); // also 30 seconds after actual holding
    expect(r.resendDue(at(9, 7)), isFalse);
    expect(r.resendDue(at(9, 8)), isTrue);
    r.verifyIncomingSignal(
        senderKey: 'same-video', sentAt: at(8, 16), capturedAt: at(8, 45));
    expect(r.noticeRevision, 1);
    expect(r.holdingSent, isTrue);
    expect(
        r.verifyIncomingSignal(
            senderKey: 'old-hi', sentAt: at(7, 0), capturedAt: at(8, 45)),
        isFalse);
    expect(r.eventAt, at(8, 16));
  });

  test('a badge without a verified current clock cannot request a resend', () {
    final r = recovery()
      ..holdingSent = true
      ..holdingSentAt = at(7, 48);
    expect(r.canSendHoldingAt(at(8, 20)), isTrue);
    expect(r.resendDue(at(8, 20)), isFalse);
  });

  test('exact late greeting answer closes old recovery, not newer video', () {
    final r = recovery();
    final hi = <String, dynamic>{
      'id': 'hi',
      'direction': 'incoming',
      'body': 'hi',
      'sent_at': at(7, 0).toIso8601String(),
      'captured_at': at(7, 34).toIso8601String()
    };
    final answer = <String, dynamic>{
      'direction': 'outgoing',
      'source': 'generated_reply',
      'delivery_status': 'sent',
      'body': 'Hello, how can I help?',
      'sent_at': at(7, 49).toIso8601String(),
      'reply_metadata': {
        'raw_response': {'delivery_batch_end_message_id': 'hi'}
      }
    };
    expect(r.acceptsGeneratedReply(answer, [hi]), isTrue);
    expect(r.acceptsGeneratedReply({...answer, 'reply_metadata': {}}, [hi]),
        isFalse);
    r.verifyIncomingSignal(
        senderKey: 'video', sentAt: at(8, 16), capturedAt: at(8, 19));
    expect(r.acceptsGeneratedReply(answer, [hi]), isFalse);
  });

  test('welcome covers only earlier plain greeting, never media or a question',
      () {
    final welcome = <String, dynamic>{
      'direction': 'outgoing',
      'source': 'generated_reply',
      'sender': 'jd-transfer-welcome-v1',
      'body': '您好，欢迎来到Grozziie客服。请问有什么可以帮您？',
      'delivery_status': 'sent',
      'sent_at': at(7, 32).toIso8601String()
    };
    for (final body in [
      'hi',
      'how do I load paper?',
      '[Customer sent a video]'
    ]) {
      final incoming = <String, dynamic>{
        'id': 'incoming',
        'direction': 'incoming',
        'body': body,
        'sent_at': at(7, 0).toIso8601String(),
        'captured_at': at(7, 34).toIso8601String()
      };
      expect(
          replyAnswersIncoming(
              reply: welcome, incomingId: 'incoming', messages: [incoming]),
          body == 'hi');
      expect(
          recovery().acceptsGeneratedReply(welcome, [incoming]), body == 'hi');
      if (body == 'hi') {
        expect(
            replyAnswersIncoming(
                reply: welcome,
                incomingId: 'incoming',
                messages: [
                  {
                    ...incoming,
                    'media': [
                      {'type': 'video'}
                    ]
                  }
                ]),
            isFalse);
      }
      incoming['sent_at'] = at(8, 16).toIso8601String();
      expect(
          replyAnswersIncoming(
              reply: welcome, incomingId: 'incoming', messages: [incoming]),
          isFalse);
    }
  });

  for (final body in ['hi', 'how do I load paper?']) {
    test('late-captured $body after welcome keeps the correct pending cursor',
        () async {
      final root =
          await Directory.systemTemp.createTemp('oct18_greeting_cursor_');
      final db = CaptureDatabase(storageRoot: root);
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final now = DateTime.now().toUtc();
      CapturedConversation turn(String id, String text, DateTime sentAt) =>
          CapturedConversation(
              stableKey: 'customer:$customer',
              customerName: customer,
              customerExternalId: customer,
              verifiedCustomerId: customer,
              capturedAt: now,
              messages: [
                CapturedMessage(
                    stableId: id,
                    direction: 'incoming',
                    body: text,
                    sentAt: sentAt,
                    axPath: 'test')
              ]);
      await db.saveCapture(turn('previous', 'previous question',
          now.subtract(const Duration(minutes: 5))));
      await (await db.database).insert(
          'answered_cursors', {'user_id': customer, 'message_id': 'previous'});
      await db.appendAutomatedNoticeSent(userId: customer, reply: 'Welcome');
      await db.saveCapture(
          turn('current', body, now.subtract(const Duration(seconds: 5))));
      expect(await db.hasPendingUnanswered(customer), body != 'hi');
      if (body != 'hi') {
        await db.saveCapture(
            turn('later-hi', 'hi', now.subtract(const Duration(seconds: 1))));
        expect(await db.hasPendingUnanswered(customer), isTrue,
            reason: 'a greeting cannot skip an earlier technical question');
      }
    });
  }

  OcrObservation line(String text, double y, {double x = .2}) => OcrObservation(
      text: text, confidence: 1, x: x, y: y, width: .4, height: .02);
  OcrInspection view(List<OcrObservation> lines) => OcrInspection(
      image: Uint8List(0),
      imageWidth: 1600,
      imageHeight: 1200,
      windowTitle: 'JD',
      recognizedText: '',
      activeCustomerId: customer,
      capturedAt: at(8, 20),
      chatLeft: .18,
      chatRight: .8,
      chatBottom: .9,
      observations: lines);

  test('other-agent badge cannot merge the seller reply into customer hi', () {
    final capture = const OcrCaptureExtractor()
        .analyze(view([
          line('$customer 11:07:00', .25),
          line('hi', .29),
          line('11:07:12 格志打印机小熊 其他客服', .36),
          line('您好，在的呢，有什么可以帮您呢', .40),
        ]))
        .capture!;
    expect(capture.messages.where((m) => m.direction == 'incoming').single.body,
        'hi');
    expect(capture.messages.where((m) => m.direction == 'outgoing').single.body,
        '您好，在的呢，有什么可以帮您呢');
  });

  test('same transfer banner is stable after move, OCR wrapping and new text',
      () {
    final first = const OcrCaptureExtractor().analyze(view([
      line('您的同事格志打印机小熊将客户$customer转接给您!', .3),
    ]));
    final second = const OcrCaptureExtractor().analyze(view([
      line('您的同事格志打印机小熊', .5),
      line('将客户$customer转接给您！', .53),
      line('how to load paper?', .56),
    ]));
    expect(first.transferNoticeKey, isNotNull);
    expect(second.transferNoticeKey, first.transferNoticeKey);
  });

  test('welcome cooldown is durable, scoped, and independent of OCR event key',
      () async {
    final root = await Directory.systemTemp.createTemp('oct18_welcome_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    const quiet = Duration(minutes: 10);
    expect(
        await db.reserveTransferWelcome(
            userId: customer,
            eventKey: 'old-shape',
            now: at(7, 31),
            minimumInterval: quiet),
        isTrue);
    expect(
        await db.reserveTransferWelcome(
            userId: customer,
            eventKey: 'new-shape',
            now: at(9, 1),
            minimumInterval: quiet),
        isFalse);
    expect(
        await db.reserveTransferWelcome(
            userId: 'another',
            eventKey: 'new-shape',
            now: at(9, 1),
            minimumInterval: quiet),
        isTrue);
    expect(
        await db.reserveTransferWelcome(
            userId: customer,
            eventKey: 'actual-later-transfer',
            now: at(18, 1),
            minimumInterval: quiet),
        isTrue);
  });
}
