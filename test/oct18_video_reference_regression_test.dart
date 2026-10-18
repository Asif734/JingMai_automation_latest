import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/ocr_media_mask.dart';
import 'package:jd_automation/capture/unread_capture_recovery.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const customer = 'jd_41aeec7741d05';
const selector = OcrImageCandidateSelector();
const full =
    OcrVisualRegion(x: .26, y: .30, width: .22, height: .32, confidence: 1);
const inner =
    OcrVisualRegion(x: .30, y: .42, width: .08, height: .078, confidence: 1);
final clock = DateTime.utc(2026, 10, 18, 3, 58);

OcrObservation line(String text, double y,
        {double x = .27, double width = .20, double confidence = 1}) =>
    OcrObservation(
        text: text,
        confidence: confidence,
        x: x,
        y: y,
        width: width,
        height: .02);
OcrInspection view({
  String owner = customer,
  String senderClock = '11:57:55',
  double shift = 0,
  int window = 21203,
  int imageWidth = 2940,
  List<OcrVisualRegion> regions = const [full],
  List<OcrObservation> extra = const [],
  DateTime? capturedAt,
}) =>
    OcrInspection(
        image: Uint8List(0),
        imageWidth: imageWidth,
        imageHeight: 1722,
        windowId: window,
        windowTitle: '咚咚融合工作台',
        recognizedText: '',
        activeCustomerId: owner,
        capturedAt: capturedAt ?? clock,
        chatLeft: .18,
        chatRight: .8,
        chatBottom: .9,
        visualRegions: regions,
        observations: [
          line('$customer $senderClock', .25 + shift),
          line('OQE)DLI-A.fiD,O', .44 + shift, x: .305, width: .07),
          ...extra
        ]);

void main() {
  test('shrinking Vision rectangle cannot promote video control OCR to text',
      () {
    final masks = OcrMediaMasks()..remember(view(), customer, full);
    final fresh = view(regions: [inner]);
    expect(
        selector.looksLikeShortTypedBubble(inner, fresh.observations), isTrue,
        reason: 'reproduces the button-row false typed-bubble classification');
    expect(
        const OcrCaptureExtractor()
            .analyze(fresh)
            .capture!
            .messages
            .single
            .body,
        'OQE)DLI-A.fiD,O');
    final restored = masks.restoreCandidates(fresh, customer,
        selector.select(fresh, customer, includeTextDense: true));
    expect(restored.single.height, closeTo(.32, .00001));
    expect(
        selector.looksLikeShortTypedBubble(restored.single, fresh.observations),
        isFalse);
    masks.remember(fresh, customer, inner);
    expect(masks.regions(fresh, customer).single.height, closeTo(.32, .00001));
    expect(
        const OcrCaptureExtractor()
            .analyze(fresh,
                excludedMediaRegions: masks.regions(fresh, customer))
            .capture,
        isNull);
  });

  test('mask follows fresh sender position, never old screen y', () {
    final masks = OcrMediaMasks()..remember(view(), customer, full);
    final moved = view(shift: -.05, regions: const [
      OcrVisualRegion(x: .30, y: .37, width: .08, height: .078, confidence: 1)
    ], extra: [
      line('$customer 11:58:26', .72),
      line('what is inside this video?', .77)
    ]);
    final mask = masks.regions(moved, customer).single;
    expect(mask.y, closeTo(.25, .00001));
    final capture = const OcrCaptureExtractor()
        .analyze(moved, excludedMediaRegions: [mask]).capture!;
    expect(capture.messages.map((m) => m.body), ['what is inside this video?']);
  });

  test('separate real text at the same second as video is preserved', () {
    final first =
        view(extra: [line('$customer 11:57:55', .72), line('check this', .77)]);
    final masks = OcrMediaMasks()..remember(first, customer, full);
    final fresh = view(
        regions: [inner],
        extra: [line('$customer 11:57:55', .72), line('check this', .77)]);
    expect(selector.customerBlocks(fresh, customer).map((b) => b.sameTimeIndex),
        [0, 1]);
    final capture = const OcrCaptureExtractor()
        .analyze(fresh, excludedMediaRegions: masks.regions(fresh, customer))
        .capture!;
    expect(capture.messages.map((m) => m.body), ['check this']);
  });

  test('missing same-second sender block is ambiguous, not reassigned', () {
    final original =
        view(extra: [line('$customer 11:57:55', .72), line('check this', .77)]);
    final masks = OcrMediaMasks()..remember(original, customer, full);
    expect(masks.regions(view(), customer), isEmpty);
  });

  test('11:56:18 check-this preceding video is not swallowed by video mask',
      () {
    const attachment =
        OcrVisualRegion(x: .26, y: .43, width: .22, height: .32, confidence: 1);
    final original = OcrInspection(
        image: Uint8List(0),
        imageWidth: 2940,
        imageHeight: 1722,
        windowId: 21203,
        windowTitle: 'JD',
        recognizedText: '',
        activeCustomerId: customer,
        capturedAt: clock,
        chatLeft: .18,
        chatRight: .8,
        chatBottom: .9,
        visualRegions: const [
          attachment
        ],
        observations: [
          line('$customer 11:56:18', .25),
          line('check this', .30),
          line('$customer 11:56:18', .38),
          line('OQE)DLI-A.fiD,O', .55, x: .305, width: .07)
        ]);
    final masks = OcrMediaMasks()..remember(original, customer, attachment);
    final capture = const OcrCaptureExtractor()
        .analyze(original,
            excludedMediaRegions: masks.regions(original, customer))
        .capture!;
    expect(capture.messages.map((m) => m.body), ['check this']);
  });

  test('missing Vision rectangle keeps mask but cannot authorize a click', () {
    final masks = OcrMediaMasks()..remember(view(), customer, full);
    final fresh = view(regions: []);
    expect(masks.regions(fresh, customer), hasLength(1));
    expect(masks.restoreCandidates(fresh, customer, []), isEmpty);
    expect(
        const OcrCaptureExtractor()
            .analyze(fresh,
                excludedMediaRegions: masks.regions(fresh, customer))
            .capture,
        isNull);
  });

  test('two disjoint uploads retain two independent masks', () {
    const first =
        OcrVisualRegion(x: .26, y: .30, width: .22, height: .20, confidence: 1);
    const second =
        OcrVisualRegion(x: .26, y: .57, width: .22, height: .20, confidence: 1);
    final original = view(regions: [first, second]);
    final masks = OcrMediaMasks()
      ..remember(original, customer, first)
      ..remember(original, customer, second);
    final candidates = masks.restoreCandidates(original, customer, const [
      OcrVisualRegion(x: .30, y: .34, width: .06, height: .08, confidence: 1),
      OcrVisualRegion(x: .30, y: .60, width: .06, height: .08, confidence: 1)
    ]);
    expect(candidates.map((r) => r.y), [.30, .57]);
  });

  test('mask cannot cross a later sender after a new seller reply', () {
    final masks = OcrMediaMasks()..remember(view(), customer, full);
    final fresh = view(extra: [
      line('格志打印机小甘 11:58:03', .51),
      line('A seller reply', .56, x: .55)
    ]);
    final mask = masks.regions(fresh, customer).single;
    expect(mask.y + mask.height, lessThan(.51));
    final capture = const OcrCaptureExtractor()
        .analyze(fresh, excludedMediaRegions: [mask]).capture!;
    expect(capture.messages.single.body, 'A seller reply');
    expect(capture.messages.single.direction, 'outgoing');
  });

  for (final entry in <String, OcrInspection Function()>{
    'different customer': () => view(owner: 'jd_frqocwtljjob'),
    'different window': () => view(window: 99),
    'resized window': () => view(imageWidth: 2000),
    'new message timestamp': () => view(senderClock: '11:57:56'),
    'expired footprint': () =>
        view(capturedAt: clock.add(const Duration(minutes: 11))),
    'older snapshot': () =>
        view(capturedAt: clock.subtract(const Duration(seconds: 1))),
  }.entries) {
    test('${entry.key} cannot inherit another event media mask', () {
      final masks = OcrMediaMasks()..remember(view(), customer, full);
      expect(masks.regions(entry.value(), customer), isEmpty);
    });
  }

  final welcome = <String, dynamic>{
    'direction': 'outgoing',
    'source': 'generated_reply',
    'sender': 'jd-transfer-welcome-v1',
    'body': '您好，欢迎来到Grozziie客服。请问有什么可以帮您？',
    'delivery_status': 'sent',
    'sent_at': DateTime.utc(2026, 10, 18, 3, 55, 13).toIso8601String()
  };
  UnreadCaptureRecovery recovery() => UnreadCaptureRecovery(
      customer: customer,
      detectedAt: DateTime.utc(2026, 10, 18, 3, 55, 12, 560),
      unreadEvidence: 1,
      sidebarUnreadVerified: true,
      knownIncomingIds: {},
      knownOutgoingIds: {});

  test('11:55 handover welcome closes badge-only phantom holding job', () {
    final r = recovery();
    expect(r.acceptsGeneratedReply(welcome, [welcome]), isTrue);
    expect(
        r.acceptsGeneratedReply(
            {...welcome, 'delivery_status': 'delivery_unknown'}, []),
        isFalse);
    expect(
        r.acceptsGeneratedReply({
          ...welcome,
          'sent_at': DateTime.utc(2026, 10, 18, 3, 55, 11).toIso8601String()
        }, []),
        isFalse);
    r.verifyIncomingSignal(
        senderKey: 'how-are-you',
        sentAt: DateTime.utc(2026, 10, 18, 3, 55, 38),
        capturedAt: DateTime.utc(2026, 10, 18, 3, 55, 39));
    expect(r.acceptsGeneratedReply(welcome, [welcome]), isFalse);
    expect(r.holdingDue(DateTime.utc(2026, 10, 18, 3, 55, 57)), isFalse);
    expect(r.holdingDue(DateTime.utc(2026, 10, 18, 3, 55, 58)), isTrue);
  });

  test('welcome cannot discharge unresolved video or substantive text', () {
    expect(recovery().acceptsGeneratedReply(welcome, [], pendingMedia: true),
        isFalse);
    final incoming = <String, dynamic>{
      'id': 'new',
      'direction': 'incoming',
      'sent_at': DateTime.utc(2026, 10, 18, 3, 55, 10).toIso8601String(),
      'captured_at': DateTime.utc(2026, 10, 18, 3, 55, 14).toIso8601String(),
      'body': 'help with paper'
    };
    expect(recovery().acceptsGeneratedReply(welcome, [incoming, welcome]),
        isFalse);
    expect(
        recovery().acceptsGeneratedReply(welcome, [
          {...incoming, 'body': 'hi'},
          welcome
        ]),
        isTrue);
    expect(
        recovery().acceptsGeneratedReply(welcome, [
          {
            ...incoming,
            'body': 'hi',
            'sent_at': DateTime.utc(2026, 10, 18, 3, 55, 15).toIso8601String()
          },
          welcome
        ]),
        isFalse);
  });

  test('native message hit verification uses AX, not topmost window rectangle',
      () {
    final source =
        File('macos/Runner/AccessibilityBridge.swift').readAsStringSync();
    final verification = source.substring(
        source.indexOf('func foreground(at point:'),
        source.indexOf('if !foreground(at: point)'));
    expect(verification, contains('AXUIElementCopyElementAtPosition'));
    expect(verification, contains('AXUIElementGetPid'));
    expect(verification, contains('CFEqual(current, receptionWindow)'));
    expect(verification, isNot(contains('CGWindowListCopyWindowInfo')));
  });
}
