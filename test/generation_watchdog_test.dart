import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

const _answer =
    '''{"reply":"Restart the printer and reconnect the USB cable.","decision":"draft","confidence":0.9,"used_record_ids":["safe_restart"],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}''';
const _unresolved =
    '''{"reply":"I cannot resolve this technical printer issue.","decision":"human_review_required","confidence":0.4,"used_record_ids":[],"required_slots":[],"actions":[],"risk_level":"high","risk_triggers":["unresolved printer issue"],"auto_send_allowed":false,"attachments":[],"image_descriptions":[],"human_review_required":true,"reason":"No solution found"}''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase database;
  late File cli;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_watchdog_');
    database = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    await Directory('${root.path}/workspace').create();
    final ragCards = await Directory('${root.path}/knowledge/rag_cards')
        .create(recursive: true);
    await File('${ragCards.path}/customer_service_rag_cards.jsonl').writeAsString(
        '{"id":"safe_restart","status":"active","keywords":["printer","not working","USB"],"issue":"printer USB recovery","reply_template":"Restart the printer and reconnect the USB cable."}\n');
    cli = File('${root.path}/codex.sh');
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:watchdog',
      customerName: 'watchdog',
      customerExternalId: 'watchdog',
      capturedAt: DateTime.now(),
      messages: const [
        CapturedMessage(
          stableId: 'question',
          direction: 'incoming',
          body: 'My printer is not working. How can I fix it?',
          axPath: 'test',
        ),
      ],
    ));
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  Future<void> writeCli(String body, {String beforeInput = ''}) async {
    await cli.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
$beforeInput
cat >/dev/null
$body
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
  }

  CodexReplyService service(Duration limit,
          {List<Duration> capacityRetryDelays = const []}) =>
      CodexReplyService(
        executable: cli.path,
        workspace: Directory('${root.path}/workspace'),
        knowledgeDirectory: Directory('${root.path}/knowledge'),
        outputSchema: File('${root.path}/reply.schema.json'),
        timeout: limit,
        capacityRetryDelays: capacityRetryDelays,
      );

  test('a completed reply does not wait for the watchdog deadline', () async {
    await writeCli("printf '%s\\n' '$_answer' > \"\$output\"");
    final conversation = (await database.conversations()).single;
    final clock = Stopwatch()..start();
    final draft = await service(const Duration(seconds: 5)).generate(
      conversation: conversation,
      database: database,
    );
    expect(draft.reply, contains('Restart the printer'));
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('the watchdog includes capacity retry backoff', () async {
    final attempts = File('${root.path}/attempts');
    await writeCli('''
printf 'attempt\\n' >> "${attempts.path}"
printf '%s\\n' 'Selected model is at capacity. Please try a different model.'
exit 1
''');
    await expectLater(
      service(const Duration(seconds: 2),
          capacityRetryDelays: const [Duration(seconds: 3)]).generate(
        conversation: (await database.conversations()).single,
        database: database,
      ),
      throwsA(isA<CodexGenerationTimedOut>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    expect(await attempts.readAsLines(), ['attempt']);
    expect(await database.hasPendingUnanswered('watchdog'), isTrue);
    expect(await database.hasUndeliveredDraft('watchdog'), isFalse);
  });

  test('the second investigation shares the original deadline', () async {
    final attempts = File('${root.path}/attempts');
    await writeCli('''
printf 'attempt\\n' >> "${attempts.path}"
sleep 3
printf '%s\\n' '$_unresolved' > "\$output"
''');
    await expectLater(
      service(const Duration(seconds: 5)).generate(
        conversation: (await database.conversations()).single,
        database: database,
      ),
      throwsA(isA<CodexGenerationTimedOut>()),
    );
    expect(await attempts.readAsLines(), ['attempt', 'attempt']);
    // Let the shell's short-lived sleep child close inherited pipes. The
    // cancelled generation must never persist or deliver a late draft.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(await database.hasPendingUnanswered('watchdog'), isTrue);
    expect(await database.hasUndeliveredDraft('watchdog'), isFalse);
  });

  test('a CLI ignoring SIGTERM is killed when generation expires', () async {
    final pidFile = File('${root.path}/pid');
    await writeCli('exec sleep 30', beforeInput: '''
trap '' TERM
printf '%s' "\$\$" > "${pidFile.path}"
''');
    await expectLater(
      service(const Duration(seconds: 2)).generate(
        conversation: (await database.conversations()).single,
        database: database,
      ),
      throwsA(isA<CodexGenerationTimedOut>()),
    );
    final pid = int.parse(await pidFile.readAsString());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((await Process.run('kill', ['-0', '$pid'])).exitCode, isNot(0));
    expect(await database.hasPendingUnanswered('watchdog'), isTrue);
  });
}
