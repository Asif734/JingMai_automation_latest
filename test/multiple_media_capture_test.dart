import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/media_identity.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

void main() {
  const selector = OcrImageCandidateSelector();
  const customer = 'jd_41aeec7741d05';
  OcrObservation label(String text, double y) => OcrObservation(
      text: text, confidence: 1, x: .2, y: y, width: .2, height: .02);
  OcrInspection inspection(
          List<OcrObservation> labels, List<OcrVisualRegion> regions) =>
      OcrInspection(
          image: Uint8List(0),
          imageWidth: 1600,
          imageHeight: 1200,
          windowTitle: 'JD',
          recognizedText: '',
          activeCustomerId: customer,
          capturedAt: DateTime.utc(2026, 10, 16, 4, 27, 26),
          chatLeft: .18,
          chatRight: .8,
          chatBottom: .9,
          observations: labels,
          visualRegions: regions);

  test('selects all disjoint media, not nested play/text rectangles', () {
    final view = inspection([
      label('$customer 12:27:20', .25),
      label('格志打印机小甘 12:27:22', .8)
    ], const [
      OcrVisualRegion(x: .2, y: .30, width: .25, height: .17, confidence: 1),
      OcrVisualRegion(x: .25, y: .33, width: .08, height: .08, confidence: 1),
      OcrVisualRegion(x: .2, y: .55, width: .25, height: .20, confidence: 1),
      OcrVisualRegion(x: .2, y: .83, width: .25, height: .06, confidence: 1),
    ]);
    final candidates = selector.select(view, customer, includeTextDense: true);
    expect(candidates.map((r) => r.y).toSet(), {.30, .55});
    expect(
        candidates.every((r) =>
            selector.sentAtForRegion(view, customer, r) ==
            DateTime.utc(2026, 10, 16, 4, 27, 20)),
        isTrue);
    expect(selector.select(view, 'jd_another123', includeTextDense: true),
        isEmpty);
    expect(
        selector.select(
            inspection([label(customer, .05)], view.visualRegions), customer),
        isEmpty);
  });
  for (final type in ['image', 'video']) {
    test(
        '$type already captured newest event cannot hide earlier uncaptured media',
        () async {
      final root = await Directory.systemTemp.createTemp('jd_multiple_media_');
      addTearDown(() => root.delete(recursive: true));
      final store = ConversationFileStore(root);
      final path = await store.saveMedia(
          userId: customer, filename: 'same.$type', bytes: [1, 2, 3]);
      final view = inspection([
        label('$customer 12:27:20', .25),
        label('$customer 12:27:21', .56)
      ], const [
        OcrVisualRegion(x: .2, y: .30, width: .2, height: .20, confidence: 1),
        OcrVisualRegion(x: .2, y: .61, width: .2, height: .15, confidence: 1)
      ]);
      Future<int> save(DateTime at) async {
        if (await store.hasCapturedMediaEvent(customer, type, 'same-hash',
            sentAt: at)) {
          return 0;
        }
        final result = await store.appendCapture(CapturedConversation(
            stableKey: 'customer:$customer',
            customerName: customer,
            customerExternalId: customer,
            verifiedCustomerId: customer,
            capturedAt: view.capturedAt,
            messages: [
              CapturedMessage(
                  stableId: mediaMessageStableId(type, 'same-hash', at),
                  direction: 'incoming',
                  body: '[Customer sent a $type]',
                  sender: customer,
                  sentAt: at,
                  axPath: 'test',
                  media: [
                    CapturedMedia(
                        type: type, path: path, verifiedCustomerId: customer)
                  ])
            ]));
        return result.insertedIncomingIds.length;
      }

      final newest = DateTime.utc(2026, 10, 16, 4, 27, 21);
      expect(await save(newest), 1);
      var inserted = 0;
      for (final region
          in selector.select(view, customer, includeTextDense: true)) {
        inserted +=
            await save(selector.sentAtForRegion(view, customer, region)!);
      }
      expect(inserted, 1);
      expect((await store.read(customer))!['messages'], hasLength(2));
      // A restart skips both prior events but accepts another new timestamp.
      final restarted = ConversationFileStore(root);
      expect(
          await restarted.hasCapturedMediaEvent(customer, type, 'same-hash',
              sentAt: newest),
          isTrue);
      expect(await save(newest.add(const Duration(seconds: 1))), 1);
      expect((await store.read(customer))!['messages'], hasLength(3));
      expect(
          await restarted.hasCapturedMediaEvent(
              'jd_another123', type, 'same-hash',
              sentAt: newest),
          isFalse);
    });
  }
}
