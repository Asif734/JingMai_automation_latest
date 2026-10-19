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
      'TP874有货吗',
      'where can i get this?',
      'Where can I buy this ribbon?',
      'How can I buy this?',
      '这个在哪里买？',
      '纸卷哪里买？',
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
    for (final text in [
      'Where can I get the driver?',
      'Where can I get this repaired?',
      'Where can I buy this? It is burning now.'
    ]) {
      expect(isPurchaseLocationQuery(text), isFalse, reason: text);
    }
    for (final text in [
      'how fast does it print?',
      'what type of printer is this?',
      'how much does it cost?',
      '这个多少钱？'
    ]) {
      expect(isGeneralProductInquiry(text), isTrue, reason: text);
      expect(isTechnicalSupportTurn(text, 'paper stuck, printer not working'),
          isFalse,
          reason: text);
    }
    expect(isGeneralProductInquiry('how do I connect this printer?'), isFalse);
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
        expect(result.reply, contains('our JD store'));
      } else {
        expect(result.usedRecordIds, ['product_model_feature_catalog']);
      }
      expect((jsonDecode(result.rawJson) as Map)['risk_triggers'], isEmpty);
    }
  });

  test('all reply paths reject requests for customer product pages or links',
      () {
    final service = CodexReplyService(
        executable: '/unused',
        workspace: Directory('/unused'),
        knowledgeDirectory: Directory('/unused'),
        outputSchema: File('/unused'));
    for (final item in [
      (
        'where can i get this?',
        'Could you share the product page so I can check the exact listing?'
      ),
      ('Where can I buy this?', 'Please send me a link to this item.'),
      ('这个在哪里买？', '方便发一下商品页面吗？'),
      ('这个在哪里买？', '可以把链接发我吗？'),
    ]) {
      final draft = AiDraft.fromJson({
        'reply': item.$2,
        'decision': 'ask_clarification',
        'confidence': .9,
        'used_record_ids': [],
        'required_slots': ['product_listing'],
        'actions': [],
        'risk_level': 'low',
        'risk_triggers': [],
        'human_review_required': false,
      }, mediaBaseUrl: Uri());
      final result = service.enforceCustomerFacingPolicy(draft, item.$1);
      expect(result.reply, isNot(contains(item.$2)));
      expect(result.reply, matches(r'our JD store|我们京东店铺'));
      expect(result.reply, contains(RegExp(r'[?？]')));
      expect((jsonDecode(result.rawJson) as Map)['required_slots'],
          isNot(contains('product_listing')));
      expect(draftRequiresHumanReview(result), isFalse);
    }
  });

  test('offering an approved tutorial link is not asking for a product page',
      () {
    final service = CodexReplyService(
        executable: '/unused',
        workspace: Directory('/unused'),
        knowledgeDirectory: Directory('/unused'),
        outputSchema: File('/unused'));
    for (final reply in [
      'I can share the approved tutorial link.',
      '我可以把教程链接发给您。',
      'Please open the following tutorial link.'
    ]) {
      final draft = AiDraft.fromJson({
        'reply': '$reply\nhttps://example.test/guide.mp4',
        'decision': 'draft',
        'confidence': .9,
        'used_record_ids': ['approved_tutorial'],
        'required_slots': [],
        'actions': [],
        'risk_level': 'low',
        'risk_triggers': [],
        'human_review_required': false,
      }, mediaBaseUrl: Uri());
      final result =
          service.enforceCustomerFacingPolicy(draft, 'How do I load paper?');
      expect(result.reply, contains(reply));
      expect(result.reply, contains('https://example.test/guide.mp4'));
      expect(result.decision, 'draft');
    }
  });
}
