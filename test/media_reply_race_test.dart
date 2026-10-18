import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/reply_message_scope.dart';
import 'package:jd_automation/capture/unread_capture_recovery.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/media_identity.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

const customer = 'jd_41aeec7741d05';
const selector = OcrImageCandidateSelector();
const region =
    OcrVisualRegion(x: .20, y: .30, width: .25, height: .28, confidence: 1);
final mediaAt = DateTime.utc(2026, 10, 16, 4, 27, 20);

OcrObservation label(String text, double x, double y) => OcrObservation(
    text: text, confidence: 1, x: x, y: y, width: .18, height: .02);

OcrInspection view(
        {String clock = '12:27:20',
        String owner = customer,
        bool sellerBelow = true,
        bool sidebarSeller = false}) =>
    OcrInspection(
      image: Uint8List(0),
      imageWidth: 2940,
      imageHeight: 1722,
      windowTitle: '咚咚融合工作台',
      recognizedText: '',
      activeCustomerId: owner,
      capturedAt: mediaAt.add(const Duration(seconds: 6)),
      chatLeft: .18,
      chatRight: .80,
      chatBottom: .90,
      observations: [
        label('$customer $clock', .20, .25),
        if (sellerBelow) ...[
          label('格志打印机小甘 12:27:22', .52, .65),
          label('What issue are you having?', .52, .70),
        ],
        if (sidebarSeller) label('格志打印机贝贝', .01, .70),
      ],
      visualRegions: const [region],
    );

Map<String, dynamic> generated(String boundary) => {
      'direction': 'outgoing',
      'source': 'generated_reply',
      'delivery_status': 'sent',
      'body': 'Confirmed generated answer.',
      'sent_at': mediaAt.add(const Duration(seconds: 2)).toIso8601String(),
      'reply_metadata': {
        'raw_response': {'delivery_batch_end_message_id': boundary}
      },
    };

UnreadCaptureRecovery recovery() => UnreadCaptureRecovery(
    customer: customer,
    unreadEvidence: 1,
    detectedAt: mediaAt,
    knownIncomingIds: const {},
    knownOutgoingIds: const {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('12:27:20 media survives the older 12:27:22 outgoing reply', () {
    final inspection = view();
    expect(
        const OcrCaptureExtractor()
            .analyze(inspection)
            .latestVisibleSenderIsIncoming,
        isFalse);
    final candidate =
        selector.select(inspection, customer, includeTextDense: true).single;
    expect(selector.sentAtForRegion(inspection, customer, candidate), mediaAt);
    expect(
        selector.mayCaptureWithLaterActivity(inspection, customer, candidate),
        isTrue);
    expect(selector.hasUncapturedRecentCustomerMedia(inspection, customer, []),
        isTrue);
  });

  test('old/unknown clocks and other owners do not bypass historical guard',
      () {
    for (final inspection in [
      view(clock: '10-12 17:08:30'),
      view(clock: ''),
      view(owner: 'jd_other_customer'),
      view(clock: '12:30:00')
    ]) {
      expect(selector.mayCaptureWithLaterActivity(inspection, customer, region),
          isFalse);
      expect(
          selector.hasUncapturedRecentCustomerMedia(inspection, customer, []),
          isFalse);
    }
    expect(
        selector.mayCaptureWithLaterActivity(
            view(clock: '', sellerBelow: false, sidebarSeller: true),
            customer,
            region),
        isTrue);
  });

  test('captured media cannot restart recovery, but resend timestamp can', () {
    final known = <Map<String, dynamic>>[
      {
        'direction': 'incoming',
        'sent_at': mediaAt.toIso8601String(),
        'media': [
          {'type': 'video', 'path': '/owned/video.mp4'}
        ],
      }
    ];
    expect(selector.hasUncapturedRecentCustomerMedia(view(), customer, known),
        isFalse);
    expect(
        selector.hasUncapturedRecentCustomerMedia(
            view(clock: '12:27:21'), customer, known),
        isTrue);
  });

  test('older batch cannot resolve newer recovery or suppress its fallback',
      () {
    final r = recovery();
    r.verifyIncomingSignal(
        senderKey: '$customer\u001f12:27:20',
        sentAt: mediaAt,
        capturedAt: mediaAt);
    final history = <Map<String, dynamic>>[
      {
        'id': 'text-old', 'direction': 'incoming',
        // Inside the former 15-second tolerance: still not the new media.
        'sent_at':
            mediaAt.subtract(const Duration(seconds: 8)).toIso8601String(),
      },
      {
        'id': 'media-new',
        'direction': 'incoming',
        'sent_at': mediaAt.toIso8601String(),
      }
    ];
    final oldReply = generated('text-old');
    expect(r.acceptsGeneratedReply(oldReply, history), isFalse);
    expect(
        r.acceptsIncoming('text-old',
            sentAt: mediaAt.subtract(const Duration(seconds: 8)),
            capturedAt: mediaAt.add(const Duration(seconds: 5))),
        isFalse);
    expect(r.holdingDue(mediaAt.add(const Duration(seconds: 20))), isTrue);
    expect(
        replyAnswersIncoming(
            reply: oldReply, incomingId: 'media-new', messages: history),
        isFalse);
    expect(
        replyAnswersIncoming(
            reply: oldReply, incomingId: 'text-old', messages: history),
        isTrue);
    expect(r.acceptsGeneratedReply(generated('media-new'), history), isTrue);
    expect(
        replyAnswersIncoming(
            reply: generated('media-new'),
            incomingId: 'media-new',
            messages: history),
        isTrue);
    expect(
        replyAnswersIncoming(reply: {
          'direction': 'outgoing',
          'source': 'generated_reply',
          'sent_at': mediaAt.add(const Duration(seconds: 3)).toIso8601String()
        }, incomingId: 'media-new', messages: history),
        isFalse);
    // A late older OCR pass cannot roll the verified recovery clock backward.
    expect(
        r.verifyIncomingSignal(
            senderKey: 'old',
            sentAt: mediaAt.subtract(const Duration(seconds: 8)),
            capturedAt: mediaAt),
        isFalse);
    expect(r.latestIncomingSentAt, mediaAt);
  });

  test('explicit human replies are preserved, including reused wording', () {
    final history = <Map<String, dynamic>>[
      {
        'id': 'incoming',
        'direction': 'incoming',
        'sent_at': mediaAt.toIso8601String(),
      }
    ];
    final human = <String, dynamic>{
      'direction': 'outgoing',
      'source': 'jd_automation',
      'body': 'Please wait',
      'delivery_status': 'sent',
      'sent_at': mediaAt.add(const Duration(seconds: 20)).toIso8601String()
    };
    expect(
        replyAnswersIncoming(
            reply: human, incomingId: 'incoming', messages: history),
        isTrue);
    final own = generated('incoming')..['body'] = 'Please wait';
    expect(
        isObservedGeneratedReply(
            body: 'Please wait',
            sentAt: mediaAt.add(const Duration(seconds: 2)),
            messages: [own]),
        isTrue);
    expect(
        isObservedGeneratedReply(
            body: 'Please wait',
            sentAt: mediaAt.add(const Duration(seconds: 20)),
            messages: [own]),
        isFalse);
    expect(
        replyAnswersIncoming(
            reply: {...human, 'delivery_status': 'delivery_unknown'},
            incomingId: 'incoming',
            messages: history),
        isFalse);
  });

  for (final kind in ['image', 'video']) {
    for (final stage in [
      'generation',
      'queued send',
      'send click',
      'holding reply'
    ]) {
      test('$kind arriving during $stage stays pending after the older reply',
          () async {
        final root =
            await Directory.systemTemp.createTemp('jd_media_reply_race_');
        final db = CaptureDatabase(storageRoot: root);
        addTearDown(() async {
          await db.close();
          await root.delete(recursive: true);
        });
        CapturedConversation capture(
                String owner, List<CapturedMessage> messages) =>
            CapturedConversation(
                stableKey: 'customer:$owner',
                customerName: owner,
                customerExternalId: owner,
                verifiedCustomerId: owner,
                capturedAt: mediaAt.add(const Duration(seconds: 6)),
                messages: messages);
        final oldAt = mediaAt.subtract(const Duration(seconds: 18));
        await db.saveCapture(capture(customer, [
          CapturedMessage(
              stableId: 'text-old',
              direction: 'incoming',
              body: 'i need help with tp879',
              sentAt: oldAt,
              axPath: 'test')
        ]));
        await db.saveCapture(capture('other-buyer', [
          CapturedMessage(
              stableId: 'other-question',
              direction: 'incoming',
              body: 'printer help',
              sentAt: mediaAt,
              axPath: 'test')
        ]));
        final pending =
            (await db.conversations()).firstWhere((c) => c.userId == customer);
        const draft = AiDraft(
            reply: 'What issue are you having?',
            decision: 'draft',
            confidence: 1,
            riskLevel: 'low',
            model: 'test',
            usedRecordIds: [],
            actions: [],
            attachments: [],
            rawJson:
                '{"reply":"What issue are you having?","decision":"draft","confidence":1,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}');
        if (stage != 'generation') {
          expect(
              await db.saveDraft(pending.id, draft,
                  expectedMessageId: 'text-old'),
              1);
        }
        if (stage == 'holding reply') {
          await (await db.history).appendSlaFallbackSent(
              userId: customer, messageId: 'old-holding', reply: '请稍等，我正在核对。');
        }
        // Send may finish before the next OCR pass sees the new media.
        if (stage == 'send click') {
          expect(await db.markReplySent(userId: customer, reply: draft.reply),
              isTrue);
        }
        final store = await db.history;
        final path = await store.saveMedia(
            userId: customer, filename: 'owned.$kind', bytes: [1, 2, 3]);
        final id = mediaMessageStableId(kind, 'new-bytes', mediaAt);
        final mediaCapture = capture(customer, [
          if (stage == 'send click')
            CapturedMessage(
                stableId: 'ocr-older-reply-below-media',
                direction: 'outgoing',
                body: draft.reply,
                sentAt: mediaAt.add(const Duration(seconds: 2)),
                axPath: 'ocr:seller'),
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: '[Customer sent a $kind]',
              sentAt: mediaAt,
              axPath: 'test',
              media: [
                CapturedMedia(
                    type: kind, path: path, verifiedCustomerId: customer)
              ])
        ]);
        expect(await db.saveCapture(mediaCapture), 1);
        if (stage == 'generation') {
          expect(
              await db.saveDraft(pending.id, draft,
                  expectedMessageId: 'text-old'),
              1);
        }
        if (stage != 'send click') {
          final delivery = await db.nextReadyDelivery();
          expect(delivery?.batchEndMessageId, 'text-old');
          expect(
              await db.markReplySent(
                  userId: customer,
                  reply: draft.reply,
                  expectedDelivery: delivery),
              isTrue);
        }
        expect(await db.answeredMessageId(customer), 'text-old');
        expect(await db.pendingMessageId(customer), id);
        expect(await db.hasPendingUnanswered(customer), isTrue);
        expect((await db.slaFallbackJob(customer))?.messageId, id);
        expect(await db.hasPendingUnanswered('other-buyer'), isTrue);
        expect(await db.answeredMessageId('other-buyer'), isNull);
        expect(await db.saveCapture(mediaCapture), 0);
        expect(
            await store.hasCapturedMediaEvent('other-buyer', kind, 'new-bytes',
                sentAt: mediaAt),
            isFalse);
      });
    }
  }
}
