import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/resilient_database.dart';
import 'package:jd_automation/storage/reply_outbox.dart';
import 'package:jd_automation/storage/fallback_delivery_journal.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _BusyException implements DatabaseException {
  @override
  int getResultCode() => 5;
  @override
  String toString() => 'database is locked; COMMIT';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CommitFailureDatabase implements Database {
  _CommitFailureDatabase(this.started, this.failCommit, this.events);
  final Completer<void> started;
  final Completer<void> failCommit;
  final List<String> events;
  bool closed = false;
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) async {
    events.add('transaction');
    started.complete();
    await failCommit.future;
    throw _BusyException();
  }

  @override
  Future<void> close() async {
    closed = true;
    events.add('rollback-close');
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) async =>
      throw StateError('Read entered poisoned connection');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CapturedConversation _capture(String id) => CapturedConversation(
        stableKey: 'customer:lock-test',
        customerName: 'lock-test',
        customerExternalId: 'lock-test',
        capturedAt: DateTime.now(),
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: 'Please help with USB printing',
              sentAt: DateTime.now(),
              axPath: 'test')
        ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'interrupted send retries after verified absence, never after failed OCR',
      () async {
    final root = await Directory.systemTemp.createTemp('interrupted_outbox_');
    addTearDown(() => root.delete(recursive: true));
    final outbox = ReplyOutbox(root);
    final at = DateTime.now();
    final item = OutboxReply(
        userId: 'buyer',
        batchEndMessageId: 'question',
        draft: AiDraft.fromJson({
          'reply': 'The original answer',
          'decision': 'draft',
          'confidence': 1,
          'model': 'test',
          'used_record_ids': [],
          'actions': [],
          'attachments': []
        }, mediaBaseUrl: Uri()),
        createdAt: at.subtract(const Duration(minutes: 1)),
        state: 'sending');
    await outbox.save(item);
    expect(
        await outbox.recordVerifiedAbsence(item,
            exactUnansweredBubbleVisible: false, now: at),
        isFalse);
    expect(item.verifiedAbsences, 0);
    expect(
        await outbox.recordVerifiedAbsence(item,
            exactUnansweredBubbleVisible: true, now: at),
        isFalse);
    final restarted = (await ReplyOutbox(root).pending()).single;
    expect(
        await outbox.recordVerifiedAbsence(restarted,
            exactUnansweredBubbleVisible: true,
            now: at.add(const Duration(seconds: 1))),
        isFalse);
    expect(
        await outbox.recordVerifiedAbsence(restarted,
            exactUnansweredBubbleVisible: true,
            now: at.add(const Duration(seconds: 6))),
        isTrue);
    var sends = 0;
    final results = await Future.wait([
      outbox.sendReady(restarted,
          send: (_) async {
            sends++;
          },
          definitelyBeforeSend: (_) => false),
      outbox.sendReady(restarted,
          send: (_) async {
            sends++;
          },
          definitelyBeforeSend: (_) => false),
    ]);
    expect(results.where((sent) => sent), hasLength(1));
    expect(sends, 1);
  });

  test('acknowledging an original answer preserves a newer unanswered question',
      () async {
    final root = await Directory.systemTemp.createTemp('outbox_batch_cursor_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    await database.saveCapture(_capture('original'));
    await database.saveCapture(_capture('newer'));
    final draft = AiDraft.fromJson({
      'reply': 'Answer for original',
      'decision': 'draft',
      'confidence': 1,
      'model': 'test',
      'used_record_ids': [],
      'actions': [],
      'attachments': []
    }, mediaBaseUrl: Uri());
    await (await database.history).appendSentReply(
        userId: 'lock-test',
        displayName: 'lock-test',
        stableKey: 'customer:lock-test',
        draft: draft);
    await database.acknowledgeOutboxReply(
        userId: 'lock-test', batchEndMessageId: 'original', reply: draft.reply);
    expect(await database.answeredMessageId('lock-test'), 'original');
    expect(await database.pendingMessageId('lock-test'), 'newer');
    expect(await database.hasPendingUnanswered('lock-test'), isTrue);
  });

  test('failed COMMIT closes poisoned connection before queued reads enter',
      () async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('commit_recovery_');
    final started = Completer<void>();
    final fail = Completer<void>();
    final events = <String>[];
    final poisoned = _CommitFailureDatabase(started, fail, events);
    var opens = 0;
    final database = ResilientDatabase(() async {
      opens++;
      if (opens == 1) return poisoned;
      events.add('reopen');
      return databaseFactoryFfi.openDatabase('${root.path}/test.db',
          options: OpenDatabaseOptions(singleInstance: false));
    });
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final transaction = database.transaction((txn) async => 42);
    await started.future;
    final read = database.rawQuery('SELECT 1 AS value');
    fail.complete();
    expect(await transaction.timeout(const Duration(seconds: 4)), 42);
    expect((await read.timeout(const Duration(seconds: 4))).single['value'], 1);
    expect(poisoned.closed, isTrue);
    expect(events, ['transaction', 'rollback-close', 'reopen']);
  });

  Future<Process> holdLock(String path, String sql) async {
    final process = await Process.start('/usr/bin/sqlite3', [path]);
    final ready = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line == 'locked');
    process.stdin.writeln('$sql; SELECT \'locked\';');
    await process.stdin.flush();
    await ready.timeout(const Duration(seconds: 4));
    return process;
  }

  Future<void> releaseLock(Process process) async {
    process.stdin.writeln('ROLLBACK;');
    process.stdin.writeln('.quit');
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 4));
  }

  test('real failed COMMIT recovers and does not apply a transaction twice',
      () async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('real_commit_recovery_');
    Process? reader;
    Future<void>? release;
    var recovered = 0;
    final database = ResilientDatabase(
        () => databaseFactoryFfi.openDatabase('${root.path}/commit.db',
            options: OpenDatabaseOptions(
                singleInstance: false,
                onConfigure: (db) async {
                  await db.execute('PRAGMA busy_timeout=50');
                  await db.rawQuery('PRAGMA journal_mode=DELETE');
                })), onRecovery: (error, attempt) {
      recovered++;
      release ??= releaseLock(reader!);
    });
    addTearDown(() async {
      await release;
      await database.close();
      await root.delete(recursive: true);
    });
    await database.execute('CREATE TABLE counter(value INTEGER)');
    await database.execute('INSERT INTO counter VALUES(0)');
    reader = await holdLock(
        '${root.path}/commit.db', 'BEGIN; SELECT value FROM counter');
    await database.transaction((txn) async {
      await txn.rawUpdate('UPDATE counter SET value=value+1');
    }).timeout(const Duration(seconds: 5));
    expect(recovered, greaterThanOrEqualTo(1));
    expect(
        (await database.rawQuery('SELECT value FROM counter')).single['value'],
        1);
  });

  test('live diagnostic reader cannot block capture or original reply queue',
      () async {
    final root = await Directory.systemTemp.createTemp('wal_reader_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    await database.saveCapture(_capture('first'));
    final reader = await holdLock('${root.path}/jd_automation.sqlite3',
        'BEGIN; SELECT count(*) FROM pending_customers');
    try {
      await database
          .saveCapture(_capture('second'))
          .timeout(const Duration(seconds: 3));
      expect(await database.pendingMessageId('lock-test'), 'second');
    } finally {
      await releaseLock(reader);
    }
  });

  test(
      'writer lock preserves original generated answer and repairs queue after release',
      () async {
    final root = await Directory.systemTemp.createTemp('writer_recovery_');
    final database = CaptureDatabase(storageRoot: root);
    final outbox = ReplyOutbox(Directory('${root.path}/reply_outbox'));
    final fallbacks =
        FallbackDeliveryJournal(Directory('${root.path}/fallback_delivery'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    await database.saveCapture(_capture('old'));
    final writer =
        await holdLock('${root.path}/jd_automation.sqlite3', 'BEGIN IMMEDIATE');
    final draft = AiDraft.fromJson({
      'reply': 'Please connect the USB data cable and print a test page.',
      'decision': 'draft',
      'confidence': 1,
      'model': 'test',
      'risk_level': 'low',
      'used_record_ids': ['usb'],
      'actions': [],
      'attachments': [],
    }, mediaBaseUrl: Uri());
    var originalReplySends = 0;
    try {
      await expectLater(
          database
              .saveCapture(_capture('new'))
              .timeout(const Duration(seconds: 5)),
          throwsA(predicate(ResilientDatabase.isContention)));
      await outbox.save(OutboxReply(
          userId: 'lock-test',
          batchEndMessageId: 'new',
          draft: draft,
          createdAt: DateTime.now()));
      expect((await outbox.pending()).single.draft.reply, draft.reply);
      final savedAnswer = (await outbox.pending()).single;
      Future<void> sendOriginal(AiDraft answer) async {
        expect(answer.reply, draft.reply);
        originalReplySends++;
      }

      expect(
          await outbox.sendReady(savedAnswer,
              send: sendOriginal, definitelyBeforeSend: (_) => false),
          isTrue);
      // A second caller and a process restart cannot send the same confirmed
      // original answer again while SQLite is still unavailable.
      final restarted = ReplyOutbox(Directory('${root.path}/reply_outbox'));
      expect((await restarted.pending()).single.state, 'sent');
      expect(
          await restarted.sendReady((await restarted.pending()).single,
              send: sendOriginal, definitelyBeforeSend: (_) => false),
          isFalse);
      expect(originalReplySends, 1);
      expect(await fallbacks.reserve('lock-test', 'new'), isTrue);
      expect(await fallbacks.reserve('lock-test', 'new'), isFalse);
      // WAL reads and the independent original-answer journal still work
      // while another process owns the SQLite write lock.
      expect(
          (await (await database.database).rawQuery('SELECT 1 AS alive'))
              .single['alive'],
          1);
    } finally {
      await releaseLock(writer);
    }
    await database.repairPendingCaptures().timeout(const Duration(seconds: 5));
    expect(await database.pendingMessageId('lock-test'), 'new');
    final preserved = (await outbox.pending()).single;
    await database.acknowledgeOutboxReply(
        userId: preserved.userId,
        batchEndMessageId: preserved.batchEndMessageId,
        reply: preserved.draft.reply);
    await outbox.remove(preserved.userId, preserved.batchEndMessageId);
    expect(await database.hasPendingUnanswered('lock-test'), isFalse);
    expect(await database.nextReadyDelivery(), isNull);
    expect(originalReplySends, 1);
  });
}
