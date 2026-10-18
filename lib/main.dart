import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';

import 'capture/capture_coordinator.dart';
import 'capture/attachment_download_queue.dart';
import 'capture/media_acquisition.dart';
import 'capture/failed_send_retry_policy.dart';
import 'capture/ocr_capture_extractor.dart';
import 'capture/ocr_image_candidate_selector.dart';
import 'capture/ocr_media_mask.dart';
import 'capture/reply_message_scope.dart';
import 'capture/unread_capture_recovery.dart';
import 'capture/video_audio_extractor.dart';
import 'capture/video_frame_extractor.dart';
import 'capture/video_capture_queue.dart';
import 'codex/codex_reply_service.dart';
import 'codex/customer_media_evidence.dart';
import 'codex/holding_replies.dart';
import 'codex/knowledge_inspection.dart';
import 'codex/local_reply_router.dart';
import 'domain/capture_models.dart';
import 'domain/media_identity.dart';
import 'platform/macos_capture_adapter.dart';
import 'runtime/app_runtime.dart';
import 'runtime/accessibility_permission_monitor.dart';
import 'runtime/app_error_state.dart';
import 'runtime/automation_lease.dart';
import 'runtime/installation_check.dart';
import 'runtime/serial_delivery_worker.dart';
import 'runtime/ui_operation_scheduler.dart';
import 'storage/capture_database.dart';
import 'storage/cache_video_claims.dart';
import 'storage/diagnostic_log.dart';
import 'storage/fallback_delivery_journal.dart';
import 'storage/resilient_database.dart';
import 'storage/reply_outbox.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.environment['JD_INSTALLATION_CHECK'] == '1') {
    await checkInstallation();
    return;
  }
  runApp(const JdAutomationApp());
}

class JdAutomationApp extends StatelessWidget {
  const JdAutomationApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: AppRuntime.appName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xfff26b21),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xfffaf8f6),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
          ),
        ),
        home: const CaptureHome(),
      );
}

class CaptureHome extends StatefulWidget {
  const CaptureHome({super.key});

  @override
  State<CaptureHome> createState() => _CaptureHomeState();
}

class _CaptureHomeState extends State<CaptureHome> {
  // Covers native window capture, Apple Vision recognition, and JD UI delays.
  static const _captureOperationTimeout = Duration(seconds: 90);
  static const _unreadOperationTimeout = Duration(seconds: 12);
  // A holding message must not sit behind a full 90-second OCR/media pass.
  static const _fallbackInspectionTimeout = Duration(seconds: 4);
  static const _scanInterval = Duration(seconds: 2);
  static const _batchCollectionWindow = Duration(milliseconds: 1000);
  static const _draftFailureRetryDelay = Duration(seconds: 10);
  static const _deliveryFailureRetryDelay = Duration(seconds: 10);
  static const _identityEvidenceRefresh = Duration(seconds: 30);
  static const _identityFailureQuarantine = Duration(minutes: 2);
  static const _unreadClearConfirmation = Duration(seconds: 12);
  late final MacOSCaptureAdapter _adapter;
  late final CaptureCoordinator _coordinator;
  late final CaptureDatabase _database;
  late final DiagnosticLog _diagnosticLog;
  late final Future<FallbackDeliveryJournal> _fallbackJournal;
  late final Future<ReplyOutbox> _replyOutbox;
  late final Future<VideoCaptureQueue> _videoCaptureQueue;
  late final Future<AttachmentDownloadQueue> _attachmentDownloads;
  late final Future<CacheVideoClaims> _cacheVideoClaims;
  AutomationLease? _automationLease;
  AccessibilityPermissionMonitor? _permissionMonitor;
  StreamSubscription? _updateSubscription;
  StreamSubscription? _diagnosticSubscription;
  StreamSubscription? _failedSendInspectionSubscription;
  List<ConversationSummary> _conversations = const [];
  Map<String, Object?> _status = const {};
  String _diagnostics = 'No AX inspection yet.';
  AppErrorState _errorState = AppErrorState();
  Object? get _error => _errorState.value;
  set _error(Object? value) => _errorState.value = value;
  List<ChatTransferLog> _transferLogs = const [];
  OcrInspection? _ocrInspection;
  bool _autoCaptureRunning = false;
  bool _autoCaptureStarting = false;
  bool _autoCaptureBusy = false;
  Timer? _autoCaptureTimer;
  Timer? _unreadSignalTimer;
  Timer? _activeChatSignalTimer;
  bool _unreadSignalBusy = false;
  bool _activeChatSignalBusy = false;
  bool _failedSendRetryBusy = false;
  Timer? _failedSendRetryTimer;
  final Map<String, Timer> _draftRetryTimers = {};
  final Map<String, Timer> _batchCollectionTimers = {};
  final Map<String, Timer> _slaFallbackTimers = {};
  Timer? _deliveryRetryTimer;
  Timer? _deliveryRecoveryTimer;
  bool _deliveryRecoveryBusy = false;
  bool _outboxRecoveryBusy = false;
  final Set<String> _draftQueue = {};
  // Each active customer owns a separate Codex CLI turn. Twenty
  // workers let the normal multi-chat workload generate concurrently without
  // launching an unbounded number of local model processes.
  static const int _maxConcurrentDraftWorkers = 20;
  final Set<String> _activeDraftUsers = {};
  final Map<String, CodexGenerationCancellation> _activeDraftCancellations = {};
  final Map<String, String> _activeDraftMessageIds = {};
  late final UiOperationScheduler _uiScheduler;
  int get _pendingJdUiOperations => _uiScheduler.pendingCount;
  int _priorityUiOperations = 0;
  SerialDeliveryWorker<QueuedDelivery>? _deliveryWorker;
  bool get _deliveryWorkerRunning => _deliveryWorker?.isRunning ?? false;
  final Map<String, int> _processingUnreadEvidence = {};
  final Map<String, int> _handledUnreadEvidence = {};
  final Map<String, DateTime> _handledUnreadAt = {};
  final Map<String, DateTime> _unreadClearObservedAt = {};
  final Map<String, String> _handledIncomingSenderKeys = {};
  final Map<String, DateTime> _lastUnreadProbeAt = {};
  final Map<String, UnreadCaptureRecovery> _unreadRecovery = {};
  final MediaAcquisitions _mediaAcquisitions = MediaAcquisitions();
  final OcrMediaMasks _ocrMediaMasks = OcrMediaMasks();
  final MediaEvidenceVersions _mediaEvidenceVersions = MediaEvidenceVersions();
  final String _mediaEvidenceSession =
      DateTime.now().microsecondsSinceEpoch.toString();
  final SidebarUnreadTracker _sidebarUnreadTracker = SidebarUnreadTracker();
  final Set<String> _startingUnreadRecovery = {};
  final Map<String, Timer> _unreadHoldingTimers = {};
  final Map<String, Timer> _unreadResendTimers = {};
  final Map<String, DateTime> _identityQuarantineUntil = {};
  final Set<String> _reportedIdentityRepairs = {};
  Set<String> _trustedCustomerIds = const {};
  DateTime? _trustedCustomerIdsLoadedAt;
  final Set<String> _visibleTransferWelcomes = {};
  final Set<String> _transferringCustomers = {};
  String _visibleMediaTrace = 'visible image candidates=0, saved=0';

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS) {
      _database = CaptureDatabase(onDatabaseRecovery: (error, attempt) {
        _diagnosticLog.record('database.contention_recovered', fields: {
          'attempt': attempt,
          'action': 'close_rollback_reopen',
          'error': error.toString(),
        });
      });
      _fallbackJournal = _database.storageRoot.then((root) =>
          FallbackDeliveryJournal(Directory('${root.path}/fallback_delivery')));
      _replyOutbox = _database.storageRoot
          .then((root) => ReplyOutbox(Directory('${root.path}/reply_outbox')));
      _cacheVideoClaims = _database.storageRoot.then((root) =>
          CacheVideoClaims(Directory('${root.path}/cache_video_claims')));
      _attachmentDownloads = _database.storageRoot.then((root) =>
          AttachmentDownloadQueue(
              Directory('${root.path}/attachment_download_jobs'),
              enabled: () => mounted && _autoCaptureRunning,
              poll: _completeAttachmentDownload,
              failed: _attachmentDownloadFailed,
              onError: (error, stack) => _diagnosticLog.record(
                  'capture.attachment_job_error',
                  fields: {'error': error.toString()}),
              onIdle: (customer) {
                if (mounted && _autoCaptureRunning) {
                  _scheduleDraftGeneration(customer, newEvidence: true);
                }
              }));
      _videoCaptureQueue = _database.storageRoot.then((root) =>
          VideoCaptureQueue(Directory('${root.path}/video_capture_jobs'),
              enabled: () => mounted && _autoCaptureRunning,
              process: _completeVideoCaptureJob,
              onIdle: (customer) {
                if (mounted && _autoCaptureRunning) {
                  _scheduleDraftGeneration(customer, newEvidence: true);
                }
              },
              onError: (error, stack) => _diagnosticLog.record(
                  'capture.video_job_retry',
                  fields: {'error': error.toString()})));
      _diagnosticLog = DiagnosticLog(
          () async => Directory('${(await _database.storageRoot).path}/logs'));
      _errorState = AppErrorState(log: _diagnosticLog);
      _adapter = MacOSCaptureAdapter(
          diagnosticLog: _diagnosticLog,
          trustedCustomerIds: _savedTrustedCustomerIds);
      _uiScheduler = UiOperationScheduler(
        beginNative: _adapter.beginUiOperation,
        endNative: _adapter.endUiOperation,
        cancelNative: _adapter.cancelUiOperation,
        onDiagnostic: (event, fields) =>
            _diagnosticLog.record(event, fields: fields),
      );
      _diagnosticLog.record('app.started');
      _coordinator = CaptureCoordinator(_adapter, _database);
      _deliveryWorker = SerialDeliveryWorker<QueuedDelivery>(
        enabled: () => mounted && _autoCaptureRunning,
        next: _database.nextReadyDelivery,
        deliver: (delivery) => _withJdUiOperation(
            () => _sendAutomaticallyUnlocked(delivery),
            customer: delivery.userId,
            label: 'delivery.original',
            priority: UiPriority.originalReply),
        failed: _handleDeliveryFailure,
        afterAttempt: _coordinator.refresh,
        onError: (error, stack) {
          if (mounted) setState(() => _error = error);
        },
      );
      _updateSubscription = _coordinator.updates.listen(
        (value) {
          setState(() => _conversations = value);
          _refreshTickets();
        },
        onError: (Object error) => setState(() => _error = error),
      );
      _diagnosticSubscription = _adapter.diagnostics.listen(
        (value) => setState(() =>
            _diagnostics = const JsonEncoder.withIndent('  ').convert(value)),
      );
      _failedSendInspectionSubscription = _adapter.failedSendInspections.listen(
        (inspection) => _queueFailedSendRetry(
            inspection.customer, inspection.candidates,
            capturedAt: inspection.capturedAt),
      );
      _permissionMonitor = AccessibilityPermissionMonitor(
        readStatus: _adapter.status,
        onStatus: (status) {
          if (mounted) setState(() => _status = status);
        },
        onError: (error, stack) {
          if (mounted) setState(() => _error = error);
        },
      )..start();
      _refreshTickets();
    }
  }

  Future<void> _refreshStatus() =>
      _permissionMonitor?.refresh() ?? Future<void>.value();

  Future<void> _refreshTickets() async {
    try {
      final logs = await _database.chatTransferLogs();
      if (!mounted) return;
      setState(() => _transferLogs = logs);
    } catch (_) {
      // Capture remains available if local ticket storage is unavailable.
    }
  }

  String _transferAcknowledgement(HumanReviewTicket ticket) =>
      safeTransferAcknowledgement();

  String _allAgentsBusyMessage(HumanReviewTicket ticket) =>
      '目前其他客服同事都在忙，暂时无法转接。我会继续在这里为您处理这个问题。';

  Future<void> _sendTransferStatusNotice({
    required String customer,
    required String message,
    required String model,
  }) async {
    await _adapter
        .openConversation(customer, allowActivation: true)
        .timeout(_captureOperationTimeout);
    await _adapter.sendDraftOnce(
      expectedCustomer: customer,
      reply: message,
      mediaPaths: const [],
    ).timeout(_captureOperationTimeout);
    await _database.appendAutomatedNoticeSent(
      userId: customer,
      reply: message,
      model: model,
    );
  }

  Future<void> _beginAutomaticTransfer(HumanReviewTicket ticket) async {
    final customer = ticket.conversationId;
    await _database.markTicketContacting(ticket.id);
    _finishUnreadRecovery(customer);
    _draftRetryTimers.remove(customer)?.cancel();
    _slaFallbackTimers.remove(customer)?.cancel();
    _draftQueue.remove(customer);
    await _coordinator.refresh();
    await _refreshTickets();
  }

  Future<void> _autoTransferTicket(HumanReviewTicket ticket,
      {String? acknowledgement}) async {
    final customer = ticket.conversationId;
    if (!_transferringCustomers.add(customer)) return;
    ChatTransferLog? log;
    String? target;
    var transferStarted = false;
    if (mounted) {
      setState(() {
        _error = null;
        _diagnostics = 'Automatically transferring $customer…';
      });
    }
    try {
      log = await _database.reserveChatTransferLog(ticket: ticket);
      if (log == null) return;

      await _withJdUiOperation(() async {
        await _adapter
            .ensureReceptionWindow(allowActivation: true)
            .timeout(_captureOperationTimeout);
        await _adapter
            .openConversation(customer, allowActivation: true)
            .timeout(_captureOperationTimeout);
        var preview = await _adapter
            .listActiveTransferAccounts(customer)
            .timeout(_captureOperationTimeout);
        var eligible = preview.activeAccounts
            .where((account) =>
                account.trim().toLowerCase() !=
                preview.sourceAccount.trim().toLowerCase())
            .toList(growable: false);
        if (eligible.isEmpty) {
          await _adapter.cancelTransferSelection();
          throw PlatformException(
            code: 'no_active_transfer_accounts',
            message: 'No other JD sub-account is currently active.',
          );
        }
        target = await _database.chooseAutomaticTransferAccount(eligible);
        await _database.updateChatTransferLog(
          id: log!.id,
          status: 'ready',
          sourceAccount: preview.sourceAccount,
          targetAccount: target,
        );
        await _refreshTickets();

        // The customer must receive a problem acknowledgement before the
        // external handoff. Close the modal, send once with exact-customer
        // verification, then reopen and revalidate the target's live badge.
        await _adapter
            .cancelTransferSelection()
            .timeout(_captureOperationTimeout);
        await _beginAutomaticTransfer(ticket);
        transferStarted = true;
        await _sendTransferStatusNotice(
          customer: customer,
          message: acknowledgement ?? _transferAcknowledgement(ticket),
          model: 'jd-transfer-acknowledgement-v1',
        );
        preview = await _adapter
            .listActiveTransferAccounts(customer)
            .timeout(_captureOperationTimeout);
        eligible = preview.activeAccounts
            .where((account) =>
                account.trim().toLowerCase() !=
                preview.sourceAccount.trim().toLowerCase())
            .toList(growable: false);
        if (eligible.isEmpty) {
          await _adapter.cancelTransferSelection();
          throw PlatformException(
            code: 'no_active_transfer_accounts',
            message: 'No other JD sub-account is currently active.',
          );
        }
        if (!eligible.contains(target)) {
          target = await _database.chooseAutomaticTransferAccount(eligible);
        }

        // `transferring` is written before the irreversible click. If the app
        // exits afterward, the unique ticket log prevents an unsafe retry.
        await _database.updateChatTransferLog(
          id: log!.id,
          status: 'transferring',
          sourceAccount: preview.sourceAccount,
          targetAccount: target,
        );

        await _adapter
            .transferConversation(
              expectedCustomer: customer,
              targetAccount: target!,
            )
            .timeout(_captureOperationTimeout);
        await _database.markTicketContacted(
          ticket.id,
          assignedTo: target,
        );
        await _database.updateChatTransferLog(
          id: log!.id,
          status: 'transferred',
          sourceAccount: preview.sourceAccount,
          targetAccount: target,
        );
        await _coordinator.refresh();
        await _refreshTickets();
        if (mounted) {
          setState(() =>
              _diagnostics = 'Automatically transferred $customer to $target.');
        }
      });
    } catch (caughtError) {
      Object error = caughtError;
      final noActive = error is PlatformException &&
          error.code == 'no_active_transfer_accounts';
      if (noActive && log != null) {
        try {
          if (!transferStarted) {
            await _beginAutomaticTransfer(ticket);
            transferStarted = true;
          }
          await _withJdUiOperation(() => _sendTransferStatusNotice(
                customer: customer,
                message: _allAgentsBusyMessage(ticket),
                model: 'jd-transfer-no-active-agent-v1',
              ));
          await _database.updateChatTransferLog(
            id: log.id,
            status: 'agents_busy',
            // Preserve the native badge evidence for diagnosis. A genuinely
            // busy result is still terminal for this request, but it must not
            // erase which rows/colors were observed.
            error: error.toString(),
          );
          await _database.markTicketAwaitingCurrentAgent(ticket.id);
          await _coordinator.refresh();
          await _refreshTickets();
          if (mounted) {
            setState(() => _diagnostics =
                'No active transfer target for $customer; sent the busy-agent notice and kept the conversation on this account.');
          }
          return;
        } catch (noticeError) {
          error = noticeError;
        }
      }
      final unconfirmed =
          error is PlatformException && error.code == 'transfer_unconfirmed';
      if (log != null) {
        await _database.updateChatTransferLog(
          id: log.id,
          status: unconfirmed ? 'unconfirmed' : 'failed',
          targetAccount: target,
          error: error.toString(),
        );
        if (transferStarted) {
          await _database.markTicketAwaitingCurrentAgent(ticket.id);
        }
      }
      if (!unconfirmed) {
        try {
          await _adapter
              .cancelTransferSelection()
              .timeout(_captureOperationTimeout);
        } catch (_) {
          // There may be no open dialog when an earlier precondition failed.
        }
      }
      await _refreshTickets();
      if (mounted) setState(() => _error = error);
    } finally {
      _transferringCustomers.remove(customer);
      if (mounted) setState(() {});
    }
  }

  Future<void> _start() async {
    if (_autoCaptureStarting) return;
    if (_autoCaptureRunning) {
      _autoCaptureTimer?.cancel();
      _unreadSignalTimer?.cancel();
      _activeChatSignalTimer?.cancel();
      _failedSendRetryTimer?.cancel();
      _deliveryRecoveryTimer?.cancel();
      for (final timer in _unreadHoldingTimers.values) {
        timer.cancel();
      }
      for (final timer in _unreadResendTimers.values) {
        timer.cancel();
      }
      setState(() => _autoCaptureRunning = false);
      await _uiScheduler.cancelAll();
      return;
    }
    setState(() {
      _autoCaptureStarting = true;
      _error = null;
      _diagnostics = 'Opening the JD reception window…';
    });
    try {
      final status = await _adapter.status();
      if (status['uiWorkerAvailable'] == false ||
          status['uiWorkerTrusted'] == false ||
          status['uiWorkerScreenRecording'] == false) {
        throw PlatformException(
            code: 'ui_worker_permission_unavailable',
            message:
                'The isolated UI worker is not ready or lacks Accessibility/Screen Recording access. No automation was started. Check macOS permissions for this exact Review app.');
      }
      if ((status['competingApps'] as List? ?? const []).isNotEmpty) {
        throw PlatformException(
            code: 'another_automation_app_running',
            message:
                'Close the other JD Automation app before starting automation.');
      }
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) {
        throw StateError(
            'The shared automation lock directory could not be resolved.');
      }
      _automationLease ??= AutomationLease(
          Directory('$home/Library/Application Support/JD Automation Shared'));
      if (!await _automationLease!.acquire()) {
        throw PlatformException(
            code: 'automation_lock_busy',
            message:
                'Another app instance owns JD automation. Close it before starting this instance.');
      }
      await _adapter
          .ensureReceptionWindow(allowActivation: true)
          .timeout(_captureOperationTimeout);
    } catch (error) {
      if (mounted) setState(() => _error = error);
      return;
    } finally {
      if (mounted) setState(() => _autoCaptureStarting = false);
    }
    if (!mounted) return;
    setState(() {
      _autoCaptureRunning = true;
      _error = null;
      _diagnostics =
          'Automatic OCR capture started. The sidebar is checked every 2 seconds; saved customer evidence is queued for drafting immediately.';
    });
    _autoCaptureTimer =
        Timer.periodic(_scanInterval, (_) => unawaited(_runAutoCaptureCycle()));
    // This read-only sidebar poll is intentionally independent of the slower
    // OCR/media capture cycle. A busy video extraction cannot prevent the
    // unread clock from starting for another customer.
    _unreadSignalTimer =
        Timer.periodic(_scanInterval, (_) => unawaited(_pollUnreadSignals()));
    _activeChatSignalTimer = Timer.periodic(
        const Duration(seconds: 3), (_) => unawaited(_pollActiveChatSignal()));
    _deliveryRecoveryTimer?.cancel();
    _deliveryRecoveryTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => unawaited(_recoverDeliveryWork()));
    unawaited(_pollUnreadSignals());
    unawaited(_pollActiveChatSignal());
    for (final recovery in _unreadRecovery.values) {
      _armUnreadRecoveryTimers(recovery);
    }
    unawaited(_recoverAutomationQueues());
    unawaited(_runAutoCaptureCycle());
  }

  Future<void> _recoverAutomationQueues() async {
    await (await _videoCaptureQueue).resume();
    await (await _attachmentDownloads).resume();
    await _database.repairPendingCaptures();
    await _recoverOriginalReplyOutbox();
    final pending = await _database.conversations();
    for (final conversation in pending) {
      _scheduleDraftGeneration(conversation.userId, newEvidence: true);
    }
    for (final job in await _database.pendingSlaFallbackJobs()) {
      _armSlaFallback(job);
    }
    _requestDelivery();
  }

  Future<void> _recoverDeliveryWork() async {
    if (!_autoCaptureRunning || _deliveryRecoveryBusy) return;
    _deliveryRecoveryBusy = true;
    try {
      await (await _videoCaptureQueue).resume();
      await (await _attachmentDownloads).resume();
      _requestDelivery();
      await _recoverOriginalReplyOutbox();
      await _database.repairPendingCaptures();
      final pending = await _database.conversations();
      for (final conversation in pending) {
        if (!_autoCaptureRunning) return;
        _scheduleDraftGeneration(conversation.userId, newEvidence: false);
      }
      for (final job in await _database.pendingSlaFallbackJobs()) {
        if (!_autoCaptureRunning) return;
        _armSlaFallback(job);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      _deliveryRecoveryBusy = false;
    }
  }

  static const _uncapturedHoldingReply = '已收到您刚发来的消息，我正在仔细核对，请稍候。';
  static const _uncapturedResendReply =
      '抱歉，我这边暂时没能看清您刚才发送的内容。方便您再描述一下遇到的问题，或重新发送图片、视频吗？我会继续帮您查看。';

  bool _isOwnHoldingReply(String? body) =>
      body == _uncapturedHoldingReply || chineseHoldingReplies.contains(body);

  OcrExtractionAttempt _analyzeUnreadInspection(
      OcrInspection inspection, UnreadCaptureRecovery? recovery) {
    final strict = const OcrCaptureExtractor().analyze(inspection);
    if (recovery?.useRelaxedBodyOcr(DateTime.now()) != true) return strict;
    final relaxed = const OcrCaptureExtractor(bodyConfidenceThreshold: 0.30)
        .analyze(inspection);
    final latest = relaxed.capture?.messages.reversed
        .where((message) => message.direction == 'incoming')
        .firstOrNull;
    if (latest == null ||
        recovery!.knownIncomingIds.contains(latest.stableId)) {
      return relaxed;
    }
    final strictIds = strict.capture?.messages
            .where((message) => message.direction == 'incoming')
            .map((message) => message.stableId)
            .toSet() ??
        const <String>{};
    if (strictIds.contains(latest.stableId) ||
        recovery.confirmRelaxedBody(latest.body)) {
      return relaxed;
    }
    return strict;
  }

  Future<void> _beginUnreadRecovery(String customer, int evidence,
      {DateTime? detectedAt, bool sidebarUnreadVerified = false}) async {
    final existing = _unreadRecovery[customer];
    if (existing != null) {
      if (sidebarUnreadVerified) existing.verifySidebarUnread();
      return;
    }
    if (!_startingUnreadRecovery.add(customer)) {
      return;
    }
    try {
      final document = await (await _database.history).read(customer);
      final messages = (document?['messages'] as List<Object?>? ?? const [])
          .whereType<Map<String, dynamic>>();
      final eventAt = detectedAt ?? DateTime.now();
      final answeredMessageId = await _database.answeredMessageId(customer);
      DateTime? messageAt(Map<String, dynamic> message) =>
          DateTime.tryParse(message['sent_at']?.toString() ?? '') ??
          DateTime.tryParse(message['captured_at']?.toString() ?? '');
      final recovery = UnreadCaptureRecovery(
        customer: customer,
        unreadEvidence: evidence,
        detectedAt: eventAt,
        knownIncomingIds: UnreadCaptureRecovery.incomingBaseline(messages,
            detectedAt: eventAt, answeredMessageId: answeredMessageId),
        knownOutgoingIds: messages
            .where((message) =>
                message['direction'] == 'outgoing' &&
                (messageAt(message)?.isBefore(eventAt) ?? false))
            .map((message) => message['id']?.toString() ?? '')
            .toSet(),
        sidebarUnreadVerified: sidebarUnreadVerified,
      );
      _unreadRecovery[customer] = recovery;
      _armUnreadRecoveryTimers(recovery);
    } finally {
      _startingUnreadRecovery.remove(customer);
    }
  }

  DateTime _unreadDetectedAt(QianniuConversationRow row) {
    return UnreadCaptureRecovery.detectedFromBadge(
        DateTime.now(), row.unreadAgeSeconds);
  }

  /// Track a real clear-to-unread transition independently of OCR. Existing
  /// unread rows seen at application startup are deliberately not considered
  /// new: that is what previously reopened inactive customers indefinitely.
  void _observeSidebarUnread(QianniuConversationRow row) {
    _sidebarUnreadTracker.observe(
      customer: row.customer,
      unread: row.unread,
      observedAt: DateTime.now(),
      unreadAgeSeconds: row.unreadAgeSeconds,
    );
  }

  bool _hasVerifiedSidebarUnread(QianniuConversationRow row) =>
      _sidebarUnreadTracker.isVerified(row.customer);

  void _refreshHandledUnread(QianniuConversationRow row) {
    final handledAt = _handledUnreadAt[row.customer];
    if (handledAt == null) {
      _unreadClearObservedAt.remove(row.customer);
      return;
    }
    final now = DateTime.now();
    if (!row.unread) {
      final clearSince =
          _unreadClearObservedAt.putIfAbsent(row.customer, () => now);
      // Screenshot evidence can flicker for a poll while JD is repainting the
      // sidebar. Require a continuous clear interval before allowing the same
      // stale row to create another recovery cycle.
      if (now.difference(clearSince) < _unreadClearConfirmation) return;
      _handledUnreadEvidence.remove(row.customer);
      _handledUnreadAt.remove(row.customer);
      _unreadClearObservedAt.remove(row.customer);
      return;
    }
    _unreadClearObservedAt.remove(row.customer);
    if (UnreadCaptureRecovery.badgeStartedAfterHandled(
        now, row.unreadAgeSeconds, handledAt)) {
      _handledUnreadEvidence.remove(row.customer);
      _handledUnreadAt.remove(row.customer);
    }
  }

  Future<Set<String>> _savedTrustedCustomerIds() async {
    final now = DateTime.now();
    if (_trustedCustomerIdsLoadedAt == null ||
        now.difference(_trustedCustomerIdsLoadedAt!) >=
            _identityEvidenceRefresh) {
      _trustedCustomerIds =
          await (await _database.history).trustedCustomerIds();
      _trustedCustomerIdsLoadedAt = now;
    }
    return {..._trustedCustomerIds};
  }

  Future<Set<String>> _currentTrustedCustomerIds() async {
    final now = DateTime.now();
    final result = await _savedTrustedCustomerIds();
    final inspected = _ocrInspection;
    if (inspected != null &&
        now.difference(inspected.capturedAt).abs() <
            const Duration(minutes: 1)) {
      final active = inspected.activeCustomerId?.trim();
      if (active != null && active.isNotEmpty) result.add(active);
    }
    return result;
  }

  bool _identityIsQuarantined(String observedCustomer) {
    final until = _identityQuarantineUntil[observedCustomer];
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _identityQuarantineUntil.remove(observedCustomer);
    return false;
  }

  void _quarantineIdentity(String observedCustomer, String reason) {
    _identityQuarantineUntil[observedCustomer] =
        DateTime.now().add(_identityFailureQuarantine);
    _diagnosticLog.record('conversation.identity_quarantined', fields: {
      'observed_customer': observedCustomer,
      'reason': reason,
      'retry_after_seconds': _identityFailureQuarantine.inSeconds,
    });
  }

  bool _isIdentityOpenFailure(String code) => const {
        'conversation_identity_ambiguous',
        'conversation_not_found',
        'customer_switch_not_verified',
        'conversation_verification_failed',
      }.contains(code);

  Future<List<QianniuConversationRow>> _reconciledConversationRows() async {
    final rows = await _adapter.listConversationRows();
    final trusted = await _currentTrustedCustomerIds();
    final merged = <String, QianniuConversationRow>{};
    for (final row in rows) {
      final observed = row.observedCustomer ?? row.customer;
      if (_identityIsQuarantined(observed)) continue;
      final resolution = resolveObservedCustomerIdentity(row.customer, trusted);
      if (resolution.kind == CustomerIdentityResolutionKind.invalid ||
          resolution.kind == CustomerIdentityResolutionKind.ambiguous) {
        _quarantineIdentity(observed, resolution.kind.name);
        continue;
      }
      final customer = resolution.customer ?? row.customer.trim();
      final needsAxVerification =
          resolution.kind == CustomerIdentityResolutionKind.unmatched;
      if (resolution.kind ==
              CustomerIdentityResolutionKind.uniqueTrustedNearMatch &&
          _reportedIdentityRepairs.add('$observed->$customer')) {
        _diagnosticLog.record('conversation.identity_reconciled', fields: {
          'observed_customer': observed,
          'verified_customer': customer,
          'basis': 'unique_saved_or_ax_identity_edit_distance_1',
        });
      }
      final resolved = row.withCustomer(customer,
          identityNeedsAxVerification: needsAxVerification);
      final existing = merged[customer];
      if (existing == null) {
        merged[customer] = resolved;
        continue;
      }
      final ages = [existing.unreadAgeSeconds, resolved.unreadAgeSeconds]
          .whereType<int>()
          .toList(growable: false);
      merged[customer] = QianniuConversationRow(
        customer: customer,
        observedCustomer: existing.observedCustomer,
        unread: existing.unread || resolved.unread,
        unreadEvidence: existing.unreadEvidence > resolved.unreadEvidence
            ? existing.unreadEvidence
            : resolved.unreadEvidence,
        evidenceAvailable:
            existing.evidenceAvailable || resolved.evidenceAvailable,
        identityNeedsAxVerification: existing.identityNeedsAxVerification ||
            resolved.identityNeedsAxVerification,
        unreadAgeSeconds: ages.isEmpty
            ? null
            : ages.reduce((left, right) => left < right ? left : right),
      );
    }
    return merged.values.toList(growable: false);
  }

  Future<void> _pollUnreadSignals() async {
    if (!_autoCaptureRunning || _unreadSignalBusy) return;
    _unreadSignalBusy = true;
    try {
      final rows =
          await _reconciledConversationRows().timeout(_unreadOperationTimeout);
      for (final row in rows) {
        _observeSidebarUnread(row);
        _refreshHandledUnread(row);
        if (!row.unread) {
          continue;
        }
        if (_hasVerifiedSidebarUnread(row)) {
          _unreadRecovery[row.customer]?.verifySidebarUnread();
        }
        if (row.identityNeedsAxVerification ||
            _unreadRecovery.containsKey(row.customer) ||
            _handledUnreadEvidence.containsKey(row.customer) ||
            await _database.isHumanContacting(row.customer)) {
          continue;
        }
        await _beginUnreadRecovery(row.customer, row.unreadEvidence,
            detectedAt: _unreadDetectedAt(row),
            sidebarUnreadVerified: _hasVerifiedSidebarUnread(row));
      }
    } catch (_) {
      // The capture cycle continues to inspect the active chat even if a
      // transient sidebar read fails. The next signal poll retries.
    } finally {
      _unreadSignalBusy = false;
    }
  }

  /// A selected JD row may not expose an unread flag. Observe its verified
  /// sender clock independently of the slow full capture/media cycle so the
  /// 20-second deadline starts even when content extraction fails.
  Future<void> _pollActiveChatSignal() async {
    // Full-window Vision OCR is read-only, but it still competes for AX and
    // CPU with the exact-customer switch/send path. A generated reply already
    // waiting for JD gets priority; the lightweight sidebar poll continues to
    // detect other customers while delivery drains.
    if (!_autoCaptureRunning ||
        _activeChatSignalBusy ||
        _deliveryWorkerRunning ||
        _pendingJdUiOperations != 0 ||
        _priorityUiOperations != 0 ||
        _autoCaptureBusy) {
      return;
    }
    _activeChatSignalBusy = true;
    try {
      final windows =
          await _adapter.listOcrWindows().timeout(_unreadOperationTimeout);
      if (windows.isEmpty) return;
      final reception = windows.firstWhere(
          (window) => window.title.contains('咚咚融合工作台'),
          orElse: () => windows.first);
      final inspection = await _adapter
          .inspectOcr(windowId: reception.windowId, fast: true)
          .timeout(_unreadOperationTimeout);
      final customer = inspection.activeCustomerId?.trim();
      if (customer == null ||
          customer.isEmpty ||
          await _database.isHumanContacting(customer)) {
        return;
      }
      final extraction = const OcrCaptureExtractor().analyze(inspection);
      final senderKey = extraction.latestIncomingSenderKey;
      final incomingAt = extraction.latestIncomingSentAt;
      if ((!extraction.latestVisibleSenderIsIncoming &&
              !await _hasUncapturedRecentVisibleMedia(inspection, customer)) ||
          senderKey == null ||
          incomingAt == null ||
          incomingAt.isBefore(
              inspection.capturedAt.subtract(const Duration(minutes: 10))) ||
          incomingAt
              .isAfter(inspection.capturedAt.add(const Duration(minutes: 1))) ||
          _handledIncomingSenderKeys[customer] == senderKey) {
        return;
      }
      if (_unreadRecovery[customer] == null) {
        await _beginUnreadRecovery(customer, 0, detectedAt: incomingAt);
      }
      final recovery = _unreadRecovery[customer];
      if (recovery != null) {
        _observeRecoverySignal(recovery, extraction, inspection);
      }
      // Fast text cannot promote thumbnail OCR when Vision temporarily loses
      // the full media rectangle. The full, sender-masked capture owns it.
      final capture = _ocrMediaMasks.regions(inspection, customer).isEmpty
          ? const OcrCaptureExtractor().verifiedFastTextCapture(inspection)
          : null;
      if (capture != null) {
        final inserted = await _database.saveCapture(capture);
        if (inserted > 0) {
          if (recovery != null) {
            await _database.capSlaFallbackDue(
                userId: customer,
                dueAt:
                    recovery.eventAt.add(UnreadCaptureRecovery.holdingAfter));
            if (recovery.holdingSentAt case final sentAt?) {
              await _database.acknowledgeUncapturedHolding(
                  userId: customer, sentAt: sentAt);
            }
            _finishUnreadRecovery(customer, expectedRecovery: recovery);
          }
          _scheduleDraftGeneration(customer, newEvidence: true);
          await _coordinator.refresh();
        }
      }
    } catch (_) {
      // The full capture and sidebar signal paths remain available.
    } finally {
      _activeChatSignalBusy = false;
    }
  }

  bool get _retryUiIdle => failedSendRetryCanRun(
        captureBusy: _autoCaptureBusy,
        activeSignalBusy: _activeChatSignalBusy,
        unreadSignalBusy: _unreadSignalBusy,
        deliveryBusy: _deliveryWorkerRunning,
        priorityUiBusy: _priorityUiOperations != 0,
        transferBusy: _transferringCustomers.isNotEmpty,
        incomingRecoveryPending:
            _unreadRecovery.isNotEmpty || _startingUnreadRecovery.isNotEmpty,
        fallbackPending: _slaFallbackTimers.isNotEmpty,
        draftingPending: _activeDraftUsers.isNotEmpty ||
            _draftQueue.isNotEmpty ||
            _batchCollectionTimers.isNotEmpty,
      );

  void _queueFailedSendRetry(
      String customer, List<Map<String, Object?>> candidates,
      {required DateTime capturedAt}) {
    _failedSendRetryTimer?.cancel();
    _failedSendRetryTimer = null;
    // Ordinary chats never enqueue retry work. A detected icon is optional
    // maintenance: skip instead of waiting behind capture, delivery, or SLA.
    if (candidates.isEmpty ||
        _failedSendRetryBusy ||
        !_autoCaptureRunning ||
        !mounted ||
        DateTime.now().difference(capturedAt) > const Duration(seconds: 15)) {
      return;
    }
    if (!_retryUiIdle || _pendingJdUiOperations != 0) {
      // Keep only this recently observed candidate, outside the UI queue.
      // This avoids starvation if the 2s capture and 3s OCR timers overlap.
      _failedSendRetryTimer = Timer(const Duration(milliseconds: 400), () {
        _queueFailedSendRetry(customer, candidates, capturedAt: capturedAt);
      });
      return;
    }
    _failedSendRetryBusy = true;
    // Do not delay the existing incoming-message/SLA poll behind the UI lock.
    unawaited(() async {
      try {
        await _withJdUiOperation(() async {
          if (!mounted ||
              !_autoCaptureRunning ||
              !_retryUiIdle ||
              _pendingJdUiOperations > 1 ||
              await _database.isHumanContacting(customer)) {
            return;
          }
          if (!_retryUiIdle ||
              _pendingJdUiOperations > 1 ||
              !_autoCaptureRunning ||
              !mounted) {
            return;
          }
          for (final candidate in candidates) {
            if (!_retryUiIdle ||
                _pendingJdUiOperations > 1 ||
                !_autoCaptureRunning ||
                !mounted) {
              break;
            }
            final retry = await _adapter.retryFailedOutgoingMessage(
                expectedCustomer: customer, candidate: candidate);
            if (retry['retried'] == true) {
              if (mounted) {
                setState(() => _diagnostics =
                    'Retried the existing failed JD message for $customer; no reply was regenerated or retyped.');
              }
              break; // One existing-icon click per poll, including multiple failures.
            }
          }
        });
      } catch (_) {
        // Retry inspection must never interrupt normal capture or generation.
      } finally {
        _failedSendRetryBusy = false;
      }
    }());
  }

  void _armUnreadRecoveryTimers(UnreadCaptureRecovery recovery) {
    final customer = recovery.customer;
    _unreadHoldingTimers.remove(customer)?.cancel();
    _unreadResendTimers.remove(customer)?.cancel();
    final now = DateTime.now();
    if (!recovery.holdingSent) {
      final due = recovery.eventAt.add(UnreadCaptureRecovery.holdingAfter);
      _unreadHoldingTimers[customer] = Timer(
        due.isAfter(now) ? due.difference(now) : Duration.zero,
        () => unawaited(_sendUnreadRecoveryNotice(recovery, resend: false)),
      );
    } else {
      _armUnreadResendTimer(recovery);
    }
  }

  void _armUnreadResendTimer(UnreadCaptureRecovery recovery) {
    final customer = recovery.customer;
    _unreadResendTimers.remove(customer)?.cancel();
    if (!recovery.holdingSent ||
        recovery.holdingSentAt == null ||
        !recovery.hasVerifiedIncomingSignal ||
        recovery.resendSent) {
      return;
    }
    final now = DateTime.now();
    final due = recovery.resendDueAt;
    _unreadResendTimers[customer] = Timer(
      due.isAfter(now) ? due.difference(now) : Duration.zero,
      () => unawaited(_sendUnreadRecoveryNotice(recovery, resend: true)),
    );
  }

  void _finishUnreadRecovery(String customer,
      {DateTime? handledAt, UnreadCaptureRecovery? expectedRecovery}) {
    if (expectedRecovery != null &&
        !identical(_unreadRecovery[customer], expectedRecovery)) {
      return;
    }
    final recovery = _unreadRecovery.remove(customer);
    _unreadHoldingTimers.remove(customer)?.cancel();
    _unreadResendTimers.remove(customer)?.cancel();
    if (recovery != null) {
      _handledUnreadEvidence[customer] = recovery.unreadEvidence;
      _handledUnreadAt[customer] = handledAt ?? DateTime.now();
      _unreadClearObservedAt.remove(customer);
      _processingUnreadEvidence[customer] = recovery.unreadEvidence;
      if (recovery.latestIncomingSenderKey case final senderKey?) {
        _handledIncomingSenderKeys[customer] = senderKey;
      }
    }
  }

  Future<bool> _hasUncapturedRecentVisibleMedia(
      OcrInspection inspection, String customer) async {
    final document = await (await _database.history).read(customer);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>();
    return const OcrImageCandidateSelector()
        .hasUncapturedRecentCustomerMedia(inspection, customer, messages);
  }

  Future<bool> _hasRecoveredIncoming(UnreadCaptureRecovery recovery) async {
    final document = await (await _database.history).read(recovery.customer);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>();
    return messages.any((message) {
      if (message['direction'] != 'incoming') return false;
      final capturedAt =
          DateTime.tryParse(message['captured_at']?.toString() ?? '');
      if (capturedAt == null) return false;
      return recovery.acceptsIncoming(
        message['id']?.toString() ?? '',
        sentAt: DateTime.tryParse(message['sent_at']?.toString() ?? ''),
        capturedAt: capturedAt,
      );
    });
  }

  Future<DateTime?> _newOutgoingAt(UnreadCaptureRecovery recovery) async {
    final document = await (await _database.history).read(recovery.customer);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    DateTime? newest;
    for (final message in messages) {
      if (!isConfirmedOutgoingReply(message) ||
          recovery.knownOutgoingIds.contains(message['id']?.toString() ?? '') ||
          message['body'] == _uncapturedHoldingReply ||
          message['body'] == _uncapturedResendReply) {
        continue;
      }
      if (isGeneratedReply(message) &&
          !recovery.acceptsGeneratedReply(message, messages,
              pendingMedia: _mediaAcquisitions
                  .forCustomer(recovery.customer)
                  .any((event) =>
                      !event.acquired &&
                      !event.sentAt.isBefore(recovery.detectedAt.subtract(
                          UnreadCaptureRecovery
                              .detectedTurnClockTolerance))))) {
        continue;
      }
      final sentAt = DateTime.tryParse(message['sent_at']?.toString() ?? '') ??
          DateTime.tryParse(message['captured_at']?.toString() ?? '');
      if (sentAt == null || sentAt.isBefore(recovery.detectedAt)) continue;
      if (newest == null || sentAt.isAfter(newest)) newest = sentAt;
    }
    return newest;
  }

  Future<DateTime?> _holdingSentSinceRecovery(
      UnreadCaptureRecovery recovery) async {
    final document = await (await _database.history).read(recovery.customer);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>();
    return recovery.holdingReplySentAt(messages);
  }

  void _observeRecoverySignal(UnreadCaptureRecovery recovery,
      OcrExtractionAttempt extraction, OcrInspection inspection) {
    final revision = recovery.noticeRevision;
    final hadClock = recovery.hasVerifiedIncomingSignal;
    recovery.verifyIncomingSignal(
        senderKey: extraction.latestIncomingSenderKey,
        sentAt: extraction.latestIncomingSentAt,
        capturedAt: inspection.capturedAt);
    if (recovery.noticeRevision != revision ||
        (!hadClock && recovery.hasVerifiedIncomingSignal)) {
      _diagnosticLog.record('unread_recovery.new_event', fields: {
        'customer': recovery.customer,
        'event_at': recovery.eventAt.toUtc().toIso8601String(),
        'previous_notice_cancelled': true,
      });
      _armUnreadRecoveryTimers(recovery);
    }
  }

  /// Only acquired, customer-verified media evidence may hide thumbnail OCR.
  Future<MediaAcquisition> _recordVerifiedUpload(OcrInspection inspection,
      String customer, OcrVisualRegion region, DateTime at, int slot) async {
    final event = _mediaAcquisitions.observe(
        customer, uploadEventKey(at, slot), at, inspection.capturedAt)
      ..acquired = true;
    _ocrMediaMasks.remember(inspection, customer, region);
    await (await _database.history)
        .recordMediaAcquisition(customer, event.toJson());
    return event;
  }

  /// A queued old timer cannot send before checking the current sender clock.
  /// In particular, a badge-only recovery never authorizes a resend request.
  Future<OcrInspection?> _preflightRecoveryNotice(
      UnreadCaptureRecovery recovery) async {
    try {
      await _adapter
          .openConversation(recovery.customer, allowActivation: true)
          .timeout(const Duration(seconds: 8));
      final windows =
          await _adapter.listOcrWindows().timeout(_fallbackInspectionTimeout);
      if (windows.isEmpty) return null;
      final window = windows.firstWhere((w) => w.title.contains('咚咚融合工作台'),
          orElse: () => windows.first);
      final inspection = await _adapter
          .inspectExpectedCustomer(
              windowId: window.windowId,
              expectedCustomer: recovery.customer,
              fast: true)
          .timeout(_fallbackInspectionTimeout);
      if (!identical(_unreadRecovery[recovery.customer], recovery)) return null;
      final extraction = _analyzeUnreadInspection(inspection, recovery);
      _observeRecoverySignal(recovery, extraction, inspection);
      // A notice preflight is read-only. Rectangles alone are not uploads and
      // must not create collection waits or mask a real text message.
      return inspection;
    } on PlatformException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  Future<void> _sendUnreadRecoveryNotice(UnreadCaptureRecovery recovery,
      {required bool resend}) async {
    if (!_autoCaptureRunning ||
        !identical(_unreadRecovery[recovery.customer], recovery) ||
        recovery.noticeSending) {
      return;
    }
    final noticeRevision = recovery.noticeRevision;
    recovery.noticeSending = true;
    try {
      await _withFallbackPriority(() async {
        if (!_autoCaptureRunning ||
            !identical(_unreadRecovery[recovery.customer], recovery)) {
          return;
        }
        if (noticeRevision != recovery.noticeRevision) return;
        if (await _database.isHumanContacting(recovery.customer)) {
          _finishUnreadRecovery(recovery.customer);
          return;
        }
        final preflight = await _preflightRecoveryNotice(recovery);
        if (await _newOutgoingAt(recovery) case final sentAt?) {
          _finishUnreadRecovery(recovery.customer, handledAt: sentAt);
          return;
        }
        if (!recovery.holdingSent) {
          final sentAt = await _holdingSentSinceRecovery(recovery);
          if (sentAt != null) {
            recovery.holdingSent = true;
            recovery.holdingSentAt = sentAt;
            _armUnreadResendTimer(recovery);
            if (!resend) return;
          }
        }
        if (await _hasRecoveredIncoming(recovery)) {
          if (recovery.holdingSentAt case final sentAt?) {
            await _database.acknowledgeUncapturedHolding(
                userId: recovery.customer, sentAt: sentAt);
            _slaFallbackTimers.remove(recovery.customer)?.cancel();
          }
          _finishUnreadRecovery(recovery.customer);
          _scheduleDraftGeneration(recovery.customer, newEvidence: false);
          return;
        }
        // A durable SLA row can belong to an older, still-generating batch.
        // Only _hasRecoveredIncoming above proves this recovery was captured.
        final now = DateTime.now();
        final freshSender = preflight == null
            ? null
            : _analyzeUnreadInspection(preflight, recovery)
                .latestIncomingSentAt;
        if (resend &&
            (freshSender == null ||
                freshSender != recovery.latestIncomingSentAt)) {
          recovery.requestImmediateCaptureRetry();
          _retryUnreadRecoveryNotice(recovery,
              resend: true, delay: const Duration(seconds: 5));
          return;
        }
        if (resend ? !recovery.resendDue(now) : !recovery.holdingDue(now)) {
          _armUnreadRecoveryTimers(recovery);
          return;
        }
        // Video decoding runs outside the UI queue and never suppresses a
        // customer's holding/resend deadline, including on decoder failure.
        if (!recovery.canSendHoldingAt(now)) {
          _diagnosticLog.record('unread_recovery.notice_suppressed', fields: {
            'customer': recovery.customer,
            'reason': 'sidebar_badge_without_fresh_incoming_sender_clock',
            'action': 'capture_retry_scheduled',
          });
          // The customer may simply be waiting in an unselected row. Do not
          // mark that unread badge as handled: doing so suppresses every later
          // row switch until JD happens to clear/reset the badge. Keep the
          // recovery and let the bounded capture cadence retry. Re-arming the
          // notice is essential: a later successful sender-clock scan must
          // still produce the holding message instead of being silently lost.
          _retryUnreadRecoveryNotice(recovery,
              resend: resend, delay: const Duration(seconds: 5));
          return;
        }
        // This is only a bounded check for a colleague's visible reply. The
        // capture loop owns text/media extraction; OCR failure must not block
        // the 20-second notice. sendDraftOnce verifies the customer again.
        try {
          final windows = preflight != null
              ? const <OcrWindowInfo>[]
              : await _adapter
                  .listOcrWindows()
                  .timeout(_fallbackInspectionTimeout);
          if (preflight != null || windows.isNotEmpty) {
            final reception = windows.isEmpty
                ? null
                : windows.firstWhere(
                    (window) => window.title.contains('咚咚融合工作台'),
                    orElse: () => windows.first);
            final inspection = preflight ??
                await _adapter
                    .inspectExpectedCustomer(
                      windowId: reception!.windowId,
                      expectedCustomer: recovery.customer,
                    )
                    .timeout(_fallbackInspectionTimeout);
            _observeRecoverySignal(recovery,
                _analyzeUnreadInspection(inspection, recovery), inspection);
            final visible =
                const OcrCaptureExtractor().analyze(inspection).capture;
            final history =
                await (await _database.history).read(recovery.customer);
            final knownMessages =
                (history?['messages'] as List<Object?>? ?? const [])
                    .whereType<Map<String, dynamic>>();
            final colleagueReply = visible?.messages.reversed
                .where((message) =>
                    message.direction == 'outgoing' &&
                    !isObservedGeneratedReply(
                        body: message.body,
                        sentAt: message.sentAt,
                        messages: knownMessages) &&
                    !recovery.knownOutgoingIds.contains(message.stableId) &&
                    !_isOwnHoldingReply(message.body) &&
                    message.body != _uncapturedResendReply &&
                    (message.sentAt?.isBefore(recovery.detectedAt) == false))
                .firstOrNull;
            if (colleagueReply != null) {
              _finishUnreadRecovery(recovery.customer,
                  handledAt: colleagueReply.sentAt);
              return;
            }
          }
        } on TimeoutException {
          // The verified send remains possible even if OCR is slow.
        } on PlatformException {
          // The send performs its own exact-customer verification.
        }
        if (!identical(_unreadRecovery[recovery.customer], recovery)) return;
        if (await _database.isHumanContacting(recovery.customer)) {
          _finishUnreadRecovery(recovery.customer);
          return;
        }
        if (await _newOutgoingAt(recovery) case final sentAt?) {
          _finishUnreadRecovery(recovery.customer, handledAt: sentAt);
          return;
        }
        if (!recovery.holdingSent) {
          final sentAt = await _holdingSentSinceRecovery(recovery);
          if (sentAt != null) {
            recovery.holdingSent = true;
            recovery.holdingSentAt = sentAt;
            _armUnreadResendTimer(recovery);
            if (!resend) return;
          }
        }
        if (await _hasRecoveredIncoming(recovery)) {
          if (recovery.holdingSentAt case final sentAt?) {
            await _database.acknowledgeUncapturedHolding(
                userId: recovery.customer, sentAt: sentAt);
            _slaFallbackTimers.remove(recovery.customer)?.cancel();
          }
          _finishUnreadRecovery(recovery.customer);
          _scheduleDraftGeneration(recovery.customer, newEvidence: false);
          return;
        }
        if (resend
            ? !recovery.resendDue(DateTime.now())
            : !recovery.holdingDue(DateTime.now())) {
          _armUnreadRecoveryTimers(recovery);
          return;
        }
        final uploadReceipt = uploadHoldingReceipt(
            _mediaAcquisitions.forCustomer(recovery.customer),
            recovery.latestIncomingSentAt);
        final receiptKey = uploadReceipt == null
            ? null
            : (resend ? '$uploadReceipt:readability' : uploadReceipt);
        final reply = resend && uploadReceipt != null
            ? '我已收到您发送的附件，但目前还没能读取完整内容。您希望我重点查看哪一处？我会继续帮您核对。'
            : resend
                ? _uncapturedResendReply
                : _uncapturedHoldingReply;
        final journalKey = receiptKey ??
            'unread-recovery:${recovery.eventAt.microsecondsSinceEpoch}:${resend ? 'resend' : 'holding'}';
        final journal = await _fallbackJournal;
        if (!_autoCaptureRunning) return;
        if (!await journal.reserve(recovery.customer, journalKey)) {
          if (resend) {
            recovery.resendSent = true;
          } else {
            recovery.holdingSent = true;
            recovery.holdingSentAt ??= DateTime.now();
            _armUnreadResendTimer(recovery);
          }
          return;
        }
        try {
          await _adapter.sendDraftOnce(
              expectedCustomer: recovery.customer,
              reply: reply,
              mediaPaths: const []);
        } on PlatformException catch (error) {
          if (_definitelyBeforeSend(error)) {
            await journal.releaseBeforeSend(recovery.customer, journalKey);
          }
          rethrow;
        }
        final sentAt = DateTime.now();
        if (resend) {
          recovery.resendSent = true;
        } else {
          recovery.holdingSent = true;
          recovery.holdingSentAt = sentAt;
          _armUnreadResendTimer(recovery);
        }
        try {
          await (await _database.history).appendSlaFallbackSent(
            userId: recovery.customer,
            messageId:
                'unread-recovery:${recovery.eventAt.microsecondsSinceEpoch}:${resend ? 'resend' : 'holding'}',
            reply: reply,
            receiptKey: receiptKey,
          );
          if (!resend) {
            await _database.acknowledgeUncapturedHolding(
                userId: recovery.customer, sentAt: sentAt);
            _slaFallbackTimers.remove(recovery.customer)?.cancel();
          }
        } catch (error) {
          // JD already confirmed the send. Never repeat it merely because
          // local history storage failed afterward.
          if (mounted) setState(() => _error = error);
        }
        if (mounted) {
          setState(() => _diagnostics = resend
              ? 'Asked ${recovery.customer} to resend content that could not be captured.'
              : 'Sent a holding message to ${recovery.customer} while capture retries continue.');
        }
        if (resend) {
          _finishUnreadRecovery(recovery.customer, handledAt: sentAt);
        }
      });
    } on PlatformException catch (error) {
      if (_isIdentityOpenFailure(error.code)) {
        // Recovery already belongs to a verified customer. A missing row or
        // transient menu/layout change is not evidence that their ID is bad.
        // Preserve both deadlines and retry without blocking other customers.
        _retryUnreadRecoveryNotice(recovery,
            resend: resend, delay: const Duration(seconds: 5));
      } else {
        // A notice that was not confirmed returns to its retry timer instead
        // of resolving this recovery without a customer-visible send.
        _retryUnreadRecoveryNotice(recovery, resend: resend);
      }
      if (mounted) setState(() => _error = error);
    } catch (error) {
      if (ResilientDatabase.isContention(error)) {
        try {
          final job = await _fallbackJobFromHistory(recovery.customer);
          if (job != null && await _hasRecoveredIncoming(recovery)) {
            await _sendFallbackDuringDatabaseContention(job);
          } else {
            await _sendUncapturedNoticeWithoutDatabase(recovery,
                resend: resend);
          }
        } catch (noticeError) {
          _diagnosticLog.record('unread_recovery.storage_retry', fields: {
            'customer': recovery.customer,
            'error': noticeError.toString(),
          });
        }
      }
      _retryUnreadRecoveryNotice(recovery, resend: resend);
      if (mounted) setState(() => _error = error);
    } finally {
      recovery.noticeSending = false;
      if (noticeRevision != recovery.noticeRevision &&
          identical(_unreadRecovery[recovery.customer], recovery)) {
        _armUnreadRecoveryTimers(recovery);
      }
    }
  }

  Future<void> _sendUncapturedNoticeWithoutDatabase(
      UnreadCaptureRecovery recovery,
      {required bool resend}) async {
    if (!_autoCaptureRunning ||
        !identical(_unreadRecovery[recovery.customer], recovery) ||
        _transferringCustomers.contains(recovery.customer) ||
        !recovery.canSendHoldingAt(DateTime.now())) {
      return;
    }
    await _withFallbackPriority(() async {
      if (!_autoCaptureRunning ||
          !identical(_unreadRecovery[recovery.customer], recovery)) {
        return;
      }
      final inspection = await _preflightRecoveryNotice(recovery);
      final freshSender = inspection == null
          ? null
          : _analyzeUnreadInspection(inspection, recovery).latestIncomingSentAt;
      if (resend &&
          (freshSender == null ||
              freshSender != recovery.latestIncomingSentAt)) {
        return;
      }
      if (await _newOutgoingAt(recovery) != null) return;
      if (resend
          ? !recovery.resendDue(DateTime.now())
          : !recovery.holdingDue(DateTime.now())) {
        _armUnreadRecoveryTimers(recovery);
        return;
      }
      if (!resend &&
          (recovery.holdingSent ||
              await _holdingSentSinceRecovery(recovery) != null)) {
        return;
      }
      final journal = await _fallbackJournal;
      final messageId =
          'unread-recovery:${recovery.eventAt.microsecondsSinceEpoch}:${resend ? 'resend' : 'holding'}';
      if (!_autoCaptureRunning) return;
      if (!await journal.reserve(recovery.customer, messageId)) return;
      final upload = uploadHoldingReceipt(
          _mediaAcquisitions.forCustomer(recovery.customer),
          recovery.latestIncomingSentAt);
      final reply = resend && upload != null
          ? '我已收到您发送的附件，但目前还没能读取完整内容。您希望我重点查看哪一处？我会继续帮您核对。'
          : resend
              ? _uncapturedResendReply
              : _uncapturedHoldingReply;
      try {
        await _adapter.sendDraftOnce(
            expectedCustomer: recovery.customer,
            reply: reply,
            mediaPaths: const []);
      } on PlatformException catch (error) {
        if (_definitelyBeforeSend(error)) {
          await journal.releaseBeforeSend(recovery.customer, messageId);
        }
        rethrow;
      }
      await (await _database.history).appendSlaFallbackSent(
          userId: recovery.customer, messageId: messageId, reply: reply);
      if (resend) {
        recovery.resendSent = true;
        _finishUnreadRecovery(recovery.customer);
      } else {
        recovery.holdingSent = true;
        recovery.holdingSentAt = DateTime.now();
        _armUnreadResendTimer(recovery);
      }
    });
  }

  void _retryUnreadRecoveryNotice(UnreadCaptureRecovery recovery,
      {required bool resend, Duration delay = const Duration(seconds: 2)}) {
    if (!identical(_unreadRecovery[recovery.customer], recovery)) return;
    final timers = resend ? _unreadResendTimers : _unreadHoldingTimers;
    timers.remove(recovery.customer)?.cancel();
    timers[recovery.customer] = Timer(
      delay,
      () => unawaited(_sendUnreadRecoveryNotice(recovery, resend: resend)),
    );
  }

  void _scheduleDraftGeneration(String userId, {required bool newEvidence}) {
    unawaited(_scheduleSlaFallback(userId));
    if (newEvidence) {
      _draftRetryTimers.remove(userId)?.cancel();
      _batchCollectionTimers.remove(userId)?.cancel();
      _batchCollectionTimers[userId] = Timer(_batchCollectionWindow, () {
        _batchCollectionTimers.remove(userId);
        unawaited(_queueDraftIfPending(userId));
      });
      return;
    }
    if (_batchCollectionTimers.containsKey(userId)) return;
    if (!newEvidence &&
        (_draftRetryTimers.containsKey(userId) ||
            _draftQueue.contains(userId) ||
            _activeDraftUsers.contains(userId))) {
      return;
    }
    unawaited(_queueDraftIfPending(userId));
  }

  Future<void> _queueDraftIfPending(String userId) async {
    try {
      await _queueDraftIfPendingChecked(userId);
    } catch (error) {
      _diagnosticLog.record('generation.queue_retry', fields: {
        'customer': userId,
        'error': error.toString(),
      });
      _scheduleDraftRetry(userId);
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _queueDraftIfPendingChecked(String userId) async {
    if (_mediaAcquisitions.deferGeneration(userId, DateTime.now())) {
      _draftRetryTimers.remove(userId)?.cancel();
      _draftRetryTimers[userId] = Timer(const Duration(seconds: 1), () {
        _draftRetryTimers.remove(userId);
        unawaited(_queueDraftIfPending(userId));
      });
      return;
    }
    final videos = await _videoCaptureQueue;
    await videos.initialize();
    // Only this customer's next generation waits for its owned media files.
    // Other customers and already generated replies proceed independently.
    if (videos.hasCustomer(userId)) return;
    final attachments = await _attachmentDownloads;
    await attachments.initialize();
    if (attachments.hasCustomer(userId)) return;
    if (!await _database.hasPendingUnanswered(userId) ||
        await _database.isHumanContacting(userId)) {
      return;
    }
    if (_activeDraftUsers.contains(userId) ||
        await _database.hasUndeliveredDraft(userId)) {
      return;
    }
    final pendingMessageId = await _database.pendingMessageId(userId);
    if (pendingMessageId == null) return;
    _draftQueue.add(userId);
    _runDraftWorkers();
  }

  Future<void> _scheduleSlaFallback(String userId) async {
    SlaFallbackJob? job;
    try {
      job = await _database.slaFallbackJob(userId);
    } catch (error) {
      if (!ResilientDatabase.isContention(error)) rethrow;
      job = await _fallbackJobFromHistory(userId);
    }
    if (job == null) {
      _slaFallbackTimers.remove(userId)?.cancel();
      return;
    }
    _armSlaFallback(job);
  }

  Future<SlaFallbackJob?> _fallbackJobFromHistory(String userId) async {
    final document = await (await _database.history).read(userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final incoming = messages
        .where((message) => message['direction'] == 'incoming')
        .lastOrNull;
    final capturedAt =
        DateTime.tryParse(incoming?['captured_at']?.toString() ?? '');
    if (incoming == null ||
        capturedAt == null ||
        DateTime.now().difference(capturedAt) > const Duration(minutes: 10)) {
      return null;
    }
    return SlaFallbackJob(
        userId: userId,
        messageId: incoming['id'].toString(),
        dueAt: capturedAt.add(CaptureDatabase.slaFallbackDelay));
  }

  Future<bool> _sendHoldingWithJournal(SlaFallbackJob job, String reply) async {
    final store = await _database.history;
    final document = await store.read(job.userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final incomingIndex = messages.indexWhere((message) =>
        message['id'] == job.messageId && message['direction'] == 'incoming');
    if (incomingIndex < 0 || await _hasReplySinceSlaMessage(job)) return false;
    final lastFinal = messages.lastIndexWhere(isConfirmedOutgoingReply);
    final lastHolding = messages
        .lastIndexWhere((message) => message['source'] == 'sla_fallback');
    if (lastHolding > lastFinal) {
      final heldAt =
          DateTime.tryParse(messages[lastHolding]['sent_at']?.toString() ?? '');
      final incomingAt = DateTime.tryParse(
          messages[incomingIndex]['sent_at']?.toString() ?? '');
      if (heldAt == null || incomingAt == null || !incomingAt.isAfter(heldAt)) {
        return false;
      }
      final remaining =
          heldAt.add(const Duration(seconds: 50)).difference(DateTime.now());
      if (!remaining.isNegative) {
        await _database.releaseSlaFallback(
            userId: job.userId,
            messageId: job.messageId,
            retryDelay: remaining);
        unawaited(_scheduleSlaFallback(job.userId));
        return false;
      }
    }
    final receiptKey = uploadHoldingReceipt(
        _mediaAcquisitions.forCustomer(job.userId),
        DateTime.tryParse(
            messages[incomingIndex]['sent_at']?.toString() ?? ''));
    if (receiptKey != null &&
        messages.any((m) => m['media_event_receipt'] == receiptKey)) {
      return false;
    }
    final journal = await _fallbackJournal;
    final journalKey = receiptKey ?? job.messageId;
    if (!await journal.reserve(job.userId, journalKey)) return false;
    try {
      await _adapter.sendDraftOnce(
          expectedCustomer: job.userId, reply: reply, mediaPaths: const []);
    } on PlatformException catch (error) {
      if (_definitelyBeforeSend(error)) {
        await journal.releaseBeforeSend(job.userId, journalKey);
      }
      rethrow;
    }
    // Preserve a confirmed send before touching SQLite. An SQL failure must
    // never lose this receipt and cause a second customer-visible holding.
    await store.appendSlaFallbackSent(
        userId: job.userId,
        messageId: job.messageId,
        reply: reply,
        receiptKey: receiptKey);
    return true;
  }

  Future<void> _sendFallbackDuringDatabaseContention(SlaFallbackJob job) async {
    if (!_autoCaptureRunning || _transferringCustomers.contains(job.userId)) {
      return;
    }
    await _withFallbackPriority(() async {
      if (!_autoCaptureRunning || await _hasReplySinceSlaMessage(job)) return;
      final freshJob = await _fallbackJobFromHistory(job.userId);
      if (freshJob == null) return;
      await _adapter
          .openConversation(job.userId, allowActivation: true)
          .timeout(const Duration(seconds: 8));
      final sent = await _sendHoldingWithJournal(job, _uncapturedHoldingReply);
      _diagnosticLog.record('fallback.independent_storage', fields: {
        'customer': job.userId,
        'sent': sent,
        'original_reply_still_pending': true,
      });
    });
    _scheduleDraftRetry(job.userId);
  }

  void _armSlaFallback(SlaFallbackJob job) {
    _slaFallbackTimers.remove(job.userId)?.cancel();
    final remaining = job.dueAt.difference(DateTime.now());
    final delay = remaining.isNegative ? Duration.zero : remaining;
    _slaFallbackTimers[job.userId] = Timer(delay, () {
      _slaFallbackTimers.remove(job.userId);
      unawaited(_sendSlaFallback(job));
    });
  }

  Future<bool> _hasReplySinceSlaMessage(SlaFallbackJob job) async {
    final document = await (await _database.history).read(job.userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    return messages.any((message) {
      return !_isOwnHoldingReply(message['body']?.toString()) &&
          replyAnswersIncoming(
              reply: message, incomingId: job.messageId, messages: messages);
    });
  }

  Future<void> _sendSlaFallback(SlaFallbackJob job) async {
    if (!_autoCaptureRunning) return;
    try {
      final document = await (await _database.history).read(job.userId);
      final incomingBodies =
          (document?['messages'] as List<Object?>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .where((message) => message['direction'] == 'incoming')
              .map((message) => message['body']?.toString() ?? '')
              .where((body) => body.trim().isNotEmpty)
              .toList(growable: false);
      final latestCustomerText = incomingBodies
              .where((body) => !body.startsWith('[Customer sent'))
              .lastOrNull ??
          incomingBodies.lastOrNull ??
          '';
      final holdingReply = chooseHoldingReply(latestCustomerText);
      await _withFallbackPriority(() async {
        if (!await _database.reserveSlaFallback(
            userId: job.userId, messageId: job.messageId, dueAt: job.dueAt)) {
          return;
        }
        try {
          // Do this before touching JingMai. A transfer welcome, manual reply,
          // or generated reply may already have answered the turn while the
          // timer was waiting. Such a row is terminal, not retryable.
          if (await _hasReplySinceSlaMessage(job)) {
            await _database.completeSlaFallbackAfterReply(
              userId: job.userId,
              messageId: job.messageId,
            );
            return;
          }
          await _adapter
              .openConversation(job.userId, allowActivation: true)
              .timeout(const Duration(seconds: 8));
          // The timer may have reserved this job before a generated or manual
          // reply completed. Recheck at the last possible point so a holding
          // message can never follow a real reply from the same SLA window.
          if (!await _database.isSlaFallbackReservedForSend(
              userId: job.userId, messageId: job.messageId)) {
            return;
          }
          if (await _hasReplySinceSlaMessage(job)) {
            await _database.completeSlaFallbackAfterReply(
              userId: job.userId,
              messageId: job.messageId,
            );
            return;
          }
          if (!await _sendHoldingWithJournal(job, holdingReply)) {
            await _database.completeSlaFallbackAfterReply(
                userId: job.userId, messageId: job.messageId);
            return;
          }
          final recorded = await _database.markSlaFallbackSent(
            userId: job.userId,
            messageId: job.messageId,
            reply: holdingReply,
          );
          if (recorded && mounted) {
            setState(() => _diagnostics =
                'Sent a holding message to ${job.userId}; the final answer remains queued.');
          }
        } on PlatformException catch (_) {
          await _database.releaseSlaFallback(
            userId: job.userId,
            messageId: job.messageId,
          );
          unawaited(_scheduleSlaFallback(job.userId));
          rethrow;
        } catch (_) {
          await _database.releaseSlaFallback(
            userId: job.userId,
            messageId: job.messageId,
          );
          unawaited(_scheduleSlaFallback(job.userId));
          rethrow;
        }
      });
      await _coordinator.refresh();
    } catch (error) {
      if (ResilientDatabase.isContention(error)) {
        try {
          await _sendFallbackDuringDatabaseContention(job);
        } catch (fallbackError) {
          _diagnosticLog.record('fallback.independent_storage_failed', fields: {
            'customer': job.userId,
            'error': fallbackError.toString(),
          });
          if (_autoCaptureRunning) {
            _slaFallbackTimers[job.userId] = Timer(const Duration(seconds: 2),
                () => unawaited(_sendSlaFallback(job)));
          }
        }
      }
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _runAutoCaptureCycle() async {
    // Capture and delivery share the same serialized JingMai UI queue. Queue
    // the capture instead of dropping it while a delivery is active: sidebar
    // detection alone cannot verify or save a message in an unselected row.
    if (!_autoCaptureRunning || _autoCaptureBusy) {
      return;
    }
    _autoCaptureBusy = true;
    final scanStartedAt = DateTime.now();
    if (mounted) {
      setState(() {
        _error = null;
        _diagnostics =
            'Checking JD unread messages at ${_formatClock(scanStartedAt)}…';
      });
    }
    try {
      // Baseline polling does not activate JD. A verified unread media bubble
      // may briefly bring it forward to inspect the video play overlay, then
      // restore the operator's previous frontmost application.
      final rows = await _withJdUiOperation(() async {
        if (!_autoCaptureRunning || !mounted) return <QianniuConversationRow>[];
        await _adapter.ensureReceptionWindow(allowActivation: false);
        return _reconciledConversationRows().timeout(_unreadOperationTimeout);
      },
          label: 'capture.sidebar',
          priority: UiPriority.capture,
          timeout: const Duration(seconds: 18));
      if (rows.isEmpty) {
        if (mounted) {
          setState(() => _diagnostics =
              'No safely identified JD conversation rows are available; no chat was opened.');
        }
        return;
      }
      for (final row in rows) {
        _observeSidebarUnread(row);
        _refreshHandledUnread(row);
      }
      final evidenceAvailable = rows.any((row) => row.evidenceAvailable);
      for (final row in rows.where((row) => !row.unread)) {
        _processingUnreadEvidence.remove(row.customer);
        _lastUnreadProbeAt.remove(row.customer);
      }
      for (final row in rows.where((row) => row.unread)) {
        if (_hasVerifiedSidebarUnread(row)) {
          _unreadRecovery[row.customer]?.verifySidebarUnread();
        }
        if (!row.identityNeedsAxVerification &&
            !_unreadRecovery.containsKey(row.customer) &&
            !_handledUnreadEvidence.containsKey(row.customer) &&
            !await _database.isHumanContacting(row.customer)) {
          await _beginUnreadRecovery(row.customer, row.unreadEvidence,
              detectedAt: _unreadDetectedAt(row),
              sidebarUnreadVerified: _hasVerifiedSidebarUnread(row));
        }
      }
      final orderedRows = rows.where((row) {
        if (_mediaAcquisitions.retryDue(row.customer, DateTime.now())) {
          return true;
        }
        final recovery = _unreadRecovery[row.customer];
        if (recovery != null) {
          return recovery.captureRetryDue(DateTime.now());
        }
        return (evidenceAvailable &&
                row.unread &&
                !_processingUnreadEvidence.containsKey(row.customer) &&
                !_handledUnreadEvidence.containsKey(row.customer)) ||
            (row.unread &&
                !_handledUnreadEvidence.containsKey(row.customer) &&
                (_lastUnreadProbeAt[row.customer] == null ||
                    DateTime.now()
                            .difference(_lastUnreadProbeAt[row.customer]!) >=
                        const Duration(seconds: 8)));
      }).toList(growable: false);
      if (orderedRows.isEmpty) {
        var insertedFromActiveChat = 0;
        await _withJdUiOperation(() async {
          if (!_autoCaptureRunning || !mounted) return;
          final windows =
              await _adapter.listOcrWindows().timeout(_captureOperationTimeout);
          if (windows.isNotEmpty) {
            final reception = windows.firstWhere(
                (window) => window.title.contains('咚咚融合工作台'),
                orElse: () => windows.first);
            final inspection =
                await _inspectStableConversation(reception.windowId);
            if (mounted) setState(() => _ocrInspection = inspection);
            // JD does not expose an unread flag for the active sidebar row.
            // Poll the already-open chat independently; durable message IDs
            // prevent duplicate saves while keeping the unread count truthful.
            final activeCustomer = inspection.activeCustomerId?.trim();
            if (activeCustomer != null &&
                activeCustomer.isNotEmpty &&
                rows.any((row) => row.customer == activeCustomer)) {
              final activeRow =
                  rows.firstWhere((row) => row.customer == activeCustomer);
              var recovery = _unreadRecovery[activeCustomer];
              final extraction = _analyzeUnreadInspection(inspection, recovery);
              final senderKey = extraction.latestIncomingSenderKey;
              final incomingTime = extraction.latestIncomingSentAt;
              final recentIncoming = incomingTime != null &&
                  !incomingTime.isBefore(inspection.capturedAt
                      .subtract(const Duration(minutes: 10))) &&
                  !incomingTime.isAfter(
                      inspection.capturedAt.add(const Duration(minutes: 1)));
              if (recovery == null &&
                  (activeRow.unread || recentIncoming) &&
                  (extraction.latestVisibleSenderIsIncoming ||
                      await _hasUncapturedRecentVisibleMedia(
                          inspection, activeCustomer)) &&
                  senderKey != null &&
                  _handledIncomingSenderKeys[activeCustomer] != senderKey &&
                  !await _database.isHumanContacting(activeCustomer)) {
                await _beginUnreadRecovery(
                    activeCustomer, activeRow.unreadEvidence,
                    detectedAt: activeRow.unread
                        ? _unreadDetectedAt(activeRow)
                        : incomingTime);
                recovery = _unreadRecovery[activeCustomer];
              }
              if (recovery != null) {
                _observeRecoverySignal(recovery, extraction, inspection);
              }
              if (!extraction.transferNoticeVisible) {
                _visibleTransferWelcomes.remove(activeCustomer);
              }
              if (!await _database.isHumanContacting(activeCustomer)) {
                // The selected chat may never show a sidebar unread badge.
                // Its sender clock can start recovery, and this same pass must
                // inspect the media bubble instead of waiting for a row scan.
                final capture = await _captureWithVisibleMedia(
                  inspection,
                  extraction,
                  // A media-only turn can have no OCR sender/body and JD may
                  // clear its unread badge as soon as this chat is opened.
                  // Let the bounded visual candidate check recover that turn.
                  allowUnlabeledLatestImage:
                      recovery != null || extraction.capture == null,
                  allowRecoveryAfterHolding: recovery?.holdingSent == true,
                );
                if (capture != null) {
                  insertedFromActiveChat = await _database.saveCapture(capture);
                }
                if (recovery != null &&
                    insertedFromActiveChat > 0 &&
                    capture != null &&
                    capture.messages.any((message) =>
                        message.direction == 'incoming' &&
                        recovery!.acceptsIncoming(message.stableId,
                            sentAt: message.sentAt,
                            capturedAt: capture.capturedAt))) {
                  await _database.capSlaFallbackDue(
                    userId: activeCustomer,
                    dueAt: recovery.eventAt
                        .add(UnreadCaptureRecovery.holdingAfter),
                  );
                  if (recovery.holdingSentAt case final sentAt?) {
                    await _database.acknowledgeUncapturedHolding(
                        userId: activeCustomer, sentAt: sentAt);
                    _slaFallbackTimers.remove(activeCustomer)?.cancel();
                  }
                  _finishUnreadRecovery(activeCustomer,
                      expectedRecovery: recovery);
                }
                await _database.ensurePendingForUnanswered(activeCustomer);
                if (await _database.hasPendingUnanswered(activeCustomer)) {
                  _scheduleDraftGeneration(activeCustomer,
                      newEvidence: insertedFromActiveChat > 0);
                }
                if (insertedFromActiveChat > 0) await _coordinator.refresh();
              }
              if (extraction.transferNoticeVisible) {
                await _handleTransferNotice(
                  activeCustomer,
                  extraction.transferNoticeKey ??
                      'visible-transfer-${inspection.capturedAt.day}',
                );
              }
            }
          }
        },
            label: 'capture.active_customer',
            priority: UiPriority.capture,
            timeout: const Duration(seconds: 35));
        if (mounted) {
          setState(() => _diagnostics = evidenceAvailable
              ? insertedFromActiveChat > 0
                  ? 'Scan ${_formatClock(scanStartedAt)}: no unread conversations were detected; saved $insertedFromActiveChat unseen message(s) from the already-open JD chat.'
                  : 'Scan ${_formatClock(scanStartedAt)}: checked ${rows.length} customer rows; no unread conversations were detected. The already-open JD chat was checked and contained no unseen messages.'
              : 'Scan ${_formatClock(scanStartedAt)}: unread screenshot evidence was unavailable. Automatic row switching was skipped to avoid stealing keyboard focus.');
        }
        return;
      }
      final windows =
          await _adapter.listOcrWindows().timeout(_captureOperationTimeout);
      if (windows.isEmpty) {
        throw StateError('No visible JD 咚咚 window is available.');
      }
      final reception = windows.firstWhere(
          (window) => window.title.contains('咚咚融合工作台'),
          orElse: () => windows.first);
      var insertedTotal = 0;
      for (final row in orderedRows) {
        if (!_autoCaptureRunning) break;
        var customer = row.customer;
        try {
          await _withJdUiOperation(() async {
            if (!_autoCaptureRunning || !mounted) return;
            if (row.identityNeedsAxVerification) {
              final observed = row.observedCustomer ?? customer;
              customer = await _adapter
                  .resolveConversationIdentityFromAx(observed,
                      allowActivation: _hasVerifiedSidebarUnread(row))
                  .timeout(_unreadOperationTimeout);
              _trustedCustomerIds = {..._trustedCustomerIds, customer};
              _diagnosticLog
                  .record('conversation.identity_reconciled', fields: {
                'observed_customer': observed,
                'verified_customer': customer,
                'basis': 'active_ax_header',
              });
            }
            if (row.unread) _lastUnreadProbeAt[customer] = DateTime.now();
            // Human takeover is scoped to one customer. Keep monitoring every
            // other row while leaving this customer's Qianniu chat untouched.
            if (await _database.isHumanContacting(customer)) return;
            if (row.unread &&
                !_unreadRecovery.containsKey(customer) &&
                !_handledUnreadEvidence.containsKey(customer)) {
              await _beginUnreadRecovery(customer, row.unreadEvidence,
                  detectedAt: _unreadDetectedAt(row),
                  sidebarUnreadVerified: _hasVerifiedSidebarUnread(row));
            }
            var recovery = _unreadRecovery[customer];
            recovery?.recordCaptureAttempt(DateTime.now());
            await _adapter
                .openConversation(customer,
                    allowActivation:
                        recovery?.canSendHoldingAt(DateTime.now()) == true)
                .timeout(_unreadOperationTimeout);
            final inspection = await _adapter
                .inspectExpectedCustomer(
                  windowId: reception.windowId,
                  expectedCustomer: customer,
                )
                .timeout(_unreadOperationTimeout);
            if (mounted) setState(() => _ocrInspection = inspection);
            recovery = _unreadRecovery[customer];
            final extraction = _analyzeUnreadInspection(inspection, recovery);
            final senderKey = extraction.latestIncomingSenderKey;
            if (recovery == null &&
                row.unread &&
                (extraction.latestVisibleSenderIsIncoming ||
                    await _hasUncapturedRecentVisibleMedia(
                        inspection, customer)) &&
                senderKey != null &&
                _handledIncomingSenderKeys[customer] != senderKey) {
              await _beginUnreadRecovery(customer, row.unreadEvidence,
                  detectedAt: _unreadDetectedAt(row));
              recovery = _unreadRecovery[customer];
            }
            if (recovery != null) {
              _observeRecoverySignal(recovery, extraction, inspection);
            }
            if (!extraction.transferNoticeVisible) {
              _visibleTransferWelcomes.remove(customer);
            }
            final capture = await _captureWithVisibleMedia(
                    inspection, extraction,
                    allowUnlabeledLatestImage: row.unread || recovery != null,
                    allowRecoveryAfterHolding: recovery?.holdingSent == true)
                .timeout(_captureOperationTimeout);
            var insertedForCustomer = 0;
            if (capture != null) {
              insertedForCustomer = await _database.saveCapture(capture);
              insertedTotal += insertedForCustomer;
            }
            final capturedNewIncoming = recovery != null &&
                insertedForCustomer > 0 &&
                (extraction.latestVisibleSenderIsIncoming ||
                    extraction.capture == null ||
                    (recovery.holdingSent &&
                        _isOwnHoldingReply(
                            extraction.capture?.messages.lastOrNull?.body)) ||
                    (capture?.messages.any((message) =>
                            message.direction == 'incoming' &&
                            message.media.isNotEmpty) ==
                        true)) &&
                capture != null &&
                capture.messages.any((message) =>
                    message.direction == 'incoming' &&
                    recovery!.acceptsIncoming(message.stableId,
                        sentAt: message.sentAt,
                        capturedAt: capture.capturedAt));
            if (capturedNewIncoming) {
              await _database.capSlaFallbackDue(
                userId: customer,
                dueAt: recovery.eventAt.add(UnreadCaptureRecovery.holdingAfter),
              );
              if (recovery.holdingSentAt case final sentAt?) {
                await _database.acknowledgeUncapturedHolding(
                    userId: customer, sentAt: sentAt);
                _slaFallbackTimers.remove(customer)?.cancel();
              }
              _finishUnreadRecovery(customer, expectedRecovery: recovery);
            }
            if (capturedNewIncoming ||
                (recovery == null &&
                    (capture != null || extraction.transferNoticeVisible))) {
              _processingUnreadEvidence[customer] = row.unreadEvidence;
            }
            await _database.ensurePendingForUnanswered(customer);
            // Queue the durable current message immediately. Optional history
            // scrolling must never prevent an already-saved customer turn from
            // reaching Codex.
            if (await _database.hasPendingUnanswered(customer)) {
              _scheduleDraftGeneration(customer,
                  newEvidence: insertedForCustomer > 0);
            }
            if (extraction.transferNoticeVisible) {
              await _handleTransferNotice(
                customer,
                extraction.transferNoticeKey ?? row.unreadEvidence.toString(),
              );
            }

            // Never scroll into history. Only the current bottom viewport may
            // create work, so one unread turn cannot produce one historical
            // reply followed by another reply for the actual latest item.
            if (mounted) setState(() => _ocrInspection = inspection);
          },
              customer: row.identityNeedsAxVerification ? null : customer,
              label: 'capture.customer',
              priority: UiPriority.capture,
              timeout: const Duration(seconds: 35));
        } on PlatformException catch (error) {
          _diagnosticLog.record('capture.customer_failed', fields: {
            'expected_customer': customer,
            'code': error.code,
            'error': error.toString(),
          });
          if (error.code == 'composer_not_empty') break;
          if (_isIdentityOpenFailure(error.code)) {
            final observed = row.observedCustomer ?? customer;
            // Quarantine only the uncertain OCR spelling. A transient native
            // row-read failure for the already trusted exact ID must not hide
            // a real unread customer for two minutes.
            if (observed != customer) {
              _quarantineIdentity(observed, error.code);
            }
          }
          if (error.code == 'qianniu_not_frontmost') {
            if (mounted) {
              setState(() => _diagnostics =
                  'Unread conversation detected, but JD 咚咚 is not the active application. Capture deferred without stealing focus.');
            }
            break;
          }
          if (mounted) setState(() => _error = error);
          // One unverified customer must not starve the remaining rows.
        } on TimeoutException catch (error) {
          _diagnosticLog.record('capture.customer_timeout', fields: {
            'expected_customer': customer,
            'error': error.toString(),
          });
          if (mounted) setState(() => _error = error);
        }
        // Give an already-due holding message or delivery a turn before
        // switching to another customer. A busy multi-chat scan must not
        // monopolize the single JD UI queue past the response deadline.
        _requestDelivery();
      }
      await _coordinator.refresh();
      if (mounted) {
        final unreadCount = rows.where((row) => row.unread).length;
        final unreadEvidenceAvailable =
            rows.any((row) => row.evidenceAvailable);
        setState(() => _diagnostics = insertedTotal == 0
            ? 'Scan ${_formatClock(scanStartedAt)} completed for ${rows.length} customers; '
                '${unreadEvidenceAvailable ? '$unreadCount unread row(s) were prioritized' : 'unread screenshot evidence was unavailable'}; '
                'no unseen messages were saved; $_visibleMediaTrace.'
            : 'Scan ${_formatClock(scanStartedAt)} prioritized $unreadCount unread row(s) and saved '
                '$insertedTotal unseen message(s) across ${rows.length} customers. '
                'Draft generation is queued separately.');
      }
    } on TimeoutException catch (error) {
      if (mounted) {
        final text =
            'Scan ${_formatClock(scanStartedAt)} timed out during a JD operation. It was released; the next 2-second sidebar check will retry.';
        _errorState.record(error, displayedText: text, surface: 'diagnostics');
        setState(() => _diagnostics = text);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      _autoCaptureBusy = false;
      _requestDelivery();
    }
  }

  /// Let a newly selected JD conversation settle, then perform one Apple
  /// Vision pass over the complete visible conversation.
  Future<OcrInspection> _inspectStableConversation(int windowId) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return _adapter
        .inspectOcr(windowId: windowId)
        .timeout(_captureOperationTimeout);
  }

  String _formatClock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:'
      '${value.second.toString().padLeft(2, '0')}';

  Future<void> _handleTransferNotice(String userId, String eventKey) async {
    if (!_visibleTransferWelcomes.add(userId)) return;
    // A transferred chat can already contain the customer's real question.
    // Preserve that queued answer and record the transfer as handled without
    // inserting a generic welcome in front of it.
    if (await _database.hasPendingUnanswered(userId) ||
        await _database.hasUndeliveredDraft(userId) ||
        _mediaAcquisitions
            .forCustomer(userId)
            .any((event) => !event.acquired)) {
      await _database.reserveTransferWelcome(
          userId: userId,
          eventKey: eventKey,
          minimumInterval: const Duration(minutes: 10));
      return;
    }
    await _sendTransferWelcomeOnce(userId, eventKey);
  }

  Future<bool> _sendTransferWelcomeOnce(String userId, String eventKey) async {
    if (!await _database.reserveTransferWelcome(
        userId: userId,
        eventKey: eventKey,
        minimumInterval: const Duration(minutes: 10))) {
      return false;
    }
    const welcome = LocalReplyRouter.transferWelcome;
    try {
      await _adapter.sendDraftOnce(
        expectedCustomer: userId,
        reply: welcome,
        mediaPaths: const [],
      );
    } on PlatformException catch (_) {
      // A failed or ambiguous welcome must not leave this conversation
      // permanently reserved. Release it so the visible transfer can retry on
      // a later scan; the operator has chosen progress over a permanent freeze.
      await _database.releaseTransferWelcomeReservation(
        userId: userId,
        eventKey: eventKey,
      );
      _visibleTransferWelcomes.remove(userId);
      rethrow;
    }
    await _database.appendAutomatedNoticeSent(userId: userId, reply: welcome);
    _handledUnreadEvidence[userId] = int.tryParse(eventKey) ?? 0;
    _handledUnreadAt[userId] = DateTime.now();
    if (mounted) {
      setState(() => _diagnostics =
          'Detected a JD transfer and sent one welcome message to $userId.');
    }
    return true;
  }

  void _runDraftWorkers() {
    while (_activeDraftUsers.length < _maxConcurrentDraftWorkers &&
        _draftQueue.isNotEmpty) {
      String? userId;
      for (final candidate in _draftQueue) {
        // One customer owns at most one active Codex process. A later turn
        // waits until the frozen reply is delivered, while up to twenty
        // different customers generate in parallel. Every
        // worker starts its own Codex CLI turn with its own input and output
        // file; customer sessions and histories are never shared.
        if (!_activeDraftUsers.contains(candidate)) {
          userId = candidate;
          break;
        }
      }
      if (userId == null) break;
      _draftQueue.remove(userId);
      _activeDraftUsers.add(userId);
      final cancellation = CodexGenerationCancellation();
      _activeDraftCancellations[userId] = cancellation;
      unawaited(_runDraftWorker(userId, cancellation));
    }
  }

  Future<void> _runDraftWorker(
      String userId, CodexGenerationCancellation cancellation) async {
    final mediaVersion = _mediaEvidenceVersions[userId] ?? 0;
    try {
      await _processDraftUser(userId, cancellation);
    } on CodexGenerationCancelled {
      _diagnosticLog
          .record('generation.cancelled', fields: {'customer': userId});
      // A later saved customer message owns the queued replacement turn.
    } on CodexGenerationTimedOut {
      _diagnosticLog.record('generation.failed', fields: {
        'customer': userId,
        'reason': 'generation_deadline_exceeded',
        'batch_end_message_id': _activeDraftMessageIds[userId],
      });
      _scheduleDraftRetry(userId);
      // The holding-message sender must not retain this generation worker.
      // Its original 20-second deadline stays independent of the watchdog.
      unawaited(_scheduleSlaFallback(userId).catchError((Object error) {
        if (mounted) setState(() => _error = error);
      }));
    } on CodexReplyException catch (error) {
      _diagnosticLog.record('generation.failed', fields: {
        'customer': userId,
        'reason': error.message,
        'batch_end_message_id': _activeDraftMessageIds[userId],
      });
      if (isCodexModelCapacityError(error.message)) {
        if (mounted) {
          const text =
              'Reply generation is retrying because the Codex models are busy.';
          _errorState.record(error,
              displayedText: text, surface: 'diagnostics');
          setState(() {
            _error = null;
            _diagnostics = text;
          });
        }
      } else if (mounted) {
        setState(() => _error = error);
      }
      _scheduleDraftRetry(userId);
    } catch (error) {
      _diagnosticLog.record('generation.failed', fields: {
        'customer': userId,
        'reason': error.toString(),
        'batch_end_message_id': _activeDraftMessageIds[userId],
      });
      if (mounted) setState(() => _error = error);
      _scheduleDraftRetry(userId);
    } finally {
      if (identical(_activeDraftCancellations[userId], cancellation)) {
        _activeDraftCancellations.remove(userId);
        _activeDraftMessageIds.remove(userId);
      }
      _activeDraftUsers.remove(userId);
      if (mediaVersion != (_mediaEvidenceVersions[userId] ?? 0)) {
        _scheduleDraftGeneration(userId, newEvidence: true);
      }
      _runDraftWorkers();
      _requestDelivery();
    }
  }

  void _scheduleDraftRetry(String userId) {
    _draftRetryTimers.remove(userId)?.cancel();
    _draftRetryTimers[userId] = Timer(_draftFailureRetryDelay, () async {
      _draftRetryTimers.remove(userId);
      try {
        await _database.repairPendingCaptures();
        await _recoverOriginalReplyOutbox();
        await _queueDraftIfPending(userId);
      } catch (error) {
        _scheduleDraftRetry(userId);
        if (mounted) setState(() => _error = error);
      }
    });
  }

  Future<void> _processDraftUser(
      String userId, CodexGenerationCancellation cancellation) async {
    cancellation.throwIfCancelled();
    final pending = await _database.conversations();
    final matches = pending
        .where((conversation) => conversation.userId == userId)
        .toList(growable: false);
    if (matches.isEmpty) return;
    if (!await _database.hasPendingUnanswered(userId)) return;
    final conversation = matches.first;
    final messageIdAtGenerationStart = await _database.pendingMessageId(userId);
    if (messageIdAtGenerationStart == null) return;
    if ((await (await _replyOutbox).pending())
        .any((item) => item.userId == userId)) {
      await _recoverOriginalReplyOutbox();
      return;
    }
    _activeDraftMessageIds[userId] = messageIdAtGenerationStart;
    final service = await CodexReplyService.discover(_database,
        onDiagnostic: (event, fields) =>
            _diagnosticLog.record(event, fields: fields));
    final document = await (await _database.history).read(userId);
    final rows =
        (document?['messages'] as List<Object?>? ?? const []).whereType<Map>();
    final boundary =
        rows.where((m) => m['id'] == messageIdAtGenerationStart).firstOrNull;
    final through = DateTime.tryParse(boundary?['sent_at']?.toString() ?? '');
    final mediaVersion =
        _mediaEvidenceVersions.revisionThrough(userId, through);
    cancellation.throwIfCancelled();
    _diagnosticLog.record('generation.started', fields: {
      'customer': userId,
      'batch_end_message_id': messageIdAtGenerationStart,
      'media_revision': mediaVersion,
    });
    var draft = await service.generate(
        conversation: conversation,
        database: _database,
        batchEndMessageId: messageIdAtGenerationStart,
        cancellation: cancellation);
    if (mounted) {
      setState(() {
        final visibleError = _error;
        if (visibleError is CodexReplyException &&
            isCodexModelCapacityError(visibleError.message)) {
          _error = null;
        }
        if (draft.model == service.capacityFallbackModel &&
            service.capacityFallbackModel != service.model) {
          _diagnostics =
              'The primary Codex model was busy; this reply used ${draft.model}.';
        }
      });
    }
    cancellation.throwIfCancelled();
    if (mediaVersion !=
        _mediaEvidenceVersions.revisionThrough(userId, through)) {
      _diagnosticLog
          .record('generation.result_superseded_by_new_media', fields: {
        'customer': userId,
        'batch_end_message_id': messageIdAtGenerationStart,
        'started_media_revision': mediaVersion,
        'current_media_revision':
            _mediaEvidenceVersions.revisionThrough(userId, through),
      });
      return;
    }
    if (await _promoteCodexDetectedVideo(conversation, draft)) {
      _scheduleDraftGeneration(userId, newEvidence: true);
      return;
    }
    draft = withMediaEvidenceRevision(draft,
        session: _mediaEvidenceSession,
        revision: mediaVersion,
        throughSentAt: through);
    final explicitTransfer = isExplicitHumanTransfer(draft);
    if (!explicitTransfer) {
      await (await _replyOutbox).save(OutboxReply(
          userId: userId,
          batchEndMessageId: messageIdAtGenerationStart,
          draft: draft,
          createdAt: DateTime.now()));
    }
    final saved = await _database.saveDraft(conversation.id, draft,
        expectedMessageId: messageIdAtGenerationStart,
        deliverable: !explicitTransfer);
    _diagnosticLog.record('generation.completed', fields: {
      'customer': userId,
      'batch_end_message_id': messageIdAtGenerationStart,
      'draft_saved': saved > 0,
      'original_outbox_retained': !explicitTransfer,
      'decision': draft.decision,
    });
    // Contacting or a manually observed seller reply may remove the queue
    // while Codex is generating. Never send a result from that stale turn.
    if (saved == 0 || await _database.isHumanContacting(userId)) return;
    final needsHuman = draftRequiresHumanReview(draft);
    if (needsHuman) {
      final document = await (await _database.history).read(userId);
      final messages = (document?['messages'] as List<Object?>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      final requestMessage = messages.firstWhere((message) =>
          message['direction'] == 'incoming' &&
          message['id'] == messageIdAtGenerationStart);
      final ticket = await _database.createHumanReviewTicket(
        userId: userId,
        customerRequest:
            customerAuthoredText(requestMessage['body']?.toString() ?? ''),
        reason: draftHumanReviewReason(draft),
        requestMessageId: explicitTransfer ? messageIdAtGenerationStart : null,
      );
      await _refreshTickets();
      if (explicitTransfer) {
        // This draft records the transfer decision but must never be sent.
        // The transfer flow sends its own acknowledgement before handoff.
        await _autoTransferTicket(ticket,
            acknowledgement: transferNoticeForDraft(draft));
        await _database.discardTransferOnlyDraft(userId);
      }
      if (draft.attachments.isNotEmpty && mounted) {
        setState(() => _diagnostics =
            'Human-review acknowledgement for $userId unexpectedly contained media and was not sent.');
      }
    }
    await _coordinator.refresh();
    _requestDelivery();
  }

  Future<bool> _promoteCodexDetectedVideo(
      ConversationSummary conversation, AiDraft draft) async {
    final videoImagePaths = draft.imageDescriptions.entries
        .where((entry) => codexIdentifiedVideoThumbnail(entry.value))
        .map((entry) => entry.key)
        .toSet();
    if (videoImagePaths.isEmpty) return false;

    final document = await (await _database.history).read(conversation.userId);
    String? expectedFingerprint;
    final messages = document?['messages'] as List<Object?>? ?? const [];
    for (final message
        in messages.whereType<Map<String, dynamic>>().toList().reversed) {
      final mediaItems = message['media'] as List<Object?>? ?? const [];
      for (final media in mediaItems.whereType<Map<String, dynamic>>()) {
        if (videoImagePaths.contains(media['path']?.toString())) {
          expectedFingerprint = media['visual_fingerprint']?.toString();
          break;
        }
      }
      if (expectedFingerprint?.isNotEmpty == true) break;
    }
    if (expectedFingerprint?.isNotEmpty != true) return false;

    try {
      return await _withJdUiOperation(() async {
        await _adapter
            .openConversation(conversation.userId, allowActivation: true)
            .timeout(_captureOperationTimeout);
        final windows =
            await _adapter.listOcrWindows().timeout(_captureOperationTimeout);
        if (windows.isEmpty) return false;
        final reception = windows.firstWhere(
            (window) => window.title.contains('咚咚融合工作台'),
            orElse: () => windows.first);
        final inspection = await _adapter
            .inspectExpectedCustomer(
              windowId: reception.windowId,
              expectedCustomer: conversation.userId,
            )
            .timeout(_captureOperationTimeout);
        final candidates = const OcrImageCandidateSelector().select(
          inspection,
          conversation.userId,
          allowUnlabeledLatestImage: true,
        );
        for (final region in candidates) {
          final visible = await _adapter.captureImageRegion(
            expectedCustomer: conversation.userId,
            windowId: inspection.windowId,
            x: region.x,
            y: region.y,
            width: region.width,
            height: region.height,
            sourceInspection: inspection,
            sourceSenderY: const OcrImageCandidateSelector()
                .senderYForRegion(inspection, conversation.userId, region),
          );
          final fingerprint = visible.visualFingerprint ?? '';
          if (!_similarImageFingerprints(expectedFingerprint!, fingerprint)) {
            continue;
          }
          final queued = await _saveVisibleVideo(
            conversation.userId,
            inspection.windowId,
            region,
            fingerprint,
            sourceInspection: inspection,
            sentAt: const OcrImageCandidateSelector()
                .sentAtForRegion(inspection, conversation.userId, region),
          );
          if (queued && mounted) {
            setState(() => _diagnostics =
                'Codex recognized a video thumbnail for ${conversation.userId}; downloaded it and queued the sampled frames for a second analysis.');
          }
          return queued;
        }
        return false;
      });
    } catch (error) {
      if (mounted) {
        final text =
            'Codex recognized a video thumbnail, but JD video download failed: $error';
        _errorState.record(error, displayedText: text, surface: 'diagnostics');
        setState(() => _diagnostics = text);
      }
      return false;
    }
  }

  bool _similarImageFingerprints(String left, String right,
      {int maximumDistance = 8}) {
    final a = BigInt.tryParse(left, radix: 16);
    final b = BigInt.tryParse(right, radix: 16);
    if (a == null || b == null) return false;
    var difference = a ^ b;
    var distance = 0;
    while (difference > BigInt.zero && distance <= maximumDistance) {
      difference &= difference - BigInt.one;
      distance++;
    }
    return distance <= maximumDistance;
  }

  void _requestDelivery() {
    if (!_autoCaptureRunning) return;
    unawaited(_deliveryWorker?.request());
  }

  Future<void> _recordOutboxReceipt(OutboxReply item,
      {QueuedDelivery? expectedDelivery}) async {
    final outbox = await _replyOutbox;
    item.state = 'sent';
    await outbox.save(item);
    final store = await _database.history;
    final document = await store.read(item.userId);
    final alreadyRecorded =
        (document?['messages'] as List<Object?>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .any((message) {
      final metadata = message['reply_metadata'];
      final raw = metadata is Map ? metadata['raw_response'] : null;
      return raw is Map &&
          raw['delivery_batch_end_message_id'] == item.batchEndMessageId;
    });
    if (!alreadyRecorded) {
      final raw = (jsonDecode(item.draft.rawJson) as Map<String, dynamic>)
        ..['delivery_batch_end_message_id'] = item.batchEndMessageId;
      await store.appendSentReply(
          userId: item.userId,
          displayName: item.userId,
          stableKey: item.userId,
          draft: AiDraft.fromJson(raw.cast<String, Object?>(),
              mediaBaseUrl: Uri()));
    }
    // Delivery acknowledges only this frozen batch. Capturing a newer turn
    // owns its own recovery and must not lose its timers to an older send.
    if (expectedDelivery != null) {
      await _database.markReplySent(
          userId: item.userId,
          reply: item.draft.reply,
          recordHistory: false,
          expectedDelivery: expectedDelivery);
    } else {
      await _database.acknowledgeOutboxReply(
          userId: item.userId,
          batchEndMessageId: item.batchEndMessageId,
          reply: item.draft.reply);
    }
    await _scheduleSlaFallback(item.userId);
    await outbox.remove(item.userId, item.batchEndMessageId);
  }

  Future<bool> _outboxSupersededByReply(OutboxReply item) async {
    final document = await (await _database.history).read(item.userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    // A human may answer while generation is still running, before the outbox
    // entry's creation time. The exact answered batch + positive receipt is
    // what matters; an outbox creation clock must not retain stale work.
    return messages.any((message) => replyAnswersIncoming(
        reply: message,
        incomingId: item.batchEndMessageId,
        messages: messages));
  }

  Future<void> _recoverOriginalReplyOutbox() async {
    if (_outboxRecoveryBusy) return;
    _outboxRecoveryBusy = true;
    try {
      await _recoverOriginalReplyOutboxOnce();
    } finally {
      _outboxRecoveryBusy = false;
    }
  }

  Future<void> _recoverOriginalReplyOutboxOnce() async {
    final outbox = await _replyOutbox;
    for (final item in await outbox.pending()) {
      if (!_autoCaptureRunning) return;
      try {
        if (item.state == 'sent') {
          await _withJdUiOperation(() async {
            final current = (await outbox.pending())
                .where((entry) =>
                    entry.userId == item.userId &&
                    entry.batchEndMessageId == item.batchEndMessageId)
                .firstOrNull;
            if (current != null) await _recordOutboxReceipt(current);
          });
          continue;
        }
        if (await _outboxSupersededByReply(item)) {
          await outbox.remove(item.userId, item.batchEndMessageId);
          continue;
        }
        try {
          if (await _database.isHumanContacting(item.userId)) continue;
          if (item.state == 'sending') {
            await _withJdUiOperation(() => _sendOutboxReplyUnlocked(item));
            continue;
          }
          if (await _database.hasUndeliveredDraft(item.userId)) continue;
          await _database.ensurePendingForUnanswered(item.userId);
          final conversation = (await _database.conversations())
              .where((conversation) => conversation.userId == item.userId)
              .firstOrNull;
          if (conversation == null) {
            final restored = await _database.restoreUnsentOutboxDraft(
                userId: item.userId,
                batchEndMessageId: item.batchEndMessageId,
                draft: item.draft);
            _diagnosticLog
                .record('delivery.original_bookkeeping_repaired', fields: {
              'customer': item.userId,
              'batch_end_message_id': item.batchEndMessageId,
              'restored': restored,
              'original_retained': true,
            });
            if (restored) _requestDelivery();
            continue;
          }
          await _database.saveDraft(conversation.id, item.draft,
              expectedMessageId: item.batchEndMessageId);
          _requestDelivery();
        } catch (error) {
          if (!ResilientDatabase.isContention(error)) rethrow;
          // Original answers are delivered from their own durable journal if
          // SQLite is unavailable. Recipient verification and the common UI
          // lock still apply exactly as in ordinary delivery.
          await _withJdUiOperation(() => _sendOutboxReplyUnlocked(item));
        }
      } catch (error) {
        _diagnosticLog.record('delivery.outbox_retry', fields: {
          'customer': item.userId,
          'state': item.state,
          'error': error.toString(),
        });
      }
    }
  }

  Future<void> _sendOutboxReplyUnlocked(OutboxReply original) async {
    if (!_autoCaptureRunning ||
        _transferringCustomers.contains(original.userId)) {
      return;
    }
    final outbox = await _replyOutbox;
    final item = (await outbox.pending())
        .where((item) =>
            item.userId == original.userId &&
            item.batchEndMessageId == original.batchEndMessageId)
        .firstOrNull;
    if (item == null) return;
    if (item.state == 'sent') {
      await _recordOutboxReceipt(item);
      return;
    }
    if (await _refreshReplyForNewMedia(item.userId, item.draft)) return;
    if (await _outboxSupersededByReply(item)) {
      await outbox.remove(item.userId, item.batchEndMessageId);
      return;
    }
    await _adapter
        .openConversation(item.userId, allowActivation: true)
        .timeout(const Duration(seconds: 8));
    if (item.state == 'sending') {
      // A process interruption or uncertain native callback does not authorize
      // a duplicate Send. Reconcile its exact visible outgoing receipt.
      final windows =
          await _adapter.listOcrWindows().timeout(_fallbackInspectionTimeout);
      if (windows.isEmpty) return;
      final window = windows.firstWhere(
          (window) => window.title.contains('咚咚融合工作台'),
          orElse: () => windows.first);
      final inspection = await _adapter
          .inspectExpectedCustomer(
              windowId: window.windowId, expectedCustomer: item.userId)
          .timeout(_fallbackInspectionTimeout);
      final capture = const OcrCaptureExtractor().analyze(inspection).capture;
      final receipt = capture?.messages.any((message) =>
              message.direction == 'outgoing' &&
              message.deliveryConfirmed &&
              message.body.replaceAll(RegExp(r'\s+'), '') ==
                  item.draft.reply.replaceAll(RegExp(r'\s+'), '') &&
              message.sentAt != null &&
              !message.sentAt!.isBefore(
                  item.createdAt.subtract(const Duration(seconds: 1)))) ??
          false;
      if (receipt) {
        await _recordOutboxReceipt(item);
        return;
      }
      final exactQuestionVisible = capture?.messages.any((message) =>
              message.direction == 'incoming' &&
              message.stableId == item.batchEndMessageId) ??
          false;
      final latestVisibleIncoming =
          capture?.messages.lastOrNull?.direction == 'incoming';
      if (!await outbox.recordVerifiedAbsence(item,
          exactUnansweredBubbleVisible:
              exactQuestionVisible && latestVisibleIncoming)) {
        return;
      }
    }
    final sent = await outbox.sendReady(item,
        send: (draft) async {
          _verifyDraftMediaRevision(item.userId, draft);
          await _adapter.sendDraftOnce(
              expectedCustomer: item.userId,
              reply: draft.reply,
              mediaPaths: const []);
        },
        definitelyBeforeSend: (error) =>
            error is PlatformException && _definitelyBeforeSend(error));
    if (!sent) return;
    await _recordOutboxReceipt(item);
    _diagnosticLog.record('delivery.outbox_sent', fields: {
      'customer': item.userId,
      'batch_end_message_id': item.batchEndMessageId,
    });
  }

  bool _definitelyBeforeSend(PlatformException error) => const {
        'media_evidence_changed',
        'final_customer_verification_failed',
        'customer_switch_not_verified',
        'composer_not_empty',
        'owned_composer_recovery_failed',
        'conversation_verification_failed',
        'operation_expired',
        'ui_worker_unavailable',
        'ui_operation_cancelled',
        'invalid_ui_operation',
        'invalid_send_request',
        'jd_unavailable',
        'expected_conversation_missing',
        'pre_insert_verification_failed',
        'composer_read_failed',
        'composer_not_settable',
        'pre_send_verification_failed',
        'send_click_failed',
        'send_not_committed',
      }.contains(error.code);

  bool _draftHasNewMedia(String userId, AiDraft draft) =>
      hasNewerMediaEvidence(draft,
          session: _mediaEvidenceSession,
          revision: _mediaEvidenceVersions.revisionThrough(
              userId, mediaEvidenceBoundary(draft)));

  void _verifyDraftMediaRevision(String userId, AiDraft draft) {
    if (_draftHasNewMedia(userId, draft)) {
      throw PlatformException(code: 'media_evidence_changed');
    }
  }

  Future<bool> _refreshReplyForNewMedia(String userId, AiDraft draft) async {
    if (!_draftHasNewMedia(userId, draft)) return false;
    final outbox = await _replyOutbox;
    final current = (await outbox.pending())
        .where((item) =>
            item.userId == userId && item.draft.rawJson == draft.rawJson)
        .firstOrNull;
    if (current != null && !await outbox.discardReady(current)) return false;
    await _database.discardGeneratedDraft(userId,
        expectedRawJson: draft.rawJson);
    _diagnosticLog.record('generation.refresh_for_acquired_media',
        fields: {'customer': userId});
    _scheduleDraftGeneration(userId, newEvidence: true);
    return true;
  }

  Future<void> _handleDeliveryFailure(
      QueuedDelivery delivery, Object error, StackTrace stack) async {
    _diagnosticLog.record('delivery.failed', fields: {
      'expected_customer': delivery.userId,
      'error': error.toString(),
    });
    await _database.markGeneratedDraftDeliveryFailure(
      userId: delivery.userId,
      error: error.toString(),
      retryDelay: _deliveryFailureRetryDelay,
      expectedDelivery: delivery,
    );
    _deliveryRetryTimer?.cancel();
    _deliveryRetryTimer = Timer(_deliveryFailureRetryDelay, _requestDelivery);
    if (mounted) setState(() => _error = error);
  }

  Future<T> _withJdUiOperation<T>(
    Future<T> Function() operation, {
    String? customer,
    String label = 'ui.operation',
    UiPriority priority = UiPriority.maintenance,
    Duration timeout = const Duration(seconds: 30),
  }) =>
      _uiScheduler.schedule(operation,
          customer: customer,
          label: label,
          priority: priority,
          timeout: timeout);

  Future<T> _withFallbackPriority<T>(Future<T> Function() operation) async {
    // All customer-changing work shares one queue. Priority remains visible to
    // optional maintenance tasks, but a fallback may never switch the active
    // chat while another customer's image capture is still validating it.
    _priorityUiOperations++;
    try {
      return await _withJdUiOperation(operation,
          priority: UiPriority.fallback, label: 'delivery.fallback');
    } finally {
      _priorityUiOperations--;
    }
  }

  Future<bool> _sendAutomaticallyUnlocked(QueuedDelivery delivery) async {
    final userId = delivery.userId;
    final draft = delivery.draft;
    if (!_autoCaptureRunning ||
        !await _database.isGeneratedDraftReadyForSend(
          userId: userId,
          reply: draft.reply,
          expectedDelivery: delivery,
        ) ||
        await _database.isHumanContacting(userId)) {
      return false;
    }
    if (await _refreshReplyForNewMedia(userId, draft)) return false;
    final uiAcquiredAt = DateTime.now();
    _diagnosticLog.record('delivery.ui_acquired', fields: {
      'expected_customer': userId,
      'draft_queue_wait_ms':
          uiAcquiredAt.millisecondsSinceEpoch - delivery.createdAtMs,
    });
    try {
      // Draft generation is independent from sidebar scanning. Another unread
      // customer may have become visible while Codex was working, so reopen
      // and verify the draft's exact customer immediately before sending.
      await _adapter
          .openConversation(userId, allowActivation: true)
          .timeout(_captureOperationTimeout);
      final mediaPaths = draft.attachments
          .where((attachment) => attachment.url.scheme == 'file')
          .map((attachment) => attachment.url.toFilePath())
          .toList(growable: false);
      if (mediaPaths.length != draft.attachments.length) {
        throw StateError(
            'Automatic media sending requires verified local files.');
      }
      // Re-check after opening the conversation. A transfer may have removed
      // a delivery that was claimed before it acquired the JD UI lock.
      if (!_autoCaptureRunning ||
          !await _database.isGeneratedDraftReadyForSend(
            userId: userId,
            reply: draft.reply,
            expectedDelivery: delivery,
          ) ||
          await _database.isHumanContacting(userId)) {
        return false;
      }
      final outbox = await _replyOutbox;
      final existing = (await outbox.pending())
          .where((item) =>
              item.userId == userId &&
              item.batchEndMessageId == delivery.batchEndMessageId)
          .firstOrNull;
      if (existing != null && existing.state != 'ready') {
        await _sendOutboxReplyUnlocked(existing);
        return existing.state == 'sent';
      }
      final durableReply = existing ??
          OutboxReply(
              userId: userId,
              batchEndMessageId: delivery.batchEndMessageId ?? '',
              draft: draft,
              createdAt:
                  DateTime.fromMillisecondsSinceEpoch(delivery.createdAtMs));
      if (existing == null) await outbox.save(durableReply);
      final sent = await outbox.sendReady(durableReply,
          send: (answer) async {
            _verifyDraftMediaRevision(userId, answer);
            await _adapter.sendDraftOnce(
                expectedCustomer: userId,
                reply: answer.reply,
                mediaPaths: mediaPaths);
          },
          definitelyBeforeSend: (error) =>
              error is PlatformException && _definitelyBeforeSend(error));
      if (!sent) return false;
      await _recordOutboxReceipt(durableReply, expectedDelivery: delivery);
      _scheduleDraftGeneration(userId, newEvidence: false);
      final evidence = _processingUnreadEvidence[userId];
      if (evidence != null && !_unreadRecovery.containsKey(userId)) {
        _handledUnreadEvidence[userId] = evidence;
        _handledUnreadAt[userId] = DateTime.now();
      }
      if (mounted) {
        setState(() {
          _diagnostics =
              'Verified and automatically sent ${draft.model} reply to $userId.';
        });
      }
      _diagnosticLog.record('delivery.sent', fields: {
        'expected_customer': userId,
        'draft_queue_wait_ms':
            uiAcquiredAt.millisecondsSinceEpoch - delivery.createdAtMs,
        'ui_delivery_ms':
            DateTime.now().difference(uiAcquiredAt).inMilliseconds,
      });
      return true;
    } catch (_) {
      if (mounted) {
        setState(() => _diagnostics =
            'Automatic send to $userId failed; the reply remains queued for retry.');
      }
      rethrow;
    }
  }

  Future<CapturedConversation?> _captureWithVisibleMedia(
    OcrInspection inspection,
    OcrExtractionAttempt extraction, {
    bool allowUnlabeledLatestImage = false,
    bool allowRecoveryAfterHolding = false,
    int mediaRefreshAttempt = 0,
  }) async {
    final customer = extraction.customerId ?? extraction.capture?.customerName;
    if (customer != null &&
        !customerIdentitiesMatch(inspection.activeCustomerId, customer)) {
      throw PlatformException(
          code: 'capture_identity_unverified',
          message:
              'Media/text owner $customer differs from the verified active chat ${inspection.activeCustomerId}.');
    }
    if (customer == null || inspection.windowId == 0) {
      return extraction.capture;
    }
    var textCapture = extraction.capture;
    final latestVisible = textCapture?.messages.lastOrNull;
    final onlyOurHoldingIsBelow = allowRecoveryAfterHolding &&
        latestVisible?.direction == 'outgoing' &&
        _isOwnHoldingReply(latestVisible?.body);

    // Keep verified OCR text, then inspect any customer-owned visual region in
    // the same viewport. A missed sender label can leave an older seller reply
    // as the last OCR message even when a new video is visible below it.
    const candidateSelector = OcrImageCandidateSelector();
    var imageCandidates = candidateSelector.select(
      inspection,
      customer,
      allowUnlabeledLatestImage: allowUnlabeledLatestImage,
      // Text on a customer's video thumbnail is video content, not a chat
      // message. Inspect dense rectangles for the play overlay as well.
      includeTextDense: true,
    );
    final viewportFallbackRegions = <OcrVisualRegion>[];
    if (imageCandidates.isEmpty && allowUnlabeledLatestImage) {
      final fallback =
          candidateSelector.fallbackLatestCustomerBlock(inspection, customer);
      if (fallback != null) {
        imageCandidates = [fallback];
        viewportFallbackRegions.add(fallback);
      }
    }
    imageCandidates =
        _ocrMediaMasks.restoreCandidates(inspection, customer, imageCandidates);
    // Retain the full sender-bound footprint even when this scan sees only
    // a tiny play/control rectangle (or no rectangle at all).
    final priorMediaMasks = _ocrMediaMasks.regions(inspection, customer);
    if (priorMediaMasks.isNotEmpty) {
      textCapture = extraction.textExcludingMedia(inspection, priorMediaMasks);
    }
    if ((latestVisible?.direction == 'outgoing' && !onlyOurHoldingIsBelow) ||
        extraction.latestIncomingHasText) {
      imageCandidates = imageCandidates.where((region) {
        final eligible = candidateSelector.mayCaptureWithLaterActivity(
            inspection, customer, region);
        _diagnosticLog.record('capture.media_candidate_routing', fields: {
          'customer': customer,
          'message_at': candidateSelector
              .sentAtForRegion(inspection, customer, region)
              ?.toUtc()
              .toIso8601String(),
          'eligible': eligible,
          'reason': eligible
              ? 'customer_media_independent_of_later_reply'
              : 'historical_or_unstamped_media_below_seller_activity',
        });
        return eligible;
      }).toList(growable: false);
    }
    if (!extraction.latestVisibleSenderIsIncoming &&
        !onlyOurHoldingIsBelow &&
        !(allowUnlabeledLatestImage && textCapture == null) &&
        imageCandidates.isEmpty) {
      _visibleMediaTrace =
          'strict routing: newest visible sender is not the customer';
      return textCapture;
    }
    final capturedMedia = <CapturedMessage>[];
    // Prefer verified originals. A sender/snapshot-verified attachment preview
    // is retained explicitly as partial evidence, never called an original.
    // Visit every customer-owned bubble in message order. A duplicate or a
    // failed acquisition must never hide the remaining images/videos.
    imageCandidates.sort((a, b) => a.y.compareTo(b.y));
    var queuedVideos = 0;
    var failures = 0;
    final inspectedMediaSources = <String>[];
    final confirmedMediaRegions = <OcrVisualRegion>[...priorMediaMasks];
    final mediaRecovery = _unreadRecovery[customer];
    // Every verified new-message recovery must inspect JD's cache, including
    // turns where text OCR succeeded. A customer can send text and media in
    // the same turn, and successful text extraction is not evidence that the
    // accompanying image/video was captured.
    // Candidate regions perform their own read-only cache lookup below; do not
    // enumerate the shared directory twice before verifying an original.
    final shouldProbeDirectMedia = imageCandidates.isEmpty &&
        mediaRecovery != null &&
        mediaRecovery.directMediaProbeDue(DateTime.now());
    if (shouldProbeDirectMedia) {
      final recovery = mediaRecovery;
      recovery.recordDirectMediaProbe(DateTime.now());
      try {
        final senderAt = extraction.latestIncomingSentAt;
        if (recovery.hasVerifiedIncomingSignal &&
            senderAt != null &&
            extraction.latestVisibleSenderIsIncoming &&
            !extraction.latestIncomingHasText) {
          // Pale/black previews may have NO Vision rectangle. Restore the
          // old direct cache route for a verified media-only sender as well.
          final direct = await _captureDirectCachedVideo(
              customer, inspection.windowId, senderAt);
          if (direct != null) {
            final event = _mediaAcquisitions.observe(customer,
                uploadEventKey(senderAt, 0), senderAt, inspection.capturedAt)
              ..acquired = true;
            if (direct) queuedVideos++;
            await (await _database.history)
                .recordMediaAcquisition(customer, event.toJson());
            inspectedMediaSources
                .add('819ce2a-direct-jd-video-cache-without-preview');
          }
        } else {
          await _probeRecentMediaCache(customer, recovery)
              .timeout(_unreadOperationTimeout);
          inspectedMediaSources.add('discovery-only-jd-cache');
        }
      } on PlatformException {
        failures++;
      } on TimeoutException {
        failures++;
      }
    }
    var refreshRequired = false;
    final mediaSlots = <int, int>{};
    for (final region in imageCandidates) {
      String? attemptedMediaKind;
      final messageAt =
          candidateSelector.sentAtForRegion(inspection, customer, region);
      final slot = messageAt == null
          ? 0
          : mediaSlots[mediaMessageSecond(messageAt)] ?? 0;
      void confirmMediaSlot() {
        if (messageAt != null) {
          mediaSlots[mediaMessageSecond(messageAt)] = slot + 1;
        }
      }

      final allowPreview = candidateSelector.mayRetainAttachmentPreview(
          inspection, customer, region);
      MediaAcquisition? event;
      try {
        // 819ce2a's direct cache acquisition precedes ALL screenshot/play-icon
        // classification for a non-text sender region. Readable text needs a
        // visual original-file match; a cache clock must not turn "hi" into video.
        if (messageAt != null &&
            !candidateSelector.hasReadableText(
                region, inspection.observations)) {
          final direct = await _captureDirectCachedVideo(
              customer, inspection.windowId, messageAt,
              sourceEventKey: uploadEventKey(messageAt, slot));
          if (direct != null) {
            confirmMediaSlot();
            await _recordVerifiedUpload(
                inspection, customer, region, messageAt, slot);
            confirmedMediaRegions.add(region);
            if (direct) queuedVideos++;
            inspectedMediaSources.add('819ce2a-direct-jd-video-cache');
            continue;
          }
        }
        final expectedMediaAt = messageAt ??
            _unreadRecovery[customer]?.eventAt ??
            inspection.capturedAt;
        final visible = await _adapter
            .captureCachedMediaRegion(
              expectedCustomer: customer,
              windowId: inspection.windowId,
              region: region,
              expectedMediaAt: expectedMediaAt,
              sourceInspection: inspection,
              sourceSenderY: candidateSelector.senderYForRegion(
                  inspection, customer, region),
              allowAttachmentPreview: allowPreview,
              previewTextRegions:
                  candidateSelector.previewTextRegions(inspection, region),
            )
            .timeout(_unreadOperationTimeout);
        if (visible == null) {
          // Normal cache miss: no upload event, mask, menu, generation wait,
          // or shared cleanup state. Keep the text and inspect the next item.
          inspectedMediaSources.add('cache-miss-text-preserved');
          continue;
        }
        inspectedMediaSources.add(visible.captureSource ?? visible.kind);
        attemptedMediaKind = visible.kind;
        // The sender label can sit above OCR's text band while the media
        // thumbnail is still clearly visible. Start the 20-second recovery
        // clock before a video cache copy or frame extraction can stall.
        if (!extraction.latestVisibleSenderIsIncoming &&
            (visible.kind == 'video' ||
                (visible.kind == 'image' &&
                    visible.bytes != null &&
                    !candidateSelector.isTextDense(
                        region, inspection.observations))) &&
            visible.visualFingerprint?.isNotEmpty == true &&
            !_unreadRecovery.containsKey(customer) &&
            !await (await _database.history).hasSimilarImageFingerprint(
              customer,
              visible.visualFingerprint!,
            )) {
          await _beginUnreadRecovery(customer, 0,
              detectedAt: inspection.capturedAt);
        }
        if (visible.kind == 'video') {
          confirmMediaSlot();
          // Classification itself is enough to reject OCR text inside the
          // thumbnail, even if the cache copy must be retried later.
          confirmedMediaRegions.add(region);
          if (messageAt != null) {
            event = await _recordVerifiedUpload(
                inspection, customer, region, messageAt, slot);
          }
          final queued = await _saveVisibleVideo(
            customer,
            inspection.windowId,
            region,
            visible.visualFingerprint ?? '',
            sourceInspection: inspection,
            sentAt: messageAt,
            cacheReferenceToken: visible.cacheReferenceToken,
            sourceEventKey:
                messageAt == null ? null : uploadEventKey(messageAt, slot),
          );
          if (queued) queuedVideos++;
          if (event != null) event.acquired = true;
        } else if ((visible.kind == 'image' ||
                visible.kind == 'attachment_preview') &&
            visible.bytes != null) {
          // A rectangle around a long ordinary text bubble can look like an
          // image to Vision. A screenshot matched pixel-for-pixel to an
          // original in JD's image cache is already verified media, however,
          // and must not be discarded merely because the image itself contains
          // a lot of readable text.
          final cacheOriginal = visible.captureSource == 'jd-image-cache';
          final retainedPreview = allowPreview &&
              visible.kind == 'attachment_preview' &&
              visible.captureSource == 'verified-window-preview';
          if (retainedPreview && messageAt != null) {
            final key = uploadEventKey(messageAt, slot);
            final single = imageCandidates
                    .where((r) =>
                        candidateSelector.sentAtForRegion(
                            inspection, customer, r) ==
                        messageAt)
                    .length ==
                1;
            final queue = await _videoCaptureQueue;
            await queue.initialize();
            if (queue.hasEvent(customer, messageAt, key,
                    singleVisibleBubble: single) ||
                await (await _database.history).hasOriginalMediaEvent(
                    customer, messageAt, key,
                    singleVisibleBubble: single)) {
              confirmMediaSlot();
              confirmedMediaRegions.add(region);
              await _recordVerifiedUpload(
                  inspection, customer, region, messageAt, slot);
              _diagnosticLog
                  .record('capture.redundant_preview_skipped', fields: {
                'customer': customer,
                'event_key': key,
                'message_at': messageAt.toUtc().toIso8601String(),
              });
              continue;
            }
          }
          if (!cacheOriginal && !retainedPreview) {
            throw PlatformException(code: 'media_original_not_verified');
          }
          if (retainedPreview ||
              candidateSelector.shouldSaveImage(
                region,
                inspection.observations,
                fromVerifiedCache: cacheOriginal,
              )) {
            confirmMediaSlot();
            confirmedMediaRegions.add(region);
            if (messageAt != null) {
              event = await _recordVerifiedUpload(
                  inspection, customer, region, messageAt, slot);
            }
            final saved = await _saveVisibleImage(
              customer,
              visible,
              sentAt: messageAt,
              viewportFallback: viewportFallbackRegions
                  .any((item) => identical(item, region)),
              cacheCopy: cacheOriginal,
              sourceEventKey:
                  messageAt == null ? null : uploadEventKey(messageAt, slot),
              attachmentPreview: retainedPreview,
            );
            if (saved != null) {
              capturedMedia.add(saved);
              // Persist each acquired image before attempting the next item.
              // A later native timeout must not lose earlier captured media.
              final inserted = await _database.saveCapture(CapturedConversation(
                  stableKey:
                      'customer:${sha256.convert(utf8.encode(customer))}',
                  customerName: customer,
                  customerExternalId: customer,
                  verifiedCustomerId: customer,
                  messages: [saved],
                  capturedAt: inspection.capturedAt));
              if (inserted > 0) {
                _mediaEvidenceVersions.record(
                    customer, saved.stableId, MediaEvidenceStage.ready,
                    sentAt: saved.sentAt);
              }
              _diagnosticLog.record('capture.media_saved', fields: {
                'customer': customer,
                'kind': 'image',
                'evidence': retainedPreview
                    ? 'partial_attachment_preview'
                    : 'cache_original',
                'message_id': saved.stableId,
                'message_at': saved.sentAt?.toUtc().toIso8601String()
              });
            }
            if (event != null) event.acquired = true;
          }
        }
        if (event?.acquired == true) {
          await (await _database.history)
              .recordMediaAcquisition(customer, event!.toJson());
        }
      } on PlatformException catch (error) {
        failures++;
        if (event != null) {
          event.failure = error.code;
          await (await _database.history)
              .recordMediaAcquisition(customer, event.toJson());
        }
        _diagnosticLog.record('capture.media_item_failed', fields: {
          'customer': customer,
          'kind': attemptedMediaKind,
          'message_at': messageAt?.toUtc().toIso8601String(),
          'code': error.code,
        });
        if (error.code == 'media_snapshot_changed') {
          // Do not reuse any remaining coordinates after a scroll, warning,
          // resize or newly inserted message. The next poll re-runs OCR.
          _diagnosticLog.record('capture.media_rescan_required',
              fields: {'customer': customer});
          refreshRequired = true;
          break;
        }
        if (attemptedMediaKind == 'video') {
          await (await _database.history).recordMediaCaptureFailure(
              customer, 'video',
              sentAt: messageAt, reason: error.code);
        }
        // One invalid visual rectangle must not discard other candidates or
        // text already extracted from the visible conversation.
      } on TimeoutException {
        failures++;
        if (event != null) {
          event.failure = 'media_acquisition_timeout';
          await (await _database.history)
              .recordMediaAcquisition(customer, event.toJson());
        }
        if (attemptedMediaKind == 'video') {
          await (await _database.history).recordMediaCaptureFailure(
              customer, 'video',
              sentAt: messageAt, reason: 'video_capture_timeout');
        }
        // A stalled native media operation cannot hold the JD UI queue past
        // the customer's fallback deadline.
      } catch (error) {
        failures++;
        _diagnosticLog.record('capture.media_item_failed', fields: {
          'customer': customer,
          'message_at': messageAt?.toUtc().toIso8601String(),
          'kind': attemptedMediaKind,
          'error': error.toString(),
        });
        // Disk/decoder failures are scoped to this item, not the entire batch.
      }
    }
    _visibleMediaTrace =
        'strict routing: cache originals first, verified attachment previews second; candidates='
        '${imageCandidates.length}, captured=${capturedMedia.length}, video_jobs=$queuedVideos, '
        'failures=$failures, sources=${inspectedMediaSources.join(',')}; '
        'JD image viewer was not opened';
    if (confirmedMediaRegions.isNotEmpty) {
      // Re-read text with the verified media rectangles masked. Otherwise OCR
      // of a play icon or text displayed *inside* a video can close unread
      // recovery and generate a reply to a fabricated customer sentence.
      textCapture =
          extraction.textExcludingMedia(inspection, confirmedMediaRegions);
    }
    if (refreshRequired) {
      // The old OCR snapshot is no longer proof of typed text. Only acquired
      // originals survive a failed refresh; never merge stale thumbnail OCR.
      textCapture = null;
    }
    if (refreshRequired && mediaRefreshAttempt == 0) {
      try {
        final fresh = await _adapter
            .inspectExpectedCustomer(
                windowId: inspection.windowId,
                expectedCustomer: customer,
                maximumAttempts: 1,
                fast: false)
            .timeout(_fallbackInspectionTimeout);
        final retry = await _captureWithVisibleMedia(
            fresh, const OcrCaptureExtractor().analyze(fresh),
            allowUnlabeledLatestImage: allowUnlabeledLatestImage,
            allowRecoveryAfterHolding: allowRecoveryAfterHolding,
            mediaRefreshAttempt: 1);
        if (retry != null) {
          final merged = <String, CapturedMessage>{
            for (final m in [...capturedMedia, ...retry.messages])
              m.stableId: m,
          };
          return CapturedConversation(
              stableKey: retry.stableKey,
              customerName: customer,
              customerExternalId: customer,
              verifiedCustomerId: customer,
              messages: merged.values.toList(),
              capturedAt: fresh.capturedAt);
        }
      } on PlatformException catch (_) {
        // A different customer or failed refresh never authorizes old coordinates.
      } on TimeoutException catch (_) {
        // Other customers regain the UI queue; the bounded next poll retries.
      }
    }
    if (capturedMedia.isEmpty) return textCapture;
    final uniqueMedia = <String, CapturedMessage>{
      for (final message in capturedMedia) message.stableId: message,
    }.values.toList(growable: false);
    return CapturedConversation(
      stableKey: textCapture?.stableKey ??
          'customer:${sha256.convert(utf8.encode(customer))}',
      customerName: customer,
      customerExternalId: customer,
      verifiedCustomerId: inspection.activeCustomerId,
      capturedAt: inspection.capturedAt,
      messages: [...?textCapture?.messages, ...uniqueMedia],
    );
  }

  Future<void> _probeRecentMediaCache(
    String customer,
    UnreadCaptureRecovery recovery,
  ) async {
    final probe = await _adapter.probeRecentCachedMedia(
      expectedCustomer: customer,
      expectedMediaAt: recovery.eventAt,
    );
    _diagnosticLog.record('capture.media_cache_probed', fields: {
      'customer': customer,
      'candidate_found': probe['candidateFound'],
      'candidate_count': probe['cacheCandidateCount'],
      'selection_ambiguous': probe['cacheSelectionAmbiguous'],
      'action': 'visible_customer_media_cross_check_required',
      'reason': probe['reason'],
    });
  }

  Future<bool> _completeAttachmentDownload(
      AttachmentDownloadTicket ticket) async {
    final store = await _database.history;
    final own = Directory(
        '${store.mediaDirectory.path}/${store.safeUserId(ticket.customer)}/attachment_exports');
    final actual = await Directory(ticket.directory).resolveSymbolicLinks();
    if (!actual.startsWith('${await own.resolveSymbolicLinks()}/')) {
      throw StateError(
          'Attachment download is outside this customer’s private directory.');
    }
    final original = await _adapter.pollAttachmentDownload(ticket);
    if (original == null) return false;
    if (original.kind == 'image') {
      final message = await _saveVisibleImage(ticket.customer, original,
          sentAt: ticket.sentAt, originalDownload: true);
      if (message != null) {
        final capturedAt = DateTime.now();
        final inserted = await _database.saveCapture(CapturedConversation(
            stableKey:
                'customer:${sha256.convert(utf8.encode(ticket.customer))}',
            customerName: ticket.customer,
            customerExternalId: ticket.customer,
            verifiedCustomerId: ticket.customer,
            messages: [message],
            capturedAt: capturedAt));
        if (inserted > 0) {
          _mediaEvidenceVersions.record(
              ticket.customer, message.stableId, MediaEvidenceStage.ready,
              sentAt: message.sentAt);
        }
        final recovery = _unreadRecovery[ticket.customer];
        if (recovery != null &&
            recovery.acceptsIncoming(message.stableId,
                sentAt: message.sentAt, capturedAt: capturedAt)) {
          if (recovery.holdingSentAt case final at?) {
            await _database.acknowledgeUncapturedHolding(
                userId: ticket.customer, sentAt: at);
          }
          _finishUnreadRecovery(ticket.customer, expectedRecovery: recovery);
        }
      }
    } else if (original.downloadedVideo case final video?) {
      await _enqueueDownloadedVideo(ticket.customer, video, '',
          sentAt: ticket.sentAt);
    } else {
      throw StateError('Attachment original has no validated payload.');
    }
    final event = _mediaAcquisitions.observe(
        ticket.customer, ticket.eventKey, ticket.sentAt, ticket.startedAt)
      ..acquired = true
      ..attachmentFallbackStarted = true;
    await store.recordMediaAcquisition(ticket.customer, event.toJson());
    _diagnosticLog.record('capture.attachment_original_saved', fields: {
      'customer': ticket.customer,
      'event_key': ticket.eventKey,
      'kind': original.kind,
      'message_at': ticket.sentAt.toUtc().toIso8601String(),
    });
    await _coordinator.refresh();
    return true;
  }

  Future<void> _attachmentDownloadFailed(
      AttachmentDownloadTicket ticket, Object error) async {
    final event = _mediaAcquisitions.observe(
        ticket.customer, ticket.eventKey, ticket.sentAt, ticket.startedAt)
      ..failure = 'attachment_download_failed'
      ..attachmentFallbackStarted = true;
    _diagnosticLog.record('capture.attachment_download_failed', fields: {
      'customer': ticket.customer,
      'event_key': ticket.eventKey,
      'error': error.toString(),
    });
    await (await _database.history)
        .recordMediaAcquisition(ticket.customer, event.toJson());
  }

  Future<bool> _saveVisibleVideo(
    String customer,
    int windowId,
    OcrVisualRegion region,
    String thumbnailFingerprint, {
    required OcrInspection sourceInspection,
    DateTime? sentAt,
    String? cacheReferenceToken,
    String? sourceEventKey,
  }) async {
    final store = await _database.history;
    // Similar thumbnails cannot identify a message: a customer may resend the
    // same video or two distinct clips can show the same printer. Deduplicate
    // only after acquiring verified bytes and reading this bubble's timestamp.
    final destination = Directory(
      '${store.mediaDirectory.path}/${store.safeUserId(customer)}/videos',
    );
    await destination.create(recursive: true);
    final downloaded = await _adapter
        .downloadVideoAt(
          expectedCustomer: customer,
          windowId: windowId,
          x: region.x,
          y: region.y,
          width: region.width,
          height: region.height,
          expectedMediaAt: sentAt,
          destinationDirectory: destination.path,
          cacheReferenceToken: cacheReferenceToken,
          sourceInspection: sourceInspection,
          sourceSenderY: const OcrImageCandidateSelector()
              .senderYForRegion(sourceInspection, customer, region),
        )
        .timeout(_unreadOperationTimeout);
    if (downloaded.path.isEmpty) return false;
    return _enqueueDownloadedVideo(customer, downloaded, thumbnailFingerprint,
        sentAt: sentAt, sourceEventKey: sourceEventKey);
  }

  /// Null means no safe cache match; false means acquired but already queued
  /// or saved. Neither requires a Save As dialog or screenshot classification.
  Future<bool?> _captureDirectCachedVideo(
      String customer, int windowId, DateTime sentAt,
      {String? sourceEventKey}) async {
    final store = await _database.history;
    final destination = Directory(
        '${store.mediaDirectory.path}/${store.safeUserId(customer)}/videos');
    await destination.create(recursive: true);
    final competing = <DateTime>{
      ..._mediaAcquisitions.competingTimes(customer, sentAt),
      for (final entry in _unreadRecovery.entries)
        if (entry.key != customer) entry.value.eventAt,
    };
    final cached = await _adapter
        .captureRecentCachedVideo(
            expectedCustomer: customer,
            windowId: windowId,
            expectedMediaAt: sentAt,
            destinationDirectory: destination.path,
            competingMessageTimes: competing)
        .timeout(_unreadOperationTimeout);
    if (cached == null) return null;
    if (!await (await _cacheVideoClaims)
        .claim(cached.cacheKey, customer, sentAt)) {
      if (cached.createdCopy) {
        final file = File(cached.video.path);
        final actual = await file.resolveSymbolicLinks();
        final own = await destination.resolveSymbolicLinks();
        if (actual.startsWith('$own/')) await file.delete();
      }
      _diagnosticLog.record('capture.cache_video_claim_rejected', fields: {
        'customer': customer,
        'message_at': sentAt.toUtc().toIso8601String(),
        'reason': 'cache_entry_already_belongs_to_another_customer',
      });
      return null;
    }
    _diagnosticLog.record('capture.cache_video_acquired', fields: {
      'customer': customer,
      'message_at': sentAt.toUtc().toIso8601String(),
      'source_commit': '819ce2a',
      'original_name': cached.video.originalName,
      'ownership_verification': cached.video.ownershipVerification,
    });
    return _enqueueDownloadedVideo(customer, cached.video, '',
        sentAt: sentAt, sourceEventKey: sourceEventKey);
  }

  Future<bool> _enqueueDownloadedVideo(String customer,
      DownloadedVideoPayload downloaded, String thumbnailFingerprint,
      {DateTime? sentAt, String? sourceEventKey}) async {
    final store = await _database.history;
    final digest =
        (await sha256.bind(File(downloaded.path).openRead()).first).toString();
    if (await store.hasCapturedMediaEvent(customer, 'video', digest,
        sentAt: sentAt)) {
      _diagnosticLog.record('capture.media_event_duplicate', fields: {
        'customer': customer,
        'kind': 'video',
        'content_sha256': digest,
        'message_at': sentAt?.toUtc().toIso8601String()
      });
      return false;
    }
    final queue = await _videoCaptureQueue;
    final job = VideoCaptureJob(
        customer: customer,
        path: downloaded.path,
        digest: digest,
        sentAt: sentAt,
        fingerprint: thumbnailFingerprint,
        ownershipVerification: downloaded.ownershipVerification,
        mimeType: downloaded.mimeType,
        originalName: downloaded.originalName,
        sourceEventKey: sourceEventKey);
    final enqueued = await queue.enqueue(job);
    if (!enqueued) return false;
    _mediaEvidenceVersions.record(
        customer, job.messageId, MediaEvidenceStage.original,
        sentAt: job.sentAt);
    _diagnosticLog.record('capture.video_job_queued', fields: {
      'customer': customer,
      'content_sha256': digest,
      'message_at': sentAt?.toUtc().toIso8601String()
    });
    return true;
  }

  Future<void> _completeVideoCaptureJob(VideoCaptureJob job) async {
    if (!mounted) throw StateError('App closed; retain durable video job.');
    final store = await _database.history;
    final ownRoot = Directory(
        '${store.mediaDirectory.path}/${store.safeUserId(job.customer)}');
    final original = File(job.path);
    final ownerPath = await ownRoot.resolveSymbolicLinks();
    final actualPath = await original.resolveSymbolicLinks();
    if (!actualPath.startsWith('$ownerPath/')) {
      throw StateError(
          'Queued video is outside this customer’s private directory.');
    }
    final digest = (await sha256.bind(original.openRead()).first).toString();
    if (digest != job.digest) {
      throw StateError('Queued video content hash changed.');
    }
    if (await store.hasCapturedMediaEvent(job.customer, 'video', digest,
        sentAt: job.sentAt)) {
      final document = await store.read(job.customer);
      final partial = (document?['messages'] as List<Object?>? ?? const [])
          .whereType<Map>()
          .where((m) => m['id'] == job.messageId)
          .any((m) => (m['media'] as List<Object?>? ?? const [])
              .whereType<Map>()
              .any((media) =>
                  media['type'] == 'video' && media['is_partial'] == true));
      if (partial) {
        await store.recordMediaCaptureFailure(job.customer, 'video',
            sentAt: job.sentAt, reason: 'video_analysis_failed');
      }
      return;
    }
    CapturedMessage? message;
    String? failure;
    try {
      message = await _processDownloadedVideo(
          job.customer,
          DownloadedVideoPayload(
              path: job.path,
              mimeType: job.mimeType,
              ownershipVerification: job.ownershipVerification,
              originalName: job.originalName ?? 'customer-video.mp4'),
          job.fingerprint,
          sentAt: job.sentAt,
          sourceEventKey: job.sourceEventKey);
    } catch (error) {
      failure = error.toString();
      _diagnosticLog.record('capture.video_processing_failed', fields: {
        'customer': job.customer,
        'message_at': job.sentAt?.toUtc().toIso8601String(),
        'content_sha256': digest,
        'error': failure
      });
      // Preserve the original and its event even if decoding fails. Codex is
      // explicitly told it has no readable frames; do not reuse an older clip.
      message = CapturedMessage(
          stableId: job.messageId,
          direction: 'incoming',
          body:
              '[Customer sent a video; original saved, but video analysis failed. No readable frames are available.]',
          sender: job.customer,
          sentAt: job.sentAt,
          axPath: 'ocr:jd-video-cache',
          media: [
            CapturedMedia(
                type: 'video',
                path: job.path,
                mimeType: job.mimeType,
                originalName: job.originalName,
                captureSource: 'jd_video_cache',
                sourceEventKey: job.sourceEventKey,
                isPartial: true,
                description:
                    'Video analysis unavailable; do not describe its contents.',
                visualFingerprint: job.fingerprint,
                contentSha256: digest,
                verifiedCustomerId: job.customer,
                ownershipVerification: job.ownershipVerification)
          ]);
    }
    if (message == null) return;
    final capture = CapturedConversation(
        stableKey: 'customer:${sha256.convert(utf8.encode(job.customer))}',
        customerName: job.customer,
        customerExternalId: job.customer,
        verifiedCustomerId: job.customer,
        messages: [message],
        capturedAt: DateTime.now());
    final inserted = await _database.saveCapture(capture);
    if (inserted > 0) {
      _mediaEvidenceVersions.record(
          job.customer, message.stableId, MediaEvidenceStage.ready,
          sentAt: message.sentAt);
    }
    if (failure != null) {
      await store.recordMediaCaptureFailure(job.customer, 'video',
          sentAt: job.sentAt, reason: 'video_analysis_failed');
    }
    final recovery = _unreadRecovery[job.customer];
    if (recovery != null &&
        recovery.acceptsIncoming(message.stableId,
            sentAt: message.sentAt, capturedAt: capture.capturedAt)) {
      if (recovery.holdingSentAt case final at?) {
        await _database.acknowledgeUncapturedHolding(
            userId: job.customer, sentAt: at);
      }
      _finishUnreadRecovery(job.customer, expectedRecovery: recovery);
    }
    await _coordinator.refresh();
  }

  Future<CapturedMessage?> _processDownloadedVideo(
    String customer,
    DownloadedVideoPayload downloaded,
    String thumbnailFingerprint, {
    DateTime? sentAt,
    String? sourceEventKey,
  }) async {
    final ownership = downloaded.ownershipVerification;
    Future<CapturedMessage?> processDownloadedVideo() async {
      final contentDigest =
          (await sha256.bind(File(downloaded.path).openRead()).first)
              .toString();
      if (await (await _database.history).hasCapturedMediaEvent(
          customer, 'video', contentDigest,
          sentAt: sentAt)) {
        _diagnosticLog.record('capture.media_event_duplicate', fields: {
          'customer': customer,
          'kind': 'video',
          'message_at': sentAt?.toUtc().toIso8601String(),
          'content_sha256': contentDigest,
        });
        return null;
      }
      final extracted =
          await const VideoFrameExtractor().extract(downloaded.path);
      CapturedMedia? audioMedia;
      try {
        final audio =
            await const VideoAudioExtractor().extract(downloaded.path);
        if (!audio.hasAudioStream) {
          // Visual evidence still proceeds without an audio stream.
        } else if (!audio.hasAudibleContent) {
          audioMedia = CapturedMedia(
            type: 'audio',
            path: audio.audioPath!,
            mimeType: 'audio/wav',
            originalName: 'video_audio.wav',
            captureSource: 'jd_video_audio_ffmpeg',
            verifiedCustomerId: customer,
            ownershipVerification: ownership,
            description:
                'Audio stream present; meaningful sound was not detected.',
          );
        } else {
          SpeechTranscription? speech;
          try {
            speech = await _adapter
                .transcribeAudio(audio.audioPath!)
                .timeout(const Duration(seconds: 15));
          } catch (_) {
            // Audio evidence remains useful even if permission, connectivity, or
            // the platform recognizer is temporarily unavailable.
          }
          final transcript =
              speech?.transcript.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
          if (speech?.speechDetected == true && transcript.isNotEmpty) {
            final bounded = transcript.length <= 8000
                ? transcript
                : '${transcript.substring(0, 8000)}…';
            audioMedia = CapturedMedia(
              type: 'audio',
              path: audio.audioPath!,
              mimeType: 'audio/wav',
              originalName: 'video_audio.wav',
              captureSource: 'jd_video_audio_ffmpeg',
              verifiedCustomerId: customer,
              ownershipVerification: ownership,
              speechTranscript: bounded,
              speechLanguage: speech!.language,
              speechConfidence: speech.confidence,
              description:
                  'Audible speech transcribed as ${speech.language} with confidence ${speech.confidence.toStringAsFixed(2)}: $bounded',
            );
          } else {
            audioMedia = CapturedMedia(
              type: 'audio',
              path: audio.audioPath!,
              mimeType: 'audio/wav',
              originalName: 'video_audio.wav',
              captureSource: 'jd_video_audio_ffmpeg',
              verifiedCustomerId: customer,
              ownershipVerification: ownership,
              description:
                  'Audible content detected; no speech transcript was available.',
            );
          }
        }
      } catch (_) {
        // Visual video analysis must still proceed if the audio stream is
        // malformed or local FFmpeg audio extraction is unavailable.
      }
      final frameMedia = <CapturedMedia>[];
      for (var index = 0; index < extracted.framePaths.length; index++) {
        frameMedia.add(CapturedMedia(
          type: 'image',
          path: extracted.framePaths[index],
          mimeType: 'image/jpeg',
          originalName:
              'video_frame_${(index + 1).toString().padLeft(2, '0')}s.jpg',
          captureSource: 'jd_video_frame_1fps',
          description: 'Pending Codex visual analysis.',
          verifiedCustomerId: customer,
          ownershipVerification: ownership,
        ));
      }
      return CapturedMessage(
        stableId: mediaMessageStableId('video', extracted.sha256Digest, sentAt),
        direction: 'incoming',
        body: '[Customer sent a video]',
        sender: customer,
        sentAt: sentAt,
        axPath: 'ocr:jd-video-cache',
        media: [
          CapturedMedia(
            type: 'video',
            path: downloaded.path,
            mimeType: downloaded.mimeType,
            originalName: downloaded.originalName,
            captureSource: 'jd_video_cache',
            sourceEventKey: sourceEventKey,
            description:
                'Original customer video; visual evidence is stored in the sampled frame images.',
            visualFingerprint: thumbnailFingerprint,
            contentSha256: extracted.sha256Digest,
            verifiedCustomerId: customer,
            ownershipVerification: ownership,
          ),
          if (audioMedia != null) audioMedia,
          ...frameMedia,
        ],
      );
    }

    return processDownloadedVideo();
  }

  Future<CapturedMessage?> _saveVisibleImage(
    String customer,
    VisibleImagePayload image, {
    DateTime? sentAt,
    bool viewportFallback = false,
    bool originalDownload = false,
    bool clipboardCopy = false,
    bool cacheCopy = false,
    String? sourceEventKey,
    bool attachmentPreview = false,
  }) async {
    final bytes = image.bytes!;
    final fingerprint = image.visualFingerprint ?? '';
    final digest = sha256.convert(bytes).toString();
    final previewId = attachmentPreview && sourceEventKey != null
        ? 'visible-attachment-preview:${sha256.convert(utf8.encode('$customer:$sourceEventKey'))}'
        : null;
    if (attachmentPreview &&
        sourceEventKey != null &&
        await (await _database.history).hasAcquiredImageEvent(
            customer, sourceEventKey,
            previewId: previewId)) {
      return null;
    }
    if (await (await _database.history)
        .hasCapturedMediaEvent(customer, 'image', digest, sentAt: sentAt)) {
      _diagnosticLog.record('capture.media_event_duplicate', fields: {
        'customer': customer,
        'kind': 'image',
        'message_at': sentAt?.toUtc().toIso8601String(),
        'content_sha256': digest,
      });
      return null;
    }
    final extension = image.extension ?? 'png';
    final originalName = image.originalName ??
        'qianniu_${DateTime.now().millisecondsSinceEpoch}.$extension';
    final path = await (await _database.history).saveMedia(
      userId: customer,
      filename: originalName,
      bytes: bytes,
    );
    return CapturedMessage(
      stableId: previewId ?? mediaMessageStableId('image', digest, sentAt),
      direction: 'incoming',
      body: attachmentPreview
          ? '[Customer sent an attachment; visible preview captured, original not verified]'
          : clipboardCopy
              ? '[Customer sent an image; copied from JD]'
              : cacheCopy
                  ? '[Customer sent an image; original copied from JD cache]'
                  : originalDownload
                      ? '[Customer sent an image; original downloaded]'
                      : '[Customer sent an image; visible portion captured]',
      sender: customer,
      sentAt: sentAt,
      axPath: clipboardCopy
          ? 'ocr:jd-clipboard-image'
          : cacheCopy
              ? 'ocr:jd-image-cache'
              : viewportFallback
                  ? 'ocr:visible-chat-viewport-fallback'
                  : 'ocr:visible-image-region',
      media: [
        CapturedMedia(
          type: 'image',
          path: path,
          mimeType: image.mimeType,
          originalName: originalName,
          captureSource: clipboardCopy
              ? 'jd_clipboard_copy'
              : cacheCopy
                  ? 'jd_image_cache'
                  : originalDownload
                      ? 'jd_image_viewer_download'
                      : attachmentPreview
                          ? 'verified_attachment_preview'
                          : viewportFallback
                              ? 'verified_chat_viewport_fallback'
                              : 'verified_window_crop',
          isPartial: !originalDownload && !clipboardCopy && !cacheCopy,
          sourceEventKey: sourceEventKey,
          description: attachmentPreview
              ? 'Verified visible attachment preview only. Original file/type is unverified; '
                  'it may be an image or a video poster. Describe only visible pixels, '
                  'not unseen video actions. White/grey/black content is valid evidence.'
              : 'Pending Codex visual analysis.',
          visualFingerprint: fingerprint,
          contentSha256: digest,
          verifiedCustomerId: customer,
          ownershipVerification: image.ownershipVerification,
        ),
      ],
    );
  }

  Future<void> _inspect() async {
    try {
      final result = await _adapter.inspectTree();
      setState(() => _diagnostics = result['tree'] as String? ?? '$result');
    } catch (error) {
      setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    if (Platform.isMacOS) {
      _uiScheduler.close();
      unawaited(_attachmentDownloads.then((queue) => queue.close()));
    }
    _permissionMonitor?.dispose();
    // The lease is held until this controller closes, including while paused,
    // so an in-flight native operation cannot race another app's controller.
    unawaited(_automationLease?.release());
    _autoCaptureTimer?.cancel();
    _unreadSignalTimer?.cancel();
    _activeChatSignalTimer?.cancel();
    _failedSendRetryTimer?.cancel();
    _deliveryRetryTimer?.cancel();
    _deliveryRecoveryTimer?.cancel();
    for (final timer in _draftRetryTimers.values) {
      timer.cancel();
    }
    for (final timer in _batchCollectionTimers.values) {
      timer.cancel();
    }
    for (final timer in _slaFallbackTimers.values) {
      timer.cancel();
    }
    for (final timer in _unreadHoldingTimers.values) {
      timer.cancel();
    }
    for (final timer in _unreadResendTimers.values) {
      timer.cancel();
    }
    _updateSubscription?.cancel();
    _diagnosticSubscription?.cancel();
    _failedSendInspectionSubscription?.cancel();
    unawaited(_videoCaptureQueue.then((queue) => queue.close()));
    _adapter.close();
    _database.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) {
      return const Scaffold(
          body: Center(
              child:
                  Text('The capture adapter currently supports macOS only.')));
    }
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        titleSpacing: 20,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 18,
              child: Icon(Icons.support_agent_rounded, size: 21),
            ),
            SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppRuntime.appName,
                    style:
                        TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                Text('Customer communication console',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: Colors.black54)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh connection status',
            onPressed: _refreshStatus,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Accessibility diagnostics',
            onPressed: _inspect,
            icon: const Icon(Icons.troubleshoot_rounded),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _autoCaptureStarting ? null : _start,
            icon: Icon(_autoCaptureRunning
                ? Icons.stop_circle_outlined
                : _autoCaptureStarting
                    ? Icons.hourglass_top_rounded
                    : Icons.play_circle_outline_rounded),
            label: Text(_autoCaptureRunning
                ? 'Stop automation'
                : _autoCaptureStarting
                    ? 'Opening JD…'
                    : 'Start automation'),
          ),
          const SizedBox(width: 20),
        ],
      ),
      body: Row(children: [
        SizedBox(
          width: 310,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _status['trusted'] == true
                      ? Colors.green.withValues(alpha: 0.08)
                      : Theme.of(context)
                          .colorScheme
                          .errorContainer
                          .withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _status['trusted'] == true
                        ? Colors.green.withValues(alpha: 0.25)
                        : Theme.of(context).colorScheme.error.withValues(
                              alpha: 0.20,
                            ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _status['trusted'] == true
                          ? Icons.check_circle_rounded
                          : Icons.error_outline_rounded,
                      color: _status['trusted'] == true
                          ? Colors.green.shade700
                          : Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _status['trusted'] == true
                                ? 'JD connection ready'
                                : _status.containsKey('trusted')
                                    ? 'Access required'
                                    : 'Checking Accessibility…',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _status['trusted'] == true
                                ? 'Automation can monitor conversations'
                                : 'Allow Accessibility for ${AppRuntime.appName}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_status['trusted'] == false)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: OutlinedButton(
                  onPressed: () async {
                    await _adapter.requestAccessibility();
                    await _refreshStatus();
                  },
                  child: const Text('Request Accessibility access'),
                ),
              ),
            if (_status['trusted'] == false)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: SelectableText(
                    'Authorize this exact app copy:\n'
                    '${_status['appBundlePath'] ?? Platform.resolvedExecutable}\n'
                    'Permission refreshes automatically when you return.',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_errorState.displayedText!,
                      style: const TextStyle(color: Colors.red))),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Transfer records',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  if (_transferLogs.isNotEmpty)
                    Badge(label: Text('${_transferLogs.length}')),
                ],
              ),
            ),
            if (_transferLogs.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 2, 12, 10),
                child: Text('No transfer records',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final log in _transferLogs.take(20))
                      ListTile(
                        dense: true,
                        leading: Icon(
                          log.status == 'transferred'
                              ? Icons.check_circle
                              : log.status == 'failed' ||
                                      log.status == 'unconfirmed'
                                  ? Icons.error_outline
                                  : Icons.sync,
                          color: log.status == 'transferred'
                              ? Colors.green
                              : log.status == 'failed' ||
                                      log.status == 'unconfirmed'
                                  ? Colors.red
                                  : Colors.orange,
                          size: 20,
                        ),
                        title: Text(
                          '${log.sourceAccount} → ${log.targetAccount ?? '正在选择在线账号'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${log.conversationId} · ${log.status}\n${log.reason}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(),
            Expanded(
                child: ListView.builder(
              itemCount: _conversations.length,
              itemBuilder: (context, index) {
                final item = _conversations[index];
                return ListTile(
                  title: Text(item.customerName),
                  subtitle: Text(
                      item.messages.isEmpty
                          ? 'No messages'
                          : item.messages.last.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  onTap: () => showDialog<void>(
                      context: context,
                      builder: (_) => _MessageDialog(
                            conversation: item,
                            database: _database,
                            onReplyCompleted: _coordinator.refresh,
                          )).then((_) => _refreshTickets()),
                );
              },
            )),
          ]),
        ),
        const VerticalDivider(width: 1),
        Expanded(
            child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
                _ocrInspection == null
                    ? 'Accessibility diagnostics'
                    : 'OCR diagnostics — ${_ocrInspection!.windowTitle}',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_ocrInspection == null
                ? 'Use this output to map roles and paths from the installed JD 咚咚 build. Sending remains guarded by exact customer verification.'
                : '${_ocrInspection!.observations.length} Apple Vision text regions • ${_ocrInspection!.imageWidth}×${_ocrInspection!.imageHeight}. Red boxes show Apple Vision observations.'),
            const SizedBox(height: 8),
            if (_ocrInspection != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _diagnostics.startsWith('Saved') ||
                          _diagnostics.contains('already saved') ||
                          _diagnostics.startsWith('Sent')
                      ? Colors.green.withValues(alpha: 0.10)
                      : Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(_diagnostics),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
                child: _ocrInspection == null
                    ? SingleChildScrollView(
                        child: SelectableText(_diagnostics,
                            style: const TextStyle(
                                fontFamily: 'Menlo', fontSize: 11)))
                    : _OcrDiagnosticView(inspection: _ocrInspection!)),
          ]),
        )),
      ]),
    );
  }
}

class _OcrDiagnosticView extends StatelessWidget {
  const _OcrDiagnosticView({required this.inspection});

  final OcrInspection inspection;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          flex: 3,
          child: InteractiveViewer(
            minScale: 0.25,
            maxScale: 5,
            child: AspectRatio(
              aspectRatio: inspection.imageWidth / inspection.imageHeight,
              child: Stack(fit: StackFit.expand, children: [
                Image.memory(inspection.image, fit: BoxFit.fill),
                CustomPaint(painter: _OcrBoxPainter(inspection.observations)),
              ]),
            ),
          ),
        ),
        const VerticalDivider(),
        Expanded(
          child: ListView.builder(
            itemCount: inspection.observations.length,
            itemBuilder: (context, index) {
              final observation = inspection.observations[index];
              return ListTile(
                dense: true,
                title: SelectableText(observation.text),
                subtitle: Text(
                    '${(observation.confidence * 100).toStringAsFixed(1)}% • x=${observation.x.toStringAsFixed(3)}, y=${observation.y.toStringAsFixed(3)}'),
              );
            },
          ),
        ),
      ]);
}

class _OcrBoxPainter extends CustomPainter {
  const _OcrBoxPainter(this.observations);

  final List<OcrObservation> observations;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final observation in observations) {
      canvas.drawRect(
        Rect.fromLTWH(
          observation.x * size.width,
          observation.y * size.height,
          observation.width * size.width,
          observation.height * size.height,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OcrBoxPainter oldDelegate) =>
      oldDelegate.observations != observations;
}

class _MessageDialog extends StatefulWidget {
  const _MessageDialog({
    required this.conversation,
    required this.database,
    required this.onReplyCompleted,
  });

  final ConversationSummary conversation;
  final CaptureDatabase database;
  final Future<void> Function() onReplyCompleted;

  @override
  State<_MessageDialog> createState() => _MessageDialogState();
}

class _MessageDialogState extends State<_MessageDialog> {
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.conversation.customerName),
        content: SizedBox(
          width: 620,
          height: 560,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Captured and sent messages',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: widget.conversation.messages
                    .map((message) => ListTile(
                          dense: true,
                          leading: Icon(message.direction == 'incoming'
                              ? Icons.call_received
                              : message.direction == 'outgoing'
                                  ? Icons.call_made
                                  : Icons.help_outline),
                          title: Text(message.body),
                          subtitle: Text(message.stableId),
                        ))
                    .toList(),
              ),
            ),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(10),
                child: Text(
                    'Replies are generated and sent automatically. Unsent drafts are not shown or written to conversation JSON.'),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'))
        ],
      );
}
