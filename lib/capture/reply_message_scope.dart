/// Generated answers acknowledge their frozen input batch, not every customer
/// message that happened to arrive before the actual Send click.
bool isConfirmedOutgoingReply(Map<String, dynamic> reply) =>
    reply['direction'] == 'outgoing' &&
    reply['source'] != 'sla_fallback' &&
    reply['quarantined'] != true &&
    reply['delivery_status'] == 'sent' &&
    DateTime.tryParse(reply['sent_at']?.toString() ?? '') != null &&
    (reply['body']?.toString().trim().isNotEmpty ?? false);

String? generatedReplyBatchEnd(Map<String, dynamic> reply) {
  final metadata = reply['reply_metadata'];
  final raw = metadata is Map ? metadata['raw_response'] : null;
  final id = raw is Map ? raw['delivery_batch_end_message_id'] : null;
  return id is String && id.isNotEmpty ? id : null;
}

bool isGeneratedReply(Map<String, dynamic> reply) =>
    reply['source'] == 'generated_reply' ||
    generatedReplyBatchEnd(reply) != null;

bool isTransferWelcomeReply(Map<String, dynamic> reply) {
  final metadata = reply['reply_metadata'];
  return reply['sender'] == 'jd-transfer-welcome-v1' ||
      (metadata is Map && metadata['model'] == 'jd-transfer-welcome-v1');
}

/// A visible copy of our own send is not a colleague taking over. Match its
/// clock as well as its text so a later human using the same words still wins.
bool isObservedGeneratedReply({
  required String body,
  required DateTime? sentAt,
  required Iterable<Map<String, dynamic>> messages,
}) {
  if (sentAt == null) return false;
  String normalize(String value) => value.replaceAll(RegExp(r'\s+'), '');
  return messages.any((message) {
    if (!isGeneratedReply(message) ||
        !isConfirmedOutgoingReply(message) ||
        normalize(message['body']?.toString() ?? '') != normalize(body)) {
      return false;
    }
    final at = DateTime.tryParse(message['sent_at']?.toString() ?? '');
    return at != null &&
        sentAt.difference(at).abs() < const Duration(seconds: 5);
  });
}

bool replyAnswersIncoming({
  required Map<String, dynamic> reply,
  required String incomingId,
  required List<Map<String, dynamic>> messages,
}) {
  if (!isConfirmedOutgoingReply(reply)) {
    return false;
  }
  final incomingIndex = messages.indexWhere((message) =>
      message['direction'] == 'incoming' && message['id'] == incomingId);
  if (incomingIndex < 0) return false;
  if (isTransferWelcomeReply(reply)) {
    if ((messages[incomingIndex]['media'] as List<Object?>? ?? const [])
        .isNotEmpty) {
      return false;
    }
    final body = (messages[incomingIndex]['body']?.toString() ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[\s.,!?，。！？~～]'), '');
    final greeting =
        const {'hi', 'hello', 'hey', '你好', '您好', '您好老板', '你好老板'}.contains(body);
    final incomingAt =
        DateTime.tryParse(messages[incomingIndex]['sent_at']?.toString() ?? '');
    final sentAt = DateTime.tryParse(reply['sent_at']?.toString() ?? '');
    return greeting &&
        incomingAt != null &&
        sentAt != null &&
        !sentAt.isBefore(incomingAt) &&
        sentAt.difference(incomingAt) < const Duration(minutes: 10);
  }
  if (isGeneratedReply(reply)) {
    final boundary = generatedReplyBatchEnd(reply);
    final batchIndex = boundary == null
        ? -1
        : messages.indexWhere((message) =>
            message['direction'] == 'incoming' && message['id'] == boundary);
    return batchIndex >= incomingIndex;
  }
  // Preserve explicit human replies. Unknown legacy generated batches above
  // are deliberately not treated as answers to newly arrived messages.
  final incomingAt =
      DateTime.tryParse(messages[incomingIndex]['sent_at']?.toString() ?? '');
  final sentAt = DateTime.tryParse(reply['sent_at']?.toString() ?? '');
  return incomingAt != null && sentAt != null && !sentAt.isBefore(incomingAt);
}
