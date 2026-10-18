import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Independent of SQLite. A reservation survives an uncertain Send click or
/// process restart so database recovery cannot cause a duplicate notice.
class FallbackDeliveryJournal {
  FallbackDeliveryJournal(this.directory);

  final Directory directory;
  Future<void> _tail = Future<void>.value();

  File _file(String customer, String messageId) => File(p.join(directory.path,
      '${sha256.convert(utf8.encode('$customer\u001f$messageId'))}.json'));

  Future<bool> reserve(String customer, String messageId) async {
    final release = Completer<void>();
    final previous = _tail;
    _tail = release.future;
    await previous;
    try {
      await directory.create(recursive: true);
      final file = _file(customer, messageId);
      if (await file.exists()) return false;
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
          jsonEncode({
            'customer': customer,
            'message_id': messageId,
            'state': 'reserved',
            'reserved_at': DateTime.now().toUtc().toIso8601String(),
          }),
          flush: true);
      await temporary.rename(file.path);
      return true;
    } finally {
      release.complete();
    }
  }

  /// Only a confirmed pre-click failure may remove a reservation.
  Future<void> releaseBeforeSend(String customer, String messageId) async {
    final file = _file(customer, messageId);
    if (await file.exists()) await file.delete();
  }
}
