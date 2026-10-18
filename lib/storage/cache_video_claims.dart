import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// A shared JD cache entry cannot migrate to a different customer on a later
/// poll or restart. This is a file-event claim, not content deduplication:
/// identical video bytes in a different cache entry remain a separate upload.
class CacheVideoClaims {
  CacheVideoClaims(this.directory);
  final Directory directory;
  Future<void> _tail = Future<void>.value();

  Future<bool> claim(String cacheKey, String customer, DateTime sentAt) async {
    if (cacheKey.isEmpty || customer.isEmpty) return false;
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      await directory.create(recursive: true);
      final file = File(
          '${directory.path}/${sha256.convert(utf8.encode(cacheKey))}.json');
      if (await file.exists()) {
        final existing = jsonDecode(await file.readAsString()) as Map;
        return existing['customer'] == customer &&
            existing['cache_key'] == cacheKey;
      }
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
          jsonEncode({
            'customer': customer,
            'cache_key': cacheKey,
            'first_sent_at': sentAt.toUtc().toIso8601String(),
          }),
          flush: true);
      await temporary.rename(file.path);
      return true;
    } finally {
      release.complete();
    }
  }
}
