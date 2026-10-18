import 'dart:convert';

import '../domain/capture_models.dart';
import '../domain/media_identity.dart';

enum MediaEvidenceStage { original, ready }

/// Session-local input revisions, not polling counters. Message IDs include
/// the media hash and JD send timestamp; customer ownership is a separate key.
/// A queued original and its first ready frame set are real input changes.
/// Reading either again is not. Never expire entries while the app is running.
class MediaEvidenceVersions {
  final Map<String, int> _versions = {};
  final Map<String, Set<(String, MediaEvidenceStage)>> _seen = {};
  final Map<String, List<DateTime?>> _clocks = {};

  int? operator [](String customer) => _versions[customer];

  /// Later customer turns do not invalidate a frozen earlier answer. A late
  /// acquisition/upgrade at or before its input boundary still does.
  int revisionThrough(String customer, DateTime? through) => through == null
      ? (_versions[customer] ?? 0)
      : (_clocks[customer] ?? const [])
          .where((at) => at == null || !at.isAfter(through))
          .length;

  bool record(String customer, String messageId, MediaEvidenceStage stage,
      {DateTime? sentAt}) {
    if (customer.isEmpty || messageId.isEmpty) {
      throw ArgumentError('Media evidence requires a customer and message ID.');
    }
    if (!_seen.putIfAbsent(customer, () => {}).add((messageId, stage))) {
      return false;
    }
    _versions.update(customer, (n) => n + 1, ifAbsent: () => 1);
    _clocks.putIfAbsent(customer, () => []).add(sentAt);
    return true;
  }
}

/// App-owned revision, not model output. A later verified original invalidates
/// an unsent draft made without it. A restart is not itself newer evidence.
AiDraft withMediaEvidenceRevision(AiDraft draft,
    {required String session, required int revision, DateTime? throughSentAt}) {
  final raw = (jsonDecode(draft.rawJson) as Map).cast<String, Object?>();
  raw['_media_evidence_revision'] = {
    'session': session,
    'revision': revision,
    if (throughSentAt != null)
      'through_sent_at': throughSentAt.toUtc().toIso8601String(),
  };
  return AiDraft(
      reply: draft.reply,
      decision: draft.decision,
      confidence: draft.confidence,
      riskLevel: draft.riskLevel,
      model: draft.model,
      usedRecordIds: draft.usedRecordIds,
      actions: draft.actions,
      attachments: draft.attachments,
      rawJson: jsonEncode(raw),
      imageDescriptions: draft.imageDescriptions,
      ticket: draft.ticket);
}

DateTime? mediaEvidenceBoundary(AiDraft draft) {
  final stamp = (jsonDecode(draft.rawJson) as Map)['_media_evidence_revision'];
  return stamp is Map
      ? DateTime.tryParse(stamp['through_sent_at']?.toString() ?? '')
      : null;
}

bool hasNewerMediaEvidence(AiDraft draft,
    {required String session, required int revision}) {
  final raw = jsonDecode(draft.rawJson) as Map;
  final stamp = raw['_media_evidence_revision'];
  return stamp is Map &&
      stamp['session'] == session &&
      stamp['revision'] is int &&
      revision > (stamp['revision'] as int);
}

/// One sender-bounded upload, not one screenshot. A slot distinguishes several
/// disjoint attachments sharing the same sender clock. Never use cache mtime.
String uploadEventKey(DateTime sentAt, int slot) =>
    'upload:${mediaMessageSecond(sentAt)}:$slot';

class MediaAcquisition {
  MediaAcquisition(
      {required this.customer,
      required this.key,
      required this.sentAt,
      required this.firstSeen});
  final String customer;
  final String key;
  final DateTime sentAt;
  final DateTime firstSeen;
  int attempts = 0;
  DateTime? lastAttempt;
  bool acquired = false;
  bool holdingSent = false;
  bool attachmentFallbackStarted = false;
  String? failure;
  static const collectionBudget = Duration(seconds: 20);
  static const retryBudget = Duration(seconds: 50);
  static const maximumAttempts = 8;

  bool canAttempt(DateTime now) =>
      !acquired &&
      attempts < maximumAttempts &&
      now.difference(firstSeen) < retryBudget;
  bool retryDue(DateTime now) =>
      canAttempt(now) &&
      (lastAttempt == null ||
          now.difference(lastAttempt!) >=
              Duration(
                  seconds: attempts <= 1
                      ? 2
                      : attempts == 2
                          ? 4
                          : 8));
  bool deferGeneration(DateTime now) =>
      !acquired && now.difference(firstSeen) < collectionBudget;
  void attempting(DateTime now) {
    attempts++;
    lastAttempt = now;
  }

  Map<String, Object?> toJson() => {
        'customer_id': customer,
        'event_key': key,
        'sent_at': sentAt.toUtc().toIso8601String(),
        'first_seen': firstSeen.toUtc().toIso8601String(),
        'state': acquired ? 'acquired' : 'unresolved',
        'attempts': attempts,
        'failure': failure,
        'attachment_fallback_started': attachmentFallbackStarted,
      };
}

class MediaAcquisitions {
  final Map<String, MediaAcquisition> _events = {};
  String _key(String customer, String key) => '$customer\u001f$key';
  MediaAcquisition observe(
      String customer, String key, DateTime sentAt, DateTime now) {
    _events.removeWhere(
        (_, e) => now.difference(e.firstSeen) > const Duration(minutes: 10));
    return _events.putIfAbsent(
        _key(customer, key),
        () => MediaAcquisition(
            customer: customer, key: key, sentAt: sentAt, firstSeen: now));
  }

  List<MediaAcquisition> forCustomer(String customer) =>
      _events.values.where((e) => e.customer == customer).toList();
  Iterable<DateTime> competingTimes(String customer, DateTime at) =>
      _events.values
          .where((e) =>
              e.customer != customer ||
              mediaMessageSecond(e.sentAt) != mediaMessageSecond(at))
          .map((e) => e.sentAt);
  bool retryDue(String customer, DateTime now) =>
      forCustomer(customer).any((e) => e.retryDue(now));
  bool deferGeneration(String customer, DateTime now) =>
      forCustomer(customer).any((e) => e.deferGeneration(now));
}

String? uploadHoldingReceipt(
    Iterable<MediaAcquisition> events, DateTime? sentAt) {
  if (sentAt == null) return null;
  final matches = events
      .where((e) => e.sentAt.difference(sentAt).inSeconds.abs() <= 30)
      .toList()
    ..sort((a, b) => a.sentAt
        .difference(sentAt)
        .abs()
        .compareTo(b.sentAt.difference(sentAt).abs()));
  return matches.isEmpty
      ? null
      : 'upload:${mediaMessageSecond(matches.first.sentAt)}:holding';
}
