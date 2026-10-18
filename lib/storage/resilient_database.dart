import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Serializes access outside sqflite's native transaction queue. A failed
/// COMMIT can leave that native queue holding a transaction which Dart has
/// already closed. No subsequent request may enter it before we close the
/// connection (rolling back) and reopen it.
class ResilientDatabase {
  ResilientDatabase(this._open, {this.onRecovery});

  final Future<Database> Function() _open;
  final void Function(Object error, int attempt)? onRecovery;
  Database? _connection;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  static bool isContention(Object error) {
    if (error is! DatabaseException) return false;
    final code = error.getResultCode();
    return (code != null && (code & 0xff == 5 || code & 0xff == 6)) ||
        error.toString().toLowerCase().contains('database is locked') ||
        error.toString().toLowerCase().contains('database is busy');
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final release = Completer<void>();
    final previous = _tail;
    _tail = release.future;
    return () async {
      await previous;
      try {
        return await action();
      } finally {
        release.complete();
      }
    }();
  }

  Future<T> _run<T>(Future<T> Function(Database database) action) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await _serialized(() async {
          if (_closed) throw StateError('Database is closed.');
          try {
            final connection = _connection ??= await _open();
            return await action(connection);
          } catch (error) {
            if (!isContention(error)) rethrow;
            // Every caller, including reads, is outside this native queue.
            // Closing here cannot wait behind another queued application call.
            final broken = _connection;
            _connection = null;
            if (broken != null) await broken.close();
            onRecovery?.call(error, attempt);
            rethrow;
          }
        });
      } catch (error) {
        if (!isContention(error) || attempt >= 3) rethrow;
        // Yield the application queue between bounded attempts. The caller's
        // durable job remains pending if an external writer stays busy.
        await Future<void>.delayed(Duration(milliseconds: attempt * 50));
      }
    }
  }

  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
          {bool? exclusive}) =>
      _run((database) => database.transaction(action, exclusive: exclusive));

  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _run((database) => database.execute(sql, arguments));

  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      _run((database) => database.rawQuery(sql, arguments));

  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      _run((database) => database.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset));

  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      _run((database) => database.rawInsert(sql, arguments));

  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _run((database) => database.rawUpdate(sql, arguments));

  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _run((database) => database.rawDelete(sql, arguments));

  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      _run((database) => database.insert(table, values,
          nullColumnHack: nullColumnHack,
          conflictAlgorithm: conflictAlgorithm));

  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      _run((database) => database.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm));

  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _run((database) =>
          database.delete(table, where: where, whereArgs: whereArgs));

  Future<int> getVersion() => _run((database) => database.getVersion());

  Future<void> close() => _serialized(() async {
        _closed = true;
        final connection = _connection;
        _connection = null;
        await connection?.close();
      });
}
