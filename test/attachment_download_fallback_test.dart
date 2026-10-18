import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/attachment_download_queue.dart';
import 'package:jd_automation/codex/customer_media_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/exact-attachment-fallback');
  const customer = 'jd_41aeec7741d05';
  const directory =
      '/private/media/$customer/attachment_exports/attachment_random';
  final at = DateTime.utc(2026, 10, 18, 4, 32, 4);
  const region =
      OcrVisualRegion(x: .3, y: .4, width: .2, height: .3, confidence: 1);
  OcrInspection source({String owner = customer, int window = 21203}) =>
      OcrInspection(
          image: Uint8List.fromList([1, 2, 3]),
          imageWidth: 1800,
          imageHeight: 1400,
          windowId: window,
          windowTitle: 'JD',
          recognizedText: '',
          activeCustomerId: owner,
          capturedAt: at,
          observations: const []);
  final ticket = AttachmentDownloadTicket(
      token: 'owned-token',
      customer: customer,
      eventKey: 'upload:123:0',
      sentAt: at,
      startedAt: at,
      directory: directory,
      originalName: 'original');
  Map<String, Object?> started() => {
        'state': 'started',
        'token': ticket.token,
        'directory': directory,
        'originalName': ticket.originalName,
        'verifiedCustomerId': customer,
        'expectedMediaAtMs': at.millisecondsSinceEpoch,
        'ownershipVerification': 'exact_customer_attachment_reference',
      };
  Map<String, Object?> ready({String kind = 'video'}) => {
        ...started(),
        'state': 'ready',
        'kind': kind,
        if (kind == 'video') 'path': '$directory/original.mp4',
        'mimeType': kind == 'video' ? 'video/mp4' : 'image/png',
        if (kind == 'image') ...{
          'extension': 'png',
          'dataBase64': base64Encode([1, 2, 3]),
        },
      };
  void mock(Future<Object?> Function(MethodCall) handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test(
      'fallback carries exact customer, source pixels, sender clock and destination',
      () async {
    mock((call) async {
      expect(call.method, 'beginAttachmentDownload');
      final args = call.arguments as Map;
      expect(args['expectedCustomer'], customer);
      expect(args['windowId'], 21203);
      expect(args['eventKey'], ticket.eventKey);
      expect(args['expectedMediaAtMs'], at.millisecondsSinceEpoch);
      expect(args['destinationDirectory'], directory);
      expect(args['sourceSenderY'], .35);
      expect(args['sourcePngBase64'], base64Encode([1, 2, 3]));
      final remaining = (args['operationDeadlineMs'] as int) -
          DateTime.now().millisecondsSinceEpoch;
      expect(remaining, inInclusiveRange(6000, 8000));
      return started();
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    final result = await adapter.beginAttachmentDownload(
        expectedCustomer: customer,
        windowId: 21203,
        region: region,
        sourceInspection: source(),
        senderY: .35,
        sentAt: at,
        eventKey: ticket.eventKey,
        destinationDirectory: directory);
    expect(result.customer, customer);
    expect(result.sentAt, at);
    expect(result.token, ticket.token);
  });

  for (final invalidSource in [
    source(owner: 'jd_frqocwtljjob'),
    source(window: 12)
  ]) {
    test('wrong source customer/window is rejected before any menu action',
        () async {
      mock((call) async => fail('Native UI must not be invoked'));
      final adapter = MacOSCaptureAdapter(channel: channel);
      addTearDown(adapter.close);
      await expectLater(
          adapter.beginAttachmentDownload(
              expectedCustomer: customer,
              windowId: 21203,
              region: region,
              sourceInspection: invalidSource,
              senderY: .35,
              sentAt: at,
              eventKey: ticket.eventKey,
              destinationDirectory: directory),
          throwsA(isA<PlatformException>()));
    });
  }

  test('stale preflight tells caller no UI was attempted', () async {
    mock((call) async =>
        {'error': 'media_snapshot_changed', 'uiAttempted': false});
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    await expectLater(
        adapter.beginAttachmentDownload(
            expectedCustomer: customer,
            windowId: 21203,
            region: region,
            sourceInspection: source(),
            senderY: .35,
            sentAt: at,
            eventKey: ticket.eventKey,
            destinationDirectory: directory),
        throwsA(isA<PlatformException>().having(
            (e) => (e.details as Map)['uiAttempted'], 'uiAttempted', false)));
  });

  for (final mutation in <String, Map<String, Object?>>{
    'other customer': {'verifiedCustomerId': '格志打印机贝贝'},
    'other token': {'token': 'other-token'},
    'other timestamp': {
      'expectedMediaAtMs':
          at.add(const Duration(seconds: 1)).millisecondsSinceEpoch
    },
    'missing exact message proof': {
      'ownershipVerification': 'visible_customer_region'
    },
    'other private folder': {'path': '/private/media/other/video.mp4'},
  }.entries) {
    test('download polling rejects ${mutation.key}', () async {
      mock((call) async => {...ready(), ...mutation.value});
      final adapter = MacOSCaptureAdapter(channel: channel);
      addTearDown(adapter.close);
      await expectLater(adapter.pollAttachmentDownload(ticket),
          throwsA(isA<PlatformException>()));
    });
  }

  for (final background in ['white', 'black', 'grey']) {
    test('$background video is read from its exported original, not a preview',
        () async {
      final calls = <String>[];
      mock((call) async {
        calls.add(call.method);
        expect((call.arguments as Map)['sent_at'], at.toIso8601String());
        return ready();
      });
      final adapter = MacOSCaptureAdapter(channel: channel);
      addTearDown(adapter.close);
      final original = await adapter.pollAttachmentDownload(ticket);
      expect(original!.kind, 'video');
      expect(original.downloadedVideo!.path, '$directory/original.mp4');
      expect(calls, ['pollAttachmentDownload']);
      expect(
          containsInternalCaptureText(original.ownershipVerification), isTrue);
    });
  }

  test('actual image payload is preserved without a thumbnail colour filter',
      () async {
    mock((call) async => ready(kind: 'image'));
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    final original = await adapter.pollAttachmentDownload(ticket);
    expect(original!.kind, 'image');
    expect(original.bytes, [1, 2, 3]);
    expect(original.downloadedVideo, isNull);
  });

  test('not-yet-exported attachment stays pending without touching JD UI',
      () async {
    mock((call) async {
      expect(call.method, 'pollAttachmentDownload');
      return {'state': 'pending'};
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    expect(await adapter.pollAttachmentDownload(ticket), isNull);
  });

  test('native export is bounded and polling is file-only', () {
    final native =
        File('macos/Runner/AccessibilityBridge.swift').readAsStringSync();
    final begin = native.substring(
        native.indexOf('func beginAttachmentDownload('),
        native.indexOf('func pollAttachmentDownload('));
    final poll = native.substring(
        native.indexOf('func pollAttachmentDownload('),
        native.indexOf('func downloadVideoAt('));
    expect(begin, contains('addingTimeInterval(8)'));
    expect(begin, contains('if cleanup()'));
    expect(begin, contains('.jd-attachment-export.json'));
    expect(poll, contains('attachmentFileQueue.async'));
    expect(poll, contains('attachmentContainerKind(data)'));
    expect(poll, contains('asset.cancelLoading()'));
    for (final uiAction in [
      'postClick(',
      'postRightClick(',
      'postKeyToPID(',
      'CGWindowListCreateImage(',
      'activeCustomerIdentity('
    ]) {
      expect(poll, isNot(contains(uiAction)));
    }
    final panel = native.substring(
        native.indexOf('private func setAttachmentExportDirectory('),
        native.indexOf('func beginAttachmentDownload('));
    expect(panel, isNot(contains('CGWindowListCreateImage(')),
        reason: 'No screenshot capture while NSSavePanel is open');
    expect(
        panel, contains('attachmentPanelIsFrontmost(pid: pid, focused: name)'));
    expect(panel, contains('path.identifier == "PathTextField"'));
    expect(panel, contains('node.value == directory.lastPathComponent'));
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('_beginAttachmentFallback(')),
        reason: 'Automatic cache misses must never open Save As');
    expect(main, isNot(contains('.beginAttachmentDownload(')));
    expect(main, contains('if (attachments.hasCustomer(userId)) return;'));
  });
}
