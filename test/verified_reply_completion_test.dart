import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/reply_message_scope.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

const original = AiDraft(
    reply: 'The video shows a printer.',
    decision: 'draft',
    confidence: 1,
    riskLevel: 'low',
    model: 'test',
    usedRecordIds: [],
    actions: [],
    attachments: [],
    rawJson:
        '{"reply":"The video shows a printer.","decision":"draft","confidence":1,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}');
final at = DateTime.utc(2026, 10, 18, 5, 31, 57);

CapturedConversation capture(String user, CapturedMessage message) =>
    CapturedConversation(
        stableKey: user,
        customerName: user,
        customerExternalId: user,
        capturedAt: at.add(const Duration(minutes: 2)),
        messages: [message]);
CapturedMessage question(String id) => CapturedMessage(
    stableId: id,
    direction: 'incoming',
    body: 'What is in this video?',
    sentAt: at,
    axPath: 'test');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final withDraft in [false, true]) {
    for (final dated in [false, true]) {
      test('OCR 38 cannot settle video: draft=$withDraft, dated=$dated',
          () async {
        final root = await Directory.systemTemp.createTemp('jd_completion_');
        final db = CaptureDatabase(storageRoot: root);
        addTearDown(() async {
          await db.close();
          await root.delete(recursive: true);
        });
        await db.saveCapture(capture('A', question('video-A')));
        await db.saveCapture(capture('B', question('video-B')));
        final pending =
            (await db.conversations()).firstWhere((c) => c.userId == 'A');
        if (withDraft) {
          await db.saveDraft(pending.id, original,
              expectedMessageId: 'video-A');
        }
        await (await db.history).appendSlaFallbackSent(
            userId: 'A',
            messageId: 'video-A',
            reply: 'I am checking your video.');
        await db.saveCapture(capture(
            'A',
            CapturedMessage(
                stableId: 'ocr38',
                direction: 'outgoing',
                body: '38',
                sender: '格志打印机小甘',
                sentAt: dated ? at.add(const Duration(seconds: 90)) : null,
                axPath: 'ocr:test')));
        expect(await db.answeredMessageId('A'), isNull);
        expect(await db.hasUndeliveredDraft('A'), withDraft);
        if (!withDraft) expect(await db.hasPendingUnanswered('A'), isTrue);
        expect(await db.hasPendingUnanswered('B'), isTrue);
        if (withDraft) {
          expect((await db.nextReadyDelivery())!.draft.reply, original.reply);
        }
      });
    }
  }

  test('dated numeric human reply with a receipt is still a valid reply',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_numeric_reply_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await db.saveCapture(capture('A', question('A1')));
    await db.saveCapture(capture(
        'A',
        CapturedMessage(
            stableId: 'real38',
            direction: 'outgoing',
            body: '38',
            sentAt: at.add(const Duration(seconds: 10)),
            deliveryConfirmed: true,
            axPath: 'test')));
    expect(await db.hasPendingUnanswered('A'), isFalse);
    expect(await db.answeredMessageId('A'), 'A1');
  });

  test('ready outbox repairs missing queue without replacing a newer draft',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_outbox_restore_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await db.saveCapture(capture('A', question('A1')));
    await (await db.database)
        .delete('pending_customers', where: 'user_id=?', whereArgs: ['A']);
    expect(
        await db.restoreUnsentOutboxDraft(
            userId: 'A', batchEndMessageId: 'A1', draft: original),
        isTrue);
    final ready = await db.nextReadyDelivery();
    expect(ready!.batchEndMessageId, 'A1');
    expect(ready.draft.reply, original.reply);
    expect(
        await db.restoreUnsentOutboxDraft(
            userId: 'A', batchEndMessageId: 'A1', draft: original),
        isFalse);
    expect((await db.nextReadyDelivery())!.createdAtMs, ready.createdAtMs);
    expect(
        await db.restoreUnsentOutboxDraft(
            userId: 'B', batchEndMessageId: 'A1', draft: original),
        isFalse);
  });

  test('a confirmed generated batch cannot swallow a newer incoming event', () {
    final messages = <Map<String, dynamic>>[
      {'id': 'A1', 'direction': 'incoming', 'sent_at': at.toIso8601String()},
      {
        'id': 'A2',
        'direction': 'incoming',
        'sent_at': at.add(const Duration(seconds: 2)).toIso8601String()
      },
    ];
    final reply = <String, dynamic>{
      'direction': 'outgoing',
      'source': 'generated_reply',
      'body': 'Answer to A1',
      'sent_at': at.add(const Duration(seconds: 5)).toIso8601String(),
      'delivery_status': 'sent',
      'reply_metadata': {
        'raw_response': {'delivery_batch_end_message_id': 'A1'}
      }
    };
    expect(
        replyAnswersIncoming(
            reply: reply, incomingId: 'A1', messages: messages),
        isTrue);
    expect(
        replyAnswersIncoming(
            reply: reply, incomingId: 'A2', messages: messages),
        isFalse);
    expect(
        replyAnswersIncoming(
            reply: {...reply, 'delivery_status': 'delivery_unknown'},
            incomingId: 'A1',
            messages: messages),
        isFalse);
  });

  OcrObservation line(String text, double x, double y, double width) =>
      OcrObservation(
          text: text, confidence: 1, x: x, y: y, width: width, height: .02);
  OcrInspection view(List<OcrObservation> observations) => OcrInspection(
      image: Uint8List(0),
      imageWidth: 1106,
      imageHeight: 1044,
      windowId: 1,
      windowTitle: 'JD',
      recognizedText: '',
      activeCustomerId: 'jd_41aeec7741d05',
      capturedAt: at,
      chatLeft: .05,
      chatRight: .96,
      chatBottom: .9,
      observations: observations);
  test('left video digits cannot become outgoing under a missed sender label',
      () {
    final inspection =
        view([line('13:31:13 格志打印机小甘', .62, .2, .28), line('38', .2, .5, .05)]);
    expect(const OcrCaptureExtractor().extract(inspection), isNull);
  });
  test(
      'right seller digits with receipt and left customer digits are preserved',
      () {
    final inspection = view([
      line('jd_41aeec7741d05 13:31:57', .08, .2, .3),
      line('38', .1, .3, .05),
      line('13:32:15 格志打印机小甘', .62, .5, .28),
      line('38', .8, .6, .05),
      line('已读', .72, .6, .05)
    ]);
    final messages = const OcrCaptureExtractor().extract(inspection)!.messages;
    expect(messages.map((m) => m.body), ['38', '38']);
    expect(messages.last.deliveryConfirmed, isTrue);
  });
  test('a sender-looking label inside media is excluded along with its digits',
      () {
    final inspection =
        view([line('13:31:13 格志打印机小甘', .3, .4, .3), line('38', .55, .5, .05)]);
    expect(
        const OcrCaptureExtractor()
            .analyze(inspection, excludedMediaRegions: const [
          OcrVisualRegion(x: .2, y: .3, width: .5, height: .4, confidence: 1)
        ]).capture,
        isNull);
  });
}
