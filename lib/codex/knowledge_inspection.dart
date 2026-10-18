import 'dart:convert';

import '../domain/capture_models.dart';
import 'customer_media_evidence.dart';
import 'holding_replies.dart';
import 'knowledge_evidence_selection.dart';
import 'retrieval_topics.dart';

const exhaustedKnowledgeTransferTrigger =
    'knowledge_exhausted_after_second_inspection';
const safetyIncidentTransferTrigger = 'verified_safety_incident';

bool isReportedSafetyIncident(String question) {
  if (!retrievalTopics(question).contains('safety')) return false;
  final hypothetical = RegExp(
      r'\b(?:what if|if|suppose|in case|precaution|hypothetical)\b|如果|假如|万一|要是',
      caseSensitive: false);
  final negated = RegExp(
      r"\b(?:not|no|isn['’]?t|doesn['’]?t)\b[^.!?\n]{0,25}\b(?:smok|burn|fire|flame|spark)|没有.{0,8}(?:烟|焦味|着火)|没(?:有)?冒烟",
      caseSensitive: false);
  final reported = RegExp(
      r"\b(?:is|started|starts|keeps|now|actually|there is|caught)\b[^.!?\n]{0,30}\b(?:burning|smoking|smoke|fire|flames?|sparks?)\b|\b(?:it|printer|machine|device)['’]s\s+(?:on fire|burning|smoking)\b|\b(?:smoke|fire|flames?|sparks?)\b[^.!?\n]{0,25}\b(?:coming|coming out|from|now)\b|\b(?:smells? (?:like |of )?(?:burning|burnt)|burning smell (?:from|now))\b|(?:正在|已经|现在).{0,10}(?:着火|起火|冒烟|漏电)|(?:着火|起火|冒烟|漏电|烧焦味).{0,5}(?:了|中)|^(?:it |my printer |the printer )?(?:burning|smoking)[!\s]*$",
      caseSensitive: false);
  return question.split(RegExp(r'[.!?。！？\n]')).any((sentence) =>
      !hypothetical.hasMatch(sentence) &&
      !negated.hasMatch(sentence) &&
      reported.hasMatch(sentence.trim()));
}

bool hasAppliedSafetyPolicy(AiDraft draft) {
  try {
    return (jsonDecode(draft.rawJson) as Map)['application_safety_policy']
        is Map;
  } on FormatException {
    return false;
  }
}

bool isApprovedSafetyHandoff(AiDraft draft) {
  if (!hasAppliedSafetyPolicy(draft)) return false;
  final raw = jsonDecode(draft.rawJson) as Map;
  final receipt = raw['application_safety_policy'] as Map;
  return receipt['actual_incident'] == true &&
      draft.usedRecordIds.isNotEmpty &&
      (raw['risk_triggers'] as List? ?? const [])
          .contains(safetyIncidentTransferTrigger);
}

/// Only an actual, supplied universal policy enables this backstop. It never
/// manufactures a product procedure or treats a hypothetical as an incident.
AiDraft applySuppliedSafetyPolicy(
    AiDraft draft, String question, List<Map<String, Object?>> evidence) {
  if (!retrievalTopics(question).contains('safety')) return draft;
  final policies = evidence.where(hasUniversalSafetyProcedure).toList();
  if (policies.isEmpty) return draft;
  final actual = isReportedSafetyIncident(question);
  final english = !RegExp(r'[\u3400-\u9fff]').hasMatch(question);
  final guidance = english
      ? '${actual ? 'Please stop' : 'If that happens, stop'} using the printer. Disconnect power only if it is safe to do so, keep away from flammable materials, and do not power it on again or dismantle it.'
      : '${actual ? '请立即停止' : '如果出现这种情况，请立即停止'}使用打印机，在确保安全的情况下断开电源并远离可燃物，不要再次通电测试或自行拆机。';
  final raw = jsonDecode(draft.rawJson) as Map<String, dynamic>;
  raw
    ..['reply'] = actual
        ? '$guidance ${english ? 'I’ll connect you with a customer service colleague for further assistance.' : safeTransferAcknowledgement()}'
        : guidance
    ..['decision'] = actual ? 'human_review_required' : 'draft'
    ..['human_review_required'] = actual
    ..['risk_level'] = 'high'
    ..['risk_triggers'] = actual ? [safetyIncidentTransferTrigger] : <String>[]
    ..['required_slots'] = <String>[]
    ..['used_record_ids'] = [policies.first['id'].toString()]
    ..['actions'] = <Object?>[]
    ..['reason'] = actual
        ? 'Reported active safety incident; apply supplied safety policy before handoff.'
        : null
    ..['application_safety_policy'] = {
      'actual_incident': actual,
      'record_id': policies.first['id'],
    };
  return AiDraft.fromJson(raw.cast<String, Object?>(), mediaBaseUrl: Uri());
}

String transferNoticeForDraft(AiDraft draft) =>
    isApprovedSafetyHandoff(draft) && !containsInternalCaptureText(draft.reply)
        ? draft.reply
        : safeTransferAcknowledgement();

bool isConditionalEscalationSentence(String text) =>
    RegExp(r'^(?:if\b|only if\b|when\b|若|如果|如仍|仍然|仍无法)', caseSensitive: false)
        .hasMatch(text.trim()) &&
    RegExp(r'colleague|repair|service inspection|客服同事|维修|售后检查',
            caseSensitive: false)
        .hasMatch(text);

/// A completed first attempt, not a model-supplied authorization to transfer.
class KnowledgeInspectionContext {
  const KnowledgeInspectionContext(
      {required this.reply,
      required this.signals,
      required this.queries,
      required this.recordIds,
      required this.mediaDescriptions});
  final String reply;
  final List<String> signals;
  final List<String> queries;
  final Set<String> recordIds;
  final Map<String, String> mediaDescriptions;
}

/// Route-independent: a deferral returned as an ordinary draft is still a
/// failed answer. A real, decisive clarification is a valid next step.
List<String> insufficientKnowledgeAnswerSignals(AiDraft draft) {
  final raw = jsonDecode(draft.rawJson) as Map<String, dynamic>;
  final signals = <String>[];
  if (draft.decision == 'human_review_required' ||
      raw['human_review_required'] == true) {
    signals.add('review_requested');
  }
  final unavailable = RegExp(
      r"\b(?:i|we)\s+(?:(?:do not|don['’]?t) have|(?:cannot|can['’]?t|am unable to|are unable to) (?:confirm|verify|find|provide|resolve|solve|determine))\b|\b(?:not|isn['’]?t|wasn['’]?t) (?:confirmed|documented|available|verified|listed)\b|\bno (?:matching|verified|confirmed|available|reliable|supported) (?:answer|solution|instructions?|information|video|tutorial|link|record)\b|\b(?:missing|insufficient|lacks?) (?:verified |reliable |product |required )?(?:knowledge|information|evidence|instructions?)\b|(?:尚未|暂未|未能|无法|不能|还不能)(?:准确)?(?:确认|核实|提供|解决|判断)|(?:暂无|没有|缺少|不足以|还没有)(?:可确认的|可核实的|匹配的|相关的|准确的|可靠的)?(?:资料|信息|答案|方案|步骤|教程|链接|型号)|(?:资料|信息)(?:还)?不足",
      caseSensitive: false);
  if (unavailable.hasMatch(draft.reply)) signals.add('answer_not_found');
  if (RegExp(
          r'(?:还没有|暂无|没有|缺少)(?:可确认的|可核实的|可靠的)?[^。！？\n]{0,30}(?:型号|速度参数|资料|信息|方案|教程|链接)|进一步(?:准确)?(?:核对|确认|核实)',
          caseSensitive: false)
      .hasMatch(draft.reply)) {
    signals.add('missing_answer_or_further_check');
  }
  final colleagueDeferral = RegExp(
      r'\b(?:needs?|requires?)\b[^.!?\n]{0,70}\b(?:colleague|technical review|further review|checking|confirmation)\b|\b(?:request|ask|arrange|seek|need)\b[^.!?\n]{0,45}\b(?:technical review|colleague|technical team)\b|(?:需要|请|交给|转给)[^。！？\n]{0,20}(?:客服同事|其他客服|技术同事|技术人员)|(?:客服同事|技术同事)[^。！？\n]{0,20}(?:核实|检查|协助|处理|确认)|(?:需要|还需|正在)[^。！？\n]{0,12}(?:进一步核对|进一步确认|进一步核实)',
      caseSensitive: false);
  final deferralText = draft.usedRecordIds.isNotEmpty &&
          draft.decision != 'human_review_required'
      ? RegExp(r'[^.!?。！？]+[.!?。！？]?')
          .allMatches(draft.reply)
          .map((m) => m.group(0)!.trim())
          .where((sentence) => !isConditionalEscalationSentence(sentence))
          .join(' ')
      : draft.reply;
  if (colleagueDeferral.hasMatch(deferralText)) {
    signals.add('colleague_or_checking_deferral');
  }
  if ([...chineseHoldingReplies, ...positiveSupportFallbackReplies].any(
      (text) => draft.reply
          .replaceAll(RegExp(r'\s+'), '')
          .contains(text.replaceAll(RegExp(r'\s+'), '')))) {
    signals.add('holding_instead_of_answer');
  }
  if (RegExp(
          r'\b(?:send|share|provide)\b[^.!?\n]{0,80}\bmanual\b|(?:发|提供)[^。！？\n]{0,30}说明书',
          caseSensitive: false)
      .hasMatch(draft.reply)) {
    signals.add('requesting_store_manual_instead_of_answer');
  }
  if (containsInternalCaptureText(draft.reply)) {
    signals.add('internal_capture_text');
  }
  return signals;
}

/// Focus on the unresolved request plus same-topic customer context. The
/// second search uses alternative terminology, not the failed assistant reply
/// as evidence. Confirmed model/category constraints are appended by caller.
List<String> freshInspectionQueryTexts(
    {required String latestQuestion,
    required String customerContext,
    required List<String> plannedQueries}) {
  final latest = customerAuthoredText(latestQuestion).trim();
  final context = customerAuthoredText(customerContext).trim();
  final latestTopics = retrievalTopics(latest);
  final topics = latestTopics.isEmpty ? retrievalTopics(context) : latestTopics;
  final aliases = [
    if (topics.contains('product_availability'))
      '产品目录 型号 生命周期 Current Legacy Discontinued 在售 历史型号 库存 product catalog model availability',
    if (topics.contains('print_speed'))
      '打印速度 速度版本 高速款 标准款 低速款 cps mm/s print speed versions',
    if (topics.contains('paper_feed'))
      '卡纸 走纸停顿 进纸 打印一半 纸张检测 纸型 paper jam feed stops partway',
    if (topics.contains('paper_loading'))
      '装纸 纸卷 居中 导纸器 合盖 自动识别 paper loading reload',
    if (topics.contains('paper_removal'))
      '取出纸张 停止打印 关机 不反向猛拉 remove jammed paper',
    if (topics.contains('safety'))
      '着火 冒烟 焦味 漏电 电火花 停止使用 安全断电 burning smoke fire safety',
    if (topics.contains('print_quality')) '打印质量 字迹粗 模糊 复写不清 色带 纸厚杆 对比度 灰度阈值',
    if (topics.contains('shift_setup')) '班次设置 上下班时间 员工组 时间组 设置按键 shift setup',
    if (topics.contains('date_setup')) '日期设置 年份 时间 设置按键 date setup',
  ].join(' ');
  final texts = <String>{
    ...plannedQueries
        .map(customerAuthoredText)
        .where((q) => q.trim().isNotEmpty),
    [latest, aliases.isEmpty ? '产品资料 规格 功能 使用说明 客服确认' : aliases]
        .where((q) => q.isNotEmpty)
        .join('\n'),
    [
      context.isEmpty ? latest : context,
      aliases.isEmpty ? '官方说明 已确认规则 处理步骤 常见问题' : '$aliases 操作说明 已确认参数'
    ].where((q) => q.isNotEmpty).join('\n'),
  };
  return texts.take(4).toList(growable: false);
}
