import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/capture_models.dart';

class OutboxReply {
  OutboxReply(
      {required this.userId,
      required this.batchEndMessageId,
      required this.draft,
      required this.createdAt,
      this.state = 'ready',
      this.verifiedAbsences = 0,
      this.lastVerifiedAbsenceAt});

  final String userId;
  final String batchEndMessageId;
  final AiDraft draft;
  final DateTime createdAt;
  String state;
  int verifiedAbsences;
  DateTime? lastVerifiedAbsenceAt;

  Map<String, Object?> toJson() => {
        'user_id': userId,
        'batch_end_message_id': batchEndMessageId,
        'draft': jsonDecode(draft.rawJson),
        'created_at': createdAt.toUtc().toIso8601String(),
        'state': state,
        'verified_absences': verifiedAbsences,
        'last_verified_absence_at':
            lastVerifiedAbsenceAt?.toUtc().toIso8601String(),
      };
}

/// The original answer is durable before any SQLite delivery write. A
/// confirmed receipt is retained here until SQLite has acknowledged it.
class ReplyOutbox {
  ReplyOutbox(this.directory);
  final Directory directory;
  Future<void> _sendTail = Future<void>.value();
  Future<void> _writeTail = Future<void>.value();

  File _file(String userId, String batchEnd) => File(p.join(directory.path,
      '${sha256.convert(utf8.encode('$userId\u001f$batchEnd'))}.json'));

  Future<void> save(OutboxReply reply) async {
    final release = Completer<void>();
    final previous = _writeTail;
    _writeTail = release.future;
    await previous;
    try {
      await directory.create(recursive: true);
      final file = _file(reply.userId, reply.batchEndMessageId);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(reply.toJson()), flush: true);
      await temporary.rename(file.path);
    } finally {
      release.complete();
    }
  }

  /// Two independent complete viewport checks showing the exact unanswered
  /// customer bubble and no outgoing reply permit retry after a lost callback
  /// or a process exit before Send. A missing/failed OCR pass is not evidence.
  Future<bool> recordVerifiedAbsence(OutboxReply item,
      {required bool exactUnansweredBubbleVisible, DateTime? now}) async {
    final checkedAt = now ?? DateTime.now();
    if (item.state != 'sending' ||
        !exactUnansweredBubbleVisible ||
        checkedAt.difference(item.createdAt) < const Duration(seconds: 20) ||
        (item.lastVerifiedAbsenceAt != null &&
            checkedAt.difference(item.lastVerifiedAbsenceAt!) <
                const Duration(seconds: 5))) {
      return false;
    }
    item.verifiedAbsences++;
    item.lastVerifiedAbsenceAt = checkedAt;
    if (item.verifiedAbsences >= 2) item.state = 'ready';
    await save(item);
    return item.state == 'ready';
  }

  /// Persist the send intent before invoking JD and the exact successful
  /// acknowledgement afterward. A failed SQL bookkeeping callback is outside
  /// this method and therefore can never turn a confirmed send into a retry.
  Future<bool> sendReady(
    OutboxReply item, {
    required Future<void> Function(AiDraft draft) send,
    required bool Function(Object error) definitelyBeforeSend,
  }) async {
    final release = Completer<void>();
    final previous = _sendTail;
    _sendTail = release.future;
    await previous;
    try {
      return await _sendReady(item,
          send: send, definitelyBeforeSend: definitelyBeforeSend);
    } finally {
      release.complete();
    }
  }

  Future<bool> _sendReady(
    OutboxReply item, {
    required Future<void> Function(AiDraft draft) send,
    required bool Function(Object error) definitelyBeforeSend,
  }) async {
    final current = (await pending())
        .where((candidate) =>
            candidate.userId == item.userId &&
            candidate.batchEndMessageId == item.batchEndMessageId)
        .firstOrNull;
    if (current == null || current.state != 'ready') return false;
    current.state = 'sending';
    current.verifiedAbsences = 0;
    current.lastVerifiedAbsenceAt = null;
    await save(current);
    item.state = 'sending';
    try {
      await send(current.draft);
    } catch (error) {
      if (definitelyBeforeSend(error)) {
        current.state = 'ready';
        await save(current);
        item.state = 'ready';
      }
      rethrow;
    }
    current.state = 'sent';
    await save(current);
    item.state = 'sent';
    return true;
  }

  Future<List<OutboxReply>> pending() async {
    if (!await directory.exists()) return const [];
    final replies = <OutboxReply>[];
    await for (final file in directory.list(followLinks: false)) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      replies.add(OutboxReply(
          userId: raw['user_id'] as String,
          batchEndMessageId: raw['batch_end_message_id'] as String,
          draft: AiDraft.fromJson((raw['draft'] as Map).cast<String, Object?>(),
              mediaBaseUrl: Uri()),
          createdAt: DateTime.parse(raw['created_at'] as String),
          state: raw['state'] as String,
          verifiedAbsences: raw['verified_absences'] as int? ?? 0,
          lastVerifiedAbsenceAt: DateTime.tryParse(
              raw['last_verified_absence_at']?.toString() ?? '')));
    }
    replies.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return replies;
  }

  /// Refresh only a never-sent ready draft. Serialize with Send so an uncertain
  /// or acknowledged delivery can never lose its durable receipt.
  Future<bool> discardReady(OutboxReply item) async {
    final release = Completer<void>();
    final previous = _sendTail;
    _sendTail = release.future;
    await previous;
    try {
      final current = (await pending())
          .where((candidate) =>
              candidate.userId == item.userId &&
              candidate.batchEndMessageId == item.batchEndMessageId)
          .firstOrNull;
      if (current == null ||
          current.state != 'ready' ||
          current.draft.rawJson != item.draft.rawJson) {
        return false;
      }
      await remove(item.userId, item.batchEndMessageId);
      return true;
    } finally {
      release.complete();
    }
  }

  Future<void> remove(String userId, String batchEnd) async {
    final file = _file(userId, batchEnd);
    if (await file.exists()) await file.delete();
  }
}
