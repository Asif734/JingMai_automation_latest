import 'dart:async';

enum UiPriority { originalReply, fallback, capture, maintenance }

class UiOperationCancelled implements Exception {
  const UiOperationCancelled(this.operationId, this.reason);
  final String operationId, reason;
  @override
  String toString() => 'UI operation $operationId cancelled: $reason';
}

/// A cancelled async continuation retains this revoked capability in its zone.
/// Even if a file/database future completes late, it cannot issue another UI call.
class UiOperationContext {
  UiOperationContext(this.id, this.label, this.deadline, this.customer);
  static final Object _key = Object();
  static UiOperationContext? get current =>
      Zone.current[_key] as UiOperationContext?;
  final String id, label;
  final DateTime deadline;
  String? customer;
  bool _cancelled = false;
  void check([String? expectedCustomer]) {
    if (_cancelled || !DateTime.now().isBefore(deadline)) {
      throw UiOperationCancelled(id, 'expired or revoked');
    }
    if (expectedCustomer != null && expectedCustomer.isNotEmpty) {
      if (customer != null && customer != expectedCustomer) {
        throw UiOperationCancelled(id, 'customer changed within a UI job');
      }
      customer = expectedCustomer;
    }
  }

  void revoke() => _cancelled = true;
  void resolvedFromVerifiedAx(String observed, String verified) {
    check();
    if (customer != null && customer != observed) {
      throw UiOperationCancelled(
          id, 'identity resolution belongs to another job');
    }
    customer = verified;
  }

  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: this});
}

class _UiJob<T> {
  _UiJob(
      this.context, this.priority, this.action, this.queuedAt, this.waitLimit);
  final UiOperationContext context;
  final UiPriority priority;
  final Future<T> Function() action;
  final DateTime queuedAt;
  final Duration waitLimit;
  final result = Completer<T>();
  Timer? waitTimer;
}

/// Serializes only UI work. Deadlines revoke Dart continuations AND stop the
/// owned native helper before the next job starts. Never unlock a live worker.
class UiOperationScheduler {
  UiOperationScheduler(
      {required this.beginNative,
      required this.endNative,
      required this.cancelNative,
      this.onDiagnostic,
      this.recoveryTimeout = const Duration(seconds: 3),
      this.fairnessAfter = const Duration(seconds: 5)});
  final Future<void> Function(UiOperationContext) beginNative, endNative;
  final Future<void> Function(UiOperationContext) cancelNative;
  final void Function(String, Map<String, Object?>)? onDiagnostic;
  final Duration recoveryTimeout, fairnessAfter;
  final List<_UiJob<dynamic>> _queue = [];
  _UiJob<dynamic>? _active;
  UiOperationContext? _runningContext;
  UiOperationContext? _unconfirmedStop;
  Timer? _recoveryTimer;
  bool _recovering = false, _closed = false;
  int _serial = 0;
  UiPriority? _lastPriority;
  int _priorityStreak = 0;
  final String _session = DateTime.now().microsecondsSinceEpoch.toString();
  int get pendingCount =>
      _queue.length + (_active != null || _unconfirmedStop != null ? 1 : 0);
  bool get recoveryPending => _unconfirmedStop != null;

  Future<T> schedule<T>(
    Future<T> Function() action, {
    String label = 'ui.operation',
    String? customer,
    UiPriority priority = UiPriority.maintenance,
    Duration timeout = const Duration(seconds: 30),
    Duration maximumQueueWait = const Duration(seconds: 45),
  }) {
    if (_closed) {
      return Future.error(
          const UiOperationCancelled('closed', 'scheduler closed'));
    }
    final now = DateTime.now();
    // Execution deadline is set when the job starts, not while it waits.
    final job = _UiJob<T>(
        UiOperationContext('$_session:${++_serial}', label,
            now.add(maximumQueueWait).add(timeout), customer),
        priority,
        action,
        now,
        timeout);
    _queue.add(job);
    job.waitTimer = Timer(maximumQueueWait, () {
      if (!_queue.remove(job)) return;
      job.context.revoke();
      job.result.completeError(UiOperationCancelled(
          job.context.id, 'queue wait exceeded; durable work retained'));
      _log('ui.queue_expired', job.context);
    });
    scheduleMicrotask(_pump);
    return job.result.future;
  }

  void _pump() {
    if (_closed ||
        _active != null ||
        _unconfirmedStop != null ||
        _queue.isEmpty) {
      return;
    }
    final now = DateTime.now();
    // Ready originals win. After three jobs in one priority lane, let ONE
    // aged lower-priority job through, not an entire old fallback backlog.
    _queue.sort((a, b) {
      final priority = a.priority.index.compareTo(b.priority.index);
      return priority != 0 ? priority : a.queuedAt.compareTo(b.queuedAt);
    });
    var selected = 0;
    if (_lastPriority == _queue.first.priority && _priorityStreak >= 3) {
      for (var index = 1; index < _queue.length; index++) {
        if (_queue[index].priority.index > _queue.first.priority.index &&
            now.difference(_queue[index].queuedAt) >= fairnessAfter &&
            (selected == 0 ||
                _queue[index].queuedAt.isBefore(_queue[selected].queuedAt))) {
          selected = index;
        }
      }
    }
    final job = _queue.removeAt(selected);
    _priorityStreak = _lastPriority == job.priority ? _priorityStreak + 1 : 1;
    _lastPriority = job.priority;
    job.waitTimer?.cancel();
    _active = job;
    unawaited(_run(job));
  }

  Future<void> _run(_UiJob<dynamic> job) async {
    final context = UiOperationContext(job.context.id, job.context.label,
        DateTime.now().add(job.waitLimit), job.context.customer);
    _runningContext = context;
    Object? failure;
    StackTrace? stack;
    dynamic value;
    _log('ui.started', context);
    try {
      await (() async {
        await beginNative(context);
        context.check();
        value = await context.run(job.action);
        context.check();
        await endNative(context).timeout(recoveryTimeout);
      })()
          .timeout(job.waitLimit);
    } catch (error, trace) {
      failure = error;
      stack = trace;
      // Every abnormal exit is fenced, including an inner MethodChannel
      // timeout whose native invocation may still be running.
      context.revoke();
      try {
        await cancelNative(context).timeout(recoveryTimeout);
        _log('ui.cancelled_and_stopped', context);
      } catch (recoveryError) {
        _unconfirmedStop = context;
        _log('ui.stop_unconfirmed', context,
            {'error': recoveryError.toString()});
        _retryStop();
      }
    } finally {
      context.revoke();
      _active = null;
      _runningContext = null;
      if (!job.result.isCompleted) {
        if (failure != null) {
          job.result.completeError(failure, stack);
        } else {
          job.result.complete(value);
        }
      }
      _log('ui.finished', context, {'failed': failure != null});
      scheduleMicrotask(_pump);
    }
  }

  void _retryStop() {
    if (_closed || _recovering || _recoveryTimer != null) return;
    _recoveryTimer = Timer(const Duration(milliseconds: 500), () async {
      _recoveryTimer = null;
      final context = _unconfirmedStop;
      if (context == null) return;
      _recovering = true;
      try {
        await cancelNative(context).timeout(recoveryTimeout);
        if (identical(context, _unconfirmedStop)) _unconfirmedStop = null;
        _log('ui.recovery_confirmed', context);
      } catch (_) {
        // Do not run another customer's clicks until the OS confirms stop.
      } finally {
        _recovering = false;
        if (_unconfirmedStop != null) {
          _retryStop();
        } else {
          _pump();
        }
      }
    });
  }

  void _log(String event, UiOperationContext context,
      [Map<String, Object?> extra = const {}]) {
    try {
      onDiagnostic?.call(event, {
        'operation_id': context.id,
        'label': context.label,
        'customer': context.customer,
        ...extra
      });
    } catch (_) {}
  }

  /// Stop/pause revokes queued and in-flight UI authority without discarding
  /// any customer's durable message, draft, outbox, or media job.
  Future<void> cancelAll() async {
    for (final job in _queue) {
      job.waitTimer?.cancel();
      job.context.revoke();
      job.result.completeError(
          UiOperationCancelled(job.context.id, 'automation stopped'));
    }
    _queue.clear();
    final current = _runningContext;
    if (current == null) return;
    current.revoke();
    try {
      await cancelNative(current).timeout(recoveryTimeout);
      _log('ui.stopped_by_operator', current);
    } catch (error) {
      _unconfirmedStop = current;
      _log('ui.stop_unconfirmed', current, {'error': error.toString()});
      _retryStop();
    }
  }

  void close() {
    _closed = true;
    _recoveryTimer?.cancel();
    for (final job in _queue) {
      job.waitTimer?.cancel();
      job.context.revoke();
      job.result.completeError(
          UiOperationCancelled(job.context.id, 'scheduler closed'));
    }
    _queue.clear();
    final current = _runningContext;
    if (current != null) {
      current.revoke();
      unawaited(cancelNative(current).catchError((Object _) {}));
    }
  }
}
