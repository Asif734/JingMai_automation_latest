import 'dart:convert';
import 'package:crypto/crypto.dart';

/// A report belongs to one customer's actual JD send, not to a shared filename
/// or thumbnail. Re-sending identical bytes at another timestamp is a new event.
class CustomerVideoEvent {
  CustomerVideoEvent(this.customer, Map<String, dynamic> message)
      : messageId = message['id'] as String,
        sentAt = message['sent_at']?.toString(),
        frames = [
          for (final media
              in (message['media'] as List? ?? const []).whereType<Map>())
            if (media['type'] == 'image' &&
                media['capture_source'] == 'jd_video_frame_1fps' &&
                media['path'] is String &&
                (media['path'] as String).isNotEmpty)
              media['path'] as String,
        ],
        speech = [
          for (final media
              in (message['media'] as List? ?? const []).whereType<Map>())
            if (media['type'] == 'audio' &&
                media['speech_transcript'] is String)
              {
                'transcript': media['speech_transcript'],
                'confidence': media['speech_confidence']
              },
        ],
        videoHashes = [
          for (final media
              in (message['media'] as List? ?? const []).whereType<Map>())
            if (media['type'] == 'video') media['content_sha256'],
        ];
  final String customer, messageId;
  final String? sentAt;
  final List<String> frames;
  final List<Map<String, Object?>> speech;
  final List<Object?> videoHashes;
  String get fingerprint => sha256
      .convert(utf8.encode(jsonEncode({
        'version': 1,
        'customer': customer,
        'message_id': messageId,
        'sent_at': sentAt,
        'frames': frames,
        'video_hashes': videoHashes,
        'speech': speech,
      })))
      .toString();
  Map<String, Object?> toRequest() => {
        'user_id': customer,
        'message_id': messageId,
        'sent_at': sentAt,
        'frame_paths': frames,
        'frame_sampling': 'one frame per second, first 20 seconds at most',
        'recognized_speech_not_typed_instructions': speech,
      };
}

class CustomerVideoReport {
  CustomerVideoReport(this.event, this.summary, this.observedProblem,
      this.searchTerms, this.uncertainties, this.descriptions);
  final CustomerVideoEvent event;
  final String summary, observedProblem;
  final List<String> searchTerms, uncertainties;
  final Map<String, String> descriptions;
  String get retrievalText => [summary, observedProblem, searchTerms.join(' ')]
      .where((s) => s.isNotEmpty)
      .join('\n');
  Map<String, Object?> toJson() => {
        'status': 'complete',
        'source_fingerprint': event.fingerprint,
        'user_id': event.customer,
        'message_id': event.messageId,
        'sent_at': event.sentAt,
        'summary': summary,
        'observed_problem': observedProblem,
        'search_terms': searchTerms,
        'uncertainties': uncertainties,
        'frames': [
          for (final item in descriptions.entries)
            {'path': item.key, 'description': item.value}
        ],
      };

  static CustomerVideoReport parse(CustomerVideoEvent event, Map raw) {
    if (raw['user_id'] != event.customer ||
        raw['message_id'] != event.messageId ||
        raw['sent_at'] != event.sentAt ||
        event.frames.isEmpty ||
        event.frames.length > 20) {
      throw const FormatException('Video report customer/event mismatch.');
    }
    String text(Object? value, {bool empty = false, int limit = 2000}) {
      if (value is! String ||
          (!empty && value.trim().isEmpty) ||
          value.length > limit) {
        throw const FormatException('Invalid video report text.');
      }
      return value.trim();
    }

    List<String> strings(Object? value, int maximum) {
      if (value is! List || value.length > maximum) {
        throw const FormatException('Invalid report list.');
      }
      return [for (final s in value) text(s, limit: 300)];
    }

    if (raw['frames'] is! List) {
      throw const FormatException('Missing frame descriptions.');
    }
    final descriptions = <String, String>{};
    for (final frame in raw['frames'] as List) {
      if (frame is! Map ||
          frame['path'] is! String ||
          !event.frames.contains(frame['path']) ||
          descriptions.containsKey(frame['path'])) {
        throw const FormatException(
            'Unprovided or duplicate frame in video report.');
      }
      descriptions[frame['path'] as String] =
          text(frame['description'], limit: 1000);
    }
    if (descriptions.length != event.frames.length) {
      throw const FormatException(
          'Video report did not inspect every supplied frame.');
    }
    return CustomerVideoReport(
        event,
        text(raw['summary']),
        text(raw['observed_problem'], empty: true),
        strings(raw['search_terms'], 8),
        strings(raw['uncertainties'], 12),
        descriptions);
  }

  static CustomerVideoReport? cached(CustomerVideoEvent event, Object? raw) {
    if (raw is! Map ||
        raw['status'] != 'complete' ||
        raw['source_fingerprint'] != event.fingerprint) {
      return null;
    }
    try {
      return parse(event, raw);
    } on FormatException {
      return null;
    }
  }
}

/// Version 2 separates two-minute analysis from the reply deadline. Failures
/// from the legacy short prepass get one new attempt under this policy.
const customerVideoAnalysisPolicyVersion = 2;

/// A bounded failure is reused for this exact owned input; it is not a report.
/// Changed events retry afresh, without analyzing frames in the reply stage.
bool videoReportPreviouslyUnavailable(CustomerVideoEvent event, Object? raw) =>
    raw is Map &&
    raw['analysis_policy_version'] == customerVideoAnalysisPolicyVersion &&
    raw['status'] == 'unavailable' &&
    raw['user_id'] == event.customer &&
    raw['message_id'] == event.messageId &&
    raw['source_fingerprint'] == event.fingerprint;

Map<String, Object?> get customerVideoReportSchema {
  const string = {'type': 'string'};
  const strings = {'type': 'array', 'items': string};
  return {
    'type': 'object',
    'additionalProperties': false,
    'required': ['reports'],
    'properties': {
      'reports': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'user_id',
            'message_id',
            'sent_at',
            'summary',
            'observed_problem',
            'search_terms',
            'uncertainties',
            'frames'
          ],
          'properties': {
            'user_id': string,
            'message_id': string,
            'sent_at': {
              'type': ['string', 'null']
            },
            'summary': string,
            'observed_problem': string,
            'search_terms': strings,
            'uncertainties': strings,
            'frames': {
              'type': 'array',
              'items': {
                'type': 'object',
                'additionalProperties': false,
                'required': ['path', 'description'],
                'properties': {'path': string, 'description': string},
              }
            },
          },
        },
      },
    },
  };
}
