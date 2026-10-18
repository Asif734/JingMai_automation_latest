import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/local_knowledge_retriever.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/qwen_semantic_knowledge_scorer.dart';
import 'package:jd_automation/codex/package_knowledge.dart';

void main() {
  test('prepare full Qwen index and retrieve bilingual incident evidence',
      () async {
    final root = Directory.current.path;
    final scorer = QwenSemanticKnowledgeScorer(
      cacheDirectory: Directory('$root/data/qwen_embeddings/index'),
      backend: NativeQwenEmbeddingBackend(
        modelFile: File('$root/data/qwen_embeddings/$qwenEmbeddingModel.gguf'),
        requestTimeout: const Duration(seconds: 30),
      ),
    );
    final retriever = LocalKnowledgeRetriever(
        Directory('$root/格志京东客服知识库-2026-10-04'),
        secondInspectionScorer: scorer);
    final elapsed = Stopwatch()..start();
    final progress = Timer.periodic(const Duration(seconds: 10), (_) {
      // No customer bodies or query vectors are logged.
      // ignore: avoid_print
      print(
          'Qwen KB index: ${scorer.completedChunks}/${scorer.totalChunks} chunks, ${elapsed.elapsed.inSeconds}s');
    });
    try {
      await retriever.prepareSecondInspectionIndex();
      for (final (question, model, expected) in [
        (
          'How do I insert the paper roll?',
          'tp874',
          'thermal_518_four_inch_paper_loading_20260921'
        ),
        ('纸卷怎么安装？', 'tp874', 'thermal_518_four_inch_paper_loading_20260921'),
        (
          'What speed versions are available?',
          'tp874',
          'thermal_speed_versions_selling_point'
        ),
        ('for setting up shift', 'm880d', 'attendance_manual_shift_setup'),
        (
          'How do I insert the paper roll in TP874?',
          'tp874',
          'thermal_518_four_inch_paper_loading_20260921'
        ),
        (
          'Paper is stuck halfway while printing. How do I remove this paper and reload it?',
          'tp874',
          '不反向猛拉'
        ),
        ('what if it start burning', 'tp874', '着火、冒烟、焦味、漏电或电火花'),
      ]) {
        final watch = Stopwatch()..start();
        final query = buildFocusedRetrievalQuery(customerTurns: [
          {'body': question}
        ], confirmedModels: {
          model
        }, categoryConstraints: const ProductRetrievalConstraints());
        final semantic = await retriever.retrieveFullSemantic(query, limit: 60);
        final lexical = await retriever.retrieve(query,
            limit: 60,
            currentQuestion: question,
            includeSemanticScoring: false);
        final filtered =
            await retriever.filterSecondInspectionEvidence(query, lexical);
        final candidates =
            mergeSecondInspectionResults([semantic, filtered], limit: 60);
        final records = await retriever.selectEvidence(query, candidates,
            currentQuestion: question, limit: 16);
        // ignore: avoid_print
        print(
            'Qwen $model expected=$expected top=${records.take(5).map((r) => r['id']).join(',')} ${watch.elapsedMilliseconds}ms');
        // ignore: avoid_print
        print(
            'Qwen semantic top=${semantic.take(5).map((r) => r['id']).join(',')}');
        expect(records.toString(), contains(expected));
        if (model == 'tp874') {
          expect(
              records.any((r) =>
                  r['product_line'] == 'attendance_machine' ||
                  r['product_line'] == 'dot_matrix_printer' ||
                  knowledgeProductFamilies(r).contains('dot_matrix') ||
                  knowledgeProductFamilies(r).contains('attendance')),
              isFalse);
        }
      }
    } finally {
      progress.cancel();
      await scorer.close();
    }
  },
      skip: !const bool.fromEnvironment('JD_QWEN_LIVE_TEST'),
      timeout: const Timeout(Duration(minutes: 20)));
}
