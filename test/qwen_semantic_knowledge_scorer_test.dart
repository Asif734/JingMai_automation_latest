import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/local_knowledge_retriever.dart';
import 'package:jd_automation/codex/qwen_semantic_knowledge_scorer.dart';
import 'package:jd_automation/codex/semantic_scoring.dart';

List<double> _vector(int axis) =>
    List<double>.generate(qwenEmbeddingDimensions, (i) => i == axis ? 1 : 0);

class _Backend implements QwenEmbeddingBackend {
  final calls = <List<String>>[];
  bool fail = false;
  bool invalid = false;
  @override
  Future<void> warmUp() async {}
  @override
  Future<List<List<double>>> embed(List<String> texts) async {
    calls.add(texts);
    if (fail) throw const SemanticSearchUnavailable('offline');
    return texts
        .map((text) => invalid
            ? [double.nan]
            : _vector(
                text.startsWith('Instruct:') || text.contains('装纸') ? 0 : 1))
        .toList();
  }

  @override
  Future<void> close() async {}
}

class _RecordingScorer implements SemanticKnowledgeScorer {
  final seen = <Map<String, dynamic>>[];
  final queries = <String>[];
  bool fail = false;
  @override
  Future<Map<String, double>> score(
      String query, List<Map<String, dynamic>> records) async {
    queries.add(query);
    seen.addAll(records);
    if (fail) throw const SemanticSearchUnavailable('incomplete index');
    return {
      for (final record in records)
        record['id'].toString():
            record['id'] == 'semantic_only_source' ? .95 : .2
    };
  }
}

void main() {
  late Directory root;
  setUp(() async =>
      root = await Directory.systemTemp.createTemp('jd_qwen_unit_'));
  tearDown(() => root.delete(recursive: true));

  final records = <Map<String, dynamic>>[
    {'id': 'loading', 'title': '装纸', 'content': '打开上盖，把纸卷放入纸仓。'},
    {'id': 'driver', 'title': '电脑安装', 'content': '使用Windows安装USB驱动。'},
  ];

  test('preserves English query and only persists knowledge vectors', () async {
    final backend = _Backend();
    final scorer =
        QwenSemanticKnowledgeScorer(cacheDirectory: root, backend: backend);
    await scorer.prepare(records);
    final scores =
        await scorer.score('How do I insert the paper roll?', records);
    expect(scores['loading'], greaterThan(scores['driver']!));
    expect(
        backend.calls.last.single, contains('How do I insert the paper roll?'));
    expect(backend.calls.last.single, startsWith('Instruct:'));
    final cache =
        await File('${root.path}/qwen-q8-vectors.json').readAsString();
    expect(cache, isNot(contains('How do I')));
    expect(jsonDecode(cache)['model_sha256'], qwenEmbeddingSha256);
    final count = backend.calls.length;
    await scorer.score('How do I insert the paper roll?', records);
    expect(backend.calls.length, count,
        reason: 'Identical queries reuse memory vectors.');
  });

  test(
      'restart reuses disk vectors; changed text is never scored with stale vectors',
      () async {
    final first =
        QwenSemanticKnowledgeScorer(cacheDirectory: root, backend: _Backend());
    await first.prepare(records);
    final backend = _Backend();
    final second =
        QwenSemanticKnowledgeScorer(cacheDirectory: root, backend: backend);
    await second.prepare(records);
    expect(backend.calls, isEmpty);
    await second.score('装纸怎么操作', records);
    expect(backend.calls.length, 1);
    final changed = [
      {...records.first, 'content': '更新的装纸步骤。'}
    ];
    await expectLater(second.score('装纸怎么操作', changed),
        throwsA(isA<SemanticSearchUnavailable>()));
    await second.prepare(changed);
    await second.score('装纸怎么操作', changed);
    expect(
        backend.calls
            .expand((batch) => batch)
            .any((text) => text.contains('更新的装纸步骤')),
        isTrue);
  });

  test('indexes instruction endings rather than truncating at 700 characters',
      () {
    final chunks = QwenSemanticKnowledgeScorer.documentChunks({
      'id': 'long',
      'title': '安装说明',
      'content': '${List.filled(1800, '前').join()}FINAL_LOADING_STEP',
    });
    expect(chunks.length, greaterThan(1));
    expect(chunks.last, contains('FINAL_LOADING_STEP'));
  });

  test(
      'invalid vectors and model failures cannot masquerade as a completed search',
      () async {
    final backend = _Backend()..invalid = true;
    final scorer =
        QwenSemanticKnowledgeScorer(cacheDirectory: root, backend: backend);
    await expectLater(
        scorer.prepare(records), throwsA(isA<SemanticSearchUnavailable>()));
    backend.invalid = false;
    await scorer.prepare(records);
    backend.fail = true;
    await expectLater(scorer.score('a fresh question', records),
        throwsA(isA<SemanticSearchUnavailable>()));
  });

  test(
      'full semantic path sees nonlexical sources beyond a candidate cap and rejects internal notes',
      () async {
    final cards = await Directory('${root.path}/rag_cards').create();
    await File('${cards.path}/customer_service_rag_cards.jsonl').writeAsString([
      for (var i = 0; i < 650; i++)
        jsonEncode({
          'id': 'lexical_$i',
          'status': 'active',
          'product_line': 'thermal_printer',
          'models': ['ZZ123'],
          'issue': 'paper paper driver',
          'reply_template': 'Printer information $i',
        }),
    ].join('\n'));
    await File('${cards.path}/source_chunks.jsonl').writeAsString([
      jsonEncode({
        'id': 'semantic_only_source',
        'source_file': 'thermal_loading_kb.md',
        'title': '介质安装',
        'product_line': 'thermal_printer',
        'content': '将耗材置于设备内部。'
      }),
      jsonEncode({
        'id': 'internal',
        'source_file': 'FLUTTER_INTEGRATION.md',
        'title': '开发者配置',
        'content': 'Do not send this to a customer.'
      }),
      jsonEncode({
        'id': 'wrong_family',
        'source_file': 'attendance_setup_kb.md',
        'product_line': 'attendance_machine',
        'content': '考勤日期设置。'
      }),
      jsonEncode({
        'id': 'wrong_model',
        'source_file': 'thermal_other_kb.md',
        'product_line': 'thermal_printer',
        'models': ['ZZ124'],
        'content': 'Other model.'
      }),
    ].join('\n'));
    final semantic = _RecordingScorer();
    final retriever =
        LocalKnowledgeRetriever(root, secondInspectionScorer: semantic);
    final result = await retriever.retrieveFullSemantic(
        'How do I insert the paper roll?\nExact product model: zz123',
        limit: 5);
    expect(semantic.seen.length, 651);
    expect(result.first['id'], 'semantic_only_source');
    expect(semantic.seen.map((r) => r['id']), isNot(contains('internal')));
    expect(semantic.seen.map((r) => r['id']), isNot(contains('wrong_family')));
    expect(semantic.seen.map((r) => r['id']), isNot(contains('wrong_model')));
    expect(semantic.queries.single, startsWith('How do I insert'));
    final filtered = await retriever
        .filterSecondInspectionEvidence('Exact product model: zz123', [
      {'id': 'wrong_family'},
      {'id': 'wrong_model'},
      {'id': 'internal'},
      {'id': 'semantic_only_source'},
    ]);
    expect(filtered.map((r) => r['id']), ['semantic_only_source']);
    semantic.fail = true;
    await expectLater(retriever.retrieveFullSemantic('query'),
        throwsA(isA<SemanticSearchUnavailable>()));
  });

  test(
      'second-inspection fusion does not let copied paragraphs occupy multiple slots',
      () {
    const body =
        'This complete approved procedure explains the loading steps for the matching printer.';
    final result = mergeSecondInspectionResults([
      [
        {'id': 'source', 'content': body},
        {'id': 'copy', 'content': body}
      ],
      [
        {'id': 'card', 'reply_template': body},
        {'id': 'other', 'content': 'Independent evidence'}
      ],
    ]);
    expect(result.length, 2);
    expect(result.first['id'], 'source');
  });
}
