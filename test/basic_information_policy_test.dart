import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/retrieval_topics.dart';
import 'package:jd_automation/domain/capture_models.dart';

void main() {
  test('review drafts cannot use an empty reply to request inspection',
      () async {
    final schema = jsonDecode(
        await File('codex_workspace/reply.schema.json').readAsString()) as Map;
    expect(schema['properties']['reply']['minLength'], 2);
    final policy = await File('codex_workspace/AGENTS.md').readAsString();
    expect(policy, contains('nonempty `reply`, including review drafts'));
  });
  test('sales intent is bilingual and does not inherit old technical subjects',
      () {
    for (final text in [
      'do you sell tp879',
      'Do you carry TP874?',
      'Is TP879 in stock?',
      '有TP879吗',
      'TP874有货吗'
    ]) {
      expect(hasProductSalesIntent(text), isTrue, reason: text);
      expect(hasProductFeatureIntent(text), isTrue, reason: text);
      expect(isTechnicalSupportTurn(text, 'paper stuck halfway'), isFalse);
      final focused = focusRetrievalTurns([
        {'body': 'paper stuck halfway'},
        {'body': text}
      ]);
      expect(focused.map((m) => m['body']).toList(), [text]);
    }
    expect(hasProductContext('do you have attendence machine?'), isTrue);
    expect(
        inferProductRetrievalConstraints([
          {'body': 'do you have attendence machine?'}
        ]).requiredCategories,
        contains('attendance_machine'));
    expect(
        hasProductCatalogIntentWithContext(
            'for my 500 emoloyee which one would be the best',
            'what type of attendance machine you sale?'),
        isTrue);
  });

  test('actual catalog supplies exact TP879 legacy membership, not stock',
      () async {
    final catalog = await loadProductRecommendationCatalog(
        Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'));
    final rows = verifiedCatalogRowsForModels(catalog, {'TP879'});
    final statuses = rows.where((r) => r['catalog_status'] != null).toList();
    expect(statuses.length, 1);
    expect(statuses.single['catalog_status'], 'legacy');
    expect(statuses.single['source_row'], contains('TP879'));
    expect(verifiedCatalogRowsForModels(catalog, {'tp87'}), isEmpty);
    expect(verifiedCatalogRowsForModels(catalog, {'tp879s'}), isEmpty);
    expect(
        verifiedCatalogRowsForModels(catalog, {'tp874'})
            .where((r) => r['catalog_status'] != null)
            .single['catalog_status'],
        'current');
  });

  test('basic guard cannot authorize stock or transfers from a model refusal',
      () {
    final service = CodexReplyService(
        executable: '/unused',
        workspace: Directory('/unused'),
        knowledgeDirectory: Directory('/unused'),
        outputSchema: File('/unused'));
    for (final status in ['current', 'legacy', 'discontinued', 'unknown']) {
      final refused = AiDraft.fromJson({
        'reply': 'I will transfer you to a colleague.',
        'decision': 'human_review_required',
        'confidence': .9,
        'used_record_ids': <String>[],
        'required_slots': <String>[],
        'actions': <Object?>[],
        'risk_level': 'high',
        'risk_triggers': ['knowledge_exhausted_after_second_inspection'],
        'human_review_required': true,
      }, mediaBaseUrl: Uri());
      final result = service.enforceBasicInformationPolicy(refused,
          customerText: 'do you sell tp879',
          verifiedModelFacts: status == 'unknown'
              ? []
              : [
                  {
                    'models': 'tp879',
                    'catalog_status': status,
                  }
                ],
          approvedRecordIds: {'product_model_feature_catalog'});
      expect(isExplicitHumanTransfer(result), isFalse);
      expect(draftRequiresHumanReview(result), isFalse);
      expect(result.reply, isNot(contains('transfer')));
      expect(result.reply, isNot(contains('we sell')));
      expect(result.reply, isNot(contains('is in stock')));
      expect(result.reply, contains('?'));
      if (status == 'unknown') {
        expect(result.usedRecordIds, isEmpty);
        expect(result.reply, contains('product page'));
      } else {
        expect(result.usedRecordIds, ['product_model_feature_catalog']);
      }
      expect((jsonDecode(result.rawJson) as Map)['risk_triggers'], isEmpty);
    }
  });
}
