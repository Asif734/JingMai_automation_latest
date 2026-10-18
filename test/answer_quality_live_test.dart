import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/qwen_semantic_knowledge_scorer.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/runtime/app_runtime.dart';
import 'package:jd_automation/storage/capture_database.dart';

/// Opt-in generation ONLY with synthetic customer IDs and temporary storage.
/// No JD window, capture, send, transfer or production history is touched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final question in [
    'do you sell tp879',
    'I need an attendance machine for 500 employees. Which one would be best?',
    'My TP874 paper is stuck halfway while printing. How do I remove this paper and load it again?',
    'How do I insert the paper roll in my TP874?',
    'What speed versions are available for TP874? Which is faster?',
    'M880D 第一班6点到12点，第二班16点到22点，怎么设置班次？',
    'I use a TP874. What if it starts burning? What should I do then?',
  ]) {
    test('generation-only grounded answer: $question', () async {
      // Flutter's widget binding otherwise replaces even loopback requests.
      HttpOverrides.global = null;
      final root = await Directory.systemTemp.createTemp('jd_answer_quality_');
      final database =
          CaptureDatabase(storageRoot: Directory('${root.path}/data'));
      final project = Directory.current.path;
      final backend = NativeQwenEmbeddingBackend(
          modelFile:
              File('$project/data/qwen_embeddings/$qwenEmbeddingModel.gguf'));
      final scorer = QwenSemanticKnowledgeScorer(
          cacheDirectory: Directory('$project/data/qwen_embeddings/index'),
          backend: backend);
      addTearDown(() async {
        await backend.close();
        await database.close();
        await root.delete(recursive: true);
      });
      await database.saveCapture(CapturedConversation(
          stableKey: 'synthetic:quality',
          customerName: 'synthetic-quality',
          customerExternalId: 'synthetic-quality',
          capturedAt: DateTime.now(),
          messages: [
            CapturedMessage(
                stableId: 'synthetic-question',
                direction: 'incoming',
                body: question,
                axPath: 'offline-test')
          ]));
      final executable = await AppRuntime.findCodex();
      expect(executable, isNotNull);
      // Preserve only this synthetic run's final payload before the service
      // removes its temporary directory, so schema failures are diagnosable.
      final proxy = File('${root.path}/codex-proxy.sh');
      await proxy.writeAsString('''#!/bin/sh
output=''
previous=''
for argument in "\$@"; do
  if [ "\$previous" = '--output-last-message' ]; then output="\$argument"; fi
  previous="\$argument"
done
'${executable!.replaceAll("'", "'\\''")}' "\$@"
result=\$?
if [ -f "\$output" ]; then cp "\$output" '${root.path}/model-output.json'; fi
exit "\$result"
''');
      expect((await Process.run('chmod', ['+x', proxy.path])).exitCode, 0);
      final service = CodexReplyService(
          executable: proxy.path,
          workspace: Directory('$project/codex_workspace'),
          knowledgeDirectory: Directory('$project/格志京东客服知识库-2026-10-04'),
          outputSchema: File('$project/codex_workspace/reply.schema.json'),
          secondInspectionScorer: scorer,
          timeout: const Duration(seconds: 120));
      final watch = Stopwatch()..start();
      late AiDraft draft;
      try {
        draft = await service.generate(
            conversation: (await database.conversations()).single,
            database: database,
            batchEndMessageId: 'synthetic-question');
      } on CodexReplyException {
        final payload = File('${root.path}/model-output.json');
        if (await payload.exists()) {
          final raw = await payload.readAsString();
          try {
            service.parseResponse(raw);
          } on CodexReplyException catch (error) {
            // ignore: avoid_print
            print('Synthetic replay parse failure: $error; payload=$raw');
          }
        }
        rethrow;
      }
      // ignore: avoid_print
      print(jsonEncode({
        'question': question,
        'reply': draft.reply,
        'decision': draft.decision,
        'used_record_ids': draft.usedRecordIds,
        'generation_ms': watch.elapsedMilliseconds,
        'retrieval_trace': (jsonDecode(draft.rawJson) as Map)['retrieval_trace']
      }));
      expect(isExplicitHumanTransfer(draft), isFalse);
      expect(draftRequiresHumanReview(draft), isFalse);
      if (draft.decision != 'ask_clarification') {
        expect(draft.usedRecordIds, isNotEmpty);
      }
      if (question == 'do you sell tp879') {
        expect(draft.reply.toLowerCase(),
            anyOf(contains('legacy'), contains('historical')));
        expect(draft.reply.toLowerCase(), isNot(contains('discontinued')));
        expect(draft.reply.toLowerCase(), isNot(contains('we sell tp879')));
        expect(draft.usedRecordIds, contains('product_model_feature_catalog'));
      }
      if (question.startsWith('What speed versions')) {
        for (final speed in ['110', '155', '185']) {
          expect(draft.reply, contains(speed),
              reason:
                  'Compare the supplied version table, not only the separate exact-model rating.');
        }
      }
      expect(
          draft.reply,
          isNot(matches(RegExp(
              r'photo of.{0,30}manual|send.{0,30}manual|发.{0,15}说明书',
              caseSensitive: false))));
      final after = await (await database.history).read('synthetic-quality');
      expect((after!['messages'] as List).length, 1,
          reason: 'No send takes place during generation-only replay.');
    },
        skip: !const bool.fromEnvironment('JD_ANSWER_QUALITY_LIVE'),
        timeout: const Timeout(Duration(minutes: 3)));
  }
}
