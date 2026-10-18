import 'retrieval_topics.dart';

String evidenceBody(Map<String, Object?> record) =>
    (record['content'] ?? record['reply_template'] ?? '').toString();

String evidenceKey(Map<String, Object?> record) {
  final body = evidenceBody(record)
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('#'))
      .join(' ')
      .replaceAll(RegExp(r'[\s#*`]+'), '')
      .toLowerCase();
  return body.length >= 40 ? body : record['id'].toString();
}

/// A record appearing in many correlated query variants is not independent
/// corroboration. Preserve its best rank, with only a small agreement bonus.
List<Map<String, Object?>> fuseKnowledgeCandidates(
    List<List<Map<String, Object?>>> resultSets,
    {int limit = 60}) {
  final records = <String, Map<String, Object?>>{};
  final scores = <String, double>{};
  final agreements = <String, int>{};
  for (final results in resultSets) {
    final seen = <String>{};
    for (var rank = 0; rank < results.length; rank++) {
      final record = results[rank];
      final key = evidenceKey(record);
      if (!seen.add(key)) continue;
      records.putIfAbsent(key, () => record);
      final score = 1 / (60 + rank + 1);
      if (score > (scores[key] ?? 0)) scores[key] = score;
      agreements.update(key, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  double score(String key) =>
      scores[key]! + ((agreements[key] ?? 0) > 1 ? .0001 : 0);
  final keys = records.keys.toList()
    ..sort((a, b) => score(b).compareTo(score(a)));
  return keys.take(limit).map((key) => records[key]!).toList();
}

Set<String> evidenceTopics(Map<String, Object?> record) =>
    retrievalTopics('${record['title'] ?? ''} ${record['issue'] ?? ''}\n'
        '${evidenceBody(record)} ${record['safety_reply_rule'] ?? ''}');

bool hasUniversalSafetyProcedure(Map<String, Object?> record) {
  final body = evidenceBody(record);
  // These are evidence checks, not model-name or knowledge-record ID lists.
  return RegExp(r'着火|起火').hasMatch(body) &&
      body.contains('冒烟') &&
      RegExp(r'停止使用|停止操作').hasMatch(body) &&
      body.contains('断电') &&
      body.contains('可燃物');
}

/// Check operation coverage before spending the bounded evidence budget.
/// Model/category applicability is enforced by the caller before this stage.
List<Map<String, Object?>> selectAnswerEvidence({
  required String question,
  required List<Map<String, Object?>> candidates,
  List<Map<String, Object?>> mandatory = const [],
  int limit = 16,
}) {
  final topics = retrievalTopics(question);
  final unique = <String, Map<String, Object?>>{};
  for (final record in [...mandatory, ...candidates]) {
    unique.putIfAbsent(evidenceKey(record), () => record);
  }
  final rows = unique.values.toList();
  final positions = {
    for (var i = 0; i < rows.length; i++) evidenceKey(rows[i]): i
  };
  double relevance(Map<String, Object?> record) {
    final overlap = evidenceTopics(record).intersection(topics).length;
    final primary =
        retrievalTopics('${record['title'] ?? ''} ${record['issue'] ?? ''}')
            .intersection(topics)
            .length;
    return overlap * 20 +
        primary * 10 +
        1 / (1 + positions[evidenceKey(record)]!);
  }

  rows.sort((a, b) => relevance(b).compareTo(relevance(a)));
  final selected = <Map<String, Object?>>[];
  final seen = <String>{};
  void add(Map<String, Object?> record) {
    if (selected.length < limit && seen.add(evidenceKey(record))) {
      selected.add(record);
    }
  }

  for (final record in mandatory) {
    add(record);
  }
  // A multi-part operation needs at least one passage for each part. Repeated
  // model/specification cards cannot crowd all procedure sections out.
  for (final topic in topics) {
    if (selected.any((r) => evidenceTopics(r).contains(topic))) continue;
    for (final record in rows) {
      if (evidenceTopics(record).contains(topic)) {
        add(record);
        break;
      }
    }
  }
  for (final record in rows) {
    add(record);
  }
  return selected;
}
