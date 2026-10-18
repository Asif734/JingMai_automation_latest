import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const customer = 'jd_41aeec7741d05';

OcrInspection inspection(
  String sender, {
  String? ax = customer,
  String? source = 'ax_header_before_and_after',
  double confidence = 1,
  double senderX = .22,
}) =>
    OcrInspection(
      image: Uint8List(0),
      imageWidth: 1600,
      imageHeight: 1200,
      windowTitle: 'JD',
      recognizedText: sender,
      capturedAt: DateTime.utc(2026, 10, 15, 10, 29, 30),
      activeCustomerId: ax,
      activeCustomerIdentitySource: source,
      chatLeft: .20,
      chatRight: .70,
      chatBottom: .90,
      observations: [
        OcrObservation(
            text: sender,
            confidence: confidence,
            x: senderX,
            y: .35,
            width: .20,
            height: .02),
        const OcrObservation(
            text: 'for setting up shift',
            confidence: 1,
            x: .23,
            y: .40,
            width: .20,
            height: .02),
      ],
      visualRegions: const [
        OcrVisualRegion(x: .23, y: .46, width: .20, height: .20, confidence: 1)
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final typo in [
    'jd_4laeec7741d05',
    'jd_41aeec7741d5',
    'jd_41aeec7741dd05'
  ]) {
    test('AX and unique saved ID recover sender and media ownership: $typo',
        () {
      final raw = inspection('$typo 18:29:28');
      expect(const OcrCaptureExtractor().analyze(raw).capture, isNull);
      final corrected =
          raw.reconcileCustomerSenderLabels({customer, 'jd_unrelated123'});
      expect(corrected.observations.first.text, '$customer 18:29:28');
      final capture = const OcrCaptureExtractor().extract(corrected)!;
      expect(capture.customerExternalId, customer);
      expect(capture.verifiedCustomerId, customer);
      expect(capture.messages.single.sender, customer);
      expect(capture.messages.single.body, 'for setting up shift');
      expect(const OcrImageCandidateSelector().select(corrected, customer),
          hasLength(1));
      expect(
          const OcrImageCandidateSelector()
              .select(corrected, 'jd_unrelated123'),
          isEmpty);
      // No permanent alias, raw OCR, body, coordinates or pixels are changed.
      expect(raw.observations.first.text, '$typo 18:29:28');
      expect(corrected.observations.last, same(raw.observations.last));
      expect(corrected.image, same(raw.image));
    });
  }

  test('exact IDs and malformed sender text cannot be fuzzily redirected', () {
    for (final label in [
      'jd_41aeec7741d05 18:29:28',
      'jd_41aeec7741d05z 18:29:28',
      'jd_41aeec7741d5 ...',
      'please ask jd_41aeec7741d5',
      '上海世亦小闭',
      'jd_41aeec7741d5 arbitrary suffix',
      'jd_4laeec774ld05 18:29:28'
    ]) {
      expect(
          reconcileOcrCustomerSenderLabel(
              observedLabel: label,
              verifiedAxCustomer: customer,
              trustedCustomers: {customer, 'jd_41aeec7741d05z'}),
          label);
    }
    expect(customerIdentitiesMatch('jd_4laeec7741d05', customer), isFalse);
  });

  test(
      'ambiguous saved identities, known other accounts and conflicting AX stay separate',
      () {
    expect(
        reconcileOcrCustomerSenderLabel(
            observedLabel: 'jd_abcdefgh 18:29:28',
            verifiedAxCustomer: 'jd_abcdefgi',
            trustedCustomers: {'jd_abcdefgi', 'jd_abcdefgj'}),
        'jd_abcdefgh 18:29:28');
    const other = 'jd_4laeec7741d05';
    expect(
        reconcileOcrCustomerSenderLabel(
            observedLabel: '$other 18:29:28',
            verifiedAxCustomer: customer,
            trustedCustomers: {customer, other}),
        '$other 18:29:28');
    expect(
        reconcileOcrCustomerSenderLabel(
            observedLabel: '$other 18:29:28',
            verifiedAxCustomer: 'jd_unrelated123',
            trustedCustomers: {customer, 'jd_unrelated123'}),
        '$other 18:29:28');
  });

  test(
      'repair requires saved owner, explicit AX provenance, confidence and transcript geometry',
      () {
    const raw = 'jd_4laeec7741d05 18:29:28';
    for (final input in [
      inspection(raw, ax: null),
      inspection(raw, source: null),
      inspection(raw, source: 'ocr'),
      inspection(raw, confidence: .2),
      inspection(raw, senderX: .01)
    ]) {
      expect(
          input
              .reconcileCustomerSenderLabels({customer})
              .observations
              .first
              .text,
          raw);
    }
    expect(
        inspection(raw)
            .reconcileCustomerSenderLabels({})
            .observations
            .first
            .text,
        raw);
  });

  test(
      'live adapter applies AX/saved reconciliation before extraction and media selection',
      () async {
    const channel = MethodChannel('jd.ax.sender.recovery-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'inspectOCR');
      return {
        'activeCustomerId': customer,
        'activeCustomerIdentitySource': 'ax_header_before_and_after',
        'chatRegion': {'left': .2, 'right': .7, 'bottom': .9},
        'observations': [
          {
            'text': 'jd_41aeec7741d5 18:29:28',
            'confidence': 1,
            'x': .22,
            'y': .35,
            'width': .20,
            'height': .02
          }
        ]
      };
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final adapter = MacOSCaptureAdapter(
        channel: channel, trustedCustomerIds: () async => {customer});
    addTearDown(adapter.close);
    final result = await adapter.inspectExpectedCustomer(
        windowId: 1, expectedCustomer: customer);
    expect(result.observations.single.text, '$customer 18:29:28');
    // Send/capture verification still uses exact AX identities, not edit distance.
    expect(result.activeCustomerId, customer);
  });
}
