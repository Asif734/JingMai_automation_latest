import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../domain/capture_models.dart';
import '../capture/attachment_download_queue.dart';
import '../domain/customer_identity.dart';
import '../codex/customer_media_evidence.dart';
import '../storage/diagnostic_log.dart';
import '../runtime/ui_operation_scheduler.dart';
import 'capture_adapter.dart';
export '../domain/customer_identity.dart';

class MacOSCaptureAdapter implements CaptureAdapter {
  MacOSCaptureAdapter({
    MethodChannel? channel,
    DiagnosticLog? diagnosticLog,
    this.trustedCustomerIds,
    this.openResponseTimeout = const Duration(seconds: 10),
    this.sendResponseTimeout = const Duration(seconds: 18),
  })  : _diagnosticLog = diagnosticLog,
        _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channelName = 'com.grozziie.jdAutomation/accessibility';
  final MethodChannel _channel;
  final DiagnosticLog? _diagnosticLog;
  final Future<Set<String>> Function()? trustedCustomerIds;
  // Response watchdogs are distinct from native mutation deadlines. Never
  // abandon the Dart delivery worker waiting for a lost native callback.
  final Duration openResponseTimeout;
  final Duration sendResponseTimeout;
  final _captures = StreamController<CapturedConversation>.broadcast();
  final _diagnostics = StreamController<Map<String, Object?>>.broadcast();
  final _failedSendInspections =
      StreamController<FailedSendInspection>.broadcast();
  // A sidebar OCR spelling must never become a persistent alias that redirects
  // later sends, transfers, retries, or media to a different customer.
  String _verifiedIdentityFor(String customer) => customer.trim();

  @override
  Stream<CapturedConversation> get captures => _captures.stream;

  @override
  Stream<Map<String, Object?>> get diagnostics => _diagnostics.stream;

  Stream<FailedSendInspection> get failedSendInspections =>
      _failedSendInspections.stream;

  Future<void> close() async {
    await _captures.close();
    await _diagnostics.close();
    await _failedSendInspections.close();
  }

  Future<void> beginUiOperation(UiOperationContext context) async {
    final value = await _mapCall(
        'beginUiOperation',
        {
          'operationId': context.id,
          'deadlineMs': context.deadline.millisecondsSinceEpoch,
          'customer': context.customer,
        },
        const Duration(seconds: 3));
    if (value['registered'] != true || value['operationId'] != context.id) {
      throw PlatformException(code: 'ui_operation_not_registered');
    }
  }

  Future<void> endUiOperation(UiOperationContext context) =>
      _stopUiOperation('endUiOperation', context);
  Future<void> cancelUiOperation(UiOperationContext context) =>
      _stopUiOperation('cancelUiOperation', context);
  Future<void> _stopUiOperation(
      String method, UiOperationContext context) async {
    final value = await _mapCall(
        method, {'operationId': context.id}, const Duration(seconds: 3));
    if (value['stopped'] != true || value['operationId'] != context.id) {
      throw PlatformException(code: 'ui_worker_stop_unconfirmed');
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    final arguments = (call.arguments as Map<Object?, Object?>?) ?? const {};
    if (call.method == 'capture') {
      try {
        final capture = CapturedConversation.fromMap(arguments);
        final verified = arguments['verifiedCustomerId']?.toString();
        if (!customerIdentitiesMatch(
                verified, capture.customerExternalId ?? '') ||
            !customerIdentitiesMatch(capture.customerName, verified!)) {
          throw PlatformException(
              code: 'capture_identity_unverified',
              message:
                  'Native capture did not prove the same full customer ID.');
        }
        _captures.add(capture);
      } catch (error, stack) {
        _diagnosticLog?.record('capture.rejected', fields: {
          'customer_id': arguments['customerExternalId'],
          'verified_customer_id': arguments['verifiedCustomerId'],
          'error': error.toString(),
        });
        _captures.addError(error, stack);
      }
    } else if (call.method == 'diagnostic') {
      _diagnosticLog?.record('native.diagnostic', fields: {
        for (final key in [
          'event',
          'customer',
          'expectedCustomer',
          'observedCustomer',
          'reason',
          'code',
          'operationId',
          'method'
        ])
          if (arguments[key] != null) key: arguments[key],
      });
      _diagnostics.add(arguments.map((key, value) => MapEntry('$key', value)));
    } else if (call.method == 'failedSendCandidates') {
      final inspection = FailedSendInspection.fromMap(arguments);
      if (!_failedSendInspections.isClosed &&
          inspection.customer.isNotEmpty &&
          inspection.candidates.isNotEmpty) {
        _failedSendInspections.add(inspection);
      }
    }
  }

  @override
  Future<Map<String, Object?>> status() => _mapCall('status');

  @override
  Future<bool> requestAccessibility() async =>
      await _channel.invokeMethod<bool>('requestAccessibility') ?? false;

  Future<bool> requestScreenRecording() async =>
      await _channel.invokeMethod<bool>('requestScreenRecording') ?? false;

  Future<List<OcrWindowInfo>> listOcrWindows() async {
    UiOperationContext.current?.check();
    final value = await _channel.invokeListMethod<Object?>('listOCRWindows');
    return (value ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(OcrWindowInfo.fromMap)
        .toList(growable: false);
  }

  Future<OcrInspection> inspectOcr({
    required int windowId,
    bool fast = false,
  }) async {
    final value = await _mapCall('inspectOCR', <String, Object?>{
      'windowId': windowId,
      'recognitionLevel': fast ? 'fast' : 'accurate',
    });
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ?? 'OCR inspection failed.',
      );
    }
    final inspection = OcrInspection.fromMap(value);
    final savedIds = trustedCustomerIds;
    if (savedIds == null || !inspection.hasVerifiedAxIdentity) {
      return inspection;
    }
    Set<String> trusted;
    try {
      trusted = await savedIds();
    } catch (error) {
      _diagnosticLog
          ?.record('capture.identity_cross_check_unavailable', fields: {
        'error': error.toString(),
      });
      return inspection;
    }
    final reconciled = inspection.reconcileCustomerSenderLabels(trusted);
    for (var index = 0; index < inspection.observations.length; index++) {
      if (inspection.observations[index].text !=
          reconciled.observations[index].text) {
        _diagnosticLog?.record('capture.sender_identity_recovered', fields: {
          'observed_sender': inspection.observations[index].text,
          'verified_customer': inspection.activeCustomerId,
          'basis': 'unique_saved_id_and_exact_ax_header',
        });
      }
    }
    return reconciled;
  }

  /// Waits until Qianniu's active header proves that a requested row switch
  /// completed. Callers must not persist OCR under the requested customer
  /// name until this independent identity check succeeds.
  Future<OcrInspection> inspectExpectedCustomer({
    required int windowId,
    required String expectedCustomer,
    int maximumAttempts = 6,
    Duration retryDelay = const Duration(milliseconds: 250),
    bool fast = false,
  }) async {
    final verifiedExpected = _verifiedIdentityFor(expectedCustomer);
    OcrInspection? lastInspection;
    for (var attempt = 0; attempt < maximumAttempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryDelay);
      lastInspection = await inspectOcr(windowId: windowId, fast: fast);
      if (customerIdentitiesMatch(
          lastInspection.activeCustomerId, verifiedExpected)) {
        return lastInspection;
      }
    }
    _diagnosticLog?.record('inspectExpectedCustomer.rejected', fields: {
      'code': 'customer_switch_not_verified',
      'expected_customer': verifiedExpected,
      'observed_customer': lastInspection?.activeCustomerId,
    });
    throw PlatformException(
      code: 'customer_switch_not_verified',
      message: 'JingMai did not settle on $verifiedExpected. OCR data was '
          'discarded instead of being saved to the wrong customer file '
          '(active: ${lastInspection?.activeCustomerId ?? 'unknown'}).',
    );
  }

  Future<Map<String, Object?>> sendDraftOnce({
    required String expectedCustomer,
    required String reply,
    List<String> mediaPaths = const [],
  }) async {
    if (containsInternalCaptureText(reply)) {
      throw PlatformException(
          code: 'internal_capture_text_rejected',
          message: 'Internal capture metadata cannot be sent to a customer.');
    }
    final value = await _mapCall(
        'sendDraftOnce',
        <String, Object?>{
          'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
          'reply': reply,
          'mediaPaths': mediaPaths,
          'operationDeadlineMs': DateTime.now()
              .add(const Duration(seconds: 12))
              .millisecondsSinceEpoch,
        },
        sendResponseTimeout,
        'send_unconfirmed');
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code, message: value['message'] as String? ?? 'Send failed.');
    }
    if (value['sent'] != true ||
        !customerIdentitiesMatch(
            value['customer']?.toString(), expectedCustomer) ||
        value['reply'] != reply.trim()) {
      _diagnosticLog?.record('sendDraftOnce.rejected', fields: {
        'code': 'send_confirmation_identity_mismatch',
        'expected_customer': expectedCustomer,
        'observed_customer': value['customer'],
      });
      throw PlatformException(
          code: 'send_confirmation_identity_mismatch',
          message:
              'Send acknowledgement did not confirm the exact customer and reply.');
    }
    return value;
  }

  /// Retry only an existing failed bubble. This never types text or clicks Send.
  Future<Map<String, Object?>> retryFailedOutgoingMessage({
    required String expectedCustomer,
    required Map<String, Object?> candidate,
  }) async {
    final value =
        await _mapCall('retryFailedOutgoingMessage', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'candidate': candidate,
    });
    if (value['error'] case final String code) {
      throw PlatformException(code: code, message: value['message'] as String?);
    }
    return value;
  }

  Future<VisibleImagePayload> captureImageRegion({
    required String expectedCustomer,
    required int windowId,
    required double x,
    required double y,
    required double width,
    required double height,
    DateTime? expectedMediaAt,
    bool allowActivationForVideoDetection = false,
    bool allowMessageReferenceLookup = true,
    bool allowAttachmentPreview = false,
    List<Map<String, double>> previewTextRegions = const [],
    OcrInspection? sourceInspection,
    double? sourceSenderY,
  }) async {
    _verifyMediaSource(sourceInspection, expectedCustomer, windowId);
    final value = await _mapCall('captureImageRegion', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'windowId': windowId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      if (sourceInspection != null)
        'sourcePngBase64': base64Encode(sourceInspection.image),
      if (sourceSenderY != null) 'sourceSenderY': sourceSenderY,
      if (expectedMediaAt != null)
        'expectedMediaAtMs': expectedMediaAt.millisecondsSinceEpoch,
      'allowActivationForVideoDetection': allowActivationForVideoDetection,
      'allowMessageReferenceLookup': allowMessageReferenceLookup,
      'allowAttachmentPreview': allowAttachmentPreview,
      if (allowAttachmentPreview) 'previewTextRegions': previewTextRegions,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message:
              value['message'] as String? ?? 'Image-region capture failed.');
    }
    _verifyVisibleMediaOwner(value, expectedCustomer);
    return VisibleImagePayload.fromMap(value);
  }

  /// A cache miss is normal, not an instruction to open a menu or erase text.
  /// Ownership/snapshot failures still propagate to prevent wrong-user capture.
  Future<VisibleImagePayload?> captureCachedMediaRegion({
    required String expectedCustomer,
    required int windowId,
    required OcrVisualRegion region,
    required OcrInspection sourceInspection,
    required DateTime expectedMediaAt,
    double? sourceSenderY,
    bool allowAttachmentPreview = false,
    List<Map<String, double>> previewTextRegions = const [],
  }) async {
    try {
      final payload = await captureImageRegion(
          expectedCustomer: expectedCustomer,
          windowId: windowId,
          x: region.x,
          y: region.y,
          width: region.width,
          height: region.height,
          expectedMediaAt: expectedMediaAt,
          sourceInspection: sourceInspection,
          sourceSenderY: sourceSenderY,
          allowAttachmentPreview: allowAttachmentPreview,
          previewTextRegions: previewTextRegions,
          allowActivationForVideoDetection: false,
          allowMessageReferenceLookup: false);
      if (payload.kind == 'attachment_preview' &&
          (!allowAttachmentPreview ||
              sourceSenderY == null ||
              payload.captureSource != 'verified-window-preview')) {
        throw PlatformException(code: 'attachment_preview_unverified');
      }
      return payload;
    } on PlatformException catch (error) {
      if (!const {
        'media_original_not_verified',
        'video_cache_visual_not_matched',
        'video_cache_match_ambiguous',
        'video_cache_decode_failed',
        'video_cache_check_timeout',
        'image_cache_changed_during_copy',
        'video_cache_invalid_original',
      }.contains(error.code)) {
        rethrow;
      }
      _diagnosticLog?.record('capture.cache_miss', fields: {
        'customer': expectedCustomer,
        'reason': error.code,
        'action': 'preserve_text_and_continue',
      });
      return null;
    }
  }

  /// Discovery only: a timestamp is never proof of media ownership. The result
  /// intentionally cannot carry image bytes or a video file for assignment.
  Future<Map<String, Object?>> probeRecentCachedMedia({
    required String expectedCustomer,
    required DateTime expectedMediaAt,
  }) async {
    final value = await _mapCall('probeRecentCachedMedia', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'expectedMediaAtMs': expectedMediaAt.millisecondsSinceEpoch,
    });
    final verified = customerIdentitiesMatch(
        value['verifiedCustomerId']?.toString(), expectedCustomer);
    return {
      'candidateFound': verified && value['candidateFound'] == true,
      'cacheCandidateCount':
          verified ? (value['cacheCandidateCount'] as num?)?.toInt() ?? 0 : 0,
      'cacheSelectionAmbiguous': value['cacheSelectionAmbiguous'] == true,
      'reason': value['reason']?.toString() ?? 'cache_owner_unverified',
    };
  }

  /// Restored from 819ce2a: copy the original cache video before screenshot
  /// classification. Native code rejects competing files/customer clocks and
  /// verifies the exact active customer before and after the read-only copy.
  Future<CachedVideoPayload?> captureRecentCachedVideo({
    required String expectedCustomer,
    required int windowId,
    required DateTime expectedMediaAt,
    required String destinationDirectory,
    required Iterable<DateTime> competingMessageTimes,
  }) async {
    final value = await _mapCall('captureRecentCachedVideo', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'windowId': windowId,
      'expectedMediaAtMs': expectedMediaAt.millisecondsSinceEpoch,
      'destinationDirectory': destinationDirectory,
      'competingMessageTimesMs': competingMessageTimes
          .map((at) => at.millisecondsSinceEpoch)
          .toList(growable: false),
    });
    if (value['error'] case final String code) {
      throw PlatformException(code: code, message: value['message'] as String?);
    }
    if (value['kind'] != 'video') return null;
    if (!customerIdentitiesMatch(
            value['verifiedCustomerId']?.toString(), expectedCustomer) ||
        value['ownershipVerification'] != 'exact_customer_unique_cache_clock' ||
        value['expectedMediaAtMs'] != expectedMediaAt.millisecondsSinceEpoch ||
        (value['cacheKey']?.toString() ?? '').isEmpty ||
        !const {'.mp4', '.mov', '.m4v', '.webm'}.contains(
            p.extension(value['path']?.toString() ?? '').toLowerCase()) ||
        !p.isWithin(destinationDirectory, value['path']?.toString() ?? '')) {
      throw PlatformException(
          code: 'media_owner_unverified',
          message:
              'The cache video did not match this customer, event and private directory.');
    }
    return CachedVideoPayload(
        video: DownloadedVideoPayload.fromMap(value),
        cacheKey: value['cacheKey'] as String,
        createdCopy: value['createdCopy'] == true);
  }

  void _verifyVisibleMediaOwner(
      Map<String, Object?> value, String expectedCustomer) {
    if (!customerIdentitiesMatch(
            value['verifiedCustomerId']?.toString(), expectedCustomer) ||
        value['ownershipVerification'] != 'visible_customer_region') {
      throw PlatformException(
          code: 'media_owner_unverified',
          message: 'Media was not verified against this customer’s visible '
              'message. No cache file was assigned.');
    }
  }

  Future<AttachmentDownloadTicket> beginAttachmentDownload({
    required String expectedCustomer,
    required int windowId,
    required OcrVisualRegion region,
    required OcrInspection sourceInspection,
    required double senderY,
    required DateTime sentAt,
    required String eventKey,
    required String destinationDirectory,
  }) async {
    _verifyMediaSource(sourceInspection, expectedCustomer, windowId);
    final value = await _mapCall('beginAttachmentDownload', {
      'expectedCustomer': expectedCustomer,
      'windowId': windowId,
      'x': region.x,
      'y': region.y,
      'width': region.width,
      'height': region.height,
      'sourcePngBase64': base64Encode(sourceInspection.image),
      'sourceSenderY': senderY,
      'expectedMediaAtMs': sentAt.millisecondsSinceEpoch,
      'eventKey': eventKey,
      'destinationDirectory': destinationDirectory,
      'operationDeadlineMs':
          DateTime.now().add(const Duration(seconds: 8)).millisecondsSinceEpoch,
    }).timeout(const Duration(seconds: 10));
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code, message: value['message'] as String?, details: value);
    }
    if (value['state'] != 'started' ||
        !customerIdentitiesMatch(
            value['verifiedCustomerId']?.toString(), expectedCustomer) ||
        value['ownershipVerification'] !=
            'exact_customer_attachment_reference' ||
        value['expectedMediaAtMs'] != sentAt.millisecondsSinceEpoch ||
        value['directory'] != destinationDirectory ||
        (value['token']?.toString() ?? '').isEmpty ||
        (value['originalName']?.toString() ?? '').isEmpty) {
      throw PlatformException(code: 'attachment_owner_unverified');
    }
    return AttachmentDownloadTicket(
        token: value['token'] as String,
        customer: expectedCustomer,
        eventKey: eventKey,
        sentAt: sentAt,
        startedAt: DateTime.now().toUtc(),
        directory: destinationDirectory,
        originalName: value['originalName'] as String);
  }

  Future<VisibleImagePayload?> pollAttachmentDownload(
      AttachmentDownloadTicket ticket) async {
    final value = await _mapCall('pollAttachmentDownload', ticket.toJson());
    if (value['error'] case final String code) {
      throw PlatformException(code: code, details: value);
    }
    if (value['state'] == 'pending') return null;
    if (value['state'] != 'ready' ||
        !customerIdentitiesMatch(
            value['verifiedCustomerId']?.toString(), ticket.customer) ||
        value['token'] != ticket.token ||
        value['expectedMediaAtMs'] != ticket.sentAt.millisecondsSinceEpoch ||
        value['ownershipVerification'] !=
            'exact_customer_attachment_reference' ||
        !const {'image', 'video'}.contains(value['kind'])) {
      throw PlatformException(code: 'attachment_owner_unverified');
    }
    if (value['kind'] == 'video' &&
        !p.isWithin(ticket.directory, value['path']?.toString() ?? '')) {
      throw PlatformException(code: 'attachment_path_unverified');
    }
    final media = VisibleImagePayload.fromMap(value);
    if (media.kind == 'image' && (media.bytes?.isNotEmpty != true)) {
      throw PlatformException(code: 'attachment_original_empty');
    }
    return media;
  }

  Future<MessageClassification> classifyMessageAt({
    required String expectedCustomer,
    required int windowId,
    required double x,
    required double y,
  }) async {
    final value = await _mapCall('classifyMessageAt', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'windowId': windowId,
      'x': x,
      'y': y,
    });
    return MessageClassification(
      kind: value['kind']?.toString() ?? 'unknown',
      visualFingerprint: value['visualFingerprint']?.toString(),
      image: value['kind']?.toString() == 'image'
          ? VisibleImagePayload.fromMap(value)
          : null,
    );
  }

  Future<VisibleImagePayload> downloadImageAt({
    required String expectedCustomer,
    required int windowId,
    required double x,
    required double y,
  }) async {
    final value = await _mapCall('downloadImageAt', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'windowId': windowId,
      'x': x,
      'y': y,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message: value['message'] as String? ??
              'The original JD image could not be downloaded.');
    }
    return VisibleImagePayload.fromMap(value);
  }

  Future<DownloadedVideoPayload> downloadVideoAt({
    required String expectedCustomer,
    required int windowId,
    required double x,
    required double y,
    required double width,
    required double height,
    DateTime? expectedMediaAt,
    required String destinationDirectory,
    OcrInspection? sourceInspection,
    double? sourceSenderY,
    String? cacheReferenceToken,
  }) async {
    _verifyMediaSource(sourceInspection, expectedCustomer, windowId);
    final value = await _mapCall('downloadVideoAt', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'windowId': windowId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      if (expectedMediaAt != null)
        'expectedMediaAtMs': expectedMediaAt.millisecondsSinceEpoch,
      'destinationDirectory': destinationDirectory,
      if (cacheReferenceToken != null)
        'cacheReferenceToken': cacheReferenceToken,
      if (sourceInspection != null)
        'sourcePngBase64': base64Encode(sourceInspection.image),
      if (sourceSenderY != null) 'sourceSenderY': sourceSenderY,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ??
            'The original JD video could not be downloaded.',
      );
    }
    _verifyVisibleMediaOwner(value, expectedCustomer);
    final video = DownloadedVideoPayload.fromMap(value);
    if (!p.isWithin(p.normalize(p.absolute(destinationDirectory)),
        p.normalize(p.absolute(video.path)))) {
      throw PlatformException(
          code: 'media_owner_unverified',
          message: 'Video copy is outside this customer’s private directory.');
    }
    return video;
  }

  void _verifyMediaSource(
      OcrInspection? source, String expectedCustomer, int windowId) {
    if (source == null) return; // Native refuses missing snapshot proof.
    if (source.image.isEmpty ||
        source.windowId != windowId ||
        !customerIdentitiesMatch(source.activeCustomerId, expectedCustomer)) {
      throw PlatformException(
          code: 'media_source_owner_unverified',
          message:
              'Media coordinates require the same customer/window OCR snapshot.');
    }
  }

  Future<SpeechTranscription> transcribeAudio(String path) async {
    final value = await _mapCall('transcribeAudio', <String, Object?>{
      'path': path,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ??
            'The video audio could not be transcribed.',
      );
    }
    return SpeechTranscription.fromMap(value);
  }

  Future<List<String>> listConversations() async {
    final value = await _channel.invokeListMethod<Object?>('listConversations');
    return (value ?? const [])
        .map((item) => item.toString())
        .toList(growable: false);
  }

  Future<List<QianniuConversationRow>> listConversationRows() async {
    final value =
        await _channel.invokeListMethod<Object?>('listConversationRows');
    return (value ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(QianniuConversationRow.fromMap)
        .toList(growable: false);
  }

  Future<Map<String, Object?>> ensureReceptionWindow(
      {bool allowActivation = true}) async {
    final value = await _mapCall('ensureReceptionWindow', <String, Object?>{
      'allowActivation': allowActivation,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message: value['message'] as String? ??
              'Could not open the JD 咚咚 customer-service window.');
    }
    return value;
  }

  Future<void> openConversation(String expectedCustomer,
      {bool allowActivation = true}) async {
    final nativeExpected = _verifiedIdentityFor(expectedCustomer);
    final value = await _mapCall(
        'openConversation',
        <String, Object?>{
          'expectedCustomer': nativeExpected,
          'allowActivation': allowActivation,
          'operationDeadlineMs': DateTime.now()
              .add(const Duration(seconds: 8))
              .millisecondsSinceEpoch,
        },
        openResponseTimeout,
        'conversation_open_timeout');
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message:
              value['message'] as String? ?? 'Could not open conversation.');
    }
    if (value['opened'] != true ||
        !customerIdentitiesMatch(
            value['customer']?.toString(), nativeExpected)) {
      _diagnosticLog?.record('openConversation.rejected', fields: {
        'expected_customer': nativeExpected,
        'observed_customer': value['customer'],
      });
      throw PlatformException(
          code: 'customer_switch_not_verified',
          message:
              'Requested $nativeExpected, but native confirmed ${value['customer'] ?? 'unknown'}.');
    }
  }

  /// Selects exactly one row by its observed sidebar spelling, then returns
  /// the independently read AX-header identity. Native and Dart both require
  /// exact agreement or one unambiguous edit before accepting the result.
  Future<String> resolveConversationIdentityFromAx(String observedCustomer,
      {bool allowActivation = false}) async {
    final observed = _verifiedIdentityFor(observedCustomer);
    final value = await _mapCall(
        'openConversation',
        <String, Object?>{
          'expectedCustomer': observed,
          'allowActivation': allowActivation,
          'allowObservedIdentityResolution': true,
          'operationDeadlineMs': DateTime.now()
              .add(const Duration(seconds: 8))
              .millisecondsSinceEpoch,
        },
        openResponseTimeout,
        'conversation_identity_resolution_timeout');
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message: value['message'] as String? ??
              'Could not verify the sidebar identity from AX.');
    }
    final verified = value['customer']?.toString() ?? '';
    final resolution =
        resolveObservedCustomerIdentity(observed, <String>{verified});
    if (value['opened'] != true ||
        !resolution.resolved ||
        resolution.customer != verified) {
      _diagnosticLog?.record('conversation.ax_identity_rejected', fields: {
        'observed_customer': observed,
        'verified_customer': verified,
        'resolution': resolution.kind.name,
      });
      throw PlatformException(
          code: 'customer_switch_not_verified',
          message:
              'AX did not prove a safe identity for observed row $observed.');
    }
    _diagnosticLog?.record('conversation.ax_identity_verified', fields: {
      'observed_customer': observed,
      'verified_customer': verified,
      'resolution': resolution.kind.name,
    });
    UiOperationContext.current?.resolvedFromVerifiedAx(observed, verified);
    return verified;
  }

  /// Opens JD's transfer dialog and returns the current service account plus
  /// only visible sub-accounts whose status badge is independently confirmed
  /// green by the native adapter. The dialog remains open so
  /// [transferConversation] can revalidate the automatically selected account.
  Future<TransferAccountPreview> listActiveTransferAccounts(
      String expectedCustomer) async {
    final value = await _mapCall(
      'listActiveTransferAccounts',
      <String, Object?>{
        'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      },
    );
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ??
            'Could not inspect active JD transfer accounts.',
      );
    }
    final accounts = (value['accounts'] as List<Object?>? ?? const [])
        .map((account) => account.toString())
        .where((account) => account.trim().isNotEmpty)
        .toList(growable: false);
    return TransferAccountPreview(
      sourceAccount:
          (value['sourceAccount'] as String?)?.trim().isNotEmpty == true
              ? (value['sourceAccount'] as String).trim()
              : '当前客服账号',
      activeAccounts: accounts,
    );
  }

  /// Selects the already-previewed green account, reveals its row actions,
  /// clicks that row's explicit 转接 control, and verifies that the transfer
  /// dialog closes. Native code never clicks 备注原因 or an inactive row.
  Future<Map<String, Object?>> transferConversation({
    required String expectedCustomer,
    required String targetAccount,
  }) async {
    final value = await _mapCall('transferConversation', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'targetAccount': targetAccount,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ?? 'JD chat transfer failed.',
      );
    }
    return value;
  }

  Future<void> cancelTransferSelection() async {
    final value = await _mapCall('cancelTransferSelection');
    if (value['error'] case final String code) {
      throw PlatformException(
        code: code,
        message: value['message'] as String? ??
            'Could not close the JD transfer dialog.',
      );
    }
  }

  Future<void> scrollConversation(
      {required String expectedCustomer, required int deltaY}) async {
    final value = await _mapCall('scrollConversation', <String, Object?>{
      'expectedCustomer': _verifiedIdentityFor(expectedCustomer),
      'deltaY': deltaY,
    });
    if (value['error'] case final String code) {
      throw PlatformException(
          code: code,
          message: value['message'] as String? ?? 'Could not scroll chat.');
    }
  }

  @override
  Future<void> start() => _channel.invokeMethod<void>('startCapture');

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stopCapture');

  @override
  Future<Map<String, Object?>> inspectTree({int maxDepth = 12}) =>
      _mapCall('inspectTree', <String, Object?>{'maxDepth': maxDepth});

  Future<Map<String, Object?>> _mapCall(String method,
      [Object? arguments,
      Duration? responseTimeout,
      String? timeoutCode]) async {
    final args = arguments is Map ? arguments : const {};
    final control = const {
      'beginUiOperation',
      'endUiOperation',
      'cancelUiOperation'
    }.contains(method);
    // File-only download completion and speech decoding are background jobs,
    // not UI continuations; they may safely outlive the capturing UI lease.
    final scope = control ||
            const {'pollAttachmentDownload', 'transcribeAudio'}.contains(method)
        ? null
        : UiOperationContext.current;
    try {
      scope?.check(args['expectedCustomer']?.toString());
    } on UiOperationCancelled catch (error) {
      throw PlatformException(
          code: 'ui_operation_cancelled', message: error.toString());
    }
    final requestedDeadline = (args['operationDeadlineMs'] as num?)?.toInt();
    final nativeArguments = scope == null
        ? arguments
        : <Object?, Object?>{
            ...args,
            'uiOperationId': scope.id,
            'operationDeadlineMs': requestedDeadline == null ||
                    scope.deadline.millisecondsSinceEpoch < requestedDeadline
                ? scope.deadline.millisecondsSinceEpoch
                : requestedDeadline,
          };
    final clock = Stopwatch()..start();
    final context = <String, Object?>{
      if (args['expectedCustomer'] != null)
        'expected_customer': args['expectedCustomer'],
      if (args['windowId'] != null) 'window_id': args['windowId'],
      if (method == 'captureImageRegion') ...{
        for (final key in ['x', 'y', 'width', 'height', 'expectedMediaAtMs'])
          if (args[key] != null) key: args[key],
      },
    };
    _diagnosticLog?.record('$method.started', fields: context);
    try {
      final nativeResponse =
          _channel.invokeMapMethod<Object?, Object?>(method, nativeArguments);
      final value = await (responseTimeout == null
          ? nativeResponse
          : nativeResponse.timeout(responseTimeout, onTimeout: () {
              if (scope != null) {
                scope.revoke();
                unawaited(cancelUiOperation(scope).catchError((Object _) {}));
              }
              throw PlatformException(
                code: timeoutCode ?? 'native_response_timeout',
                message: '$method did not return within '
                    '${responseTimeout.inMilliseconds} ms. The reply remains '
                    'pending; delivery must be reconciled and retried safely.',
                details: {'reason': 'native_response_timeout', ...context},
              );
            }));
      final result =
          (value ?? const {}).map((key, value) => MapEntry('$key', value));
      scope?.check();
      _diagnosticLog?.record('$method.completed', fields: {
        ...context,
        'elapsed_ms': clock.elapsedMilliseconds,
        for (final key in [
          'error',
          'message',
          'reason',
          'customer',
          'activeCustomerId',
          'observedCustomer',
          'kind',
          'cacheCrossCheck',
          'foregroundBundleIdentifier',
          'cacheMatchBasis',
          'mediaWidth',
          'mediaHeight',
          'coalescedRequests',
          'path',
          'trusted',
          'screenRecording',
          'appBundleIdentifier',
          'appBundlePath',
          'appProcessId',
          'uiWorkerAvailable',
          'uiWorkerTrusted',
          'uiWorkerScreenRecording',
          'uiWorkerError',
        ])
          if (result[key] != null) key: result[key],
      });
      return result;
    } catch (error) {
      _diagnosticLog?.record('$method.failed', fields: {
        ...context,
        'elapsed_ms': clock.elapsedMilliseconds,
        'error': error.toString(),
      });
      rethrow;
    }
  }
}

class MessageClassification {
  const MessageClassification({
    required this.kind,
    this.visualFingerprint,
    this.image,
  });

  final String kind;
  final String? visualFingerprint;
  final VisibleImagePayload? image;
}

class OcrWindowInfo {
  const OcrWindowInfo({
    this.windowId = 0,
    required this.title,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory OcrWindowInfo.fromMap(Map<Object?, Object?> value) => OcrWindowInfo(
        windowId: (value['windowId'] as num).toInt(),
        title: value['title'] as String? ?? 'Untitled JD window',
        x: (value['x'] as num?)?.toDouble() ?? 0,
        y: (value['y'] as num?)?.toDouble() ?? 0,
        width: (value['width'] as num?)?.toDouble() ?? 0,
        height: (value['height'] as num?)?.toDouble() ?? 0,
      );

  final int windowId;
  final String title;
  final double x;
  final double y;
  final double width;
  final double height;

  String get description =>
      '${width.round()}×${height.round()} at (${x.round()}, ${y.round()}) • ID $windowId';
}

class QianniuConversationRow {
  const QianniuConversationRow({
    required this.customer,
    required this.unread,
    required this.unreadEvidence,
    required this.evidenceAvailable,
    this.unreadAgeSeconds,
    this.observedCustomer,
    this.identityNeedsAxVerification = false,
  });

  factory QianniuConversationRow.fromMap(Map<Object?, Object?> value) =>
      QianniuConversationRow(
        customer: value['customer']?.toString() ?? '',
        unread: value['unread'] == true,
        unreadEvidence: (value['unreadEvidence'] as num?)?.toInt() ?? 0,
        evidenceAvailable: value['evidenceAvailable'] == true,
        unreadAgeSeconds: (value['unreadAgeSeconds'] as num?)?.toInt(),
        observedCustomer: value['customer']?.toString() ?? '',
      );

  final String customer;
  final bool unread;
  final int unreadEvidence;
  final bool evidenceAvailable;

  /// Elapsed time shown by JD's red unread badge, when confidently readable.
  final int? unreadAgeSeconds;
  final String? observedCustomer;
  final bool identityNeedsAxVerification;

  QianniuConversationRow withCustomer(String value,
          {bool? identityNeedsAxVerification}) =>
      QianniuConversationRow(
        customer: value,
        unread: unread,
        unreadEvidence: unreadEvidence,
        evidenceAvailable: evidenceAvailable,
        unreadAgeSeconds: unreadAgeSeconds,
        observedCustomer: observedCustomer ?? customer,
        identityNeedsAxVerification:
            identityNeedsAxVerification ?? this.identityNeedsAxVerification,
      );
}

class OcrObservation {
  const OcrObservation({
    required this.text,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory OcrObservation.fromMap(Map<Object?, Object?> value) => OcrObservation(
        text: value['text'] as String? ?? '',
        confidence: (value['confidence'] as num?)?.toDouble() ?? 0,
        x: (value['x'] as num?)?.toDouble() ?? 0,
        y: (value['y'] as num?)?.toDouble() ?? 0,
        width: (value['width'] as num?)?.toDouble() ?? 0,
        height: (value['height'] as num?)?.toDouble() ?? 0,
      );

  final String text;
  final double confidence;
  final double x;
  final double y;
  final double width;
  final double height;
}

class OcrInspection {
  const OcrInspection({
    required this.image,
    required this.imageWidth,
    required this.imageHeight,
    required this.windowTitle,
    required this.recognizedText,
    required this.observations,
    required this.capturedAt,
    this.visualRegions = const [],
    this.windowId = 0,
    this.activeCustomerId,
    this.activeCustomerIdentitySource,
    this.ocrEngine = 'unknown',
    this.chatLeft,
    this.chatRight,
    this.chatBottom,
    this.failedSendCandidates = const [],
  });

  factory OcrInspection.fromMap(Map<String, Object?> value) {
    final rawObservations = value['observations'] as List<Object?>? ?? const [];
    final rawVisualRegions =
        value['visualRegions'] as List<Object?>? ?? const [];
    final chatRegion = value['chatRegion'] as Map<Object?, Object?>?;
    return OcrInspection(
      image: base64Decode(value['pngBase64'] as String? ?? ''),
      imageWidth: (value['imageWidth'] as num?)?.toInt() ?? 0,
      imageHeight: (value['imageHeight'] as num?)?.toInt() ?? 0,
      windowTitle: value['windowTitle'] as String? ?? 'JD 咚咚工作台',
      recognizedText: value['recognizedText'] as String? ?? '',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(
          (value['capturedAtMs'] as num?)?.toInt() ?? 0),
      activeCustomerId: value['activeCustomerId'] as String?,
      activeCustomerIdentitySource:
          value['activeCustomerIdentitySource'] as String?,
      windowId: (value['windowId'] as num?)?.toInt() ?? 0,
      ocrEngine: value['ocrEngine'] as String? ?? 'unknown',
      chatLeft: (chatRegion?['left'] as num?)?.toDouble(),
      chatRight: (chatRegion?['right'] as num?)?.toDouble(),
      chatBottom: (chatRegion?['bottom'] as num?)?.toDouble(),
      failedSendCandidates:
          (value['failedSendCandidates'] as List<Object?>? ?? const [])
              .whereType<Map<Object?, Object?>>()
              .map((candidate) =>
                  candidate.map((key, value) => MapEntry('$key', value)))
              .toList(growable: false),
      observations: rawObservations
          .whereType<Map<Object?, Object?>>()
          .map(OcrObservation.fromMap)
          .toList(growable: false),
      visualRegions: rawVisualRegions
          .whereType<Map<Object?, Object?>>()
          .map(OcrVisualRegion.fromMap)
          .toList(growable: false),
    );
  }

  final Uint8List image;
  final int imageWidth;
  final int imageHeight;
  final String windowTitle;
  final String recognizedText;
  final List<OcrObservation> observations;
  final List<OcrVisualRegion> visualRegions;
  final DateTime capturedAt;
  final int windowId;
  final String? activeCustomerId;
  final String? activeCustomerIdentitySource;
  final String ocrEngine;
  final double? chatLeft;
  final double? chatRight;
  final double? chatBottom;
  final List<Map<String, Object?>> failedSendCandidates;

  bool get hasVerifiedAxIdentity =>
      activeCustomerIdentitySource == 'ax_header_before_and_after' &&
      customerIdentitiesMatch(activeCustomerId, activeCustomerId ?? '');

  OcrInspection reconcileCustomerSenderLabels(Set<String> trustedCustomers) {
    final left = chatLeft;
    final right = chatRight;
    final bottom = chatBottom;
    if (!hasVerifiedAxIdentity ||
        left == null ||
        right == null ||
        bottom == null ||
        left < 0 ||
        right > 1 ||
        right - left < .10 ||
        bottom <= .18 ||
        bottom > .95) {
      return this;
    }
    final corrected = observations.map((item) {
      final centerX = item.x + item.width / 2;
      if (item.confidence < .45 ||
          centerX < left ||
          centerX >= right ||
          item.y < .18 ||
          item.y >= bottom) {
        return item;
      }
      final text = reconcileOcrCustomerSenderLabel(
          observedLabel: item.text,
          verifiedAxCustomer: activeCustomerId!,
          trustedCustomers: trustedCustomers);
      return text == item.text
          ? item
          : OcrObservation(
              text: text,
              confidence: item.confidence,
              x: item.x,
              y: item.y,
              width: item.width,
              height: item.height);
    }).toList(growable: false);
    return OcrInspection(
        image: image,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        windowTitle: windowTitle,
        recognizedText: recognizedText,
        observations: corrected,
        capturedAt: capturedAt,
        visualRegions: visualRegions,
        windowId: windowId,
        activeCustomerId: activeCustomerId,
        activeCustomerIdentitySource: activeCustomerIdentitySource,
        ocrEngine: ocrEngine,
        chatLeft: chatLeft,
        chatRight: chatRight,
        chatBottom: chatBottom,
        failedSendCandidates: failedSendCandidates);
  }
}

class OcrVisualRegion {
  const OcrVisualRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.confidence,
  });

  factory OcrVisualRegion.fromMap(Map<Object?, Object?> value) =>
      OcrVisualRegion(
        x: (value['x'] as num?)?.toDouble() ?? 0,
        y: (value['y'] as num?)?.toDouble() ?? 0,
        width: (value['width'] as num?)?.toDouble() ?? 0,
        height: (value['height'] as num?)?.toDouble() ?? 0,
        confidence: (value['confidence'] as num?)?.toDouble() ?? 0,
      );

  final double x;
  final double y;
  final double width;
  final double height;
  final double confidence;
}

class VisibleImagePayload {
  const VisibleImagePayload({
    required this.kind,
    this.mimeType,
    this.extension,
    this.originalName,
    this.visualFingerprint,
    this.captureSource,
    this.bytes,
    this.cacheReferenceToken,
    this.downloadedVideo,
    this.ownershipVerification = 'visible_customer_region',
  });

  factory VisibleImagePayload.fromMap(Map<String, Object?> value) =>
      VisibleImagePayload(
        kind: value['kind']?.toString() ?? 'unsupported',
        mimeType: value['mimeType'] as String?,
        extension: value['extension'] as String?,
        originalName: value['originalName'] as String?,
        visualFingerprint: value['visualFingerprint'] as String?,
        captureSource: value['captureSource'] as String?,
        cacheReferenceToken: value['cacheReferenceToken'] as String?,
        downloadedVideo: value['kind'] == 'video' && value['path'] is String
            ? DownloadedVideoPayload.fromMap(value)
            : null,
        ownershipVerification: value['ownershipVerification'] as String? ??
            'visible_customer_region',
        bytes: value['dataBase64'] is String
            ? base64Decode(value['dataBase64']! as String)
            : null,
      );

  final String kind;
  final String? mimeType;
  final String? extension;
  final String? originalName;
  final String? visualFingerprint;
  final String? captureSource;
  final Uint8List? bytes;
  final String? cacheReferenceToken;
  final DownloadedVideoPayload? downloadedVideo;
  final String ownershipVerification;
}

class DownloadedVideoPayload {
  const DownloadedVideoPayload({
    required this.path,
    required this.originalName,
    required this.mimeType,
    this.ownershipVerification = 'visible_customer_region',
  });

  factory DownloadedVideoPayload.fromMap(Map<String, Object?> value) =>
      DownloadedVideoPayload(
        path: value['path']?.toString() ?? '',
        originalName: value['originalName']?.toString() ?? 'customer-video.mp4',
        mimeType: value['mimeType']?.toString() ?? 'video/mp4',
        ownershipVerification: value['ownershipVerification']?.toString() ??
            'visible_customer_region',
      );

  final String path;
  final String originalName;
  final String mimeType;
  final String ownershipVerification;
}

class CachedVideoPayload {
  const CachedVideoPayload(
      {required this.video, required this.cacheKey, this.createdCopy = false});
  final DownloadedVideoPayload video;
  final String cacheKey;
  final bool createdCopy;
}

class FailedSendInspection {
  const FailedSendInspection(
      {required this.customer,
      required this.capturedAt,
      required this.candidates});

  factory FailedSendInspection.fromMap(Map<Object?, Object?> value) =>
      FailedSendInspection(
        customer: value['customer']?.toString().trim() ?? '',
        capturedAt: DateTime.fromMillisecondsSinceEpoch(
            (value['capturedAtMs'] as num?)?.toInt() ?? 0,
            isUtc: true),
        candidates: [
          for (final candidate
              in (value['candidates'] as List<Object?>? ?? const []))
            if (candidate is Map)
              candidate.map((key, value) => MapEntry('$key', value)),
        ],
      );

  final String customer;
  final DateTime capturedAt;
  final List<Map<String, Object?>> candidates;
}

class SpeechTranscription {
  const SpeechTranscription({
    required this.transcript,
    required this.language,
    required this.confidence,
    required this.speechDetected,
  });

  factory SpeechTranscription.fromMap(Map<String, Object?> value) =>
      SpeechTranscription(
        transcript: value['transcript']?.toString().trim() ?? '',
        language: value['language']?.toString() ?? '',
        confidence: (value['confidence'] as num?)?.toDouble() ?? 0,
        speechDetected: value['speechDetected'] == true,
      );

  final String transcript;
  final String language;
  final double confidence;
  final bool speechDetected;
}
