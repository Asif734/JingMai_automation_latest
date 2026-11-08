import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('direct database reply bypasses retrieval and second inspection',
      () async {
    final root = await Directory.systemTemp.createTemp('direct_database_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    await File('${knowledge.path}/printer_kb.md')
        .writeAsString('Printer cleaning requires disconnecting power.');
    await File('${knowledge.path}/README.md').writeAsString('Developer notes');
    final prompt = File('${root.path}/prompt');
    final calls = File('${root.path}/calls');
    final executable = File('${root.path}/fake-codex');
    await executable.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
cat > '${prompt.path}'
echo call >> '${calls.path}'
printf '%s' '{"reply":"Please disconnect the power before cleaning the printer.","decision":"reply","confidence":0.9,"used_record_ids":["printer_kb.md"],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}' > "\$output"
''');
    await Process.run('chmod', ['+x', executable.path]);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: DateTime.utc(2026, 10, 27),
      messages: [
        CapturedMessage(
            stableId: 'question',
            direction: 'incoming',
            body: 'How should I clean the printer?',
            axPath: 'test')
      ],
    ));
    final service = CodexReplyService(
        executable: executable.path,
        workspace: workspace,
        knowledgeDirectory: knowledge,
        outputSchema: File('${root.path}/schema.json'));
    final draft = await service.generate(
        conversation: (await database.conversations()).single,
        database: database);
    final request = jsonDecode((await prompt.readAsString())
        .split('<request_json>\n')[1]
        .split('\n</request_json>')[0]) as Map;
    expect(request['knowledge_access'], 'direct_local_database');
    expect(request['database_files'], ['${knowledge.path}/printer_kb.md']);
    expect(request.containsKey('retrieved_knowledge_records'), isFalse);
    expect(request.containsKey('fresh_second_inspection_queries'), isFalse);
    expect(await calls.readAsLines(), ['call']);
    expect(draft.reply, contains('disconnect'));
    expect(draft.usedRecordIds, ['printer_kb.md']);
  });
}
