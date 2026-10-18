import 'dart:io';

import 'package:path/path.dart' as p;

/// Capture bookkeeping must never become a customer utterance, intent, or
/// customer-facing quotation. Supports histories written by older releases.
String customerAuthoredText(String body) => body
    .replaceAll(
        RegExp(
            r'\[Customer sent (?:an? )?(?:image|video|attachment)[^\]]*(?:\]|$)',
            caseSensitive: false),
        '')
    .replaceAll(
        RegExp(r'\[Video (?:speech transcript|audio)[^\]]*(?:\]|$)',
            caseSensitive: false),
        '')
    .trim();

bool containsInternalCaptureText(String text) => RegExp(
      r'\[Customer sent|\[Video (?:speech transcript|audio)|copied from JD cache|sampled at one frame per second|Pending Codex visual analysis|jd_video_frame_1fps|visible_customer_region|exact_customer_unique_cache_clock|exact_customer_attachment_reference',
      caseSensitive: false,
    ).hasMatch(text);

/// ASR is useful evidence, but is not a typed instruction authorizing a
/// refund/handoff. Keep it labelled separately, including legacy recordings.
List<Map<String, Object?>> customerSpeechEvidence(
    Map<String, dynamic> message) {
  final evidence = <Map<String, Object?>>[];
  for (final media in (message['media'] as List<Object?>? ?? const [])) {
    if (media is! Map || media['type'] != 'audio') continue;
    final transcript = media['speech_transcript']?.toString();
    if (transcript == null || transcript.trim().isEmpty) continue;
    evidence.add({
      'message_id': message['id'],
      'sent_at': message['sent_at'],
      'transcript': transcript,
      'confidence': media['speech_confidence'],
      'language': media['speech_language'],
      'provenance': 'speech_recognition_not_typed_customer_text',
    });
  }
  if (evidence.isNotEmpty) return evidence;
  final legacy = RegExp(r'\[Video speech transcript \(([^)]+)\): ([\s\S]*?)\]',
          caseSensitive: false)
      .firstMatch(message['body']?.toString() ?? '');
  if (legacy != null) {
    evidence.add({
      'message_id': message['id'],
      'sent_at': message['sent_at'],
      'transcript': legacy.group(2),
      'language': legacy.group(1),
      'confidence': null,
      'provenance': 'legacy_speech_recognition_not_typed_customer_text',
    });
  }
  return evidence;
}

/// Revalidate at generation as well as capture: edited/legacy history must not
/// smuggle another customer's media into the CLI. Shared cache/external paths
/// are never attachments: capture must first copy to private customer storage.
bool customerOwnsMedia(Map media,
    {required String customer,
    required Directory mediaDirectory,
    required String safeCustomerDirectory}) {
  final owner = media['verified_customer_id']?.toString();
  if (owner != null && owner != customer) return false;
  final path = media['path']?.toString() ?? '';
  if (path.isEmpty) return false;
  final root = p.normalize(mediaDirectory.absolute.path);
  final own = p.join(root, safeCustomerDirectory);
  final absolute = p.normalize(p.absolute(path));
  if (!p.isWithin(own, absolute)) return false;
  try {
    final file = File(absolute);
    if (file.existsSync()) {
      final resolved = file.resolveSymbolicLinksSync();
      // Resolve the shared root, not just the candidate's spelling.
      final resolvedRoot = Directory(root).existsSync()
          ? Directory(root).resolveSymbolicLinksSync()
          : root;
      final ownRoot = p.join(resolvedRoot, safeCustomerDirectory);
      if (p.isWithin(resolvedRoot, resolved) &&
          !p.isWithin(ownRoot, resolved)) {
        return false;
      }
      if (p.isWithin(own, absolute) && !p.isWithin(ownRoot, resolved)) {
        return false;
      }
    }
  } on FileSystemException {
    return false;
  }
  return true;
}

/// A failed upload belongs to an event, not to the whole lifetime of a chat.
/// A new image must never inherit an old video's failure or block analysis.
Map<String, dynamic>? relevantUnavailableMedia({
  required Object? failure,
  required String customer,
  required List<Map<String, dynamic>> messages,
  required List<Map<String, dynamic>> currentBatch,
  required bool explicitlyAsksAboutUpload,
}) {
  if (failure is! Map || currentBatch.isEmpty) return null;
  final owner = failure['customer_id']?.toString();
  if (owner != null && owner != customer) return null;
  final at = DateTime.tryParse(failure['sent_at']?.toString() ?? '');
  if (at == null) return null;
  final latestAt = currentBatch
      .map((m) => DateTime.tryParse(m['sent_at']?.toString() ?? ''))
      .whereType<DateTime>()
      .fold<DateTime?>(
          null,
          (latest, value) =>
              latest == null || value.isAfter(latest) ? value : latest);
  if (latestAt == null ||
      latestAt.isBefore(at) ||
      latestAt.difference(at) > const Duration(minutes: 5)) {
    return null;
  }
  for (final message in messages) {
    if (message['direction'] != 'incoming') continue;
    final sent = DateTime.tryParse(message['sent_at']?.toString() ?? '');
    if (sent == null || sent.isBefore(at) || sent.isAfter(latestAt)) continue;
    if ((message['media'] as List<Object?>? ?? const []).isNotEmpty) {
      return null;
    }
  }
  final exactEvent = currentBatch.any((m) =>
      (failure['message_id'] != null && m['id'] == failure['message_id']) ||
      (DateTime.tryParse(m['sent_at']?.toString() ?? '') == at &&
          RegExp(r'^\[Customer sent', caseSensitive: false)
              .hasMatch(m['body']?.toString() ?? '')));
  return exactEvent || explicitlyAsksAboutUpload
      ? Map<String, dynamic>.from(failure)
      : null;
}

/// No raw ticket text is ever echoed. It can contain OCR/ASR/system metadata.
String safeTransferAcknowledgement() => '我已记录您需要进一步协助，现在为您转接其他客服同事，请稍等。';

List<Map<String, Object?>> unresolvedCustomerUploads(Object? raw,
    {required String customer, required List<Map<String, dynamic>> batch}) {
  final clocks = batch
      .map((m) => DateTime.tryParse(m['sent_at']?.toString() ?? ''))
      .whereType<DateTime>()
      .toList()
    ..sort();
  if (raw is! List || clocks.isEmpty) return const [];
  return raw
      .whereType<Map>()
      .where((event) {
        final at = DateTime.tryParse(event['sent_at']?.toString() ?? '');
        return event['customer_id'] == customer &&
            event['state'] == 'unresolved' &&
            at != null &&
            at.difference(clocks.last).inSeconds.abs() <= 120;
      })
      .map((e) => Map<String, Object?>.from(e))
      .toList();
}
