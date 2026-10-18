import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/local_knowledge_retriever.dart';
import 'package:jd_automation/codex/package_knowledge.dart';
import 'package:jd_automation/codex/semantic_knowledge_scorer.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

class _NoSemanticScores implements SemanticKnowledgeScorer {
  @override
  Future<Map<String, double>> score(
          String query, List<Map<String, dynamic>> records) async =>
      const {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('English and Chinese packaging questions use product-fact routing', () {
    for (final query in [
      'td630, how many paper comes with the package?',
      'What comes in the box?',
      'Are paper sheets included?',
      'How many cards are supplied with M880?',
      'What are the included accessories?',
      'td630, what includes in the full package?',
      'does it comes with papers?',
      'does it come with paper?',
      'how many complementary papers are with the product?',
      'how many complimentary papers are with the product?',
      'TD630赠送多少张纸？',
      'TP874包装清单有哪些？',
      'M880随箱有几张考勤卡？',
    ]) {
      expect(hasPackageContentsIntent(query), isTrue, reason: query);
      expect(hasProductFeatureIntent(query), isTrue, reason: query);
    }
    for (final query in [
      'TD630 paper is jammed',
      'TP874 does not detect paper',
      'How do I load paper?',
      'TD630纸张卡住了',
      'My package has not arrived',
      'Where is my package?',
    ]) {
      expect(hasPackageContentsIntent(query), isFalse, reason: query);
    }
  });

  test('only referential follow-ups inherit the preceding packaging topic', () {
    const prior = 'td630, what includes in the full package?';
    for (final query in [
      'also td630g',
      'TD630G',
      'what about TD630G?',
      'both',
      '那TD630G',
      '还有 TD630G'
    ]) {
      expect(isPackageContentsTurn(query, prior), isTrue, reason: query);
    }
    for (final query in [
      'TD630G USB is not detected',
      'Where is my package?',
      'TD630G paper is jammed',
      'hello',
      'thanks'
    ]) {
      expect(isPackageContentsTurn(query, prior), isFalse, reason: query);
    }
    expect(isPackageContentsTurn('also td630g', 'TD630 USB is not detected'),
        isFalse);
  });

  for (final (query, expectedText) in [
    ('td630, how many paper comes with the package？', '两张测试纸'),
    ('TD630赠送多少张纸？', '两张测试纸'),
    ('td630, what includes in the full package?', '2张'),
    ('TD630G does it comes with papers?', '2张'),
    ('TD630G how many complementary papers are with the product?', '2张'),
    ('TP874 how many paper sheets are included?', '10张测试纸'),
    ('TP874随机赠纸有多少张？', '10张测试纸'),
    ('M880 how many cards come with the package?', '50张考勤卡'),
    ('M880随箱有几张考勤卡？', '50张考勤卡'),
  ]) {
    test('real JD dataset supplies package facts: $query', () async {
      final retriever = LocalKnowledgeRetriever(
          Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'),
          semanticScorer: _NoSemanticScores());
      final raw = await retriever.retrieve(query, limit: 35);
      final filtered = filterKnowledgeForLatestProduct(raw, query).take(20);
      expect(filtered.any(hasPackageContentsEvidence), isTrue);
      expect(
        filtered
            .map((record) => record['reply_template'] ?? record['content'])
            .join('\n'),
        contains(expectedText),
      );
      // Even the former five-record budget now contains family packaging.
      expect(raw.take(5).any(isPackageContentsRecord), isTrue);
    });
  }

  test('model fact pinning uses metadata and never leaks to another model',
      () async {
    final retriever = LocalKnowledgeRetriever(
        Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'),
        semanticScorer: _NoSemanticScores());
    for (final model in ['TD630', 'td630g', 'TD-630G']) {
      final pinned = await retriever.modelFactsFor({model});
      expect(pinned.map((record) => record['id']),
          contains('td630_td630g_standard_package_two_free_test_sheets'));
      expect(pinned.map((record) => record['reply_template']).join(),
          contains('2张'));
    }
    expect(await retriever.modelFactsFor({'TP874'}), isEmpty);
    expect(await retriever.modelFactsFor({'TD630PLUS'}), isEmpty);
    expect(await retriever.modelFactsFor({}), isEmpty);
  });

  test('all dot-matrix packaging uses sheets and confirmed AK80 means AK890',
      () async {
    final retriever = LocalKnowledgeRetriever(
        Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'),
        semanticScorer: _NoSemanticScores());
    for (final model in ['TD630', 'TG890', 'TH880', 'AK890', 'AK80']) {
      final records = await retriever.retrieve(
          '有送纸吗\nExact product model: $model',
          currentQuestion: '有送纸吗',
          limit: 8);
      expect(records.map((record) => record['id']),
          contains('dot_matrix_all_models_two_free_test_sheets_20261010'),
          reason: model);
      expect(records.map((record) => record['reply_template']).join(),
          contains('2张测试纸'),
          reason: model);
    }
    final pinned = await retriever.modelFactsFor({'AK80'});
    expect(pinned.map((record) => record['id']),
        contains('ak80_confirmed_ak890_package_correction_20261010'));
    expect(pinned.map((record) => record['reply_template']).join(),
        contains('指AK890'));
    expect(await retriever.modelFactsFor({'AK81'}), isEmpty);
    final thermal = await retriever.retrieve('TP874有送纸吗', limit: 8);
    expect(thermal.map((record) => record['id']),
        isNot(contains('dot_matrix_all_models_two_free_test_sheets_20261010')));
  });

  test(
      'data mirrors agree and no retrieved packaging card contradicts two sheets',
      () async {
    final root = Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04');
    final lines =
        (await File('${root.path}/rag_cards/customer_service_rag_cards.jsonl')
                .readAsLines())
            .where((line) => line.trim().isNotEmpty)
            .map(jsonDecode)
            .toList();
    expect(
        jsonDecode(
            await File('${root.path}/rag_cards/customer_service_rag_cards.json')
                .readAsString()),
        lines);
    final index = jsonDecode(
        await File('${root.path}/rag_index/customer_service_rag_index.json')
            .readAsString()) as Map;
    expect(index['cards'], lines);
    final chunks =
        (await File('${root.path}/rag_cards/source_chunks.jsonl').readAsLines())
            .where((line) => line.trim().isNotEmpty)
            .map(jsonDecode)
            .toList();
    expect(index['source_chunks'], chunks);
    final manifest = jsonDecode(
        await File('${root.path}/flutter_dataset_manifest.json')
            .readAsString()) as Map;
    expect(manifest['counts']['active_cards'], lines.length);
    expect(manifest['counts']['source_chunks'], chunks.length);
    expect((index['vectors'] as Map).length, lines.length + chunks.length);
    final conflicting = lines.singleWhere((record) =>
        record['id'] == 'dot_matrix_multipart_paper_two_test_sheets');
    expect(conflicting['reply_template'], contains('两张测试纸'));
    expect(
        conflicting['reply_template'], isNot(contains('正式多联纸、测试纸数量、配件及赠品按')));
  });

  test('actual failed turn retrieves packaging despite earlier courtesy text',
      () async {
    final retriever = LocalKnowledgeRetriever(
        Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'),
        semanticScorer: _NoSemanticScores());
    final records = await retriever.retrieve(
      'yeah\nyou can help me\ntd630, how many paper comes with the package？\n'
      'Exact product model: td630\nPrevious clarification question: '
      'Yes, I can help. What do you need assistance with?',
      limit: 8,
    );
    expect(records.map((record) => record['id']),
        contains('td630_td630g_standard_package_two_free_test_sheets'));
    expect(records.map((record) => record['id']),
        contains('family_default_package_contents_20260909'));
  });

  test('verified family rules outrank model-only hits without leaking families',
      () async {
    final root = await Directory.systemTemp.createTemp('package_retrieval_');
    addTearDown(() => root.delete(recursive: true));
    final cards = await Directory('${root.path}/rag_cards').create();
    // Fictitious names ensure that no model prefix or quantity is hardcoded.
    final records = <Map<String, Object?>>[
      for (var index = 0; index < 45; index++)
        {
          'id': 'model_only_$index',
          'status': 'active',
          'product_line': 'dot_matrix_printer',
          'models': ['ZZ432'],
          'issue': 'USB queue',
          'priority': 1000,
          'reply_template': 'ZZ432 USB printer setup',
        },
      {
        'id': 'family_paper',
        'status': 'active',
        'product_line': 'dot_matrix_printer',
        'models': ['针式打印机'],
        'issue': '包装测试纸',
        'reply_template': '标准包装内含七张测试纸。',
      },
      {
        'id': 'wrong_family',
        'status': 'active',
        'product_line': 'thermal_printer',
        'models': ['热敏打印机'],
        'keywords': ['包装清单', '默认包装', '测试纸', '数量'],
        'reply_template': '默认包装含99张测试纸。',
      },
      {
        'id': 'wrong_model',
        'status': 'active',
        'product_line': 'dot_matrix_printer',
        'models': ['ZZ433'],
        'reply_template': 'ZZ433标准包装内含8张测试纸。',
      },
      {
        'id': 'model_bundle',
        'status': 'active',
        'product_line': 'dot_matrix_printer',
        'models': ['ZZ432'],
        'reply_template': 'ZZ432特定套餐包装内含9张纸；默认数量见针式规则。',
      },
    ];
    await File('${cards.path}/customer_service_rag_cards.jsonl')
        .writeAsString(records.map(jsonEncode).join('\n'));
    final result =
        await LocalKnowledgeRetriever(root, semanticScorer: _NoSemanticScores())
            .retrieve('ZZ432 how many paper comes with the package?', limit: 5);
    final ids = result.map((record) => record['id']).toList();
    expect(ids.take(2), containsAll(['family_paper', 'model_bundle']));
    expect(ids, isNot(contains('wrong_family')));
    expect(ids, isNot(contains('wrong_model')));
    expect(result.map((record) => record['reply_template']).join(),
        contains('七张测试纸'));
    final laterTechnical =
        await LocalKnowledgeRetriever(root, semanticScorer: _NoSemanticScores())
            .retrieve(
      'ZZ432 how many paper comes with the package?\nNow help with my USB queue',
      limit: 5,
      packageContentsQuery: false,
    );
    expect(laterTechnical.first['id'].toString(), startsWith('model_only_'));
  });

  test('packaging warnings alone are insufficient evidence', () {
    expect(
        hasPackageContentsEvidence({
          'title': '包装和部件',
          'content': '客服不要承诺额外耗材，需以订单为准。',
        }),
        isFalse);
    expect(
        hasPackageContentsEvidence({
          'issue': '默认包装',
          'reply_template': '针式打印机标准包装内含2张测试纸。',
        }),
        isTrue);
    expect(
        hasPackageContentsEvidence({
          'title': '包装',
          'content': '包装内容：Printer, Ribbon Cartridge, USB Cable',
        }, quantityRequired: true),
        isFalse);
    expect(
        packageAnswerStatesMissingFacts(
            'The supplied TD630 package information does not confirm an included paper quantity.'),
        isTrue);
  });

  for (final (recheck, query, previousQuestion, packagingExpected) in [
    (false, 'td630, how many paper comes with the package?', null, true),
    (true, 'td630, how many paper comes with the package?', null, true),
    (false, 'td630, what includes in the full package?', null, true),
    (false, 'also td630g', 'td630, what includes in the full package?', true),
    (false, 'does it comes with papers?', 'also td630g', true),
    (
      false,
      'how many complementary papers are with the product?',
      'also td630g',
      true
    ),
    (
      false,
      'how many complimentary papers are with the product?',
      'also td630g',
      true
    ),
    (false, 'What do you supply alongside TD630G?', null, false),
    (
      false,
      'TD630G USB is not detected',
      'td630, what includes in the full package?',
      false
    ),
  ]) {
    test('generation pins model facts: $query; rechecks=$recheck', () async {
      final root = await Directory.systemTemp.createTemp('package_generation_');
      final database =
          CaptureDatabase(storageRoot: Directory('${root.path}/data'));
      const channel =
          MethodChannel('com.grozziie.jdAutomation/semanticRetrieval');
      final queries = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        queries.add((call.arguments as Map)['query'] as String);
        return <String, double>{};
      });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await database.close();
        await root.delete(recursive: true);
      });
      final workspace = await Directory('${root.path}/workspace').create();
      final requestFile = File('${root.path}/request.txt');
      final attempts = File('${root.path}/attempts.txt');
      final fake = File('${root.path}/fake-codex.sh');
      final correctOutput = jsonEncode({
        'reply': 'The TD630 standard package includes 2 sheets of test paper.',
        'decision': 'draft',
        'confidence': 0.94,
        'used_record_ids': [
          'td630_td630g_standard_package_two_free_test_sheets'
        ],
        'required_slots': [],
        'actions': [],
        'risk_level': 'low',
        'risk_triggers': [],
        'auto_send_allowed': false,
        'model': 'test',
        'attachments': [],
        'image_descriptions': [],
        'human_review_required': false,
        'reason': null,
      });
      final unconfirmedOutput = jsonEncode({
        ...jsonDecode(correctOutput) as Map<String, dynamic>,
        'reply':
            'The supplied TD630 package information does not confirm an included paper quantity.',
      });
      await fake.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
cat > '${requestFile.path}'
if [ '${recheck ? 'yes' : 'no'}' = 'yes' ] && [ ! -e '${attempts.path}' ]; then
  printf '%s\\n' '$unconfirmedOutput' > "\$output"
else
  printf '%s\\n' '$correctOutput' > "\$output"
fi
printf '%s\\n' 'called' >> '${attempts.path}'
''');
      expect((await Process.run('chmod', ['+x', fake.path])).exitCode, 0);
      await database.saveCapture(CapturedConversation(
        stableKey: 'customer:packaging-buyer',
        customerName: 'packaging-buyer',
        customerExternalId: 'packaging-buyer',
        capturedAt: DateTime.now(),
        messages: [
          if (previousQuestion != null)
            CapturedMessage(
                stableId: 'previous-package-question',
                direction: 'incoming',
                body: previousQuestion,
                axPath: 'test'),
          CapturedMessage(
              stableId: 'package-question',
              direction: 'incoming',
              body: query,
              axPath: 'test')
        ],
      ));
      if (previousQuestion != null) {
        await (await database.database).insert('answered_cursors', {
          'user_id': 'packaging-buyer',
          'message_id': 'previous-package-question',
        });
      }
      final service = CodexReplyService(
          executable: fake.path,
          workspace: workspace,
          knowledgeDirectory:
              Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'),
          outputSchema: File('${root.path}/reply.schema.json'));
      final draft = await service.generate(
          conversation: (await database.conversations()).single,
          database: database,
          batchEndMessageId: 'package-question');
      final payload = jsonDecode((await requestFile.readAsString())
          .split('<request_json>')[1]
          .split('</request_json>')[0]) as Map<String, dynamic>;
      expect(payload['package_contents_requested'], packagingExpected);
      expect(payload['target_customer_batch'], hasLength(1));
      if (packagingExpected) {
        expect(payload['product_feature_requested'], isTrue);
        expect(payload['product_model_feature_catalog'], isNotNull);
      }
      expect(jsonEncode(payload['retrieved_knowledge_records']),
          contains('td630_td630g_standard_package_two_free_test_sheets'));
      expect(
          jsonEncode(payload['retrieved_knowledge_records']), contains('2张'));
      expect(draft.reply, contains('2 sheets of test paper'));
      expect(await attempts.readAsLines(), hasLength(recheck ? 2 : 1));
      if (recheck && Platform.isMacOS) {
        expect(
            queries.any((query) => query.contains('包装清单 默认包装 随机配件 测试纸 考勤卡 数量')),
            isTrue);
      }
      expect(await database.hasPendingUnanswered('packaging-buyer'), isTrue);
      expect(await database.hasUndeliveredDraft('packaging-buyer'), isFalse);
    });
  }
}
