import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../domain/media_identity.dart';

class VideoCaptureJob {
  const VideoCaptureJob(
      {required this.customer,
      required this.path,
      required this.digest,
      required this.sentAt,
      required this.fingerprint,
      this.mimeType = 'video/mp4',
      this.ownershipVerification = 'visible_customer_region',
      this.sourceEventKey,
      this.originalName});
  final String customer;
  final String path;
  final String digest;
  final DateTime? sentAt;
  final String fingerprint;
  final String mimeType;
  final String ownershipVerification;
  final String? originalName;
  final String? sourceEventKey;
  String get messageId => mediaMessageStableId('video', digest, sentAt);
  String get key => '$customer\u001f$messageId';
  String get contentKey => '$customer\u001f$digest';
  Map<String, Object?> toJson() => {
        'customer': customer,
        'path': path,
        'sha256': digest,
        'sent_at': sentAt?.toUtc().toIso8601String(),
        'fingerprint': fingerprint,
        'mime_type': mimeType,
        'ownership_verification': ownershipVerification,
        'original_name': originalName,
        if (sourceEventKey != null) 'source_event_key': sourceEventKey,
      };
  factory VideoCaptureJob.fromJson(Map<String, dynamic> raw) => VideoCaptureJob(
      customer: raw['customer'] as String,
      path: raw['path'] as String,
      digest: raw['sha256'] as String,
      sentAt: DateTime.tryParse(raw['sent_at']?.toString() ?? ''),
      fingerprint: raw['fingerprint'] as String? ?? '',
      mimeType: raw['mime_type'] as String? ?? 'video/mp4',
      ownershipVerification:
          raw['ownership_verification'] as String? ?? 'visible_customer_region',
      originalName: raw['original_name'] as String?,
      sourceEventKey: raw['source_event_key'] as String?);
}

/// Originals and event identities survive restart before decoding starts.
/// No worker owns the JD UI queue. One failed video cannot stop another job.
class VideoCaptureQueue {
  VideoCaptureQueue(this.directory,
      {required this.process,
      required this.enabled,
      required this.onError,
      this.onIdle,
      this.maximumWorkers = 2,
      this.retryDelay = const Duration(seconds: 5)});
  final Directory directory;
  final Future<void> Function(VideoCaptureJob) process;
  final bool Function() enabled;
  final void Function(Object, StackTrace) onError;
  final void Function(String)? onIdle;
  final int maximumWorkers;
  final Duration retryDelay;
  final Map<String, VideoCaptureJob> _jobs = {};
  final Set<String> _active = {};
  final Set<String> _activeContent = {};
  final Set<String> _activeCustomers = {};
  final Set<String> _persisting = {};
  final Map<String, Timer> _retries = {};
  Future<void>? _initializing;
  bool _closed = false;

  File _file(VideoCaptureJob job) =>
      File('${directory.path}/${sha256.convert(utf8.encode(job.key))}.json');
  Future<void> initialize() => _initializing ??= () async {
        await directory.create(recursive: true);
        await for (final file in directory.list(followLinks: false)) {
          if (file is! File || !file.path.endsWith('.json')) continue;
          try {
            final job = VideoCaptureJob.fromJson(
                jsonDecode(await file.readAsString()) as Map<String, dynamic>);
            _jobs[job.key] = job;
          } catch (error, stack) {
            onError(error, stack);
          }
        }
      }();

  bool hasCustomer(String customer) =>
      _jobs.values.any((job) => job.customer == customer);
  bool hasEvent(String customer, DateTime sentAt, String eventKey,
          {bool singleVisibleBubble = false}) =>
      _jobs.values.any((job) =>
          job.customer == customer &&
          job.sentAt != null &&
          sameMediaMessageTime(job.sentAt, sentAt) &&
          (job.sourceEventKey == eventKey ||
              (singleVisibleBubble && job.sourceEventKey == null)));
  Future<void> resume() async {
    await initialize();
    _pump();
  }

  Future<bool> enqueue(VideoCaptureJob job) async {
    await initialize();
    if (_jobs.containsKey(job.key)) return false;
    // No await between reservation and insertion: concurrent identical polls
    // cannot launch two decoders or overwrite a completed event's journal.
    _jobs[job.key] = job;
    _persisting.add(job.key);
    try {
      final file = _file(job);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(job.toJson()), flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      _jobs.remove(job.key);
      rethrow;
    } finally {
      _persisting.remove(job.key);
    }
    _pump();
    return true;
  }

  void _pump() {
    if (_closed || !enabled()) return;
    for (final job in _jobs.values.toList()) {
      if (_active.length >= maximumWorkers) break;
      if (_persisting.contains(job.key) ||
          _active.contains(job.key) ||
          _activeCustomers.contains(job.customer) ||
          _activeContent.contains(job.contentKey) ||
          _retries.containsKey(job.key)) {
        continue;
      }
      _active.add(job.key);
      _activeContent.add(job.contentKey);
      _activeCustomers.add(job.customer);
      unawaited(_run(job));
    }
  }

  Future<void> _run(VideoCaptureJob job) async {
    try {
      await process(job);
      final file = _file(job);
      if (await file.exists()) await file.delete();
      _jobs.remove(job.key);
    } catch (error, stack) {
      onError(error, stack);
      if (!_closed) {
        _retries[job.key] = Timer(retryDelay, () {
          _retries.remove(job.key);
          _pump();
        });
      }
    } finally {
      _active.remove(job.key);
      _activeContent.remove(job.contentKey);
      _activeCustomers.remove(job.customer);
      if (!hasCustomer(job.customer)) onIdle?.call(job.customer);
      _pump();
    }
  }

  void close() {
    _closed = true;
    for (final timer in _retries.values) {
      timer.cancel();
    }
    _retries.clear();
  }
}
