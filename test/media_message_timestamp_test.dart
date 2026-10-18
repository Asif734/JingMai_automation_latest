import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/jd_message_timestamp.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/domain/media_identity.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  const customer = 'jd_41aeec7741d05';
  const selector = OcrImageCandidateSelector();
  const media =
      OcrVisualRegion(x: .18, y: .30, width: .20, height: .26, confidence: 1);
  OcrObservation label(String text, double x, double y) => OcrObservation(
      text: text, confidence: 1, x: x, y: y, width: .15, height: .02);
  OcrInspection inspection(List<OcrObservation> observations,
          {DateTime? polledAt}) =>
      OcrInspection(
        image: Uint8List(0),
        imageWidth: 1600,
        imageHeight: 1300,
        windowTitle: '咚咚融合工作台',
        recognizedText: '',
        activeCustomerId: customer,
        chatLeft: .15,
        chatRight: .72,
        chatBottom: .9,
        capturedAt: polledAt ?? DateTime.utc(2026, 10, 16, 3, 27),
        observations: observations,
      );

  test('media owns its timestamp, not a following text or seller timestamp',
      () {
    final view = inspection([
      label('$customer 11:26:07', .18, .25),
      label('格志打印机小甘 11:26:30', .50, .60),
      label('$customer 11:26:32', .18, .75),
    ]);
    expect(selector.sentAtForRegion(view, customer, media),
        DateTime.utc(2026, 10, 16, 3, 26, 7));
  });

  test('separately OCRed sender clock stays stable across polling', () {
    final observations = [
      label(customer, .18, .25),
      label('11:24:27', .37, .25)
    ];
    final first =
        selector.sentAtForRegion(inspection(observations), customer, media);
    final later = selector.sentAtForRegion(
        inspection(observations, polledAt: DateTime.utc(2026, 10, 16, 3, 55)),
        customer,
        media);
    expect(first, DateTime.utc(2026, 10, 16, 3, 24, 27));
    expect(later, first);
  });

  test('missing or conflicting media clocks never use polling or later text',
      () {
    for (final clocks in [
      <OcrObservation>[],
      [label('11:26:07', .37, .25), label('11:26:08', .53, .25)]
    ]) {
      final view = inspection([
        label(customer, .18, .25),
        ...clocks,
        label('$customer 11:26:32', .18, .75)
      ]);
      expect(selector.sentAtForRegion(view, customer, media), isNull);
    }
    expect(
        selector.sentAtForRegion(
            inspection([
              label('$customer 11:24:27', .18, .18),
              label('格志打印机小甘 11:24:37', .45, .25),
            ]),
            customer,
            media),
        isNull);
  });

  test('month/day JD labels preserve the original day instead of today', () {
    final view = inspection([label('$customer 10-12 17:08:30', .18, .25)]);
    expect(selector.sentAtForRegion(view, customer, media),
        DateTime.utc(2026, 10, 12, 9, 8, 30));
    expect(parseJdMessageTimestamp('2026-09-24 16:16:16', view.capturedAt),
        DateTime.utc(2026, 9, 24, 8, 16, 16));
  });

  test('JD clock rollover and invalid clocks are explicit', () {
    expect(
        parseJdMessageTimestamp(
            '23:59:58', DateTime.utc(2026, 10, 15, 16, 0, 5)),
        DateTime.utc(2026, 10, 15, 15, 59, 58));
    expect(parseJdMessageTimestamp('12-31 23:59:58', DateTime.utc(2027, 1, 1)),
        DateTime.utc(2026, 12, 31, 15, 59, 58));
    for (final invalid in [
      '25:00:00',
      '11:67:00',
      '11:26:99',
      '2026-02-30 11:00:00'
    ]) {
      expect(
          parseJdMessageTimestamp(invalid, DateTime.utc(2026, 10, 16)), isNull);
    }
  });

  test('new send second creates a new ID; timezone and subsecond jitter do not',
      () {
    final first = DateTime.utc(2026, 10, 16, 3, 26, 7);
    final id = mediaMessageStableId('video', 'same-digest', first);
    expect(
        mediaMessageStableId('video', 'same-digest',
            DateTime.parse('2026-10-16T11:26:07+08:00')),
        id);
    expect(
        mediaMessageStableId('video', 'same-digest',
            first.add(const Duration(milliseconds: 100))),
        id);
    expect(
        mediaMessageStableId(
            'video', 'same-digest', first.add(const Duration(seconds: 1))),
        isNot(id));
    expect(sameMediaMessageTime(first, null), isTrue);
    expect(sameMediaMessageTime(null, first), isFalse);
  });
}
