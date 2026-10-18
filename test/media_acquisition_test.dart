import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_acquisition.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/codex/customer_media_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/fallback_delivery_journal.dart';
import 'package:jd_automation/storage/reply_outbox.dart';

void main() {
  final at = DateTime.utc(2026, 10, 17, 10, 46, 17);
  test('short typed bubbles stay text, photo OCR does not become typed text',
      () {
    const selector = OcrImageCandidateSelector();
    const bubble =
        OcrVisualRegion(x: .2, y: .3, width: .23, height: .06, confidence: 1);
    for (final text in ['how are you doing?', '我需要帮助', 'M880D']) {
      expect(
          selector.looksLikeShortTypedBubble(bubble, [
            OcrObservation(
                text: text,
                confidence: .55,
                x: .21,
                y: .315,
                width: .20,
                height: .025)
          ]),
          isTrue,
          reason: text);
    }
    const photo =
        OcrVisualRegion(x: .2, y: .3, width: .3, height: .3, confidence: 1);
    expect(
        selector.looksLikeShortTypedBubble(photo, const [
          OcrObservation(
              text: 'TP874',
              confidence: 1,
              x: .3,
              y: .4,
              width: .05,
              height: .02)
        ]),
        isFalse);
    expect(
        selector.looksLikeShortTypedBubble(bubble, const [
          OcrObservation(
              text: '0000',
              confidence: 1,
              x: .21,
              y: .315,
              width: .20,
              height: .025)
        ]),
        isFalse);
  });
  test('new media invalidates only an older reply in the same session', () {
    final original = AiDraft.fromJson({
      'reply': 'Question about the attachment',
      'image_descriptions': [
        {'path': '/tmp/verified.jpg', 'description': 'Printer'}
      ]
    }, mediaBaseUrl: Uri());
    final stamped =
        withMediaEvidenceRevision(original, session: 'run-a', revision: 2);
    expect(stamped.reply, original.reply);
    expect(stamped.imageDescriptions, original.imageDescriptions);
    expect(
        hasNewerMediaEvidence(stamped, session: 'run-a', revision: 3), isTrue);
    expect(
        hasNewerMediaEvidence(stamped, session: 'run-a', revision: 2), isFalse);
    expect(
        hasNewerMediaEvidence(stamped, session: 'run-b', revision: 3), isFalse);
    expect(hasNewerMediaEvidence(original, session: 'run-a', revision: 3),
        isFalse);
  });
  test('media refresh cannot delete sending or confirmed outbox receipts',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_media_refresh_');
    addTearDown(() => root.delete(recursive: true));
    final outbox = ReplyOutbox(root);
    final draft = AiDraft.fromJson({'reply': 'Answer'}, mediaBaseUrl: Uri());
    for (final state in ['ready', 'sending', 'sent']) {
      final item = OutboxReply(
          userId: 'a',
          batchEndMessageId: state,
          draft: draft,
          createdAt: at,
          state: state);
      await outbox.save(item);
      expect(await outbox.discardReady(item), state == 'ready');
    }
    expect((await outbox.pending()).map((item) => item.state),
        ['sending', 'sent']);
    final item = OutboxReply(
        userId: 'b', batchEndMessageId: 'ready', draft: draft, createdAt: at);
    await outbox.save(item);
    final changed = OutboxReply(
        userId: 'b',
        batchEndMessageId: 'ready',
        draft: AiDraft.fromJson({'reply': 'New answer'}, mediaBaseUrl: Uri()),
        createdAt: at);
    await outbox.save(changed);
    expect(await outbox.discardReady(item), isFalse);
  });
  test('one upload owns preview/original retries, a new timestamp is new', () {
    final events = MediaAcquisitions();
    final first = events.observe('buyer-a', uploadEventKey(at, 0), at, at);
    final crop = events.observe('buyer-a', uploadEventKey(at, 0), at,
        at.add(const Duration(seconds: 8)));
    expect(identical(first, crop), isTrue);
    first.acquired = true;
    expect(events.retryDue('buyer-a', at), isFalse);
    expect(events.forCustomer('buyer-a'), hasLength(1));
    events.observe(
        'buyer-a',
        uploadEventKey(at.add(const Duration(seconds: 1)), 0),
        at.add(const Duration(seconds: 1)),
        at);
    expect(events.forCustomer('buyer-a'), hasLength(2));
  });
  test('multiple media at the same second and other customers stay distinct',
      () {
    final events = MediaAcquisitions();
    final first = events.observe('buyer-a', uploadEventKey(at, 0), at, at);
    events.observe('buyer-a', uploadEventKey(at, 1), at, at);
    final foreign = events.observe('buyer-b', uploadEventKey(at, 0), at, at);
    first.acquired = true;
    expect(events.forCustomer('buyer-a'), hasLength(2));
    expect(foreign.acquired, isFalse);
    expect(events.deferGeneration('buyer-c', at), isFalse);
  });
  test(
      'bounded collection and backed-off retries never retain a worker forever',
      () {
    final e = MediaAcquisition(
        customer: 'a', key: 'event', sentAt: at, firstSeen: at);
    expect(e.deferGeneration(at.add(const Duration(seconds: 19))), isTrue);
    expect(e.deferGeneration(at.add(const Duration(seconds: 20))), isFalse);
    for (final second in [0, 2, 6, 14, 22, 30, 38, 46]) {
      final now = at.add(Duration(seconds: second));
      expect(e.retryDue(now), isTrue);
      e.attempting(now);
      expect(e.retryDue(now), isFalse);
    }
    expect(e.retryDue(at.add(const Duration(seconds: 49))), isFalse);
    final expired =
        MediaAcquisition(customer: 'b', key: 'new', sentAt: at, firstSeen: at);
    expect(expired.retryDue(at.add(const Duration(seconds: 50))), isFalse);
  });
  test('acquisition metadata updates one event, not the message or SLA queue',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_upload_state_');
    addTearDown(() => root.delete(recursive: true));
    final store = ConversationFileStore(root);
    final e = MediaAcquisition(
        customer: 'buyer-a',
        key: uploadEventKey(at, 0),
        sentAt: at,
        firstSeen: at);
    await store.recordMediaAcquisition('buyer-a', e.toJson());
    e.acquired = true;
    await store.recordMediaAcquisition('buyer-a', e.toJson());
    final doc = (await store.read('buyer-a'))!;
    expect(doc['messages'], isEmpty);
    expect(doc['media_acquisition_events'], hasLength(1));
    expect(
        (doc['media_acquisition_events'] as List).single['state'], 'acquired');
    await expectLater(
        store.recordMediaAcquisition('buyer-b', e.toJson()), throwsStateError);
  });
  test('unread and SLA share a durable holding receipt for the same upload',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_upload_receipt_');
    addTearDown(() => root.delete(recursive: true));
    final store = ConversationFileStore(root);
    final e = MediaAcquisition(
        customer: 'buyer-a',
        key: uploadEventKey(at, 0),
        sentAt: at,
        firstSeen: at);
    final receipt = uploadHoldingReceipt([e], at)!;
    final journal = FallbackDeliveryJournal(Directory('${root.path}/receipts'));
    expect(await journal.reserve('buyer-a', receipt), isTrue);
    expect(
        await journal.reserve('buyer-a',
            uploadHoldingReceipt([e], at.add(const Duration(seconds: 9)))!),
        isFalse);
    expect(await journal.reserve('buyer-b', receipt), isTrue);
    await store.appendSlaFallbackSent(
        userId: 'buyer-a',
        messageId: 'unread-holding',
        reply: 'received',
        receiptKey: receipt);
    await store.appendSlaFallbackSent(
        userId: 'buyer-a',
        messageId: 'original-jpeg',
        reply: 'please wait',
        receiptKey: receipt);
    expect((await store.read('buyer-a'))!['messages'], hasLength(1));
  });
  test('unresolved metadata belongs only to this customer and current turn',
      () {
    final e = MediaAcquisition(
        customer: 'buyer-a', key: 'event', sentAt: at, firstSeen: at);
    final batch = <Map<String, dynamic>>[
      {'sent_at': at.toIso8601String()}
    ];
    expect(
        unresolvedCustomerUploads([e.toJson()],
            customer: 'buyer-a', batch: batch),
        hasLength(1));
    expect(
        unresolvedCustomerUploads([e.toJson()],
            customer: 'buyer-b', batch: batch),
        isEmpty);
    expect(
        unresolvedCustomerUploads([e.toJson()],
            customer: 'buyer-a',
            batch: [
              {'sent_at': at.add(const Duration(hours: 1)).toIso8601String()}
            ]),
        isEmpty);
    e.acquired = true;
    expect(
        unresolvedCustomerUploads([e.toJson()],
            customer: 'buyer-a', batch: batch),
        isEmpty);
  });
  test('0000 inside a pending photo is evidence, not a typed request', () {
    final view = OcrInspection(
        image: Uint8List(0),
        imageWidth: 1600,
        imageHeight: 1200,
        windowTitle: 'JD',
        recognizedText: '',
        activeCustomerId: 'jd_41aeec7741d05',
        capturedAt: at,
        chatLeft: .18,
        chatRight: .8,
        chatBottom: .9,
        observations: const [
          OcrObservation(
              text: 'jd_41aeec7741d05 18:46:17',
              confidence: 1,
              x: .2,
              y: .25,
              width: .3,
              height: .02),
          OcrObservation(
              text: '0000',
              confidence: 1,
              x: .3,
              y: .4,
              width: .05,
              height: .02),
        ]);
    final attempt = const OcrCaptureExtractor().analyze(view);
    expect(attempt.capture!.messages.single.body, '0000');
    final masked = attempt.textExcludingMedia(view, const [
      OcrVisualRegion(x: .2, y: .3, width: .3, height: .3, confidence: 1)
    ]);
    expect(masked?.messages.where((m) => m.direction == 'incoming') ?? [],
        isEmpty);
  });
}
