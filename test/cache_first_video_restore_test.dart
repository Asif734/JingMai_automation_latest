import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_acquisition.dart';
import 'package:jd_automation/capture/video_capture_queue.dart';
import 'package:jd_automation/codex/customer_media_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/cache_video_claims.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/cache-first-video-restore');
  final at = DateTime.utc(2026, 10, 18, 4, 32, 4);
  const customer = 'jd_41aeec7741d05';
  const directory = '/private/media/jd_41aeec7741d05/videos';
  Map<String, Object?> payload() => {
        'kind': 'video',
        'verifiedCustomerId': customer,
        'ownershipVerification': 'exact_customer_unique_cache_clock',
        'expectedMediaAtMs': at.millisecondsSinceEpoch,
        'path': '$directory/hash.mp4',
        'cacheKey': 'cache-entry-mtime-size',
        'originalName': '866add99731343efa7a43b6794667e40.mp4',
        'mimeType': 'video/mp4',
        'createdCopy': true,
      };

  for (final background in ['white', 'black', 'normal']) {
    test(
        '$background video uses cache originals without screenshot or menu calls',
        () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        expect(call.method, 'captureRecentCachedVideo');
        final args = call.arguments! as Map;
        expect(args['expectedCustomer'], customer);
        expect(args['expectedMediaAtMs'], at.millisecondsSinceEpoch);
        expect(args['windowId'], 21203);
        expect(args.containsKey('sourcePngBase64'), isFalse);
        expect(args['competingMessageTimesMs'],
            [at.subtract(const Duration(seconds: 33)).millisecondsSinceEpoch]);
        return payload();
      });
      final adapter = MacOSCaptureAdapter(channel: channel);
      addTearDown(adapter.close);
      final cached = await adapter.captureRecentCachedVideo(
          expectedCustomer: customer,
          windowId: 21203,
          expectedMediaAt: at,
          destinationDirectory: directory,
          competingMessageTimes: [at.subtract(const Duration(seconds: 33))]);
      expect(
          cached!.video.originalName, '866add99731343efa7a43b6794667e40.mp4');
      expect(cached.video.ownershipVerification,
          'exact_customer_unique_cache_clock');
      expect(cached.createdCopy, isTrue);
      expect(calls, ['captureRecentCachedVideo']);
    });
  }

  test('ambiguous candidate remains unresolved instead of opening Save As',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (call) async =>
                {'kind': 'none', 'reason': 'cache_video_competing_turn'});
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    expect(
        await adapter.captureRecentCachedVideo(
            expectedCustomer: customer,
            windowId: 21203,
            expectedMediaAt: at,
            destinationDirectory: directory,
            competingMessageTimes: [at]),
        isNull);
  });

  for (final invalid in <String, Map<String, Object?>>{
    'other customer': {'verifiedCustomerId': 'jd_frqocwtljjob'},
    'missing attribution': {'ownershipVerification': null},
    'different event': {
      'expectedMediaAtMs':
          at.add(const Duration(seconds: 1)).millisecondsSinceEpoch
    },
    'outside private directory': {'path': '/private/media/other/video.mp4'},
    'missing cache key': {'cacheKey': ''},
    'poster not video': {'path': '$directory/poster.jpg'},
  }.entries) {
    test('rejects ${invalid.key} from direct cache response', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel, (call) async => {...payload(), ...invalid.value});
      final adapter = MacOSCaptureAdapter(channel: channel);
      addTearDown(adapter.close);
      await expectLater(
          adapter.captureRecentCachedVideo(
              expectedCustomer: customer,
              windowId: 21203,
              expectedMediaAt: at,
              destinationDirectory: directory,
              competingMessageTimes: []),
          throwsA(isA<PlatformException>()));
    });
  }

  test('cache claims survive restart and never migrate to another customer',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_cache_claims_');
    addTearDown(() => root.delete(recursive: true));
    final claims = CacheVideoClaims(root);
    expect(await claims.claim('entry-1', customer, at), isTrue);
    final restarted = CacheVideoClaims(root);
    expect(await restarted.claim('entry-1', 'jd_frqocwtljjob', at), isFalse);
    expect(
        await restarted.claim(
            'entry-1', customer, at.add(const Duration(seconds: 1))),
        isTrue);
    expect(
        await restarted.claim(
            'new-cache-entry-same-bytes', 'jd_frqocwtljjob', at),
        isTrue);
  });

  test('concurrent customer claims cannot both take one shared cache event',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_cache_claim_race_');
    addTearDown(() => root.delete(recursive: true));
    final claims = CacheVideoClaims(root);
    expect(
        await Future.wait(
            [claims.claim('entry', 'a', at), claims.claim('entry', 'b', at)]),
        [true, false]);
  });

  test('same hash with new timestamp keeps separate durable video jobs', () {
    VideoCaptureJob job(DateTime time) => VideoCaptureJob(
        customer: customer,
        path: '$directory/hash.mp4',
        digest: 'same-hash',
        sentAt: time,
        fingerprint: '',
        ownershipVerification: 'exact_customer_unique_cache_clock');
    final first = job(at);
    final next = VideoCaptureJob.fromJson(
        job(at.add(const Duration(seconds: 1))).toJson());
    expect(next.messageId, isNot(first.messageId));
    expect(next.ownershipVerification, 'exact_customer_unique_cache_clock');
    expect(next.digest, first.digest);
    expect(containsInternalCaptureText(next.ownershipVerification), isTrue,
        reason:
            'Native provenance must never be sent to the customer as an answer');
  });

  test(
      'competitors include other buyers and other timestamps, not this exact event',
      () {
    final events = MediaAcquisitions();
    events.observe(customer, 'first', at, at);
    events.observe(customer, 'second', at.add(const Duration(seconds: 5)), at);
    events.observe('other', 'third', at, at);
    expect(events.competingTimes(customer, at),
        [at.add(const Duration(seconds: 5)), at]);
  });

  test(
      'cache capture is read-only; explicit fallback is the sole Save As caller',
      () {
    final source =
        File('macos/Runner/AccessibilityBridge.swift').readAsStringSync();
    expect(
        RegExp(r'videoReferenceFromMessage\(').allMatches(source), hasLength(2),
        reason:
            'Only its definition and explicit beginAttachmentDownload caller');
    final fallback = source.substring(
        source.indexOf('func beginAttachmentDownload('),
        source.indexOf('func pollAttachmentDownload('));
    expect(fallback, contains('self.videoReferenceFromMessage('));
    final start = source.indexOf('func captureRecentCachedVideo(');
    final end = source.indexOf('private func mediaSavePanelNodes', start);
    final restored = source.substring(start, end);
    for (final mutation in [
      'postClick(',
      'postRightClick(',
      'postCommand',
      '.activate(',
      'CGWindowListCreateImage('
    ]) {
      expect(restored, isNot(contains(mutation)));
    }
    final mainSource = File('lib/main.dart').readAsStringSync();
    final loop = mainSource.substring(
        mainSource.indexOf('// 819ce2a\'s direct cache acquisition'),
        mainSource.indexOf('inspectedMediaSources.add(visible.captureSource'));
    expect(loop.indexOf('_captureDirectCachedVideo('),
        lessThan(loop.indexOf('.captureCachedMediaRegion(')));
  });
}
