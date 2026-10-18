// One-off, exact incident repair. Run only with Review automation stopped.
// No JD UI, Codex request, send, transfer, or deletion of physical media.
import 'dart:convert';
import 'dart:io';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/codex/customer_video_report.dart';

Future<void> main(List<String> args) async {
  const customer = 'jd_41aeec7741d05';
  const previewId =
      'visible-attachment-preview:efbdf6f2345a2e4c00ae7c22819f3691b85d45e6e1ccf397a53e81a7c1f812af';
  const firstId =
      'visible-video:f84d688641ffed130e7314605b8876689dbca44117a917fbb3997dcf2d91e2c3:1792315224';
  const lastId =
      'visible-video:d4e5f82dedca465d9eeea881ad7ec476ec993a9fdea34d5a7c24407419a6a3a5:1792315381';
  final root = Directory('${Directory.current.path}/data');
  final file = File('${root.path}/$customer.json');
  final sqlFile = '${root.path}/jd_automation.sqlite3';
  final document =
      jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  if (document['user_id'] != customer) throw StateError('Wrong owner');
  final messages = (document['messages'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> message(String id) =>
      messages.singleWhere((m) => m['id'] == id);
  final original = message(firstId), last = message(lastId);
  final preview = messages.where((m) => m['id'] == previewId).firstOrNull;
  for (final video in [original, last]) {
    if (video['direction'] != 'incoming' ||
        !(video['media'] as List).whereType<Map>().any((m) =>
            m['type'] == 'video' &&
            m['verified_customer_id'] == customer &&
            m['capture_source'] == 'jd_video_cache')) {
      throw StateError('Original video proof missing');
    }
  }
  if (preview != null &&
      (preview['sent_at'] != original['sent_at'] ||
          !(preview['media'] as List).whereType<Map>().every((m) =>
              m['capture_source'] == 'verified_attachment_preview' &&
              m['verified_customer_id'] == customer &&
              m['is_partial'] == true))) {
    throw StateError('Not the verified duplicate poster');
  }
  final guard = await Process.run('sqlite3', [
    '-readonly',
    sqlFile,
    "SELECT COUNT(*) FROM generated_drafts WHERE user_id='$customer';"
  ]);
  if (guard.exitCode != 0 || guard.stdout.toString().trim() != '0') {
    throw StateError(
        'An existing generated draft must be preserved; repair aborted');
  }
  final events = [
    CustomerVideoEvent(customer, original),
    CustomerVideoEvent(customer, last)
  ];
  if (args.length != 1 || args.single != '--apply') {
    stdout.writeln(
        'Plan: back up JSON/SQLite, remove ${preview == null ? 0 : 1} exact duplicate poster, '
        'retain originals/frames, remember two observed prepass timeouts, re-arm only stale holding receipt.');
    return;
  }
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
  final backup = await Directory(
          '${root.path}/maintenance-backups/oct18-video-delivery-$stamp')
      .create(recursive: true);
  await file.copy('${backup.path}/$customer.json');
  final sqlBackup = await Process.run(
      'sqlite3', [sqlFile, ".backup '${backup.path}/jd_automation.sqlite3'"]);
  if (sqlBackup.exitCode != 0) {
    throw StateError('Database backup failed');
  }
  messages.removeWhere((m) => m['id'] == previewId);
  document['messages'] = messages;
  final temporary = File('${file.path}.incident-repair.tmp');
  await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(document),
      flush: true);
  await temporary.rename(file.path);
  await ConversationFileStore(root).recordVideoReportFailure(customer, events,
      'Video observation timed out in verified 2026-10-18 Review log; use original frames directly.');
  final latestAt = DateTime.parse(last['sent_at'] as String);
  final due = latestAt.add(const Duration(seconds: 20)).millisecondsSinceEpoch;
  final result = await Process.run('sqlite3', [
    sqlFile,
    '''BEGIN IMMEDIATE;
UPDATE sla_fallbacks SET state='pending', sent_at_ms=NULL, due_at_ms=$due,
  updated_at_ms=${DateTime.now().millisecondsSinceEpoch}
WHERE user_id='$customer' AND message_id='$lastId' AND state='sent'
  AND sent_at_ms < ${latestAt.millisecondsSinceEpoch};
COMMIT;'''
  ]);
  if (result.exitCode != 0) {
    throw StateError('Holding repair failed; backup: ${backup.path}');
  }
  stdout.writeln(
      'Removed ${preview == null ? 0 : 1} duplicate history entry; physical media unchanged.');
  stdout.writeln('Backup: ${backup.path}');
}
