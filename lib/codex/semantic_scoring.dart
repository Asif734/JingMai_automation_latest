abstract class SemanticKnowledgeScorer {
  Future<Map<String, double>> score(
      String query, List<Map<String, dynamic>> records);
}

/// A failed search is not evidence that the knowledge base has no answer.
class SemanticSearchUnavailable implements Exception {
  const SemanticSearchUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract class IndexedSemanticKnowledgeScorer
    implements SemanticKnowledgeScorer {
  Future<void> prepare(List<Map<String, dynamic>> records);
}
