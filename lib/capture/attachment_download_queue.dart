import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Issued only after native code selected one exact customer attachment and
/// closed its export dialog. Polling this receipt never touches JD's UI.
class AttachmentDownloadTicket {
  const AttachmentDownloadTicket(
      {required this.token,
      required this.customer,
      required this.eventKey,
      required this.sentAt,
      required this.startedAt,
      required this.directory,
      required this.originalName});
  final String token, customer, eventKey, directory, originalName;
  final DateTime sentAt, startedAt;
  String get key => '$customer\u001f$eventKey';
  Map<String, Object?> toJson() => {
        'token': token,
        'customer': customer,
        'event_key': eventKey,
        'sent_at': sentAt.toUtc().toIso8601String(),
        'started_at': startedAt.toUtc().toIso8601String(),
        'directory': directory,
        'original_name': originalName,
      };
  factory AttachmentDownloadTicket.fromJson(Map<String, dynamic> json) =>
      AttachmentDownloadTicket(
          token: json['token'] as String,
          customer: json['customer'] as String,
          eventKey: json['event_key'] as String,
          sentAt: DateTime.parse(json['sent_at'] as String),
          startedAt: DateTime.parse(json['started_at'] as String),
          directory: json['directory'] as String,
          originalName: json['original_name'] as String);
}

/// A bounded, durable file-wait queue independent of the shared JD UI queue.
/// One failed download cannot monopolize another customer's worker or leave
/// that customer's generation deferred forever.
class AttachmentDownloadQueue {
  AttachmentDownloadQueue(this.directory,
      {required this.enabled,
      required this.poll,
      required this.failed,
      required this.onIdle,
      this.onError,
      this.maximumWorkers = 2,
      this.timeout = const Duration(seconds: 30),
      this.pollInterval = const Duration(milliseconds: 500)});
  final Directory directory;
  final bool Function() enabled;
  final Future<bool> Function(AttachmentDownloadTicket) poll;
  final Future<void> Function(AttachmentDownloadTicket, Object) failed;
  final void Function(String) onIdle;
  final void Function(Object, StackTrace)? onError;
  final int maximumWorkers;
  final Duration timeout, pollInterval;
  final Map<String, AttachmentDownloadTicket> _jobs = {};
  final Set<String> _active = {}, _persisting = {};
  Future<void>? _initializing;
  bool _closed = false;
  File _file(AttachmentDownloadTicket ticket) =>
      File('${directory.path}/${sha256.convert(utf8.encode(ticket.key))}.json');
  Future<void> initialize() => _initializing ??= () async {
        await directory.create(recursive: true);
        await for (final entry in directory.list(followLinks: false)) {
          if (entry is! File || !entry.path.endsWith('.json')) continue;
          try {
            final ticket = AttachmentDownloadTicket.fromJson(
                jsonDecode(await entry.readAsString()) as Map<String, dynamic>);
            if (ticket.customer.isEmpty ||
                ticket.eventKey.isEmpty ||
                ticket.token.isEmpty ||
                ticket.directory.isEmpty ||
                ticket.originalName.isEmpty ||
                _file(ticket).path != entry.path ||
                ticket.startedAt
                    .isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
              throw const FormatException(
                  'Invalid attachment download ticket.');
            }
            _jobs[ticket.key] = ticket;
          } catch (error, stack) {
            _report(error, stack);
            // Retain corrupt evidence for inspection, without blocking all
            // other customers on every app restart.
            try {
              await entry.rename('${entry.path}.invalid');
            } catch (error, stack) {
              _report(error, stack);
            }
          }
        }
      }();
  bool hasCustomer(String customer) =>
      _jobs.values.any((job) => job.customer == customer);
  bool hasEvent(String customer, String eventKey) =>
      _jobs.containsKey('$customer\u001f$eventKey');
  Future<void> enqueue(AttachmentDownloadTicket ticket) async {
    await initialize();
    if (_jobs.containsKey(ticket.key)) return;
    _jobs[ticket.key] = ticket;
    _persisting.add(ticket.key);
    try {
      final target = _file(ticket);
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(jsonEncode(ticket.toJson()), flush: true);
      await temporary.rename(target.path);
    } catch (_) {
      _jobs.remove(ticket.key);
      rethrow;
    } finally {
      _persisting.remove(ticket.key);
    }
    _pump();
  }

  Future<void> resume() async {
    await initialize();
    _pump();
  }

  void _pump() {
    if (_closed || !enabled()) return;
    for (final job in _jobs.values.toList()) {
      if (_active.length >= maximumWorkers) break;
      if (_active.contains(job.key) || _persisting.contains(job.key)) continue;
      if (_active.any((key) => _jobs[key]?.customer == job.customer)) continue;
      _active.add(job.key);
      unawaited(_run(job));
    }
  }

  Future<void> _run(AttachmentDownloadTicket ticket) async {
    var complete = false;
    try {
      while (!_closed && enabled()) {
        final remaining = timeout - DateTime.now().difference(ticket.startedAt);
        if (remaining <= Duration.zero) {
          throw TimeoutException(
              'Attachment original did not finish downloading.', timeout);
        }
        if (await poll(ticket).timeout(remaining < const Duration(seconds: 5)
            ? remaining
            : const Duration(seconds: 5))) {
          complete = true;
          break;
        }
        await Future<void>.delayed(pollInterval);
      }
    } catch (error, stack) {
      complete = true;
      _report(error, stack);
      try {
        await failed(ticket, error).timeout(const Duration(seconds: 2));
      } catch (error, stack) {
        _report(error, stack);
      }
    } finally {
      if (complete) {
        _jobs.remove(ticket.key);
        try {
          final journal = _file(ticket);
          if (await journal.exists()) await journal.delete();
        } catch (error, stack) {
          _report(error, stack);
        }
      }
      _active.remove(ticket.key);
      if (!hasCustomer(ticket.customer)) {
        try {
          onIdle(ticket.customer);
        } catch (error, stack) {
          _report(error, stack);
        }
      }
      _pump();
    }
  }

  void close() {
    _closed = true;
  }

  void _report(Object error, StackTrace stack) {
    // Diagnostics are never allowed to strand a worker.
    try {
      onError?.call(error, stack);
    } catch (_) {}
  }
}
