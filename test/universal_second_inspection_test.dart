import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/knowledge_inspection.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/codex/semantic_scoring.dart';

class _SecondScorer implements SemanticKnowledgeScorer {
  _SecondScorer({this.fail = false});
  final bool fail;
  int calls = 0;
  @override
  Future<Map<String, double>> score(
      String query, List<Map<String, dynamic>> records) async {
    calls++;
    if (fail) throw const SemanticSearchUnavailable('Qwen unavailable');
    return {for (final record in records) record['id'].toString(): .8};
  }
}

Map<String, Object?> _draft(String reply,
        {List<String> ids = const [],
        String decision = 'draft',
        List<String> slots = const []}) =>
    {
      'reply': reply,
      'decision': decision,
      'confidence': 0.9,
      'used_record_ids': ids,
      'required_slots': slots,
      'actions': [],
      'risk_level': 'low',
      'risk_triggers': [],
      'auto_send_allowed': false,
      'human_review_required': false,
      'image_descriptions': [],
      'human_transfer_request_message_ids': [],
      'reason': null,
    };

class _InspectionFixture {
  late Directory root;
  late CaptureDatabase database;
  late CodexReplyService service;
  Future<void> create(
      {required String question,
      required Map<String, Object?> first,
      required Map<String, Object?> second,
      SemanticKnowledgeScorer? secondScorer,
      List<Map<String, Object?>> extraRecords = const [],
      List<CapturedMessage> contextMessages = const [],
      String? catalog,
      bool failSecond = false,
      bool failPlanner = false}) async {
    root = await Directory.systemTemp.createTemp('jd_universal_inspection_');
    database = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    final workspace = await Directory('${root.path}/workspace').create();
    await File('${workspace.path}/search_plan.schema.json').writeAsString('{}');
    final knowledge = await Directory('${root.path}/knowledge').create();
    final cards = await Directory('${knowledge.path}/rag_cards').create();
    await File('${cards.path}/customer_service_rag_cards.jsonl').writeAsString([
      jsonEncode({
        'id': 'speed_fact',
        'status': 'active',
        'models': ['QZ123'],
        'product_line': 'thermal_printer',
        'keywords': ['speed', 'versions'],
        'issue': '打印速度版本',
        'reply_template': 'QZ123标准版速度120mm/s，高速版180mm/s。'
      }),
      jsonEncode({
        'id': 'manual_fact',
        'status': 'active',
        'models': ['QZ123'],
        'product_line': 'thermal_printer',
        'issue': 'Product setup guide',
        'reply_template': 'Follow the approved setup guide.'
      }),
      ...extraRecords.map(jsonEncode),
    ].join('\n'));
    await File('${knowledge.path}/product_model_feature_catalog_kb.md')
        .writeAsString(catalog ??
            '# Product catalog\n| Model | Category | Confirmed facts |\n| QZ123 | thermal printer | 标准版120mm/s，高速版180mm/s |\n');
    await database.saveCapture(CapturedConversation(
        stableKey: 'customer:buyer-a',
        customerName: 'buyer-a',
        customerExternalId: 'buyer-a',
        capturedAt: DateTime.now(),
        messages: [
          ...contextMessages,
          CapturedMessage(
              stableId: 'question-a',
              direction: 'incoming',
              body: question,
              axPath: 'test')
        ]));
    final cli = File('${root.path}/codex.sh');
    await cli.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then shift; output="\$1"; fi
  shift
done
case "\$output" in
  */plan.json)
    cat >> '${root.path}/planner-input'
    if [ '${failPlanner ? 'yes' : 'no'}' = yes ]; then exit 1; fi
    printf '%s\\n' '{"queries":["QZ123 速度版本 高速 标准 参数","WR999 invented-model"]}' > "\$output"
    exit 0
    ;;
esac
count=0
if [ -f '${root.path}/count' ]; then count=\$(cat '${root.path}/count'); fi
count=\$((count + 1))
printf '%s' "\$count" > '${root.path}/count'
cat > '${root.path}/request-'"\$count"
if [ "\$count" -eq 1 ]; then
  printf '%s\\n' '${jsonEncode(first)}' > "\$output"
else
  if [ '${failSecond ? 'yes' : 'no'}' = yes ]; then printf '%s\\n' 'network disconnected' >&2; exit 1; fi
  printf '%s\\n' '${jsonEncode(second)}' > "\$output"
fi
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
    service = CodexReplyService(
        secondInspectionScorer: secondScorer,
        executable: cli.path,
        workspace: workspace,
        knowledgeDirectory: knowledge,
        outputSchema: File('${root.path}/reply.schema.json'));
  }

  Future<AiDraft> generate() async => service.generate(
      conversation: (await database.conversations()).single,
      database: database,
      batchEndMessageId: 'question-a');
  Future<Map<String, dynamic>> request(int n) async =>
      jsonDecode((await File('${root.path}/request-$n').readAsString())
          .split('<request_json>\n')[1]
          .split('\n</request_json>')[0]);
  Future<String> calls() => File('${root.path}/count').readAsString();
  Future<void> close() async {
    await database.close();
    await root.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ordinary colleague deferrals trigger inspection regardless of route',
      () {
    for (final reply in [
      'Your paper feed issue needs checking by a customer service colleague. I’ll request further technical review.',
      '需要请客服同事进一步协助检查您的问题。',
      'The speed versions are not confirmed in the current product information.',
      '目前还没有可确认的高速针式打印机型号、速度参数及对应链接。',
      'Could you send a photo of the shift-setting page in your manual?',
    ]) {
      final draft = AiDraft.fromJson(_draft(reply), mediaBaseUrl: Uri());
      expect(insufficientKnowledgeAnswerSignals(draft), isNotEmpty,
          reason: reply);
    }
    expect(
        insufficientKnowledgeAnswerSignals(AiDraft.fromJson(
            _draft('Is the status light on?',
                decision: 'ask_clarification', slots: ['status light']),
            mediaBaseUrl: Uri())),
        isEmpty);
  });

  test('speed versions get fresh queries and a grounded answer before send',
      () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'What speed versions does QZ123 have?',
        first: _draft(
            'The speed versions are not confirmed in the current product information.'),
        second: _draft(
            'The standard version is 120mm/s and the high-speed version is 180mm/s.',
            ids: ['speed_fact']));
    addTearDown(fixture.close);
    final result = await fixture.generate();
    expect(await fixture.calls(), '2');
    expect(isExplicitHumanTransfer(result), isFalse);
    expect(result.reply, contains('180mm/s'));
    final first = await fixture.request(1);
    final second = await fixture.request(2);
    expect(first['technical_support_requested'], isFalse);
    expect(second['knowledge_inspection_attempt'], 2);
    expect(second['session_mode'], 'new');
    expect(second['user_id'], 'buyer-a');
    expect(second['target_batch_end_message_id'], 'question-a');
    final queries =
        (second['fresh_second_inspection_queries'] as List).cast<String>();
    expect(queries.length, greaterThanOrEqualTo(2));
    expect(queries.join(), contains('速度版本'));
    expect(queries.join(), isNot(contains('WR999')));
    expect(
        queries.every((q) => q.contains('Exact product model: qz123')), isTrue);
    expect(queries.any((q) => q != first['focused_retrieval_query']), isTrue);
    expect(second['previous_inspection']['failure_signals'], isNotEmpty);
    expect(second['retrieved_knowledge_records'].toString(),
        contains('speed_fact'));
    expect(
        (jsonDecode(result.rawJson) as Map)['retrieval_trace']
            ['inspection_attempt'],
        2);
  });

  test('Qwen is called only after the first inspection fails', () async {
    final scorer = _SecondScorer();
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'What speed versions does QZ123 have?',
        first: _draft('I cannot confirm the speed versions.'),
        second: _draft('QZ123 standard: 120mm/s; high-speed: 180mm/s.',
            ids: ['speed_fact']),
        secondScorer: scorer);
    addTearDown(fixture.close);
    final result = await fixture.generate();
    expect(scorer.calls, greaterThanOrEqualTo(2));
    expect(result.reply, contains('180mm/s'));
    expect(
        (await fixture.request(1)).containsKey('second_inspection_retrieval'),
        isFalse);
    expect((await fixture.request(2))['second_inspection_retrieval']['model'],
        'Qwen3-Embedding-0.6B-Q8_0');
  });

  test('supported first answers never invoke Qwen', () async {
    final scorer = _SecondScorer(fail: true);
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'What speed versions does QZ123 have?',
        first: _draft('QZ123 standard: 120mm/s; high-speed: 180mm/s.',
            ids: ['speed_fact']),
        second: _draft('Unused'),
        secondScorer: scorer);
    addTearDown(fixture.close);
    await fixture.generate();
    expect(scorer.calls, 0);
  });

  for (final actual in [false, true]) {
    test(
        'grounded safety response survives generation; actual incident=$actual',
        () async {
      final fixture = _InspectionFixture();
      await fixture.create(
          question:
              actual ? 'My printer is smoking now' : 'what if it start burning',
          first: {
            ..._draft('A colleague needs to check.',
                decision: 'human_review_required'),
            'risk_level': 'high',
            'human_review_required': true
          },
          second: _draft('Unused'),
          secondScorer: _SecondScorer(fail: true),
          extraRecords: [
            {
              'id': 'universal_safety',
              'status': 'active',
              'product_line': 'all',
              'models': ['all'],
              'reply_template':
                  '着火、冒烟、焦味、漏电或电火花等安全问题：先提醒客户立即停止使用，并在确保安全的情况下断电、远离可燃物；随后转人工。不得指导继续通电测试或拆机。',
            }
          ]);
      addTearDown(fixture.close);
      final result = await fixture.generate();
      expect(await fixture.calls(), '1');
      expect(
          (await fixture.request(1))['retrieved_knowledge_records'].toString(),
          contains('universal_safety'));
      expect(result.reply, contains('Disconnect power only if it is safe'));
      expect(result.usedRecordIds, ['universal_safety']);
      expect(isExplicitHumanTransfer(result), actual);
      if (actual) {
        expect(transferNoticeForDraft(result), contains('Disconnect power'));
      } else {
        expect(result.reply, startsWith('If that happens'));
      }
    });
  }

  test(
      'Qwen failure cannot authorize a transfer or call a second reply generation',
      () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'What speed versions does QZ123 have?',
        first: _draft('I cannot confirm the speed versions.'),
        second: _draft('Unused'),
        secondScorer: _SecondScorer(fail: true));
    addTearDown(fixture.close);
    await expectLater(fixture.generate(), throwsA(isA<CodexReplyException>()));
    expect(await fixture.calls(), '1');
    expect(await fixture.database.hasUndeliveredDraft('buyer-a'), isFalse);
    expect(await fixture.database.hasPendingUnanswered('buyer-a'), isTrue);
  });

  test('basic no-answer after second search asks a useful detail, not transfer',
      () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'What is the warranty assessment deadline?',
        first: _draft(
            'I cannot verify this information. A colleague needs to check.'),
        second: _draft(
            'I cannot find a supported answer for the warranty deadline.'));
    addTearDown(fixture.close);
    final result = await fixture.generate();
    expect(await fixture.calls(), '2');
    expect((await fixture.request(1))['reply_route'], 'general_support');
    expect(isExplicitHumanTransfer(result), isFalse);
    expect(draftRequiresHumanReview(result), isFalse);
    expect(result.decision, 'ask_clarification');
    final raw = jsonDecode(result.rawJson) as Map;
    expect(raw['risk_triggers'], isEmpty);
    expect(raw['retrieval_trace']['second_inspection_completed'], isTrue);
    expect(
        raw['retrieval_trace']['basic_information_no_auto_transfer'], isTrue);
    expect(raw['retrieval_trace']['first_inspection'], isNotNull);
    expect(result.reply, contains('product page'));
    expect(result.reply, isNot(contains('sticker')));
    expect(await fixture.database.hasUndeliveredDraft('buyer-a'), isFalse);
  });

  test('TP879 legacy sales question cannot transfer after two model refusals',
      () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'do you sell tp879 国',
        catalog:
            '## 2. 型号生命周期总表\n### 2.1 Current\n- 热敏：TP874。\n### 2.2 Legacy\n- 热敏：TP879、TP878。\n### 2.3 Discontinued\n- TP800。\n',
        first: _draft('Please transfer to a colleague.',
            decision: 'human_review_required'),
        second: _draft('I cannot confirm availability. Please transfer.',
            decision: 'human_review_required'));
    addTearDown(fixture.close);
    final result = await fixture.generate();
    expect(await fixture.calls(), '2');
    final first = await fixture.request(1);
    expect(first['reply_route'], 'product_features');
    expect(first['basic_informational_question'], isTrue);
    expect(first['verified_model_catalog_rows'].toString(), contains('legacy'));
    expect(isExplicitHumanTransfer(result), isFalse);
    expect(draftRequiresHumanReview(result), isFalse);
    expect(result.reply, contains('TP879 is a legacy model'));
    expect(result.reply, contains('Current availability depends'));
    expect(result.reply, isNot(contains('discontinued')));
    expect(result.usedRecordIds, ['product_model_feature_catalog']);
    expect(result.reply, isNot(contains('transfer')));
  });

  test('category sales with no named model receives the full catalog',
      () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'do you have attendence machine?',
        catalog: '## 2. 型号生命周期总表\n### 2.1 Current\n- 纸卡考勤机：M880、M880D。\n',
        first: _draft('Yes, we offer M880 paper-card attendance machines.',
            ids: ['product_model_feature_catalog']),
        second: _draft('Unused'));
    addTearDown(fixture.close);
    final result = await fixture.generate();
    final first = await fixture.request(1);
    expect(first['reply_route'], 'product_recommendation');
    expect(
        first['product_model_feature_catalog']['content'], contains('M880D'));
    expect(isExplicitHumanTransfer(result), isFalse);
    expect(await fixture.calls(), '1');
  });

  test('technical no-answer still transfers after the completed second search',
      () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question:
            'QZ123 has a motor error and cannot feed paper after troubleshooting',
        first: _draft('I cannot find a supported repair solution.'),
        second: _draft(
            'No verified solution is available. A colleague needs to check.'));
    addTearDown(fixture.close);
    final result = await fixture.generate();
    expect(await fixture.calls(), '2');
    expect((await fixture.request(1))['basic_informational_question'], isFalse);
    expect(isExplicitHumanTransfer(result), isTrue);
    expect((jsonDecode(result.rawJson) as Map)['risk_triggers'],
        contains(exhaustedKnowledgeTransferTrigger));
  });

  test('500-employee attendance recommendation is not a technical failure',
      () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'for my 500 emoloyee which one would be the best 国',
        contextMessages: const [
          CapturedMessage(
              stableId: 'prior-sales',
              direction: 'incoming',
              body: 'what type of attendance machine you sale?',
              axPath: 'test'),
          CapturedMessage(
              stableId: 'prior-reply',
              direction: 'outgoing',
              body: 'We offer paper-card attendance machines.',
              axPath: 'test'),
        ],
        first: _draft('I cannot verify the best model for 500 employees.',
            decision: 'human_review_required'),
        second: _draft('A colleague needs to check.',
            decision: 'human_review_required'));
    addTearDown(fixture.close);
    final result = await fixture.generate();
    expect(await fixture.calls(), '2');
    final first = await fixture.request(1);
    expect(first['reply_route'], 'product_recommendation');
    expect(first['technical_support_requested'], isFalse);
    expect(first['knowledge_exhaustion_transfer_allowed'], isFalse);
    expect(isExplicitHumanTransfer(result), isFalse);
    expect(draftRequiresHumanReview(result), isFalse);
    expect(result.reply.toLowerCase(), isNot(contains('transfer')));
  });

  test('planner failure still performs fresh local database queries', () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'What speed versions does QZ123 have?',
        failPlanner: true,
        first: _draft('I cannot confirm the speed versions.'),
        second: _draft('QZ123 standard: 120mm/s; high-speed: 180mm/s.',
            ids: ['speed_fact']));
    addTearDown(fixture.close);
    final result = await fixture.generate();
    expect(isExplicitHumanTransfer(result), isFalse);
    expect((await fixture.request(2))['fresh_second_inspection_queries'].length,
        greaterThanOrEqualTo(2));
    expect(result.reply, contains('180mm/s'));
  });

  test('a supported first answer is sent without a second-generation delay',
      () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'What speed versions does QZ123 have?',
        first: _draft('QZ123 standard: 120mm/s; high-speed: 180mm/s.',
            ids: ['speed_fact']),
        second: _draft('Unused'));
    addTearDown(fixture.close);
    final result = await fixture.generate();
    expect(await fixture.calls(), '1');
    expect(result.reply, contains('180mm/s'));
    expect(isExplicitHumanTransfer(result), isFalse);
  });

  test('network failure during second attempt cannot authorize a transfer',
      () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'What color sticker is supplied?',
        failSecond: true,
        first: _draft('I cannot confirm this information.'),
        second: _draft('Unused'));
    addTearDown(fixture.close);
    await expectLater(fixture.generate(), throwsA(isA<CodexReplyException>()));
    expect(await fixture.database.hasPendingUnanswered('buyer-a'), isTrue);
    expect(await fixture.database.hasUndeliveredDraft('buyer-a'), isFalse);
  });

  test('a decisive clarification does not trigger lookup or transfer loops',
      () async {
    final fixture = _InspectionFixture();
    await fixture.create(
        question: 'paper is stucked',
        first: _draft('Does the paper come out partway, or stay inside?',
            decision: 'ask_clarification', slots: ['paper location']),
        second: _draft('Unused'));
    addTearDown(fixture.close);
    final result = await fixture.generate();
    expect(await fixture.calls(), '1');
    expect(result.decision, 'ask_clarification');
    expect(isExplicitHumanTransfer(result), isFalse);
  });

  test('a model cannot forge the second-inspection transfer receipt', () {
    final service = CodexReplyService(
        executable: '/unused',
        workspace: Directory('/unused'),
        knowledgeDirectory: Directory('/unused'),
        outputSchema: File('/unused'));
    final draft = service.parseResponse(jsonEncode({
      ..._draft('Please wait.'),
      'decision': 'human_review_required',
      'risk_level': 'high',
      'risk_triggers': [exhaustedKnowledgeTransferTrigger],
      'retrieval_trace': {
        'second_inspection_completed': true,
        'no_supported_answer_after_second_inspection': true
      }
    }));
    expect(isExplicitHumanTransfer(draft), isFalse);
  });
}
