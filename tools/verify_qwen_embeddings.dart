import 'dart:io';

import 'package:jd_automation/codex/qwen_semantic_knowledge_scorer.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('jd_qwen_smoke_');
  final backend = NativeQwenEmbeddingBackend(
      modelFile: File(
          '${Directory.current.path}/data/qwen_embeddings/$qwenEmbeddingModel.gguf'));
  final scorer =
      QwenSemanticKnowledgeScorer(cacheDirectory: root, backend: backend);
  final records = <Map<String, dynamic>>[
    {
      'id': 'loading',
      'title': '热敏打印机装入纸卷',
      'content': '打开上盖，把纸卷装在纸仓中，热敏面朝向打印头。纸张从导纸器中间引出，合盖后等待自动识别。'
    },
    {
      'id': 'shift',
      'title': 'M880D 考勤机班次设置',
      'content': '上下班时间使用24小时制设置，最多三组班次、六个时间点。'
    },
    {
      'id': 'ribbon',
      'title': 'TH650G 复写不清',
      'content': '更换色带后最后几联仍不清晰，需要检查纸厚调节杆档位和复写纸。'
    },
  ];
  try {
    final timer = Stopwatch()..start();
    await scorer.prepare(records);
    stdout.writeln(
        'Native Q8 startup and three-document index: ${timer.elapsedMilliseconds} ms');
    for (final (query, expected) in [
      ('How do I insert the paper roll?', 'loading'),
      ('打印机纸卷怎么放进去？', 'loading'),
      ('How do I set working shifts on M880D?', 'shift'),
      ('TH650G换了新色带最后几联还是很模糊', 'ribbon'),
    ]) {
      timer.reset();
      final scores = await scorer.score(query, records);
      final ranked = scores.keys.toList()
        ..sort((a, b) => scores[b]!.compareTo(scores[a]!));
      stdout.writeln(
          'Expected $expected, selected ${ranked.first}, query ${timer.elapsedMilliseconds} ms');
      if (ranked.first != expected) {
        throw StateError('Cross-language retrieval smoke test failed.');
      }
    }
  } finally {
    await scorer.close();
    await root.delete(recursive: true);
  }
}
