import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/capture_models.dart';
import '../capture/reply_message_scope.dart';
import '../runtime/app_runtime.dart';
import 'conversation_file_store.dart';
import 'resilient_database.dart';

/// SQLite contains the durable processing, delivery, and SLA state. Messages
/// and confirmed sent replies live in per-user JSON documents managed by
/// [history]. Unsent generated drafts remain outside conversation history.
class CaptureDatabase {
  CaptureDatabase({Directory? storageRoot, this.onDatabaseRecovery})
      : _storageRoot = storageRoot;

  final void Function(Object error, int attempt)? onDatabaseRecovery;

  final Directory? _storageRoot;
  ResilientDatabase? _database;
  Future<ResilientDatabase>? _databaseOpening;
  ConversationFileStore? _history;
  bool _legacyDraftsPurged = false;
  bool _reviewControlsSynced = false;
  final Set<String> _pendingCaptureRepairs = {};
  bool _scannedRecentHistoryForRepair = false;
  static const slaFallbackDelay = Duration(seconds: 20);

  Future<Directory> get storageRoot async =>
      _storageRoot ?? await _resolveDefaultStorageRoot();

  Future<ConversationFileStore> get history async {
    if (_history case final value?) return value;
    final value = ConversationFileStore(await storageRoot);
    _history = value;
    return value;
  }

  Future<ResilientDatabase> get database async {
    final opening = _databaseOpening ??= _openDatabase();
    try {
      return await opening;
    } catch (_) {
      if (identical(_databaseOpening, opening)) {
        final failed = _database;
        _database = null;
        await failed?.close();
        _databaseOpening = null;
      }
      rethrow;
    }
  }

  Future<ResilientDatabase> _openDatabase() async {
    if (_database case final database?) return database;
    sqfliteFfiInit();
    final databasePath =
        p.join((await storageRoot).path, 'jd_automation.sqlite3');
    final database = ResilientDatabase(() async {
      return databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) async {
            // Readers, including operator diagnostics, must not obstruct a
            // writer's COMMIT. A real competing writer waits briefly and then
            // yields to the application recovery/retry path.
            await db.execute('PRAGMA busy_timeout=750');
            await db.rawQuery('PRAGMA journal_mode=WAL');
            await db.execute('PRAGMA synchronous=FULL');
          },
          // The withdrawn connectivity build already opened some stores at v14.
          // Keep compatibility; no new tables/columns or delivery policy here.
          version: 14,
          onCreate: _create,
          onUpgrade: _upgrade,
        ),
      );
    }, onRecovery: onDatabaseRecovery);
    _database = database;
    // Repair every legacy delivery freeze into serial retry work. A generated
    // reply must never remain outside the delivery queue indefinitely.
    if ((await database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='generated_drafts'"))
        .isNotEmpty) {
      await database.rawUpdate('''UPDATE generated_drafts
        SET delivery_state='retry', retry_at_ms=0
        WHERE delivery_state IN
          ('failed_offline','delivery_unknown','sending','retry_existing')''');
    }
    if ((await database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='sla_fallbacks'"))
        .isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await database.rawUpdate('''UPDATE sla_fallbacks
        SET state='pending', due_at_ms=?, updated_at_ms=?
        WHERE state='delivery_unknown' ''', [now, now]);
    }
    if (!_legacyDraftsPurged) {
      await (await history).purgeLegacyUnsentDrafts();
      _legacyDraftsPurged = true;
    }
    if (!_reviewControlsSynced) {
      // `human_review_open` was used by older builds to pause AI as soon as a
      // ticket was created. Open tickets are informational: AI remains active
      // until an operator or the explicit transfer flow starts contacting.
      final now = DateTime.now().millisecondsSinceEpoch;
      await database.update(
          'conversation_control',
          {
            'state': 'ai_active',
            'resume_after_message_id': null,
            'updated_at_ms': now,
          },
          where: "state = 'human_review_open'");
      _reviewControlsSynced = true;
    }
    return database;
  }

  Future<void> _create(Database db, int version) async {
    await _createPendingQueue(db);
    await _createHumanReview(db);
    await _createGeneratedDrafts(db);
    await _createTransferWelcomes(db);
    await _createSlaFallbacks(db);
    await _createAnsweredCursors(db);
    await _createHumanTransferRequests(db);
    await _createChatTransferLogs(db);
  }

  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 3) {
      // Preserve legacy tables but stop writing to them.
      await _createPendingQueue(db);
    }
    if (oldVersion < 4) await _createHumanReview(db);
    if (oldVersion < 5) await _createGeneratedDrafts(db);
    if (oldVersion < 6) await _createTransferWelcomes(db);
    if (oldVersion < 7) {
      await _createSlaFallbacks(db);
      await _addColumnIfMissing(db, 'generated_drafts',
          "delivery_state TEXT NOT NULL DEFAULT 'ready'");
      await _addColumnIfMissing(db, 'generated_drafts',
          'delivery_attempts INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'generated_drafts', 'retry_at_ms INTEGER');
      await _addColumnIfMissing(db, 'generated_drafts', 'last_error TEXT');
      // Protect customers who were already waiting when the app upgraded.
      // Their original queue time is the safest available SLA anchor.
      await db.rawInsert('''INSERT OR IGNORE INTO sla_fallbacks(
        user_id,message_id,due_at_ms,state,sent_at_ms,updated_at_ms)
        SELECT user_id,newest_message_id,enqueued_at_ms + 20000,
          'pending',NULL,updated_at_ms FROM pending_customers''');
    }
    if (oldVersion < 8) {
      await _createAnsweredCursors(db);
      await _addColumnIfMissing(
          db, 'generated_drafts', 'batch_end_message_id TEXT');
    }
    if (oldVersion == 9) {
      // Version 9 stored a 35-second deadline. Restore pending work to the
      // 20-second JD response window while preserving the original anchor.
      await db.rawUpdate('''UPDATE sla_fallbacks
        SET due_at_ms=due_at_ms-15000
        WHERE state='pending' ''');
    }
    if (oldVersion < 11) await _createHumanTransferRequests(db);
    if (oldVersion < 12) await _createChatTransferLogs(db);
    if (oldVersion < 13) {
      await _addColumnIfMissing(
          db, 'human_review_tickets', 'request_message_id TEXT');
      await _addColumnIfMissing(
          db, 'chat_transfer_logs', 'request_message_id TEXT');
    }
  }

  Future<void> _addColumnIfMissing(
      Database db, String table, String definition) async {
    final column = definition.split(' ').first;
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (columns.isEmpty) return;
    if (columns.any((row) => row['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $definition');
  }

  Future<void> _createSlaFallbacks(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS sla_fallbacks (
      user_id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL,
      due_at_ms INTEGER NOT NULL,
      state TEXT NOT NULL,
      sent_at_ms INTEGER,
      updated_at_ms INTEGER NOT NULL
    )''');
    await db.execute('''CREATE INDEX IF NOT EXISTS sla_fallbacks_due
      ON sla_fallbacks(state, due_at_ms)''');
  }

  Future<void> _createTransferWelcomes(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS transfer_welcomes (
      user_id TEXT NOT NULL,
      event_key TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      PRIMARY KEY(user_id, event_key)
    )''');
  }

  Future<bool> hasTransferWelcome(
      {required String userId, required String eventKey}) async {
    final db = await database;
    final rows = await db.query('transfer_welcomes',
        columns: ['user_id'],
        where: 'user_id = ? AND event_key = ?',
        whereArgs: [userId, eventKey],
        limit: 1);
    return rows.isNotEmpty;
  }

  Future<DateTime?> latestTransferNoticeAt(String userId) async {
    final rows = await (await database).query('transfer_welcomes',
        columns: ['created_at_ms'],
        where: 'user_id = ?',
        whereArgs: [userId],
        orderBy: 'created_at_ms DESC',
        limit: 1);
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(
        rows.single['created_at_ms'] as int,
        isUtc: true);
  }

  Future<void> recordTransferWelcome(
      {required String userId, required String eventKey}) async {
    final db = await database;
    await db.insert(
        'transfer_welcomes',
        {
          'user_id': userId,
          'event_key': eventKey,
          'created_at_ms': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Atomically reserves a transfer welcome before the send click.
  ///
  /// The exact durable event key prevents a retry after an unconfirmed click.
  /// The UI layer separately suppresses repeated OCR variants while the same
  /// banner remains visible, without blocking a genuinely new transfer.
  Future<bool> reserveTransferWelcome({
    required String userId,
    required String eventKey,
    DateTime? now,
    Duration minimumInterval = Duration.zero,
  }) async {
    final db = await database;
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'transfer_welcomes',
        columns: ['user_id'],
        where: 'user_id = ? AND event_key = ?',
        whereArgs: [userId, eventKey],
        limit: 1,
      );
      if (existing.isNotEmpty) return false;
      if (minimumInterval > Duration.zero) {
        final recent = await txn.query('transfer_welcomes',
            columns: ['user_id'],
            where: 'user_id = ? AND created_at_ms >= ?',
            whereArgs: [userId, timestamp - minimumInterval.inMilliseconds],
            limit: 1);
        if (recent.isNotEmpty) return false;
      }
      await txn.insert(
        'transfer_welcomes',
        {
          'user_id': userId,
          'event_key': eventKey,
          'created_at_ms': timestamp,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return true;
    });
  }

  /// Releases a welcome reservation only when sending failed before JD's Send
  /// control was clicked. Unconfirmed post-click attempts remain reserved to
  /// prevent a duplicate welcome.
  Future<void> releaseTransferWelcomeReservation({
    required String userId,
    required String eventKey,
  }) async {
    final db = await database;
    await db.delete(
      'transfer_welcomes',
      where: 'user_id = ? AND event_key = ?',
      whereArgs: [userId, eventKey],
    );
  }

  Future<void> appendAutomatedNoticeSent(
      {required String userId,
      required String reply,
      String model = 'jd-transfer-welcome-v1'}) async {
    final raw = <String, Object?>{
      'reply': reply,
      'decision': 'draft',
      'confidence': 1.0,
      'used_record_ids': <String>[],
      'required_slots': <String>[],
      'actions': <Object?>[],
      'risk_level': 'low',
      'risk_triggers': <String>[],
      'auto_send_allowed': false,
      'model': model,
      'attachments': <Object?>[],
      'image_descriptions': <Object?>[],
      'human_review_required': false,
      'reason': null,
    };
    await (await history).appendSentReply(
      userId: userId,
      displayName: userId,
      stableKey: userId,
      draft: AiDraft.fromJson(raw, mediaBaseUrl: Uri()),
    );
  }

  Future<void> _createGeneratedDrafts(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS generated_drafts (
      user_id TEXT PRIMARY KEY,
      pending_id INTEGER NOT NULL,
      reply TEXT NOT NULL,
      model TEXT NOT NULL,
      raw_json TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      delivery_state TEXT NOT NULL DEFAULT 'ready',
      delivery_attempts INTEGER NOT NULL DEFAULT 0,
      retry_at_ms INTEGER,
      last_error TEXT,
      batch_end_message_id TEXT
    )''');
  }

  Future<void> _createAnsweredCursors(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS answered_cursors (
      user_id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL
    )''');
  }

  Future<void> _createHumanReview(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS human_review_tickets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL,
      customer_request TEXT NOT NULL,
      reason TEXT NOT NULL,
      status TEXT NOT NULL,
      assigned_to TEXT,
      request_message_id TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )''');
    await db.execute('''CREATE INDEX IF NOT EXISTS human_review_queue
      ON human_review_tickets(status, updated_at_ms DESC)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS conversation_control (
      user_id TEXT PRIMARY KEY,
      state TEXT NOT NULL,
      resume_after_message_id TEXT,
      updated_at_ms INTEGER NOT NULL
    )''');
  }

  Future<void> _createChatTransferLogs(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS chat_transfer_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ticket_id INTEGER NOT NULL UNIQUE,
      user_id TEXT NOT NULL,
      source_account TEXT NOT NULL,
      target_account TEXT,
      reason TEXT NOT NULL,
      status TEXT NOT NULL,
      error TEXT,
      request_message_id TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )''');
    await db.execute('''CREATE INDEX IF NOT EXISTS chat_transfer_log_recent
      ON chat_transfer_logs(updated_at_ms DESC, id DESC)''');
    await db.execute('''CREATE INDEX IF NOT EXISTS chat_transfer_log_target
      ON chat_transfer_logs(status, target_account, updated_at_ms DESC)''');
  }

  Future<void> _createHumanTransferRequests(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS human_transfer_requests (
      user_id TEXT PRIMARY KEY,
      request_count INTEGER NOT NULL,
      first_requested_at_ms INTEGER,
      updated_at_ms INTEGER NOT NULL
    )''');
    await db
        .execute('''CREATE TABLE IF NOT EXISTS human_transfer_request_events (
      user_id TEXT NOT NULL,
      message_id TEXT NOT NULL,
      was_repeat INTEGER NOT NULL,
      PRIMARY KEY(user_id, message_id)
    )''');
  }

  /// Returns true only for a second distinct request within ten minutes.
  /// Persisting message IDs keeps a retried generation from incrementing twice.
  Future<bool> recordHumanTransferRequest({
    required String userId,
    required String messageId,
    required DateTime requestedAt,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final priorEvent = await txn.query('human_transfer_request_events',
          columns: ['was_repeat'],
          where: 'user_id = ? AND message_id = ?',
          whereArgs: [userId, messageId],
          limit: 1);
      if (priorEvent.isNotEmpty) return priorEvent.single['was_repeat'] == 1;

      final prior = await txn.query('human_transfer_requests',
          where: 'user_id = ?', whereArgs: [userId], limit: 1);
      final now = requestedAt.millisecondsSinceEpoch;
      final first =
          prior.isEmpty ? null : prior.single['first_requested_at_ms'] as int?;
      final elapsed = first == null ? null : now - first;
      final repeated = prior.isNotEmpty &&
          prior.single['request_count'] == 1 &&
          elapsed != null &&
          elapsed >= 0 &&
          elapsed <= const Duration(minutes: 10).inMilliseconds;
      await txn.insert(
        'human_transfer_requests',
        {
          'user_id': userId,
          'request_count': repeated ? 0 : 1,
          'first_requested_at_ms': repeated ? null : now,
          'updated_at_ms': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert('human_transfer_request_events', {
        'user_id': userId,
        'message_id': messageId,
        'was_repeat': repeated ? 1 : 0,
      });
      return repeated;
    });
  }

  Future<void> _createPendingQueue(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS pending_customers (
      id INTEGER PRIMARY KEY,
      user_id TEXT NOT NULL UNIQUE,
      display_name TEXT NOT NULL,
      stable_key TEXT NOT NULL,
      newest_message_id TEXT NOT NULL,
      enqueued_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )''');
    await db.execute('''CREATE INDEX IF NOT EXISTS pending_customers_oldest
      ON pending_customers(enqueued_at_ms ASC, id ASC)''');
  }

  Future<int> saveCapture(CapturedConversation capture,
      {bool isCurrentViewport = true}) async {
    final userId = capture.customerExternalId ?? capture.customerName;
    try {
      final changed =
          await _saveCapture(capture, isCurrentViewport: isCurrentViewport);
      if (_pendingCaptureRepairs.contains(userId)) {
        await ensurePendingForUnanswered(userId);
      }
      _pendingCaptureRepairs.remove(userId);
      return changed;
    } catch (error) {
      if (ResilientDatabase.isContention(error)) {
        _pendingCaptureRepairs.add(userId);
      }
      rethrow;
    }
  }

  Future<int> _saveCapture(CapturedConversation capture,
      {required bool isCurrentViewport}) async {
    final store = await history;
    final result = await store.appendCapture(capture);
    final userId = capture.customerExternalId ?? capture.customerName;
    var reconciled = false;
    for (final message in capture.messages) {
      if (await confirmObservedGeneratedDraft(
          userId: userId, message: message, capturedAt: capture.capturedAt)) {
        reconciled = true;
        break;
      }
    }
    if (reconciled) {
      if (result.insertedIncomingIds.isNotEmpty) {
        await _upsertPending(capture, store);
      }
      // This is our older frozen reply, not a manual answer to every newer
      // message. markReplySent advanced only that frozen batch's cursor.
      return result.changed > 0 ? result.changed : 1;
    }
    // A previously captured bubble can acquire a receipt on a later poll.
    if (result.changed == 0) return 0;
    final db = await database;
    // Clear queued AI work only for a newly discovered seller message. A
    // previously generated reply can remain visually below a customer message
    // that OCR notices late; its mere presence must not mark that new question
    // as answered.
    if (isCurrentViewport && result.lastInsertedDirection == 'outgoing') {
      final document = await store.read(userId);
      final messages = (document?['messages'] as List<Object?>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      final lastIncoming = messages
          .whereType<Map<String, dynamic>>()
          .where((message) => message['direction'] == 'incoming')
          .lastOrNull;
      final insertedOutgoingIds = result.insertedOutgoingIds.toSet();
      final lastInsertedOutgoing = messages.reversed
          .where((message) =>
              message['direction'] == 'outgoing' &&
              insertedOutgoingIds.contains(message['id']?.toString()))
          .firstOrNull;
      // OCR text is only an observation. A timestamp, positive receipt and
      // matching unanswered batch are required before it may complete work.
      // In particular, a number read inside a video must not delete a draft.
      if (lastInsertedOutgoing == null ||
          !isConfirmedOutgoingReply(lastInsertedOutgoing) ||
          (lastIncoming != null &&
              !replyAnswersIncoming(
                  reply: lastInsertedOutgoing,
                  incomingId: lastIncoming['id']?.toString() ?? '',
                  messages: messages))) {
        if (result.insertedIncomingIds.isNotEmpty) {
          await _upsertPending(capture, store);
        }
        return result.changed;
      }
      // Seeing our own failed/pending bubble is not a manual seller answer.
      // Keep its uncertain draft until a positive receipt reconciles it.
      final uncertain = await db.query('generated_drafts',
          columns: ['reply'],
          where: '''user_id=? AND (
            delivery_state='delivery_unknown' OR
            (delivery_state='retry' AND last_error LIKE '%send_unconfirmed%'))''',
          whereArgs: [userId],
          limit: 1);
      if (uncertain.isNotEmpty &&
          lastInsertedOutgoing['body']
                  ?.toString()
                  .replaceAll(RegExp(r'\s+'), '') ==
              uncertain.single['reply']
                  ?.toString()
                  .replaceAll(RegExp(r'\s+'), '')) {
        await store.confirmObservedOutgoing(
            userId: userId,
            messageId: lastInsertedOutgoing['id']! as String,
            deliveryStatus: 'delivery_unknown');
        if (result.insertedIncomingIds.isNotEmpty) {
          await _upsertPending(capture, store);
        }
        return result.changed;
      }
      // OCR may discover an older seller bubble after saving a newer customer
      // message. Its position in the append-only file does not make it a reply
      // to that newer message; preserve the pending customer in that case.
      final incomingSentAt =
          DateTime.tryParse(lastIncoming?['sent_at']?.toString() ?? '');
      final outgoingSentAt =
          DateTime.tryParse(lastInsertedOutgoing['sent_at']?.toString() ?? '');
      final outgoingPredatesLatestIncoming = incomingSentAt != null &&
          outgoingSentAt != null &&
          outgoingSentAt.isBefore(incomingSentAt);
      if (outgoingPredatesLatestIncoming) {
        if (result.insertedIncomingIds.isNotEmpty) {
          await _upsertPending(capture, store);
        }
        return result.changed;
      }
      await db.transaction((txn) async {
        await txn.delete('pending_customers',
            where: 'user_id = ?', whereArgs: [userId]);
        await txn.delete('generated_drafts',
            where: 'user_id = ?', whereArgs: [userId]);
        if (lastIncoming != null) {
          await txn.rawInsert(
              '''INSERT INTO answered_cursors(user_id,message_id)
            VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET
            message_id=excluded.message_id''',
              [userId, lastIncoming['id']?.toString() ?? '']);
        }
        await txn.update(
          'sla_fallbacks',
          {
            'state': 'cancelled',
            'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'user_id = ?',
          whereArgs: [userId],
        );
      });
      return result.changed;
    }
    if (result.insertedIncomingIds.isEmpty) return result.changed;
    // A reply already generated for a frozen batch remains deliverable. The
    // new message stays pending until that earlier batch has been sent.
    final controls = await db.query('conversation_control',
        where: 'user_id = ?', whereArgs: [userId], limit: 1);
    if (controls.isNotEmpty) {
      final control = controls.first;
      if (control['state'] == 'human_contacting') return result.changed;
      if (control['state'] == 'waiting_for_customer') {
        final newestId = result.insertedIncomingIds.last;
        if (newestId == control['resume_after_message_id']) {
          return result.changed;
        }
        await db.update(
            'conversation_control',
            {
              'state': 'ai_active',
              'resume_after_message_id': null,
              'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
            },
            where: 'user_id = ?',
            whereArgs: [userId]);
      }
    }
    await _upsertPending(capture, store);
    return result.changed;
  }

  Future<void> _upsertPending(
      CapturedConversation capture, ConversationFileStore store) async {
    final userId = capture.customerExternalId ?? capture.customerName;
    // A viewport can contain an old image and newly arrived text. The image
    // may be last in the capture list even though it was already stored. Use
    // the actual durable tail so the pending cursor never moves backwards.
    final document = await store.read(userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final resetSentFallback = _newTurnAfterHoldingAndReply(messages);
    final newest =
        messages.lastWhere((message) => message['direction'] == 'incoming');
    final newestId = newest['id']?.toString() ?? '';
    final now = capture.capturedAt.millisecondsSinceEpoch;
    final answeredBoundary =
        _answeredIndex(messages, await answeredMessageId(userId));
    final firstUnanswered = messages
        .skip(answeredBoundary + 1)
        .where((message) => message['direction'] == 'incoming')
        .firstOrNull;
    // One unanswered batch starts with its first customer message. Later
    // messages update the batch tail but must never restart its SLA clock.
    final slaStartedAt = _slaStartedAt(
      capture.capturedAt,
      DateTime.tryParse(firstUnanswered?['sent_at']?.toString() ?? ''),
    );
    final db = await database;
    await db.transaction((txn) async {
      if (resetSentFallback) {
        await txn.update('sla_fallbacks', {'state': 'completed'},
            where: "user_id = ? AND state = 'sent'", whereArgs: [userId]);
      }
      final freshDue = await _resetSentHoldingForNewEvent(
          txn, userId, DateTime.tryParse(newest['sent_at']?.toString() ?? ''));
      await txn.rawInsert('''INSERT INTO pending_customers(
        user_id, display_name, stable_key, newest_message_id, enqueued_at_ms, updated_at_ms)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(user_id) DO UPDATE SET
          display_name=excluded.display_name,
          stable_key=excluded.stable_key,
          newest_message_id=excluded.newest_message_id,
          updated_at_ms=excluded.updated_at_ms''', [
        userId,
        capture.customerName,
        capture.stableKey,
        newestId,
        now,
        now,
      ]);
      await txn.rawInsert('''INSERT INTO sla_fallbacks(
        user_id,message_id,due_at_ms,state,sent_at_ms,updated_at_ms)
        VALUES(?,?,?,'pending',NULL,?)
        ON CONFLICT(user_id) DO UPDATE SET
          message_id=CASE
            WHEN sla_fallbacks.state IN ('sending','sent') THEN sla_fallbacks.message_id
            ELSE excluded.message_id END,
          due_at_ms=CASE
            WHEN sla_fallbacks.state IN ('pending','sending','reserved','sent')
              THEN MIN(sla_fallbacks.due_at_ms, excluded.due_at_ms)
            ELSE excluded.due_at_ms END,
          state=CASE
            WHEN sla_fallbacks.state IN ('pending','sending','reserved','sent')
              THEN sla_fallbacks.state
            ELSE 'pending' END,
          sent_at_ms=CASE
            WHEN sla_fallbacks.state IN ('pending','sending','reserved','sent')
              THEN sla_fallbacks.sent_at_ms
            ELSE NULL END,
          updated_at_ms=excluded.updated_at_ms''', [
        userId,
        newestId,
        freshDue ??
            _holdingWindowDue(messages, capture.capturedAt,
                slaStartedAt.add(slaFallbackDelay)),
        now,
      ]);
    });
  }

  /// JD displays message clocks in China Standard Time even when this app is
  /// running in another system timezone. OCR supplies only the displayed
  /// clock, so reconstruct today's Asia/Shanghai instant and accept it only
  /// when it is close to the capture. This avoids both a late SLA timer and an
  /// immediate fallback caused by a wrongly inferred previous-day timestamp.
  DateTime _slaStartedAt(DateTime capturedAt, DateTime? observedSentAt) {
    if (observedSentAt == null) return capturedAt;
    final capturedUtc = capturedAt.toUtc();
    final observedUtc = observedSentAt.toUtc();
    final directAge = capturedUtc.difference(observedUtc);
    if (!directAge.isNegative && directAge <= const Duration(minutes: 10)) {
      return observedUtc;
    }

    const chinaOffset = Duration(hours: 8);
    final chinaCapture = capturedUtc.add(chinaOffset);
    final displayedClock = observedSentAt.toLocal();
    var reconstructed = DateTime.utc(
      chinaCapture.year,
      chinaCapture.month,
      chinaCapture.day,
      displayedClock.hour,
      displayedClock.minute,
      displayedClock.second,
    ).subtract(chinaOffset);
    if (reconstructed.isAfter(capturedUtc.add(const Duration(minutes: 1)))) {
      reconstructed = reconstructed.subtract(const Duration(days: 1));
    }
    final reconstructedAge = capturedUtc.difference(reconstructed);
    return !reconstructedAge.isNegative &&
            reconstructedAge <= const Duration(minutes: 10)
        ? reconstructed
        : capturedAt;
  }

  /// Requeues a durable incoming message only when no generated reply appears
  /// after it. This repairs capture-success/generation-failure without ever
  /// drafting twice for an already answered message.
  Future<bool> ensurePendingForUnanswered(String userId) async {
    final db = await database;
    final drafts = await db.query('generated_drafts',
        columns: ['user_id'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    if (drafts.isNotEmpty) return false;
    final controls = await db.query('conversation_control',
        columns: ['state'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    if (controls.isNotEmpty && controls.first['state'] == 'human_contacting') {
      return false;
    }
    final document = await (await history).read(userId);
    if (document == null) return false;
    final messages = (document['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final boundary = _answeredIndex(messages, await answeredMessageId(userId));
    final incomingIndex = messages
        .lastIndexWhere((message) => message['direction'] == 'incoming');
    if (incomingIndex <= boundary) return false;
    final incoming = messages[incomingIndex];
    if (controls.isNotEmpty &&
        controls.first['state'] == 'waiting_for_customer') {
      // A new saved customer message resumes service even if its original
      // queue insertion failed during a transient database lock.
      final control = await db.query('conversation_control',
          where: 'user_id = ?', whereArgs: [userId], limit: 1);
      if (control.single['resume_after_message_id'] == incoming['id']) {
        return false;
      }
      await db.update('conversation_control',
          {'state': 'ai_active', 'resume_after_message_id': null},
          where: 'user_id = ?', whereArgs: [userId]);
    }
    final firstUnanswered = messages
        .skip(boundary + 1)
        .where((message) => message['direction'] == 'incoming')
        .first;
    final capturedAt =
        DateTime.tryParse(incoming['captured_at']?.toString() ?? '') ??
            DateTime.now().toUtc();
    final firstCapturedAt =
        DateTime.tryParse(firstUnanswered['captured_at']?.toString() ?? '') ??
            capturedAt;
    final slaStartedAt = _slaStartedAt(
      firstCapturedAt,
      DateTime.tryParse(firstUnanswered['sent_at']?.toString() ?? ''),
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.rawInsert('''INSERT INTO pending_customers(
      user_id, display_name, stable_key, newest_message_id, enqueued_at_ms, updated_at_ms)
      VALUES(?, ?, ?, ?, ?, ?)
      ON CONFLICT(user_id) DO UPDATE SET
        display_name=excluded.display_name,
        stable_key=excluded.stable_key,
        newest_message_id=excluded.newest_message_id,
        updated_at_ms=excluded.updated_at_ms''', [
      userId,
      document['display_name']?.toString() ?? userId,
      document['stable_key']?.toString() ?? userId,
      incoming['id']?.toString() ?? '',
      capturedAt.millisecondsSinceEpoch + slaFallbackDelay.inMilliseconds,
      now,
    ]);
    await _ensureSlaFallback(
      userId: userId,
      messageId: incoming['id']?.toString() ?? '',
      startedAt: slaStartedAt,
    );
    return true;
  }

  /// JSON is saved before SQL. Rebuild queue work lost to a failed SQL write,
  /// including after a process restart, without reactivating old customers.
  Future<void> repairPendingCaptures() async {
    final store = await history;
    if (!_scannedRecentHistoryForRepair) {
      await store.conversationsDirectory.create(recursive: true);
      final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 1));
      await for (final file
          in store.conversationsDirectory.list(followLinks: false)) {
        if (file is! File || !file.path.endsWith('.json')) continue;
        if ((await file.stat()).modified.toUtc().isBefore(cutoff)) continue;
        try {
          final document = jsonDecode(await file.readAsString());
          if (document is! Map<String, dynamic>) continue;
          final userId = document['user_id']?.toString();
          final incoming = (document['messages'] as List<Object?>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .where((message) => message['direction'] == 'incoming')
              .lastOrNull;
          final capturedAt =
              DateTime.tryParse(incoming?['captured_at']?.toString() ?? '');
          if (userId != null &&
              capturedAt != null &&
              !capturedAt.isBefore(cutoff)) {
            _pendingCaptureRepairs.add(userId);
          }
        } on FormatException {
          // An unrelated malformed history must not block other customers.
        }
      }
      _scannedRecentHistoryForRepair = true;
    }
    for (final userId in _pendingCaptureRepairs.toList(growable: false)) {
      await ensurePendingForUnanswered(userId);
      _pendingCaptureRepairs.remove(userId);
    }
  }

  Future<List<ConversationSummary>> conversations() async {
    final db = await database;
    final store = await history;
    final rows = await db.query('pending_customers',
        orderBy: 'enqueued_at_ms ASC, id ASC');
    return Future.wait(rows.map((row) async => ConversationSummary(
          id: row['id']! as int,
          userId: row['user_id']! as String,
          stableKey: row['stable_key']! as String,
          customerName: row['display_name']! as String,
          lastActivityAt:
              DateTime.fromMillisecondsSinceEpoch(row['updated_at_ms']! as int),
          messages: await store.lastMessages(row['user_id']! as String),
        )));
  }

  /// Returns true only when SQLite and durable JSON agree that the customer
  /// has a latest incoming message with no later outgoing reply or draft.
  /// Stale queue rows from earlier builds are removed automatically.
  Future<bool> hasPendingUnanswered(String userId) async {
    final db = await database;
    final rows = await db.query('pending_customers',
        columns: ['newest_message_id'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    if (rows.isEmpty) return false;
    final document = await (await history).read(userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final incomingIndex = messages
        .lastIndexWhere((message) => message['direction'] == 'incoming');
    final boundary = _answeredIndex(messages, await answeredMessageId(userId));
    final latestIncomingId =
        incomingIndex < 0 ? null : messages[incomingIndex]['id']?.toString();
    final queueMatchesLatest =
        rows.first['newest_message_id']?.toString() == latestIncomingId;
    if (incomingIndex <= boundary || !queueMatchesLatest) {
      await db.delete('pending_customers',
          where: 'user_id = ?', whereArgs: [userId]);
      return false;
    }
    return true;
  }

  Future<String?> pendingMessageId(String userId) async {
    final db = await database;
    final rows = await db.query('pending_customers',
        columns: ['newest_message_id'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    return rows.isEmpty ? null : rows.first['newest_message_id']?.toString();
  }

  Future<String?> answeredMessageId(String userId) async {
    final rows = await (await database).query('answered_cursors',
        columns: ['message_id'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    return rows.isEmpty ? null : rows.first['message_id']?.toString();
  }

  /// Records a receipt already saved independently of SQLite. This never
  /// sends a message and never consumes customer messages beyond its batch.
  Future<void> acknowledgeOutboxReply(
      {required String userId,
      required String batchEndMessageId,
      required String reply}) async {
    final db = await database;
    final document = await (await history).read(userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final batchIndex =
        messages.indexWhere((message) => message['id'] == batchEndMessageId);
    if (batchIndex < 0) return;
    final cursor = await answeredMessageId(userId);
    final answeredIndex = _answeredIndex(messages, cursor);
    await db.transaction((txn) async {
      await txn.delete('generated_drafts',
          where: 'user_id = ? AND batch_end_message_id = ? AND reply = ?',
          whereArgs: [userId, batchEndMessageId, reply]);
      if (cursor == null || batchIndex >= answeredIndex) {
        await txn.rawInsert('''INSERT INTO answered_cursors(user_id,message_id)
          VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET
          message_id=excluded.message_id''', [userId, batchEndMessageId]);
      }
      await txn.delete('pending_customers',
          where: 'user_id = ? AND newest_message_id = ?',
          whereArgs: [userId, batchEndMessageId]);
      await txn.update('sla_fallbacks', {'state': 'completed'},
          where: 'user_id = ? AND message_id = ?',
          whereArgs: [userId, batchEndMessageId]);
    });
    await ensurePendingForUnanswered(userId);
  }

  int _answeredIndex(List<Map<String, dynamic>> messages, String? cursor) {
    if (cursor != null) {
      final index = messages.indexWhere((message) => message['id'] == cursor);
      if (index >= 0) {
        // A transfer welcome can precede late OCR of the customer's plain
        // greeting. Do not generate a second greeting/SLA for that same hi.
        // Never jump over a substantive unanswered question or attachment.
        var boundary = index;
        final welcomes = messages.where(isTransferWelcomeReply).toList();
        for (var i = index + 1; i < messages.length; i++) {
          if (messages[i]['direction'] != 'incoming') continue;
          if (!welcomes.any((reply) => replyAnswersIncoming(
              reply: reply,
              incomingId: messages[i]['id']?.toString() ?? '',
              messages: messages))) {
            break;
          }
          boundary = i;
        }
        return boundary;
      }
      // Older OCR versions could replace a bubble ID after it had become the
      // answered cursor. Recover from the actual sent-reply boundary instead
      // of treating the entire conversation as unanswered.
    }
    // Existing installations did not have a cursor. Their last delivered or
    // manual reply is the best available boundary until the next send. OCR
    // discovery order can differ from chat order, so match dated seller
    // messages only to customer messages that are not newer than them.
    var boundary = -1;
    for (var outgoingIndex = 0;
        outgoingIndex < messages.length;
        outgoingIndex++) {
      final outgoing = messages[outgoingIndex];
      if (!_isFinalOutgoing(outgoing)) continue;
      for (var incomingIndex = 0;
          incomingIndex < messages.length;
          incomingIndex++) {
        final incoming = messages[incomingIndex];
        if (incoming['direction'] != 'incoming') continue;
        if (replyAnswersIncoming(
                reply: outgoing,
                incomingId: incoming['id']?.toString() ?? '',
                messages: messages) &&
            incomingIndex > boundary) {
          boundary = incomingIndex;
        }
      }
    }
    return boundary;
  }

  bool _isFinalOutgoing(Map<String, dynamic> message) =>
      isConfirmedOutgoingReply(message);

  bool _newTurnAfterHoldingAndReply(List<Map<String, dynamic>> messages) {
    final holding = messages
        .lastIndexWhere((message) => message['source'] == 'sla_fallback');
    final reply = messages.lastIndexWhere(_isFinalOutgoing);
    final incoming = messages
        .lastIndexWhere((message) => message['direction'] == 'incoming');
    return holding >= 0 && holding < reply && reply < incoming;
  }

  /// A receipt can cover only messages sent before that receipt. New genuine
  /// events receive their own holding deadline, with a cooldown against spam.
  /// This also repairs legacy rows whose message_id moved but sent_at did not.
  Future<int?> _resetSentHoldingForNewEvent(
      Transaction txn, String userId, DateTime? incomingAt) async {
    if (incomingAt == null) return null;
    final rows = await txn.query('sla_fallbacks',
        where: "user_id=? AND state='sent'", whereArgs: [userId], limit: 1);
    final sent = rows.firstOrNull?['sent_at_ms'] as int?;
    if (sent == null || incomingAt.millisecondsSinceEpoch <= sent) return null;
    final eventDue = incomingAt.add(slaFallbackDelay).millisecondsSinceEpoch;
    final cooldownDue = sent + const Duration(seconds: 50).inMilliseconds;
    await txn.update('sla_fallbacks', {'state': 'completed'},
        where: "user_id=? AND state='sent' AND sent_at_ms=?",
        whereArgs: [userId, sent]);
    return eventDue > cooldownDue ? eventDue : cooldownDue;
  }

  /// Do not drag a new pending window back to an older, already acknowledged
  /// message when more messages are appended or queue recovery runs again.
  int _holdingWindowDue(List<Map<String, dynamic>> messages,
      DateTime capturedAt, DateTime defaultDue) {
    final holding = messages
        .where((m) =>
            m['source'] == 'sla_fallback' && m['delivery_status'] == 'sent')
        .lastOrNull;
    final heldAt = DateTime.tryParse(holding?['sent_at']?.toString() ?? '');
    if (heldAt == null) return defaultDue.millisecondsSinceEpoch;
    final next = messages
        .skip(messages.lastIndexWhere(isConfirmedOutgoingReply) + 1)
        .where((m) =>
            m['direction'] == 'incoming' &&
            (DateTime.tryParse(m['sent_at']?.toString() ?? '')
                    ?.isAfter(heldAt) ??
                false))
        .firstOrNull;
    if (next == null) return defaultDue.millisecondsSinceEpoch;
    final eventDue = _slaStartedAt(
            capturedAt, DateTime.tryParse(next['sent_at']?.toString() ?? ''))
        .add(slaFallbackDelay);
    final cooldownDue = heldAt.add(const Duration(seconds: 50));
    return (eventDue.isAfter(cooldownDue) ? eventDue : cooldownDue)
        .millisecondsSinceEpoch;
  }

  Future<void> _ensureSlaFallback({
    required String userId,
    required String messageId,
    required DateTime startedAt,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final document = await (await history).read(userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    if (_newTurnAfterHoldingAndReply(messages)) {
      await db.update('sla_fallbacks', {'state': 'completed'},
          where: "user_id = ? AND state = 'sent'", whereArgs: [userId]);
    }
    await db.transaction((txn) async {
      final incoming = messages.where((m) => m['id'] == messageId).firstOrNull;
      final freshDue = await _resetSentHoldingForNewEvent(txn, userId,
          DateTime.tryParse(incoming?['sent_at']?.toString() ?? ''));
      await txn.rawInsert('''INSERT INTO sla_fallbacks(
      user_id,message_id,due_at_ms,state,sent_at_ms,updated_at_ms)
      VALUES(?,?,?,'pending',NULL,?)
      ON CONFLICT(user_id) DO UPDATE SET
        message_id=CASE
          WHEN sla_fallbacks.state IN ('sending','sent') THEN sla_fallbacks.message_id
          ELSE excluded.message_id END,
        due_at_ms=CASE
          WHEN sla_fallbacks.state IN ('pending','sending','reserved','sent')
            THEN MIN(sla_fallbacks.due_at_ms, excluded.due_at_ms)
          ELSE excluded.due_at_ms END,
        state=CASE
          WHEN sla_fallbacks.state IN ('pending','sending','reserved','sent')
            THEN sla_fallbacks.state
          ELSE 'pending' END,
        sent_at_ms=CASE
          WHEN sla_fallbacks.state IN ('pending','sending','reserved','sent')
            THEN sla_fallbacks.sent_at_ms
          ELSE NULL END,
        updated_at_ms=excluded.updated_at_ms
      WHERE sla_fallbacks.message_id != excluded.message_id
        OR sla_fallbacks.state IN ('completed','cancelled')''', [
        userId,
        messageId,
        freshDue ??
            _holdingWindowDue(
                messages, DateTime.now(), startedAt.add(slaFallbackDelay)),
        now,
      ]);
    });
  }

  Future<SlaFallbackJob?> slaFallbackJob(String userId) async {
    final db = await database;
    final rows = await db.query(
      'sla_fallbacks',
      where: "user_id = ? AND state = 'pending'",
      whereArgs: [userId],
      limit: 1,
    );
    return rows.isEmpty ? null : SlaFallbackJob.fromRow(rows.first);
  }

  /// Once OCR has created a durable SLA row, that row exclusively owns the
  /// one holding message for this customer turn. Unread-only recovery must
  /// stop at this boundary instead of racing a second UI send.
  Future<bool> hasActiveSlaFallback(String userId) async {
    final rows = await (await database).query(
      'sla_fallbacks',
      columns: ['user_id'],
      where:
          "user_id = ? AND state IN ('pending','sending','reserved','sent','delivery_unknown')",
      whereArgs: [userId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// OCR may finish after the unread sidebar first exposed this message.
  /// Keep the original customer-visible 20-second deadline when that happens.
  Future<void> capSlaFallbackDue({
    required String userId,
    required DateTime dueAt,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (await database).rawUpdate('''UPDATE sla_fallbacks SET
      due_at_ms=MIN(due_at_ms, ?), updated_at_ms=?
      WHERE user_id=? AND state='pending' ''', [
      dueAt.millisecondsSinceEpoch,
      now,
      userId,
    ]);
  }

  Future<List<SlaFallbackJob>> pendingSlaFallbackJobs() async {
    final db = await database;
    final rows = await db.query(
      'sla_fallbacks',
      where: "state = 'pending'",
      orderBy: 'due_at_ms ASC',
    );
    return rows.map(SlaFallbackJob.fromRow).toList(growable: false);
  }

  /// An unread-only recovery may have already sent the customer's holding
  /// message before OCR could create the normal pending SLA row. Treat that
  /// verified send as the one holding message for this response window.
  Future<void> acknowledgeUncapturedHolding(
      {required String userId, required DateTime sentAt}) async {
    final rows = await (await database).query('sla_fallbacks',
        where: 'user_id=?', whereArgs: [userId], limit: 1);
    final document = await (await history).read(userId);
    final incoming = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map>()
        .where((m) => m['id'] == rows.firstOrNull?['message_id'])
        .firstOrNull;
    final incomingAt =
        DateTime.tryParse(incoming?['sent_at']?.toString() ?? '');
    if (incomingAt != null && sentAt.isBefore(incomingAt)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await (await database).update(
      'sla_fallbacks',
      {
        'state': 'sent',
        'sent_at_ms': sentAt.millisecondsSinceEpoch,
        'updated_at_ms': now,
      },
      where:
          "user_id = ? AND message_id = ? AND due_at_ms = ? AND state IN ('pending','sending')",
      whereArgs: [
        userId,
        rows.firstOrNull?['message_id'],
        rows.firstOrNull?['due_at_ms']
      ],
    );
  }

  Future<bool> reserveSlaFallback({
    required String userId,
    required String messageId,
    required DateTime dueAt,
  }) async {
    final db = await database;
    final changed = await db.update(
      'sla_fallbacks',
      {
        'state': 'sending',
        'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
      },
      // A real reply can keep the same latest customer message pending while
      // resetting its 20-second window. Match the exact deadline as a
      // generation token so an already-fired callback from the old window
      // cannot reserve the recycled row and send after that reply.
      where:
          "user_id = ? AND message_id = ? AND due_at_ms = ? AND state = 'pending'",
      whereArgs: [userId, messageId, dueAt.millisecondsSinceEpoch],
    );
    return changed == 1;
  }

  /// Rechecks a reserved holding message immediately before the Send click.
  /// A real or manually observed reply changes this row out of `sending`, so
  /// a timer that was already queued cannot send afterward.
  Future<bool> isSlaFallbackReservedForSend(
      {required String userId, required String messageId}) async {
    final rows = await (await database).query(
      'sla_fallbacks',
      columns: ['user_id'],
      where: "user_id = ? AND message_id = ? AND state = 'sending'",
      whereArgs: [userId, messageId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> releaseSlaFallback({
    required String userId,
    required String messageId,
    Duration retryDelay = const Duration(seconds: 5),
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (await database).update(
      'sla_fallbacks',
      {
        'state': 'pending',
        'due_at_ms': now + retryDelay.inMilliseconds,
        'updated_at_ms': now,
      },
      where: "user_id = ? AND message_id = ? AND state = 'sending'",
      whereArgs: [userId, messageId],
    );
  }

  /// Finishes a reserved fallback without sending when a real seller reply is
  /// already present for the same customer turn. This is terminal: returning
  /// the row to `pending` would reopen the old conversation every retry tick.
  Future<void> completeSlaFallbackAfterReply({
    required String userId,
    required String messageId,
  }) async {
    await (await database).update(
      'sla_fallbacks',
      {
        'state': 'completed',
        'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: "user_id = ? AND message_id = ? AND state = 'sending'",
      whereArgs: [userId, messageId],
    );
  }

  Future<bool> markSlaFallbackSent({
    required String userId,
    required String messageId,
    required String reply,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final changed = await (await database).update(
      'sla_fallbacks',
      {
        'state': 'sent',
        'sent_at_ms': now,
        'updated_at_ms': now,
      },
      where: "user_id = ? AND message_id = ? AND state = 'sending'",
      whereArgs: [userId, messageId],
    );
    if (changed != 1) return false;
    await (await history).appendSlaFallbackSent(
      userId: userId,
      messageId: messageId,
      reply: reply,
    );
    return true;
  }

  /// Saves the reply for a frozen batch. If later customer evidence arrived
  /// during generation, its pending row remains for the next batch.
  Future<int> saveDraft(
    int pendingId,
    AiDraft draft, {
    String? expectedMessageId,
    bool deliverable = true,
    bool onlyIfAbsent = false,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final deliveryState = deliverable ? 'ready' : 'transfer_only';
    return db.transaction((txn) async {
      final rows = await txn.query('pending_customers',
          where: 'id = ?', whereArgs: [pendingId], limit: 1);
      if (rows.isEmpty) return 0;
      final row = rows.first;
      if (onlyIfAbsent &&
          (await txn.query('generated_drafts',
                  columns: ['user_id'],
                  where: 'user_id=?',
                  whereArgs: [row['user_id']],
                  limit: 1))
              .isNotEmpty) {
        return 0;
      }
      final newerBatchPending = expectedMessageId != null &&
          row['newest_message_id'] != expectedMessageId;
      await txn.rawInsert('''INSERT INTO generated_drafts(
        user_id,pending_id,reply,model,raw_json,created_at_ms,
        delivery_state,delivery_attempts,retry_at_ms,last_error,batch_end_message_id)
        VALUES(?,?,?,?,?,?,?,0,NULL,NULL,?) ON CONFLICT(user_id) DO UPDATE SET
        pending_id=excluded.pending_id,reply=excluded.reply,
        model=excluded.model,raw_json=excluded.raw_json,
        created_at_ms=excluded.created_at_ms,
        delivery_state=excluded.delivery_state,
        delivery_attempts=0,retry_at_ms=NULL,last_error=NULL,
        batch_end_message_id=excluded.batch_end_message_id''', [
        row['user_id'],
        pendingId,
        draft.reply,
        draft.model,
        draft.rawJson,
        now,
        deliveryState,
        expectedMessageId ?? row['newest_message_id'],
      ]);
      if (newerBatchPending) return 1;
      return txn
          .delete('pending_customers', where: 'id = ?', whereArgs: [pendingId]);
    });
  }

  Future<StoredDraft?> latestDraft(int pendingId) async => null;

  Future<bool> hasUndeliveredDraft(String userId) async {
    final rows = await (await database).query('generated_drafts',
        columns: ['user_id'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    return rows.isNotEmpty;
  }

  /// A durable ready outbox entry is proof of an unsent original, not proof
  /// that a missing queue row means it was delivered. Rebuild bookkeeping
  /// only for its exact customer/batch and only absent a verified final reply.
  Future<bool> restoreUnsentOutboxDraft(
      {required String userId,
      required String batchEndMessageId,
      required AiDraft draft}) async {
    if (await isHumanContacting(userId)) return false;
    final document = await (await history).read(userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    if (!messages.any((m) =>
            m['direction'] == 'incoming' && m['id'] == batchEndMessageId) ||
        messages.any((m) => replyAnswersIncoming(
            reply: m, incomingId: batchEndMessageId, messages: messages))) {
      return false;
    }
    final newest = messages.lastWhere((m) => m['direction'] == 'incoming');
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await database;
    await db.rawInsert('''INSERT INTO pending_customers(
      user_id,display_name,stable_key,newest_message_id,enqueued_at_ms,updated_at_ms)
      VALUES(?,?,?,?,?,?) ON CONFLICT(user_id) DO NOTHING''', [
      userId,
      document?['display_name']?.toString() ?? userId,
      document?['stable_key']?.toString() ?? userId,
      newest['id'],
      now,
      now
    ]);
    final rows = await db.query('pending_customers',
        columns: ['id'], where: 'user_id=?', whereArgs: [userId], limit: 1);
    if (rows.isEmpty) return false;
    return await saveDraft(rows.single['id']! as int, draft,
            expectedMessageId: batchEndMessageId, onlyIfAbsent: true) >
        0;
  }

  /// Sends the oldest ready reply without waiting for another customer's
  /// generation. Each customer still has at most one undelivered draft.
  Future<QueuedDelivery?> nextReadyDelivery() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final generated = await db.rawQuery('''
      SELECT d.* FROM generated_drafts d
      LEFT JOIN conversation_control c ON c.user_id=d.user_id
      WHERE (d.delivery_state='ready' OR
        (d.delivery_state='retry' AND d.retry_at_ms <= ?))
        AND (c.state IS NULL OR c.state != 'human_contacting')
      ORDER BY d.pending_id ASC LIMIT 1
    ''', [now]);
    if (generated.isEmpty) return null;
    final row = generated.first;
    final pendingId = row['pending_id']! as int;
    final raw = jsonDecode(row['raw_json']! as String) as Map<String, dynamic>;
    return QueuedDelivery(
      pendingId: pendingId,
      userId: row['user_id']! as String,
      draft: AiDraft.fromJson(raw, mediaBaseUrl: Uri()),
      createdAtMs: row['created_at_ms']! as int,
      batchEndMessageId: row['batch_end_message_id'] as String?,
    );
  }

  /// Revalidates a queued reply immediately before UI automation types it.
  /// A transfer can delete or suppress a draft after the delivery worker has
  /// already materialized it in memory.
  Future<bool> isGeneratedDraftReadyForSend({
    required String userId,
    required String reply,
    QueuedDelivery? expectedDelivery,
  }) async {
    final rows = await (await database).query(
      'generated_drafts',
      columns: ['user_id'],
      where: "user_id = ? AND reply = ? AND delivery_state IN ('ready','retry')"
          '${expectedDelivery?._identityClause ?? ''}',
      whereArgs: [userId, reply, ...?expectedDelivery?._identityArguments],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Removes an unrecoverable queue item so it cannot permanently block every
  /// later customer. Durable captured conversation history is preserved.
  Future<void> abandonPendingCustomer(String userId) async {
    final db = await database;
    await db
        .delete('pending_customers', where: 'user_id = ?', whereArgs: [userId]);
  }

  /// Automatic sends are never retried after an uncertain click. Discarding
  /// the transient draft advances FIFO delivery without altering JSON history.
  Future<void> discardGeneratedDraft(String userId,
      {String? expectedRawJson}) async {
    final db = await database;
    await db.delete('generated_drafts',
        where:
            'user_id = ?${expectedRawJson == null ? '' : ' AND raw_json = ?'}',
        whereArgs: [userId, if (expectedRawJson != null) expectedRawJson]);
  }

  /// Removes the non-deliverable draft used only to trigger an automatic
  /// transfer. Advancing its frozen-batch cursor prevents the same request
  /// from being regenerated if the transfer attempt itself fails.
  Future<void> discardTransferOnlyDraft(String userId) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'generated_drafts',
        columns: ['batch_end_message_id'],
        where: "user_id = ? AND delivery_state = 'transfer_only'",
        whereArgs: [userId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final batchEnd = rows.first['batch_end_message_id']?.toString();
      await txn.delete(
        'generated_drafts',
        where: "user_id = ? AND delivery_state = 'transfer_only'",
        whereArgs: [userId],
      );
      if (batchEnd == null || batchEnd.isEmpty) return;
      await txn.rawInsert('''INSERT INTO answered_cursors(user_id,message_id)
        VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET
        message_id=excluded.message_id''', [userId, batchEnd]);
      await txn.update(
        'sla_fallbacks',
        {
          'state': 'completed',
          'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'user_id = ? AND message_id = ?',
        whereArgs: [userId, batchEnd],
      );
    });
  }

  Future<void> markGeneratedDraftDeliveryFailure({
    required String userId,
    required String error,
    Duration retryDelay = const Duration(seconds: 10),
    QueuedDelivery? expectedDelivery,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (await database).rawUpdate('''UPDATE generated_drafts
      SET delivery_state='retry',delivery_attempts=delivery_attempts+1,
          retry_at_ms=?,last_error=? WHERE user_id=?
          ${expectedDelivery?._identityClause ?? ''}''', [
      now + retryDelay.inMilliseconds,
      error,
      userId,
      ...?expectedDelivery?._identityArguments,
    ]);
  }

  Future<List<ChatTransferLog>> chatTransferLogs({int limit = 50}) async {
    final rows = await (await database).query(
      'chat_transfer_logs',
      orderBy: 'updated_at_ms DESC, id DESC',
      limit: limit,
    );
    return rows
        .map((row) => ChatTransferLog.fromJson(row.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// Reserves one in-flight automatic transfer per ticket. A pre-click failure
  /// or an earlier no-agent result may be overwritten by a later customer
  /// request; transferring, unconfirmed, and successful outcomes remain
  /// protected from an automatic duplicate click.
  Future<ChatTransferLog?> reserveChatTransferLog({
    required HumanReviewTicket ticket,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'chat_transfer_logs',
        where: 'ticket_id = ?',
        whereArgs: [ticket.id],
        limit: 1,
      );
      final ticketRows = await txn.query(
        'human_review_tickets',
        columns: ['request_message_id'],
        where: 'id = ?',
        whereArgs: [ticket.id],
        limit: 1,
      );
      final requestMessageId = ticketRows.isEmpty
          ? null
          : ticketRows.single['request_message_id']?.toString();
      // This is the durable safety boundary between ordinary human-review
      // tickets and an explicit, repeated customer request to transfer.
      if (requestMessageId == null || requestMessageId.isEmpty) return null;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (existing.isNotEmpty) {
        final row = existing.single.cast<String, Object?>();
        final status = row['status']?.toString();
        // Both states are known to be pre-click outcomes. A later explicit
        // review request is allowed to replace them and inspect live agents.
        if (status != 'failed' && status != 'agents_busy') return null;
        // The same triggering message gets exactly one transfer attempt. Only
        // a later completed two-request cycle writes a new message ID and may
        // overwrite the failed/no-agent result.
        if (requestMessageId == row['request_message_id']?.toString()) {
          return null;
        }
        await txn.update(
          'chat_transfer_logs',
          {
            'status': 'pending',
            'reason': ticket.reason,
            'target_account': null,
            'error': null,
            'request_message_id': requestMessageId,
            'updated_at_ms': now,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        final refreshed = (await txn.query(
          'chat_transfer_logs',
          where: 'id = ?',
          whereArgs: [row['id']],
          limit: 1,
        ))
            .single;
        return ChatTransferLog.fromJson(refreshed.cast<String, Object?>());
      }
      final id = await txn.insert('chat_transfer_logs', {
        'ticket_id': ticket.id,
        'user_id': ticket.conversationId,
        'source_account': '当前客服账号',
        'reason': ticket.reason,
        'status': 'pending',
        'request_message_id': requestMessageId,
        'created_at_ms': now,
        'updated_at_ms': now,
      });
      final row = (await txn.query(
        'chat_transfer_logs',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      ))
          .single;
      return ChatTransferLog.fromJson(row.cast<String, Object?>());
    });
  }

  Future<void> updateChatTransferLog({
    required int id,
    required String status,
    String? sourceAccount,
    String? targetAccount,
    String? error,
  }) async {
    await (await database).update(
      'chat_transfer_logs',
      {
        'status': status,
        if (sourceAccount?.trim().isNotEmpty == true)
          'source_account': sourceAccount!.trim(),
        if (targetAccount?.trim().isNotEmpty == true)
          'target_account': targetAccount!.trim(),
        'error': error,
        'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Picks the least-recently used active account. Never-used accounts come
  /// first, and a stable lexical tie-break keeps the choice deterministic.
  Future<String> chooseAutomaticTransferAccount(
      Iterable<String> activeAccounts) async {
    final accounts = activeAccounts
        .map((account) => account.trim())
        .where((account) => account.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (accounts.isEmpty) {
      throw StateError('No active JD transfer account is available.');
    }
    final rows = await (await database).query(
      'chat_transfer_logs',
      columns: ['target_account', 'updated_at_ms'],
      where: "status = 'transferred' AND target_account IS NOT NULL",
      orderBy: 'updated_at_ms DESC',
    );
    final lastUsed = <String, int>{};
    for (final row in rows) {
      final account = row['target_account']?.toString();
      if (account != null) {
        lastUsed.putIfAbsent(
            account, () => (row['updated_at_ms'] as num).toInt());
      }
    }
    accounts.sort((left, right) {
      final leftAt = lastUsed[left];
      final rightAt = lastUsed[right];
      if (leftAt == null && rightAt != null) return -1;
      if (leftAt != null && rightAt == null) return 1;
      final byTime = (leftAt ?? 0).compareTo(rightAt ?? 0);
      return byTime != 0 ? byTime : left.compareTo(right);
    });
    return accounts.first;
  }

  Future<List<HumanReviewTicket>> humanReviewTickets() async {
    final db = await database;
    final rows = await db.query('human_review_tickets',
        where: "status IN ('open','contacting')",
        orderBy: 'updated_at_ms DESC, id DESC');
    return rows
        .map((row) => HumanReviewTicket(
              id: row['id']! as int,
              conversationId: row['user_id']! as String,
              customerRequest: row['customer_request']! as String,
              reason: row['reason']! as String,
              status: row['status']! as String,
              assignedTo: row['assigned_to'] as String?,
            ))
        .toList(growable: false);
  }

  Future<int> improveGenericTicketReasons() async {
    final db = await database;
    final rows = await db.query('human_review_tickets',
        columns: ['id', 'user_id', 'reason'],
        where: "status IN ('open','contacting')");
    var updated = 0;
    for (final row in rows) {
      final reason = row['reason']?.toString().trim() ?? '';
      if (reason.isNotEmpty && reason != 'Codex requested human review.') {
        continue;
      }
      final document = await (await history).read(row['user_id']! as String);
      final messages = (document?['messages'] as List<Object?>? ?? const [])
          .whereType<Map<String, dynamic>>();
      final generated = messages.toList().reversed.firstWhere(
          (item) => item['source'] == 'generated_reply',
          orElse: () => const {});
      final metadata = generated['reply_metadata'];
      if (metadata is! Map<String, dynamic>) continue;
      final raw = metadata['raw_response'];
      if (raw is! Map<String, dynamic>) continue;
      final improved = _reasonFromResponse(raw, metadata);
      updated += await db.update(
          'human_review_tickets',
          {
            'reason': improved,
            'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [row['id']]);
    }
    return updated;
  }

  String _reasonFromResponse(
      Map<String, dynamic> raw, Map<String, dynamic> metadata) {
    final explicit = raw['reason']?.toString().trim();
    if (explicit != null && explicit.isNotEmpty && explicit != 'null') {
      return explicit;
    }
    final triggers = (raw['risk_triggers'] as List<Object?>? ?? const [])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final escalation = (raw['actions'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((item) {
          final type = item['type']?.toString().toLowerCase() ?? '';
          return type.contains('human') ||
              type.contains('escalat') ||
              type.contains('route');
        })
        .map((item) => item['description']?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty);
    final details = <String>{...triggers, ...escalation}.toList();
    final risk = metadata['risk_level']?.toString() ?? 'unknown';
    return details.isEmpty
        ? 'Human review required because this reply was classified as $risk risk.'
        : 'Human review required ($risk risk): ${details.join('. ')}';
  }

  Future<HumanReviewTicket> createHumanReviewTicket({
    required String userId,
    required String customerRequest,
    required String reason,
    String? requestMessageId,
  }) async {
    final db = await database;
    final existing = await db.query('human_review_tickets',
        where: "user_id = ? AND status IN ('open','contacting')",
        whereArgs: [userId],
        orderBy: 'id DESC',
        limit: 1);
    if (existing.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        await txn.insert('human_review_tickets', {
          'user_id': userId,
          'customer_request': customerRequest,
          'reason': reason,
          'status': 'open',
          'request_message_id': requestMessageId,
          'created_at_ms': now,
          'updated_at_ms': now,
        });
        await txn.rawInsert('''INSERT INTO conversation_control(
          user_id,state,resume_after_message_id,updated_at_ms)
          VALUES(?,'ai_active',NULL,?) ON CONFLICT(user_id) DO UPDATE SET
          state='ai_active',resume_after_message_id=NULL,
          updated_at_ms=excluded.updated_at_ms''', [userId, now]);
      });
    } else if (requestMessageId?.isNotEmpty == true) {
      // A later explicit transfer request supersedes an unresolved transfer
      // attempt. Ordinary review updates retain the last working behavior.
      await db.update(
        'human_review_tickets',
        {
          'customer_request': customerRequest,
          'reason': reason,
          'status': 'open',
          'assigned_to': null,
          'request_message_id': requestMessageId,
          'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [existing.single['id']],
      );
    }
    return (await humanReviewTickets())
        .firstWhere((ticket) => ticket.conversationId == userId);
  }

  Future<void> markTicketContacting(int ticketId) async {
    final db = await database;
    final rows = await db.query('human_review_tickets',
        where: 'id = ?', whereArgs: [ticketId], limit: 1);
    if (rows.isEmpty) return;
    final userId = rows.first['user_id']! as String;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final transferDrafts = await txn.query('generated_drafts',
          columns: ['batch_end_message_id'],
          where: "user_id = ? AND delivery_state = 'transfer_only'",
          whereArgs: [userId],
          limit: 1);
      final transferredBoundary =
          transferDrafts.firstOrNull?['batch_end_message_id']?.toString();
      if (transferredBoundary != null && transferredBoundary.isNotEmpty) {
        // Consume this exact frozen batch before deleting its transfer-only
        // draft. Previously the later cleanup found no draft and old refund
        // requests resurfaced in unrelated future messages.
        await txn.rawInsert('''INSERT INTO answered_cursors(user_id,message_id)
          VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET
          message_id=excluded.message_id''', [userId, transferredBoundary]);
      }
      await txn.update('human_review_tickets',
          {'status': 'contacting', 'updated_at_ms': now},
          where: 'id = ?', whereArgs: [ticketId]);
      await txn.rawInsert('''INSERT INTO conversation_control(
        user_id,state,resume_after_message_id,updated_at_ms)
        VALUES(?,'human_contacting',NULL,?) ON CONFLICT(user_id) DO UPDATE SET
        state='human_contacting',resume_after_message_id=NULL,
        updated_at_ms=excluded.updated_at_ms''', [userId, now]);
      await txn.delete('pending_customers',
          where: 'user_id = ?', whereArgs: [userId]);
      await txn.delete('generated_drafts',
          where: 'user_id = ?', whereArgs: [userId]);
      await txn.update(
          'sla_fallbacks',
          {
            'state': 'cancelled',
            'updated_at_ms': now,
          },
          where: 'user_id = ?',
          whereArgs: [userId]);
    });
  }

  /// Transfer and delivery outcomes never suppress later customer messages.
  Future<void> markTicketAwaitingCurrentAgent(int ticketId) async {
    final db = await database;
    final rows = await db.query('human_review_tickets',
        where: 'id = ?', whereArgs: [ticketId], limit: 1);
    if (rows.isEmpty) return;
    final userId = rows.first['user_id']! as String;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
        'human_review_tickets',
        {'status': 'open', 'updated_at_ms': now},
        where: 'id = ?',
        whereArgs: [ticketId],
      );
      await txn.rawInsert('''INSERT INTO conversation_control(
        user_id,state,resume_after_message_id,updated_at_ms)
        VALUES(?,'ai_active',NULL,?)
        ON CONFLICT(user_id) DO UPDATE SET
        state='ai_active',resume_after_message_id=NULL,
        updated_at_ms=excluded.updated_at_ms''', [userId, now]);
    });
  }

  Future<void> markTicketContacted(int ticketId, {String? assignedTo}) async {
    final db = await database;
    final rows = await db.query('human_review_tickets',
        where: 'id = ?', whereArgs: [ticketId], limit: 1);
    if (rows.isEmpty) return;
    final userId = rows.first['user_id']! as String;
    final document = await (await history).read(userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final boundary = messages.reversed
        .where((message) => message['direction'] == 'incoming')
        .map((message) => message['id'] as String?)
        .whereType<String>()
        .firstOrNull;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
          'human_review_tickets',
          {
            'status': 'contacted',
            'updated_at_ms': now,
            if (assignedTo?.trim().isNotEmpty == true)
              'assigned_to': assignedTo!.trim(),
          },
          where: 'id = ?',
          whereArgs: [ticketId]);
      await txn.rawInsert('''INSERT INTO conversation_control(
        user_id,state,resume_after_message_id,updated_at_ms)
        VALUES(?,'waiting_for_customer',?,?) ON CONFLICT(user_id) DO UPDATE SET
        state='waiting_for_customer',resume_after_message_id=excluded.resume_after_message_id,
        updated_at_ms=excluded.updated_at_ms''', [userId, boundary, now]);
      await txn.delete('pending_customers',
          where: 'user_id = ?', whereArgs: [userId]);
    });
  }

  Future<bool> isHumanContacting(String userId) async {
    final db = await database;
    final rows = await db.query('conversation_control',
        columns: ['state'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    return rows.isNotEmpty && rows.first['state'] == 'human_contacting';
  }

  /// A positive receipt on the exact, recent outgoing reply can resolve a
  /// missed Send confirmation. Missing icons and other seller replies cannot.
  Future<bool> confirmObservedGeneratedDraft({
    required String userId,
    required CapturedMessage message,
    required DateTime capturedAt,
  }) async {
    if (message.direction != 'outgoing' ||
        !message.deliveryConfirmed ||
        message.sentAt == null ||
        await isHumanContacting(userId)) {
      return false;
    }
    final rows = await (await database).query('generated_drafts',
        where: '''user_id=? AND (
          delivery_state='delivery_unknown' OR
          (delivery_state='retry' AND last_error LIKE '%send_unconfirmed%'))''',
        whereArgs: [userId],
        limit: 1);
    if (rows.isEmpty) return false;
    final row = rows.single;
    final createdAt =
        DateTime.fromMillisecondsSinceEpoch(row['created_at_ms']! as int);
    String normalized(String value) => value.replaceAll(RegExp(r'\s+'), '');
    final reply = row['reply']! as String;
    if (normalized(message.body) != normalized(reply) ||
        message.sentAt!
            .isBefore(createdAt.subtract(const Duration(seconds: 1))) ||
        message.sentAt!.isAfter(capturedAt.add(const Duration(seconds: 1)))) {
      return false;
    }
    // appendCapture already stored this observed message. Do not create a
    // duplicate generated bubble or replace its original timestamp.
    if (!await (await history)
        .confirmObservedOutgoing(userId: userId, messageId: message.stableId)) {
      return false;
    }
    return markReplySent(
        userId: userId,
        reply: reply,
        recordHistory: false,
        expectedUnconfirmedCreatedAt: row['created_at_ms']! as int);
  }

  Future<bool> markReplySent(
      {required String userId,
      required String reply,
      bool recordHistory = true,
      int? expectedUnconfirmedCreatedAt,
      QueuedDelivery? expectedDelivery}) async {
    final db = await database;
    final rows = await db.query('generated_drafts',
        where: expectedUnconfirmedCreatedAt == null
            ? 'user_id = ? AND reply = ?${expectedDelivery?._identityClause ?? ''}'
            : '''user_id = ? AND reply = ? AND created_at_ms=? AND (
                delivery_state='delivery_unknown' OR
                (delivery_state='retry' AND last_error LIKE '%send_unconfirmed%'))''',
        whereArgs: [
          userId,
          reply,
          if (expectedUnconfirmedCreatedAt != null)
            expectedUnconfirmedCreatedAt
          else
            ...?expectedDelivery?._identityArguments,
        ],
        limit: 1);
    if (rows.isEmpty) {
      if (expectedUnconfirmedCreatedAt != null || expectedDelivery != null) {
        return false;
      }
      // Compatibility for an unsent draft created by a pre-v5 build.
      return (await history).markReplySent(userId: userId, reply: reply);
    }
    final row = rows.first;
    final raw = jsonDecode(row['raw_json']! as String) as Map<String, dynamic>;
    final draft = AiDraft.fromJson(raw, mediaBaseUrl: Uri());
    final batchEnd = row['batch_end_message_id']?.toString();
    final store = await history;
    String? remainingNewestMessageId;
    DateTime? remainingDueAt;
    if (batchEnd != null && batchEnd.isNotEmpty) {
      final document = await store.read(userId);
      final messages = (document?['messages'] as List<Object?>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      final batchEndIndex =
          messages.indexWhere((message) => message['id'] == batchEnd);
      if (batchEndIndex >= 0) {
        final remainingIncoming = messages
            .skip(batchEndIndex + 1)
            .where((message) => message['direction'] == 'incoming')
            .toList(growable: false);
        if (remainingIncoming.isNotEmpty) {
          remainingNewestMessageId = remainingIncoming.last['id']?.toString();
          // A real reply resets the holding-message clock for any newer frozen
          // batch. The customer has just received service, so no holding reply
          // is due until another full 20 seconds pass without a real reply.
          remainingDueAt = DateTime.now().add(slaFallbackDelay);
        }
      }
    }
    if (recordHistory) {
      await store.appendSentReply(
        userId: userId,
        displayName: userId,
        stableKey: userId,
        draft: draft,
      );
    }
    final recorded = await db.transaction((txn) async {
      final deleted = await txn.delete('generated_drafts',
          where: expectedUnconfirmedCreatedAt == null
              ? 'user_id = ?${expectedDelivery?._identityClause ?? ''}'
              : '''user_id=? AND reply=? AND created_at_ms=? AND (
                  delivery_state='delivery_unknown' OR
                  (delivery_state='retry' AND last_error LIKE '%send_unconfirmed%'))''',
          whereArgs: expectedUnconfirmedCreatedAt == null
              ? [userId, ...?expectedDelivery?._identityArguments]
              : [userId, reply, expectedUnconfirmedCreatedAt]);
      if ((expectedUnconfirmedCreatedAt != null || expectedDelivery != null) &&
          deleted != 1) {
        return false;
      }
      if (batchEnd != null && batchEnd.isNotEmpty) {
        await txn.rawInsert('''INSERT INTO answered_cursors(user_id,message_id)
          VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET
          message_id=excluded.message_id''', [userId, batchEnd]);
      }
      final updatedAt = DateTime.now().millisecondsSinceEpoch;
      if (remainingNewestMessageId != null && remainingDueAt != null) {
        // A frozen reply can cover an older message while a later customer
        // line remains pending. That remaining batch starts its own SLA at its
        // first unanswered message; it must not inherit the older deadline.
        await txn.rawUpdate('''UPDATE sla_fallbacks SET
          message_id=?, due_at_ms=?,
          state='pending', sent_at_ms=NULL,
          updated_at_ms=?
          WHERE user_id=?''', [
          remainingNewestMessageId,
          remainingDueAt.millisecondsSinceEpoch,
          updatedAt,
          userId,
        ]);
      } else {
        await txn.update(
          'sla_fallbacks',
          {
            'state': 'completed',
            'updated_at_ms': updatedAt,
          },
          where: 'user_id = ? AND message_id = ?',
          whereArgs: [userId, batchEnd],
        );
      }
      return true;
    });
    return recorded;
  }

  Future<void> seedDemoData() async {
    final store = await history;
    final imagePath = await store.saveMedia(
      userId: 'tb32020',
      filename: 'demo_customer_photo.png',
      bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
    );
    final now = DateTime.now();
    final firstDemo = CapturedConversation(
      stableKey: 'demo:tb302030',
      customerName: 'tb302030',
      customerExternalId: 'tb302030',
      capturedAt: now,
      messages: const [
        CapturedMessage(
          stableId: 'demo:tb302030:1',
          direction: 'incoming',
          body: 'Ni ha0?',
          axPath: 'demo',
        ),
      ],
    );
    await saveCapture(firstDemo);
    await _upsertPending(firstDemo, store);
    final secondDemo = CapturedConversation(
      stableKey: 'demo:tb32020',
      customerName: 'tb32020',
      customerExternalId: 'tb32020',
      capturedAt: now.add(const Duration(milliseconds: 1)),
      messages: [
        CapturedMessage(
          stableId: 'demo:tb32020:1',
          direction: 'incoming',
          body: 'hello',
          axPath: 'demo',
          media: [
            CapturedMedia(
              type: 'image',
              path: imagePath,
              mimeType: 'image/png',
              originalName: 'demo_customer_photo.png',
              visualFingerprint: 'ffffffffffffffff',
            ),
          ],
        ),
      ],
    );
    await saveCapture(secondDemo);
    await _upsertPending(secondDemo, store);
  }

  Future<void> close() async {
    if (_databaseOpening != null) await _databaseOpening;
    await _database?.close();
    _database = null;
    _databaseOpening = null;
  }

  Future<Directory> _resolveDefaultStorageRoot() async {
    final configured = Platform.environment['QIANNIU_DATA_DIR'];
    if (configured != null && configured.trim().isNotEmpty) {
      return Directory(configured).absolute;
    }

    // Development builds live below <project>/build/macos/...; walk upward to
    // the Flutter project so `open .../jd_automation.app` still writes here.
    for (final startingPoint in <Directory>[
      if (!AppRuntime.standalone) ...[
        Directory.current,
        File(Platform.resolvedExecutable).parent,
      ],
    ]) {
      var candidate = startingPoint.absolute;
      while (candidate.parent.path != candidate.path) {
        if (await File(p.join(candidate.path, 'pubspec.yaml')).exists()) {
          return Directory(p.join(candidate.path, 'data'));
        }
        candidate = candidate.parent;
      }
    }

    // Packaged installations have no source project. Allow an explicit
    // QIANNIU_DATA_DIR there; otherwise use the normal macOS fallback.
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'data'));
    if (AppRuntime.standalone) {
      await AppRuntime.installBundledInitialData(root);
    }
    return root;
  }
}

class QueuedDelivery {
  const QueuedDelivery({
    required this.pendingId,
    required this.userId,
    required this.draft,
    required this.createdAtMs,
    required this.batchEndMessageId,
  });

  final int pendingId;
  final String userId;
  final AiDraft draft;
  final int createdAtMs;
  final String? batchEndMessageId;

  String get _identityClause =>
      ' AND user_id=? AND pending_id=? AND created_at_ms=? AND reply=?'
      ' AND batch_end_message_id IS ?';
  List<Object?> get _identityArguments =>
      [userId, pendingId, createdAtMs, draft.reply, batchEndMessageId];
}

class SlaFallbackJob {
  const SlaFallbackJob({
    required this.userId,
    required this.messageId,
    required this.dueAt,
  });

  factory SlaFallbackJob.fromRow(Map<String, Object?> row) => SlaFallbackJob(
        userId: row['user_id']! as String,
        messageId: row['message_id']! as String,
        dueAt: DateTime.fromMillisecondsSinceEpoch(row['due_at_ms']! as int),
      );

  final String userId;
  final String messageId;
  final DateTime dueAt;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
