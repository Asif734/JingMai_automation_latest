import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_acquisition.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/codex/customer_media_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'jd_41aeec7741d05', other = 'jd_6c67c99371fa4';
  const selector = OcrImageCandidateSelector();
  const channel = MethodChannel('test/attachment-preview');
  final at = DateTime.utc(2026, 10, 18, 8, 49, 59);
  const region =
      OcrVisualRegion(x: .25, y: .35, width: .20, height: .24, confidence: .9);
  OcrInspection scan(
          {List<OcrObservation> body = const [],
          List<OcrVisualRegion> regions = const [region]}) =>
      OcrInspection(
          image: Uint8List.fromList([1, 2, 3]),
          imageWidth: 2000,
          imageHeight: 1400,
          windowId: 21203,
          windowTitle: 'JD',
          recognizedText: '',
          activeCustomerId: customer,
          capturedAt: at.add(const Duration(seconds: 4)),
          chatLeft: .24,
          chatRight: .8,
          chatBottom: .9,
          observations: [
            const OcrObservation(
                text: '$customer 16:49:59',
                confidence: 1,
                x: .25,
                y: .30,
                width: .3,
                height: .025),
            ...body
          ],
          visualRegions: regions);
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test(
      'flat grey/white image rectangles do not require readable or varied content',
      () {
    final source = scan();
    expect(
        selector.mayRetainAttachmentPreview(source, customer, region), isTrue);
    expect(selector.previewTextRegions(source, region), isEmpty);
    expect(selector.mayRetainAttachmentPreview(source, other, region), isFalse);
    final emptyBlock =
        selector.fallbackLatestCustomerBlock(scan(regions: []), customer)!;
    expect(
        selector.mayRetainAttachmentPreview(
            scan(regions: []), customer, emptyBlock),
        isFalse,
        reason: 'An invented empty viewport is not an attachment');
  });

  test('every separate rectangle is eligible; typed text keeps its own block',
      () {
    const first =
        OcrVisualRegion(x: .25, y: .34, width: .14, height: .17, confidence: 1);
    const second =
        OcrVisualRegion(x: .25, y: .55, width: .15, height: .20, confidence: 1);
    final source = scan(regions: [first, second]);
    final items = selector.select(source, customer, includeTextDense: true);
    expect(items, hasLength(2));
    expect(
        items.every(
            (r) => selector.mayRetainAttachmentPreview(source, customer, r)),
        isTrue);
    expect(
        items.map((r) => selector.sentAtForRegion(source, customer, r)).toSet(),
        {at});
  });

  test(
      'even uncertain hi is masked for native text-bubble rejection, not missing text',
      () {
    const hi = OcrObservation(
        text: 'hi', confidence: .15, x: .27, y: .38, width: .04, height: .02);
    expect(selector.previewTextRegions(scan(body: [hi]), region), hasLength(1));
    const small =
        OcrVisualRegion(x: .25, y: .35, width: .10, height: .07, confidence: 1);
    expect(
        selector.mayRetainAttachmentPreview(
            scan(body: [
              const OcrObservation(
                  text: 'hello',
                  confidence: .9,
                  x: .26,
                  y: .37,
                  width: .08,
                  height: .025)
            ], regions: [
              small
            ]),
            customer,
            small),
        isFalse);
  });

  test(
      'read-only preview passes ownership, source clock and text masks to native',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'captureImageRegion');
      final args = call.arguments as Map;
      expect(args['expectedCustomer'], customer);
      expect(args['expectedMediaAtMs'], at.millisecondsSinceEpoch);
      expect(args['allowAttachmentPreview'], isA<bool>());
      expect(args['allowMessageReferenceLookup'], isFalse);
      expect(args['allowActivationForVideoDetection'], isFalse);
      return {
        'kind': 'attachment_preview',
        'mimeType': 'image/png',
        'dataBase64': base64Encode([7, 8, 9]),
        'captureSource': 'verified-window-preview',
        'verifiedCustomerId': customer,
        'ownershipVerification': 'visible_customer_region'
      };
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    final payload = await adapter.captureCachedMediaRegion(
        expectedCustomer: customer,
        windowId: 21203,
        region: region,
        sourceInspection: scan(),
        expectedMediaAt: at,
        sourceSenderY: .30,
        allowAttachmentPreview: true);
    expect(payload!.kind, 'attachment_preview',
        reason: 'Do not call a possible video poster an image original');
    expect(payload.bytes, [7, 8, 9]);
    await expectLater(
        adapter.captureCachedMediaRegion(
            expectedCustomer: customer,
            windowId: 21203,
            region: region,
            sourceInspection: scan(),
            expectedMediaAt: at,
            sourceSenderY: .30),
        throwsA(isA<PlatformException>()));
  });

  test(
      'preview rescan, new timestamp, second attachment and original upgrade are separate',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_preview_events_');
    addTearDown(() => root.delete(recursive: true));
    var store = ConversationFileStore(root);
    Future<CapturedMessage> item(String owner, DateTime clock, int slot,
        {bool original = false, int revision = 1}) async {
      final key = uploadEventKey(clock, slot);
      final path = await store.saveMedia(
          userId: owner,
          filename: 'preview-$revision.png',
          bytes: [slot, revision]);
      return CapturedMessage(
          stableId: original
              ? 'visible-image:original:${clock.millisecondsSinceEpoch}:$slot'
              : 'preview:$key',
          direction: 'incoming',
          sender: owner,
          sentAt: clock,
          body: original
              ? '[Customer sent an image]'
              : '[Customer sent an attachment; visible preview captured]',
          axPath: 'test',
          media: [
            CapturedMedia(
                type: 'image',
                path: path,
                sourceEventKey: key,
                contentSha256: original ? 'original' : 'preview',
                captureSource:
                    original ? 'jd_image_cache' : 'verified_attachment_preview',
                isPartial: !original,
                verifiedCustomerId: owner)
          ]);
    }

    Future<CaptureAppendResult> save(String owner, CapturedMessage message) =>
        store.appendCapture(CapturedConversation(
            stableKey: 'customer:$owner',
            customerName: owner,
            customerExternalId: owner,
            verifiedCustomerId: owner,
            messages: [message],
            capturedAt: at));
    final preview = await item(customer, at, 0);
    expect((await save(customer, preview)).insertedIncomingIds,
        [preview.stableId]);
    for (var n = 2; n < 8; n++) {
      expect(
          (await save(customer, await item(customer, at, 0, revision: n)))
              .changed,
          0);
    }
    expect(await store.hasAcquiredImageEvent(customer, uploadEventKey(at, 0)),
        isFalse,
        reason: 'A preview must not suppress the original');
    expect((await save(customer, await item(customer, at, 1))).changed, 1);
    final later = at.add(const Duration(hours: 1));
    expect((await save(customer, await item(customer, later, 0))).changed, 1);
    expect((await save(other, await item(other, at, 0))).changed, 1);
    final original = await item(customer, at, 0, original: true);
    final upgrade = await save(customer, original);
    expect(upgrade.insertedIncomingIds, [preview.stableId]);
    expect((await store.read(customer))!['messages'], hasLength(3));
    store = ConversationFileStore(root); // restart
    expect((await save(customer, original)).changed, 0);
    expect((await save(customer, preview)).changed, 0);
    expect(await store.hasAcquiredImageEvent(customer, uploadEventKey(at, 0)),
        isTrue);
    expect(
        await store.hasCapturedMediaEvent(customer, 'image', 'original',
            sentAt: at),
        isTrue);
    final messages = (await store.read(customer))!['messages'] as List;
    expect((messages.first['media'] as List).single['is_partial'], isFalse);
    expect((await store.read(other))!['messages'], hasLength(1));
    expect(customerAuthoredText(preview.body), isEmpty);
  });
}
