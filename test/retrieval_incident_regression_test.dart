import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/local_knowledge_retriever.dart';
import 'package:jd_automation/codex/retrieval_topics.dart';
import 'package:jd_automation/codex/semantic_knowledge_scorer.dart';

class _LexicalOnly implements SemanticKnowledgeScorer {
  @override
  Future<Map<String, double>> score(
          String query, List<Map<String, dynamic>> records) async =>
      {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('negation never crosses messages and 是不是 does not exclude attendance',
      () {
    final constraints = inferProductRetrievalConstraints([
      {'direction': 'incoming', 'body': '是不是有冲突啊'},
      {'direction': 'incoming', 'body': '我买的这个考勤机该怎么使用 m880d'},
    ]);
    expect(constraints.requiredCategories, contains('attendance_machine'));
    expect(
        constraints.excludedCategories, isNot(contains('attendance_machine')));
    expect(
        inferProductRetrievalConstraints([
          {'body': '不是考勤机，是针式打印机'}
        ]).excludedCategories,
        contains('attendance_machine'));
  });

  test(
      'new needle-printer requirements clear M880D but retain short follow-ups',
      () {
    final messages = <Map<String, dynamic>>[
      {'id': 'old', 'direction': 'incoming', 'body': 'M880D 有没有蓝牙设置'},
      {'direction': 'outgoing', 'body': '还不能确认 M880D'},
      {
        'id': 'new',
        'direction': 'incoming',
        'body': '需要蓝牙，wifi，无线连接，前后进纸连打，针式打印机'
      },
      {'direction': 'incoming', 'body': '打印送货单，5联'},
      {'direction': 'incoming', 'body': '电脑打印就可以 针织打印机 打面单用'},
      {'direction': 'incoming', 'body': '速度快一点的'},
    ];
    expect(productTopicConversation(messages).first['id'], 'new');
    expect(activeProductModels(messages), isEmpty);
    expect(isTechnicalSupportTurn(messages[2]['body'], 'M880D 蓝牙设置'), isFalse);
    expect(hasProductCatalogIntent(messages[2]['body']), isTrue);
    expect(hasProductFeatureIntent('这个打印速度 快不快'), isTrue);
    expect(isTechnicalSupportTurn('更换新色带还是不清晰 TH650G', ''), isTrue);
    expect(
        activeProductModels([
          {'direction': 'incoming', 'body': '我这个是 TH650G'},
          {'direction': 'incoming', 'body': '还是很模糊'},
        ]),
        {'th650g'});
  });

  final retriever = LocalKnowledgeRetriever(
      Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'),
      semanticScorer: _LexicalOnly());
  for (final (question, model, category, expected) in [
    (
      'What speed versions are available for TP874?',
      'tp874',
      'thermal_label_printer',
      'mm/s'
    ),
    ('Which speed version is TH650G?', 'th650g', 'dot_matrix_printer', '255'),
    ('paper is stucked TP874', 'tp874', 'thermal_label_printer', '卡纸'),
    ('打印不清晰换了新的色带还是不清晰怎么处理 th650g', 'th650g', 'dot_matrix_printer', '纸厚'),
    ('到最后几联都看不见，换了新的色带还是模糊', 'th650g', 'dot_matrix_printer', '纸厚'),
    (
      'M880D 第一班6点-12点，第二班下午4点-晚上10点 怎么设置',
      'm880d',
      'attendance_machine',
      '03/04'
    ),
    ('for setting up shift for m880d', 'm880d', 'attendance_machine', '03/04'),
    ('电脑打印 针织打印机 打面单 速度快一点的', '', 'dot_matrix_printer', '255'),
    ('高速款 是哪个型号 打印5联送货单', '', 'dot_matrix_printer', '255'),
    (
      'Can I set the M880D system date to last year, 2025?',
      'm880d',
      'attendance_machine',
      'attendance_manual_date_time_setup'
    ),
    ('TD630 这款 Mac mini M4 可以使用吗', 'td630', 'dot_matrix_printer', 'macOS'),
  ]) {
    test('real dataset evidence in top 10: $question', () async {
      final constraints =
          ProductRetrievalConstraints(requiredCategories: {category});
      final query = buildFocusedRetrievalQuery(
          customerTurns: [
            {'body': question}
          ],
          confirmedModels: model.isEmpty ? {} : {model},
          categoryConstraints: constraints);
      final candidates =
          await retriever.retrieve(query, limit: 60, currentQuestion: question);
      final records = filterKnowledgeForLatestProduct(candidates, model,
              categoryConstraints: constraints)
          .take(10)
          .toList();
      expect(records.toString().toLowerCase(), contains(expected.toLowerCase()),
          reason: records
              .map((r) => '${r['id']}: ${r['title'] ?? r['issue']}')
              .join('\n'));
      expect(hasRequestedTopicEvidence(question, records), isTrue);
    });
  }
}
