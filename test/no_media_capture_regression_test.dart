import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/ocr_media_mask.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/runtime/ui_operation_scheduler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'jd_41aeec7741d05';
  const other = 'jd_6c67c99371fa4';
  const channel = MethodChannel('test/no-media-capture');
  const selector = OcrImageCandidateSelector();
  const region = OcrVisualRegion(
      x: .235, y: .689, width: .369, height: .151, confidence: .9);
  final at = DateTime.utc(2026, 10, 18, 7, 39, 56);
  OcrInspection scan(String text, {bool rectangle = false}) => OcrInspection(
      image: Uint8List.fromList([1, 2, 3]),
      imageWidth: 2940,
      imageHeight: 1722,
      windowId: 21203,
      windowTitle: '咚咚融合工作台',
      recognizedText: '',
      activeCustomerId: customer,
      capturedAt: at.add(const Duration(seconds: 3)),
      chatLeft: .235,
      chatRight: .604,
      chatBottom: .90,
      observations: [
        const OcrObservation(
            text: '$customer 15:39:56',
            confidence: 1,
            x: .24,
            y: .65,
            width: .3,
            height: .025),
        if (text.isNotEmpty)
          OcrObservation(
              text: text,
              confidence: .9,
              x: .25,
              y: .72,
              width: .045,
              height: .02),
      ],
      visualRegions: rectangle ? [region] : []);
  void mock(Future<Object?> Function(MethodCall) handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  for (final text in ['hi', 'no', 'ok', '好', '是', 'A', '1']) {
    test('short text "$text" cannot create a blank-block fallback', () {
      final source = scan(text);
      expect(selector.fallbackLatestCustomerBlock(source, customer), isNull);
      expect(
          const OcrCaptureExtractor()
              .analyze(source)
              .capture!
              .messages
              .single
              .body,
          text);
      expect(selector.hasReadableText(region, source.observations), isTrue);
    });
  }

  test('15:39:56 hi stays text even inside an oversized Vision rectangle', () {
    final source = scan('hi', rectangle: true);
    expect(selector.select(source, customer, includeTextDense: true),
        hasLength(1));
    expect(selector.hasReadableText(region, source.observations), isTrue,
        reason:
            'A clock-only cache match must not assign a video to this text');
    expect(selector.fallbackLatestCustomerBlock(source, customer), isNull);
    expect(
        const OcrCaptureExtractor()
            .analyze(source)
            .capture!
            .messages
            .single
            .body,
        'hi');
  });

  test('an empty preview may still use read-only cache discovery', () {
    final source = scan('');
    expect(selector.fallbackLatestCustomerBlock(source, customer), isNotNull);
    expect(selector.hasReadableText(region, source.observations), isFalse);
  });

  for (final reason in [
    'media_original_not_verified',
    'video_cache_visual_not_matched',
    'video_cache_match_ambiguous',
    'video_cache_decode_failed',
    'video_cache_check_timeout',
    'image_cache_changed_during_copy',
    'video_cache_invalid_original',
  ]) {
    test('$reason is an empty result; next customer can send', () async {
      final calls = <String>[];
      final entered = Completer<void>(), release = Completer<void>();
      mock((call) async {
        calls.add(call.method);
        final args = call.arguments as Map;
        if (call.method == 'captureImageRegion') {
          expect(args['expectedCustomer'], customer);
          expect(args['allowActivationForVideoDetection'], isFalse);
          expect(args['allowMessageReferenceLookup'], isFalse);
          entered.complete();
          await release.future;
          return {'error': reason};
        }
        expect(call.method, 'sendDraftOnce');
        expect(args['expectedCustomer'], other);
        return {'sent': true, 'customer': other, 'reply': 'Hello'};
      });
      final adapter = MacOSCaptureAdapter(channel: channel);
      addTearDown(adapter.close);
      final queue = UiOperationScheduler(
          beginNative: (_) async {},
          endNative: (_) async {},
          cancelNative: (_) async {});
      addTearDown(queue.close);
      final media = queue.schedule(
          () => adapter.captureCachedMediaRegion(
              expectedCustomer: customer,
              windowId: 21203,
              region: region,
              sourceInspection: scan('hi', rectangle: true),
              expectedMediaAt: at),
          customer: customer,
          priority: UiPriority.capture);
      await entered.future;
      final reply = queue.schedule(
          () => adapter.sendDraftOnce(expectedCustomer: other, reply: 'Hello'),
          customer: other,
          priority: UiPriority.originalReply);
      release.complete();
      expect(await media, isNull);
      await reply;
      expect(calls, ['captureImageRegion', 'sendDraftOnce']);
      expect(queue.pendingCount, 0);
      final masks = OcrMediaMasks();
      expect(masks.regions(scan('hi'), customer), isEmpty);
    });
  }

  test('a miss does not discard later verified image and video originals',
      () async {
    var index = 0;
    mock((call) async {
      expect(call.method, 'captureImageRegion');
      index++;
      if (index == 1) return {'error': 'media_original_not_verified'};
      return {
        'kind': index == 2 ? 'image' : 'video',
        'verifiedCustomerId': customer,
        'ownershipVerification': 'visible_customer_region',
        'captureSource':
            index == 2 ? 'jd-image-cache' : 'verified-video-cache-reference',
        if (index == 2) 'dataBase64': base64Encode([8, 9, 10]),
        if (index == 3) 'cacheReferenceToken': 'verified-original',
      };
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    final originals = <VisibleImagePayload>[];
    for (var n = 0; n < 3; n++) {
      final original = await adapter.captureCachedMediaRegion(
          expectedCustomer: customer,
          windowId: 21203,
          region: region,
          sourceInspection: scan(''),
          expectedMediaAt: at);
      if (original != null) originals.add(original);
    }
    expect(originals.map((p) => p.kind), ['image', 'video']);
    expect(originals.first.bytes, [8, 9, 10]);
    expect(originals.last.cacheReferenceToken, 'verified-original');
  });

  test('cache miss handling cannot swallow ownership or snapshot failures',
      () async {
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    for (final reason in [
      'media_owner_unverified',
      'media_snapshot_changed',
      'media_customer_changed_during_cache_check'
    ]) {
      mock((_) async => {'error': reason});
      await expectLater(
          adapter.captureCachedMediaRegion(
              expectedCustomer: customer,
              windowId: 21203,
              region: region,
              sourceInspection: scan('hi'),
              expectedMediaAt: at),
          throwsA(
              isA<PlatformException>().having((e) => e.code, 'code', reason)));
    }
  });

  test(
      'automatic capture has no menu-export or speculative upload registration',
      () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('.beginAttachmentDownload(')));
    expect(main, isNot(contains('_beginAttachmentFallback(')));
    expect(main, isNot(contains('_observeVisibleUploads(')));
    final loop = main.substring(main.indexOf('final mediaSlots ='),
        main.indexOf("inspectedMediaSources.add(visible.captureSource"));
    expect(loop.indexOf('_captureDirectCachedVideo('),
        lessThan(loop.indexOf('_recordVerifiedUpload(')));
    expect(loop, contains('if (visible == null)'));
    expect(loop, isNot(contains('_ocrMediaMasks.remember(')));
    expect(loop, isNot(contains('_mediaAcquisitions.observe(')));
  });
}
