import 'reply_message_scope.dart';

/// Distinguishes a genuinely new unread event from a stale badge already
/// present when automation starts. A parsed JD elapsed-time badge is direct
/// evidence; otherwise the same row must first be continuously clear and then
/// become unread.
class SidebarUnreadTracker {
  SidebarUnreadTracker({
    this.clearConfirmation = const Duration(seconds: 2),
  });

  final Duration clearConfirmation;
  final Map<String, bool> _lastUnread = {};
  final Map<String, DateTime> _clearSince = {};
  final Set<String> _verified = {};

  bool observe({
    required String customer,
    required bool unread,
    required DateTime observedAt,
    int? unreadAgeSeconds,
  }) {
    final previous = _lastUnread[customer];
    if (!unread) {
      _lastUnread[customer] = false;
      _clearSince.putIfAbsent(customer, () => observedAt);
      _verified.remove(customer);
      return false;
    }
    final validClock = unreadAgeSeconds != null &&
        unreadAgeSeconds >= 0 &&
        unreadAgeSeconds <= 600;
    final clearSince = _clearSince[customer];
    final verifiedTransition = previous == false &&
        clearSince != null &&
        observedAt.difference(clearSince) >= clearConfirmation;
    if (validClock || verifiedTransition) _verified.add(customer);
    _lastUnread[customer] = true;
    _clearSince.remove(customer);
    return _verified.contains(customer);
  }

  bool isVerified(String customer) => _verified.contains(customer);
}

/// A sidebar unread signal is not proof that the message body was captured.
/// Keep a separate clock until the newest incoming content is saved.
class UnreadCaptureRecovery {
  UnreadCaptureRecovery({
    required this.customer,
    required this.unreadEvidence,
    required this.detectedAt,
    required this.knownIncomingIds,
    required this.knownOutgoingIds,
    this.sidebarUnreadVerified = false,
  });

  static const relaxedOcrAfter = Duration(seconds: 20);
  static const holdingAfter = Duration(seconds: 20);
  static const resendAfter = Duration(seconds: 50);
  static const detectedTurnClockTolerance = Duration(seconds: 15);
  static const verifiedBadgeLifetime = Duration(minutes: 10);
  static const directMediaProbeInterval = Duration(seconds: 5);

  /// Recently answered incoming messages remain historical even inside the
  /// OCR clock-tolerance window. They cannot count as capture of a new turn.
  static Set<String> incomingBaseline(Iterable<Map<String, dynamic>> messages,
      {required DateTime detectedAt, String? answeredMessageId}) {
    final rows = messages.toList(growable: false);
    final answeredIndex = answeredMessageId == null
        ? -1
        : rows.indexWhere((message) => message['id'] == answeredMessageId);
    final known = <String>{};
    for (var index = 0; index < rows.length; index++) {
      final message = rows[index];
      if (message['direction'] != 'incoming') continue;
      final at = DateTime.tryParse(message['sent_at']?.toString() ?? '') ??
          DateTime.tryParse(message['captured_at']?.toString() ?? '');
      if (index <= answeredIndex ||
          (at?.isBefore(detectedAt.subtract(detectedTurnClockTolerance)) ??
              false)) {
        known.add(message['id']?.toString() ?? '');
      }
    }
    return known;
  }

  /// Use JD's elapsed unread badge when available, so a scan delayed by
  /// image/video work still inherits the customer's original deadline.
  static DateTime detectedFromBadge(DateTime observedAt, int? ageSeconds) =>
      ageSeconds != null && ageSeconds >= 0 && ageSeconds <= 600
          ? observedAt.subtract(Duration(seconds: ageSeconds))
          : observedAt;

  /// A new badge clock can appear before a poll ever sees the old badge clear.
  /// Allow for the one-second badge display and poll timing jitter.
  static bool badgeStartedAfterHandled(
      DateTime observedAt, int? ageSeconds, DateTime? handledAt) {
    if (handledAt == null ||
        ageSeconds == null ||
        ageSeconds < 0 ||
        ageSeconds > 600) {
      return false;
    }
    return detectedFromBadge(observedAt, ageSeconds)
        .isAfter(handledAt.add(const Duration(seconds: 2)));
  }

  /// A shared JD cache file may be assigned only when its modification clock
  /// is clearly closer to this customer than to every other active unread
  /// recovery. Ambiguous simultaneous customer turns are intentionally left
  /// for visible-region verification instead of risking cross-customer media.
  static bool cacheClockUniquelyMatches({
    required DateTime modifiedAt,
    required String targetCustomer,
    required Map<String, UnreadCaptureRecovery> recoveries,
    Duration ambiguityTolerance = const Duration(seconds: 3),
  }) {
    final target = recoveries[targetCustomer];
    if (target == null) return false;
    final targetDelta = modifiedAt.difference(target.detectedAt).abs();
    for (final entry in recoveries.entries) {
      if (entry.key == targetCustomer) continue;
      final competingDelta =
          modifiedAt.difference(entry.value.detectedAt).abs();
      if (competingDelta <= targetDelta + ambiguityTolerance) return false;
    }
    return true;
  }

  final String customer;
  final int unreadEvidence;
  final DateTime detectedAt;
  final Set<String> knownIncomingIds;
  final Set<String> knownOutgoingIds;
  bool sidebarUnreadVerified;
  bool holdingSent = false;
  DateTime? holdingSentAt;
  bool resendSent = false;
  bool videoProcessing = false;
  bool noticeSending = false;
  DateTime? lastCaptureAttemptAt;
  DateTime? lastDirectMediaProbeAt;
  String? latestIncomingSenderKey;
  DateTime? latestIncomingSentAt;
  int noticeRevision = 0;
  String? _tentativeRelaxedBody;

  /// Deadlines belong to the latest verified customer event, never to the
  /// sidebar recovery that happened to precede it.
  DateTime get eventAt => latestIncomingSentAt ?? detectedAt;

  bool get hasVerifiedIncomingSignal => latestIncomingSenderKey != null;

  bool acceptsGeneratedReply(
      Map<String, dynamic> reply, List<Map<String, dynamic>> messages,
      {bool pendingMedia = false}) {
    if (!isConfirmedOutgoingReply(reply)) return false;
    final boundary = generatedReplyBatchEnd(reply);
    if (boundary == null) {
      if (latestIncomingSentAt != null) return false;
      if (isTransferWelcomeReply(reply)) {
        final sent = DateTime.tryParse(reply['sent_at']?.toString() ?? '');
        if (pendingMedia ||
            reply['delivery_status'] == 'delivery_unknown' ||
            sent == null ||
            sent.isBefore(detectedAt)) {
          return false;
        }
        // A handover alone can light the sidebar. Our delivered welcome closes
        // that badge-only recovery, not a technical question/upload. A fresh
        // sender signal always takes precedence, including after the welcome.
        return !messages.any((incoming) {
          if (incoming['direction'] != 'incoming' ||
              knownIncomingIds.contains(incoming['id']?.toString() ?? '')) {
            return false;
          }
          final captured =
              DateTime.tryParse(incoming['captured_at']?.toString() ?? '');
          final at = DateTime.tryParse(incoming['sent_at']?.toString() ?? '');
          final current =
              (captured != null && !captured.isBefore(detectedAt)) ||
                  (at != null &&
                      !at.isBefore(
                          detectedAt.subtract(detectedTurnClockTolerance)));
          return current &&
              !replyAnswersIncoming(
                  reply: reply,
                  incomingId: incoming['id']?.toString() ?? '',
                  messages: messages);
        });
      }
      return messages.any((incoming) {
        final captured =
            DateTime.tryParse(incoming['captured_at']?.toString() ?? '');
        return incoming['direction'] == 'incoming' &&
            captured != null &&
            !captured.isBefore(detectedAt) &&
            replyAnswersIncoming(
                reply: reply,
                incomingId: incoming['id']?.toString() ?? '',
                messages: messages);
      });
    }
    if (knownIncomingIds.contains(boundary)) return false;
    final incoming = messages
        .where((message) =>
            message['direction'] == 'incoming' && message['id'] == boundary)
        .firstOrNull;
    final at = DateTime.tryParse(incoming?['sent_at']?.toString() ?? '');
    if (at == null) return false;
    if (latestIncomingSentAt != null) {
      return !at.isBefore(latestIncomingSentAt!);
    }
    if (!at.isBefore(detectedAt)) return true;
    // Transfer/opening can start recovery after the greeting was sent. An
    // exact frozen-batch reply to a body first captured during this recovery
    // closes it. Never use this exception once a newer sender is verified.
    final captured =
        DateTime.tryParse(incoming?['captured_at']?.toString() ?? '');
    final sent = DateTime.tryParse(reply['sent_at']?.toString() ?? '');
    return captured != null &&
        !captured.isBefore(detectedAt) &&
        sent != null &&
        !sent.isBefore(detectedAt) &&
        !at.isBefore(detectedAt.subtract(const Duration(minutes: 2)));
  }

  /// A parsed elapsed-time badge or an observed clear-to-unread transition is
  /// independent evidence that this row became unread recently. It is safe
  /// permission for a holding message only while the signal is still within
  /// JD's ten-minute display range; native send must nevertheless re-verify
  /// the exact active customer.
  bool canSendHoldingAt(DateTime now) =>
      hasVerifiedIncomingSignal ||
      (sidebarUnreadVerified &&
          !now.isAfter(detectedAt.add(verifiedBadgeLifetime)));

  void verifySidebarUnread() {
    sidebarUnreadVerified = true;
  }

  /// A red sidebar pixel is only a priority hint. It becomes permission to
  /// send a recovery notice after the active chat independently exposes a
  /// current incoming sender clock belonging to this recovery window.
  bool verifyIncomingSignal({
    required String? senderKey,
    required DateTime? sentAt,
    required DateTime capturedAt,
  }) {
    if (senderKey == null || sentAt == null) return false;
    if (sentAt.isBefore(detectedAt.subtract(detectedTurnClockTolerance)) ||
        sentAt.isAfter(capturedAt.add(const Duration(minutes: 1)))) {
      return false;
    }
    if (latestIncomingSentAt != null &&
        sentAt.isBefore(latestIncomingSentAt!)) {
      return false;
    }
    final previous = latestIncomingSentAt;
    final newEvent = previous != null
        ? sentAt.isAfter(previous)
        : sentAt.isAfter(detectedAt.add(const Duration(seconds: 2)));
    if (newEvent) {
      holdingSent = false;
      holdingSentAt = null;
      resendSent = false;
      lastCaptureAttemptAt = null;
      lastDirectMediaProbeAt = null;
      _tentativeRelaxedBody = null;
      noticeRevision++;
    }
    latestIncomingSenderKey = senderKey;
    latestIncomingSentAt = sentAt;
    return true;
  }

  /// Only a holding reply belonging to this recovery can discharge its SLA.
  /// The OCR clock tolerance is for incoming detection, never for replies:
  /// accepting a previous turn's holding reply silently drops the new turn.
  DateTime? holdingReplySentAt(Iterable<Map<String, dynamic>> messages) {
    DateTime? newest;
    for (final message in messages) {
      if (message['direction'] != 'outgoing' ||
          message['source'] != 'sla_fallback' ||
          message['delivery_status'] == 'delivery_unknown' ||
          knownOutgoingIds.contains(message['id']?.toString() ?? '')) {
        continue;
      }
      final sentAt = DateTime.tryParse(message['sent_at']?.toString() ?? '');
      if (sentAt == null || sentAt.isBefore(eventAt)) continue;
      if (newest == null || sentAt.isAfter(newest)) newest = sentAt;
    }
    return newest;
  }

  /// Visible chat history can be captured after an unread event even though
  /// those messages were sent earlier. Such a late capture must not resolve
  /// the current unread turn or cancel its fallback timer.
  bool acceptsIncoming(String messageId,
      {DateTime? sentAt, required DateTime capturedAt}) {
    if (knownIncomingIds.contains(messageId)) return false;
    // Once JD exposes the new sender clock, an older captured text batch is
    // not recovery of this media turn (even within OCR's clock tolerance).
    if (latestIncomingSentAt case final expectedAt?) {
      if (sentAt == null || sentAt.isBefore(expectedAt)) return false;
    }
    if (sentAt != null) {
      return !sentAt.isBefore(detectedAt.subtract(detectedTurnClockTolerance));
    }
    return !capturedAt.isBefore(detectedAt);
  }

  /// A single low-confidence OCR pass may read JD controls as customer text.
  /// Require the same non-empty body on two separate scans before accepting it.
  bool confirmRelaxedBody(String body) {
    final normalized = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return false;
    if (_tentativeRelaxedBody == normalized) return true;
    _tentativeRelaxedBody = normalized;
    return false;
  }

  bool captureRetryDue(DateTime now) =>
      lastCaptureAttemptAt == null ||
      !now.isBefore(lastCaptureAttemptAt!.add(const Duration(seconds: 8)));

  void recordCaptureAttempt(DateTime now) {
    lastCaptureAttemptAt = now;
  }

  bool directMediaProbeDue(DateTime now) =>
      lastDirectMediaProbeAt == null ||
      !now.isBefore(lastDirectMediaProbeAt!.add(directMediaProbeInterval));

  void recordDirectMediaProbe(DateTime now) {
    lastDirectMediaProbeAt = now;
  }

  /// A sidebar badge without a visible sender clock is inconclusive, not a
  /// handled message. Make the row eligible for the next full capture pass.
  void requestImmediateCaptureRetry() {
    lastCaptureAttemptAt = null;
  }

  bool useRelaxedBodyOcr(DateTime now) =>
      !now.isBefore(detectedAt.add(relaxedOcrAfter));

  bool holdingDue(DateTime now) =>
      !holdingSent && !now.isBefore(eventAt.add(holdingAfter));

  bool resendDue(DateTime now) =>
      holdingSent &&
      hasVerifiedIncomingSignal &&
      holdingSentAt != null &&
      !resendSent &&
      !now.isBefore(eventAt.add(resendAfter)) &&
      !now.isBefore(holdingSentAt!.add(const Duration(seconds: 30)));

  DateTime get resendDueAt {
    final original = eventAt.add(resendAfter);
    final afterHolding = holdingSentAt?.add(const Duration(seconds: 30));
    return afterHolding != null && afterHolding.isAfter(original)
        ? afterHolding
        : original;
  }
}
