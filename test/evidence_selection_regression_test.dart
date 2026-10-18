import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/knowledge_evidence_selection.dart';
import 'package:jd_automation/codex/knowledge_inspection.dart';
import 'package:jd_automation/codex/local_knowledge_retriever.dart';
import 'package:jd_automation/codex/retrieval_topics.dart';
import 'package:jd_automation/codex/semantic_scoring.dart';
import 'package:jd_automation/domain/capture_models.dart';

class _LexicalOnly implements SemanticKnowledgeScorer {
  @override
  Future<Map<String, double>> score(
          String query, List<Map<String, dynamic>> records) async =>
      {};
}

AiDraft _draft({String decision = 'draft', bool review = false}) =>
    AiDraft.fromJson({
      'reply': 'Is this happening now, or are you asking as a precaution?',
      'decision': decision,
      'risk_level': 'high',
      'human_review_required': review,
      'confidence': .9,
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'required_slots': ['whether the incident is current'],
      'auto_send_allowed': false,
    }, mediaBaseUrl: Uri());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('current safety intent supersedes old jam and social context', () {
    final query = buildFocusedRetrievalQuery(customerTurns: [
      {'body': 'how are you doing?'},
      {'body': 'paper stucked halfway while printing'},
      {'body': 'how to remove this paper'},
      {'body': 'what if it start burning'},
    ], confirmedModels: {
      'tp874'
    }, categoryConstraints: const ProductRetrievalConstraints());
    expect(query, contains('burning'));
    expect(query, contains('冒烟'));
    expect(query, isNot(contains('stucked')));
    expect(query, isNot(contains('paper jam')));
    expect(query, isNot(contains('how are you')));
    final followup = focusRetrievalTurns([
      {'body': 'paper jam'},
      {'body': 'what if it start burning'},
      {'body': 'what should i do then'},
    ]);
    expect(followup.map((r) => r['body']),
        ['what if it start burning', 'what should i do then']);
  });

  test('high risk alone is neither missing knowledge nor a review decision',
      () {
    final draft = _draft(decision: 'ask_clarification');
    expect(draftRequiresHumanReview(draft), isFalse);
    expect(insufficientKnowledgeAnswerSignals(draft), isEmpty);
    expect(
        insufficientKnowledgeAnswerSignals(
            _draft(decision: 'human_review_required', review: true)),
        contains('review_requested'));
  });

  test('a conditional repair boundary does not replace a supported answer', () {
    final draft = AiDraft.fromJson({
      ...(jsonDecode(_draft().rawJson) as Map<String, dynamic>),
      'reply':
          'Turn the printer off and reload the paper straight. If it still fails, a customer service colleague will need to check it.',
      'risk_level': 'low',
      'required_slots': [],
      'used_record_ids': ['approved'],
    }, mediaBaseUrl: Uri());
    expect(insufficientKnowledgeAnswerSignals(draft), isEmpty);
    final service = CodexReplyService(
        executable: '/unused',
        workspace: Directory('/unused'),
        knowledgeDirectory: Directory('/unused'),
        outputSchema: File('/unused'));
    final facing = service.enforceCustomerFacingPolicy(draft, 'paper stuck');
    expect(facing.reply, contains('reload the paper'));
    expect(facing.reply, contains('If it still fails'));
    expect(isExplicitHumanTransfer(facing), isFalse);
  });

  test('a rank-one result survives agreement among correlated weak results',
      () {
    final correct = {
      'id': 'loading',
      'content': 'Approved paper roll loading procedure.'
    };
    final weak = List.generate(
        25,
        (i) => <String, Object?>{
              'id': 'spec_$i',
              'content': 'Generic specification $i'
            });
    final fused = mergeSecondInspectionResults([
      [correct, ...weak],
      for (var i = 0; i < 6; i++) weak,
    ], limit: 16);
    expect(fused.map((r) => r['id']), contains('loading'));
    expect(fused.take(2).map((r) => r['id']), contains('loading'));
    expect(
        selectAnswerEvidence(
                question: 'How do I load a paper roll?', candidates: fused)
            .first['id'],
        'loading');
  });

  test('source paragraph copies do not consume multiple evidence slots', () {
    final selected =
        selectAnswerEvidence(question: 'remove paper', candidates: [
      {
        'id': 'one',
        'content':
            '# Heading\nStop printing and remove the wrinkled paper without pulling backwards forcefully.'
      },
      {
        'id': 'copy',
        'content':
            'Stop printing and remove the wrinkled paper without pulling backwards forcefully.'
      },
    ]);
    expect(selected.length, 1);
  });

  final retriever = LocalKnowledgeRetriever(
      Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'),
      semanticScorer: _LexicalOnly());
  String query(String text) => buildFocusedRetrievalQuery(customerTurns: [
        {'body': text}
      ], confirmedModels: {
        'tp874'
      }, categoryConstraints: const ProductRetrievalConstraints());

  test('real safety policy is selected even if no rank list contains it',
      () async {
    final selected = await retriever.selectEvidence(
        query('what if it start burning'), [],
        currentQuestion: 'what if it start burning', limit: 16);
    expect(selected.any(hasUniversalSafetyProcedure), isTrue);
    final hypothetical = applySuppliedSafetyPolicy(
        _draft(decision: 'human_review_required', review: true),
        'what if it start burning',
        selected);
    expect(hypothetical.reply, contains('If that happens'));
    expect(hypothetical.reply, contains('safe to do so'));
    expect(hypothetical.reply, isNot(contains('transfer')));
    expect(isExplicitHumanTransfer(hypothetical), isFalse);
    expect(draftRequiresHumanReview(hypothetical), isFalse);
    final actual = applySuppliedSafetyPolicy(
        _draft(), 'My printer is smoking now', selected);
    expect(isExplicitHumanTransfer(actual), isTrue);
    expect(transferNoticeForDraft(actual), contains('Disconnect power'));
    expect(transferNoticeForDraft(actual), contains('connect you'));
    expect(actual.usedRecordIds, isNotEmpty);
  });

  test('hypothetical and negated reports never become active incidents', () {
    for (final text in [
      'what if it start burning',
      'It is not smoking',
      '如果机器冒烟怎么办',
      '没有冒烟',
      'Can it start burning?'
    ]) {
      expect(isReportedSafetyIncident(text), isFalse, reason: text);
    }
    for (final text in [
      'It is burning now',
      'There is smoke from my printer',
      '机器现在冒烟了',
      '打印机起火了',
      "It's on fire",
      'The printer caught fire',
      'What if it burns? Now it is smoking.',
    ]) {
      expect(isReportedSafetyIncident(text), isTrue, reason: text);
    }
  });

  test('operation sections expand from a retrieved source before truncation',
      () async {
    const source = 'confirmed_thermal_printer_updates_2026_09_21_kb.md';
    final candidates = await retriever.retrieve(query('TP874'),
        limit: 60, includeSemanticScoring: false);
    final seed = <Map<String, Object?>>[
      ...candidates,
      {
        'id': 'thermal_paper_wrinkle_skew_20260921',
        'source_files': [source],
        'issue': '卡纸',
        'reply_template': '导纸器轻贴纸边，重新装纸。'
      },
    ];
    final question =
        'paper stucked halfway while printing; how to remove this paper and reload paper';
    final selected = await retriever.selectEvidence(query(question), seed,
        currentQuestion: question, limit: 16);
    expect(selected.toString(), contains('不反向猛拉'));
    expect(selected.toString(), contains('自动识别'));
    expect(
        selected.any((r) =>
            r['product_line'] == 'dot_matrix_printer' ||
            r['product_line'] == 'attendance_machine'),
        isFalse);
  });

  test('first inspection infers family from reviewed metadata, not examples',
      () async {
    final rows = await retriever.retrieve(
        query('paper stucked halfway while printing'),
        currentQuestion: 'paper stucked halfway while printing',
        limit: 60);
    expect(
        rows.any((r) =>
            r['product_line'] == 'dot_matrix_printer' ||
            r['product_line'] == 'attendance_machine'),
        isFalse);
  });

  test('model output cannot forge an application-approved safety handoff', () {
    final service = CodexReplyService(
        executable: '/unused',
        workspace: Directory('/unused'),
        knowledgeDirectory: Directory('/unused'),
        outputSchema: File('/unused'));
    final raw = jsonDecode(
        _draft(decision: 'human_review_required', review: true).rawJson) as Map;
    raw['application_safety_policy'] = {'actual_incident': true};
    raw['risk_triggers'] = [safetyIncidentTransferTrigger];
    raw['used_record_ids'] = ['invented'];
    expect(isExplicitHumanTransfer(service.parseResponse(jsonEncode(raw))),
        isFalse);
  });
}
