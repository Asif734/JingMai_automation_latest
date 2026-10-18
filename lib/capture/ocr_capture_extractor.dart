import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/capture_models.dart';
import '../codex/holding_replies.dart';
import '../platform/macos_capture_adapter.dart';
import 'ocr_image_candidate_selector.dart';
import 'jd_message_timestamp.dart';
import 'ocr_text_sanitizer.dart';

/// Converts one OCR diagnostic scan of an *open* Qianniu conversation into a
/// conservative capture candidate. All visible incoming and seller-authored
/// bubbles with a clear sender/body relationship are returned; durable IDs
/// remove older duplicates.
class OcrCaptureExtractor {
  const OcrCaptureExtractor({this.bodyConfidenceThreshold = 0.45});

  /// Recovery may relax body recognition, but sender labels and customer
  /// identity must continue to meet the normal confidence threshold.
  final double bodyConfidenceThreshold;
  static const double senderConfidenceThreshold = 0.45;

  // JD indents wrapped bubble lines independently. In particular, a short
  // final line can start to the left of the longer line above it. Treat the
  // whole center conversation column as message content; sender labels, not
  // per-line x alignment, define where a message starts and ends.
  static const double _chatBodyLeft = 0.15;
  static const double _chatBodyRight = 0.66;

  CapturedConversation? extract(OcrInspection inspection) =>
      analyze(inspection).capture;

  /// Start generation from clear text on the independent signal scan. Any
  /// customer media or uncertain body still goes through the full capture.
  CapturedConversation? verifiedFastTextCapture(OcrInspection inspection) {
    final result = const OcrCaptureExtractor(bodyConfidenceThreshold: .8)
        .analyze(inspection);
    final capture = result.capture;
    if (capture == null ||
        !result.latestVisibleSenderIsIncoming ||
        !result.latestIncomingHasText ||
        result.transferNoticeVisible ||
        result.latestIncomingSentAt == null ||
        const OcrImageCandidateSelector()
            .select(inspection, capture.customerName, includeTextDense: true)
            .isNotEmpty) {
      return null;
    }
    final latest = capture.messages.lastOrNull;
    if (latest?.direction != 'incoming' ||
        latest?.sentAt != result.latestIncomingSentAt) {
      return null;
    }
    // Do not send a partial sentence when only some wrapped lines meet the
    // fast-path threshold. The accurate scan owns mixed-confidence bodies.
    final ordinary = analyze(inspection).capture?.messages.lastOrNull;
    if (ordinary?.stableId != latest?.stableId) return null;
    final messages = capture.messages.reversed
        .takeWhile((message) => message.direction == 'incoming')
        .toList()
        .reversed
        .toList(growable: false);
    return CapturedConversation(
      stableKey: capture.stableKey,
      customerName: capture.customerName,
      customerExternalId: capture.customerExternalId,
      verifiedCustomerId: capture.verifiedCustomerId,
      messages: messages,
      capturedAt: capture.capturedAt,
    );
  }

  OcrExtractionAttempt analyze(OcrInspection inspection,
      {List<OcrVisualRegion> excludedMediaRegions = const []}) {
    final observations = inspection.observations
        .where((item) =>
            item.confidence >= bodyConfidenceThreshold &&
            item.text.trim().isNotEmpty)
        .toList(growable: false);
    final suppliedCustomer = inspection.activeCustomerId?.trim();
    final customerId = suppliedCustomer != null && suppliedCustomer.isNotEmpty
        ? suppliedCustomer
        : _customerId(observations);
    final transferNoticeKey =
        _transferNoticeKey(observations, customerId, inspection.capturedAt);
    final transferNoticeVisible = transferNoticeKey != null;
    if (customerId == null) {
      return const OcrExtractionAttempt(
          reason: 'No unambiguous full customer ID was found.');
    }
    final verifiedChatLeft = inspection.chatLeft;
    final verifiedChatRight = inspection.chatRight;
    final hasVerifiedChatRegion = verifiedChatLeft != null &&
        verifiedChatRight != null &&
        verifiedChatLeft >= 0 &&
        verifiedChatRight <= 1 &&
        verifiedChatRight - verifiedChatLeft >= 0.10;
    final chatLeft = hasVerifiedChatRegion ? verifiedChatLeft : _chatBodyLeft;
    final chatRight =
        hasVerifiedChatRegion ? verifiedChatRight : _chatBodyRight;
    final chatBottom = inspection.chatBottom != null &&
            inspection.chatBottom! > 0.25 &&
            inspection.chatBottom! <= 0.95
        ? inspection.chatBottom!
        : 0.82;

    final messageLabels = observations
        .where((item) =>
            item.confidence >= senderConfidenceThreshold &&
            !excludedMediaRegions.any((region) =>
                item.x + item.width / 2 >= region.x &&
                item.x + item.width / 2 <= region.x + region.width &&
                item.y + item.height / 2 >= region.y &&
                item.y + item.height / 2 <= region.y + region.height) &&
            (_sameIdentity(item.text, customerId) ||
                _isSellerIdentity(item.text)) &&
            item.x + item.width / 2 >= chatLeft &&
            item.x + item.width / 2 < chatRight &&
            item.y >= 0.18 &&
            item.y < chatBottom)
        .map((item) => _MessageLabel(
              observation: item,
              direction: _sameIdentity(item.text, customerId)
                  ? 'incoming'
                  : 'outgoing',
            ))
        .toList()
      ..sort(
          (left, right) => left.observation.y.compareTo(right.observation.y));
    if (messageLabels.isEmpty) {
      return OcrExtractionAttempt(
          reason: 'Customer $customerId was identified, but no matching '
              'message sender label was visible in the chat area.',
          customerId: customerId,
          transferNoticeVisible: transferNoticeVisible,
          transferNoticeKey: transferNoticeKey);
    }
    final incomingLabels = messageLabels
        .where((label) => label.direction == 'incoming')
        .toList(growable: false);
    final latestVisibleSenderIsIncoming =
        messageLabels.last.direction == 'incoming';
    final latestIncomingLabel = incomingLabels.lastOrNull?.observation;
    final latestIncomingClock = latestIncomingLabel == null
        ? null
        : _timestamp.firstMatch(latestIncomingLabel.text)?.group(0) ??
            observations
                .where((item) =>
                    (item.y - latestIncomingLabel.y).abs() < 0.018 &&
                    item.x > latestIncomingLabel.x &&
                    _timestamp.hasMatch(item.text))
                .map((item) => _timestamp.firstMatch(item.text)!.group(0))
                .firstOrNull;
    final latestIncomingSenderKey = latestIncomingClock == null
        ? null
        : '$customerId\u001f$latestIncomingClock';
    final latestIncomingSentAt =
        _parseTimestamp(latestIncomingClock, inspection.capturedAt);
    final sender = incomingLabels.isEmpty
        ? messageLabels.last.observation
        : incomingLabels.last.observation;
    final fallbackCopyTarget = OcrCopyTarget(
      x: (sender.x + 0.045).clamp(0.20, 0.63),
      y: (sender.y + 0.040).clamp(0.18, 0.81),
    );

    final capturedMessages = <CapturedMessage>[];
    OcrObservation? latestBodyObservation;
    var latestIncomingHasText = false;
    for (var index = 0; index < messageLabels.length; index++) {
      final label = messageLabels[index];
      final currentSender = label.observation;
      final bottom = index + 1 < messageLabels.length
          ? messageLabels[index + 1].observation.y
          // JD can leave a larger vertical gap before the newest bottom
          // bubble. The next sender safely bounds older messages; the final
          // sender may use the remaining verified chat area above composer.
          : chatBottom;
      final bodies = observations.where((item) {
        final text = item.text.trim();
        if (item.y <= currentSender.y + 0.006 || item.y >= bottom) {
          return false;
        }
        final centerX = item.x + item.width / 2;
        final centerY = item.y + item.height / 2;
        if (centerX < chatLeft || centerX >= chatRight) return false;
        if (excludedMediaRegions.any((region) =>
            centerX >= region.x &&
            centerX <= region.x + region.width &&
            centerY >= region.y &&
            centerY <= region.y + region.height)) {
          return false;
        }
        return !_isMetadata(text, customerId);
      }).toList()
        ..sort((left, right) {
          final byY = _verticalCenter(left).compareTo(_verticalCenter(right));
          return byY != 0 ? byY : left.x.compareTo(right.x);
        });
      if (bodies.isEmpty) continue;
      // Real JD seller bubbles are right-aligned. A left-side video display
      // under a misread/missing customer label is not an outgoing bubble.
      // Keep numeric customer messages and long/wrapped seller replies intact.
      if (hasVerifiedChatRegion &&
          label.direction == 'outgoing' &&
          bodies.every(
              (item) => item.x + item.width < (chatLeft + chatRight) / 2)) {
        continue;
      }
      final assembled = _assembleBubbleText(bodies);
      final body = label.direction == 'incoming'
          ? stripAppendedHoldingReply(assembled)
          : assembled;
      if (body.isEmpty) continue;
      // Only a receipt on this seller bubble proves a formerly uncertain send.
      // It is not required for ordinary reply generation or normal sending.
      final bodyTop =
          bodies.map((item) => item.y).reduce((a, b) => a < b ? a : b);
      final bodyBottom = bodies
          .map((item) => item.y + item.height)
          .reduce((a, b) => a > b ? a : b);
      final bodyLeft =
          bodies.map((item) => item.x).reduce((a, b) => a < b ? a : b);
      final deliveryConfirmed = label.direction == 'outgoing' &&
          observations.any((item) =>
              item.confidence >= 0.8 &&
              (item.text.trim() == '已读' || item.text.trim() == '未读') &&
              item.x + item.width / 2 >= chatLeft &&
              item.x + item.width / 2 < chatRight &&
              item.x + item.width <= bodyLeft + 0.015 &&
              item.y + item.height / 2 >= bodyTop - 0.012 &&
              item.y + item.height / 2 <= bodyBottom + 0.012);
      // The JD transfer summary can be visually merged into the last customer
      // bubble by OCR. It is interface metadata, not a new customer request.
      // The caller handles the transfer separately by sending one welcome.
      if (transferNoticeVisible && _isTransferContextBody(body)) continue;
      final timestamp = _timestamp.firstMatch(currentSender.text)?.group(0) ??
          observations
              .where((item) =>
                  (item.y - currentSender.y).abs() < 0.018 &&
                  item.x > currentSender.x &&
                  _timestamp.hasMatch(item.text))
              .map((item) => item.text.trim())
              .firstOrNull;
      final identity = '$customerId\u001f${label.direction}\u001f'
          '${_fingerprintTimestamp(timestamp)}\u001f${_fingerprintText(body)}';
      capturedMessages.add(CapturedMessage(
        stableId: 'ocr:${sha256.convert(utf8.encode(identity))}',
        direction: label.direction,
        body: body,
        deliveryConfirmed: deliveryConfirmed,
        sender: label.direction == 'incoming'
            ? customerId
            : currentSender.text.trim(),
        sentAt: _parseTimestamp(timestamp, inspection.capturedAt),
        axPath: 'ocr:active-conversation',
      ));
      if (label.direction == 'incoming') latestBodyObservation = bodies.first;
      if (label.direction == 'incoming' &&
          identical(currentSender, incomingLabels.last.observation)) {
        latestIncomingHasText = true;
      }
    }
    if (capturedMessages.isEmpty) {
      return OcrExtractionAttempt(
          reason: 'Customer $customerId was identified, but no message '
              'body was recognized beneath the visible sender labels.',
          customerId: customerId,
          copyTarget: fallbackCopyTarget,
          transferNoticeVisible: transferNoticeVisible,
          transferNoticeKey: transferNoticeKey,
          latestVisibleSenderIsIncoming: latestVisibleSenderIsIncoming,
          latestIncomingSenderKey: latestIncomingSenderKey,
          latestIncomingSentAt: latestIncomingSentAt);
    }
    final latestBody = latestBodyObservation;
    final latestIncomingSender =
        incomingLabels.isEmpty ? null : incomingLabels.last.observation;
    // An image-only customer turn has a sender label but no OCR body. Aim the
    // clipboard classification just below that newest label instead of at an
    // older text body, so JD can confirm that the new bubble is an image.
    final latestIncomingHasNoBody = latestIncomingSender != null &&
        (latestBody == null ||
            latestIncomingSender.y > latestBody.y + latestBody.height + 0.006);
    return OcrExtractionAttempt(
      reason:
          'Extracted ${capturedMessages.length} visible message(s) for $customerId.',
      customerId: customerId,
      copyTarget: latestIncomingHasNoBody
          ? fallbackCopyTarget
          : latestBody == null
              ? null
              : OcrCopyTarget(
                  x: (latestBody.x + latestBody.width / 2).clamp(0.20, 0.63),
                  y: (latestBody.y + latestBody.height / 2).clamp(0.18, 0.81),
                ),
      capture: CapturedConversation(
        stableKey: 'customer:${sha256.convert(utf8.encode(customerId))}',
        customerName: customerId,
        customerExternalId: customerId,
        verifiedCustomerId: suppliedCustomer,
        capturedAt: inspection.capturedAt,
        messages: capturedMessages,
      ),
      bodyConfidenceThreshold: bodyConfidenceThreshold,
      transferNoticeVisible: transferNoticeVisible,
      transferNoticeKey: transferNoticeKey,
      latestIncomingHasText: latestIncomingHasText,
      latestVisibleSenderIsIncoming: latestVisibleSenderIsIncoming,
      latestIncomingSenderKey: latestIncomingSenderKey,
      latestIncomingSentAt: latestIncomingSentAt,
    );
  }

  String _assembleBubbleText(List<OcrObservation> observations) {
    final lines = <List<OcrObservation>>[];
    for (final observation in observations) {
      final center = _verticalCenter(observation);
      List<OcrObservation>? matchingLine;
      for (final line in lines.reversed) {
        final lineCenter =
            line.map(_verticalCenter).reduce((left, right) => left + right) /
                line.length;
        final tolerance = <double>[
          0.010,
          observation.height * 0.55,
          ...line.map((item) => item.height * 0.55),
        ].reduce((left, right) => left > right ? left : right);
        if ((center - lineCenter).abs() <= tolerance) {
          matchingLine = line;
          break;
        }
        if (center > lineCenter + 0.035) break;
      }
      (matchingLine ?? (lines..add(<OcrObservation>[])).last).add(observation);
    }

    lines.sort((left, right) =>
        _verticalCenter(left.first).compareTo(_verticalCenter(right.first)));
    final textLines = <String>[];
    for (final line in lines) {
      line.sort((left, right) => left.x.compareTo(right.x));
      // The sender labels and verified chat-area cutoff already bound this
      // message. Never stop on vertical gaps: OCR may return words or
      // wrapped fragments with unexpectedly separated boxes, and every box
      // inside the sender-bounded region belongs to the same visible turn.
      final text = line
          .map((item) => item.text.trim())
          .where((text) => !isJdOcrControlFragment(text))
          .join(' ')
          .trim();
      if (text.isNotEmpty) textLines.add(text);
    }
    final combined = textLines.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    // Sanitize after assembling wrapped lines so a multi-line platform banner
    // is removed as a unit without leaking its continuation into the request.
    final cleaned = sanitizeJdOcrText(combined)
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(RegExp(r'([\u3400-\u9fff])\s+([\u3400-\u9fff])'),
            (match) => '${match.group(1)}${match.group(2)}')
        .trim();
    return cleaned;
  }

  double _verticalCenter(OcrObservation observation) =>
      observation.y + observation.height / 2;

  String? _transferNoticeKey(List<OcrObservation> observations,
      String? customerId, DateTime capturedAt) {
    final customerPrefix = customerId?.substring(
        0, customerId.length < 10 ? customerId.length : 10);
    for (final observation in observations) {
      final nearby = observations
          .where((item) =>
              (item.y - observation.y).abs() <= 0.10 &&
              item.x + item.width / 2 >= 0.15 &&
              item.x + item.width / 2 <= 0.85)
          .toList()
        ..sort((left, right) {
          final vertical = left.y.compareTo(right.y);
          return vertical != 0 ? vertical : left.x.compareTo(right.x);
        });
      final compact =
          nearby.map((item) => item.text.replaceAll(RegExp(r'\s+'), '')).join();
      final colleagueTransfer = RegExp(r'(您的)?同事.+将客户').hasMatch(compact);
      final jdTransferSummary = RegExp(r'用户诉求[:：]?(?:要求|催促)?转接')
          .hasMatch(observation.text.replaceAll(RegExp(r'\s+'), ''));
      if (!colleagueTransfer && !jdTransferSummary) continue;
      if (!jdTransferSummary &&
          customerPrefix != null &&
          !compact.contains(customerPrefix)) {
        continue;
      }
      // The same banner moves as messages arrive. Its screen position and
      // adjacent questions must never create another transfer event.
      final source =
          RegExp(r'(?:您的)?同事(.{1,40}?)将客户').firstMatch(compact)?.group(1) ??
              'summary';
      final day = capturedAt
          .toUtc()
          .add(const Duration(hours: 8))
          .toIso8601String()
          .substring(0, 10);
      final identity = '$customerId\u001ftransfer\u001f$source\u001f$day';
      return sha256.convert(utf8.encode(identity)).toString();
    }
    return null;
  }

  String? _customerId(List<OcrObservation> observations) {
    final candidates = <String, double>{};
    for (final item in observations) {
      final text = item.text.trim();
      if (!_looksLikeAccountIdentity(text) || text.contains('...')) continue;
      if (_ignoredIdentifiers.contains(text.toLowerCase())) continue;
      var score = candidates[text] ?? 0;
      score +=
          10; // Repetition across the header, messages and profile is strong.
      if (item.x >= 0.58 && item.x < 0.85 && item.y >= 0.14 && item.y < 0.36) {
        score += 30; // Full identity in the customer-information header.
      }
      if (item.x >= 0.15 && item.x < 0.58 && item.y >= 0.18 && item.y < 0.82) {
        score += 8; // Sender label in the message history.
      }
      candidates[text] = score;
    }
    if (candidates.isEmpty) return null;
    final ranked = candidates.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    // Refuse a tie: saving a message under the wrong customer is worse than
    // requiring another diagnostic scan.
    if (ranked.length > 1 && ranked[0].value == ranked[1].value) return null;
    return ranked.first.key;
  }

  bool _sameIdentity(String value, String customerId) {
    return customerSenderLabelMatches(value, customerId);
  }

  bool _looksLikeAccountIdentity(String value) {
    final text = value.trim();
    if (text.length < 2 || text.length > 80 || _timestamp.hasMatch(text)) {
      return false;
    }
    // Qianniu customer display identities are not restricted to JD-generated
    // ASCII IDs. They can be ordinary account names, digits, or CJK business
    // names. Require actual name/number content while rejecting obvious UI.
    return RegExp(r'[A-Za-z0-9_\u3400-\u9fff]').hasMatch(text) &&
        !RegExp(r'[\r\n]').hasMatch(text);
  }

  bool _isMetadata(String value, String customerId) {
    final lower = value.toLowerCase();
    return _sameIdentity(value, customerId) ||
        // Sidebar previews are visually truncated; actual chat bubbles are
        // not. Never merge a neighboring customer's preview into this turn.
        value.contains('...') ||
        value.contains('…') ||
        RegExp(r'(您的)?同事.*将客户')
            .hasMatch(value.replaceAll(RegExp(r'\s+'), '')) ||
        value.contains('转接给您') ||
        value.contains('上次会话小结') ||
        RegExp(r'用户诉求[:：]?.*转接').hasMatch(value) ||
        RegExp(r'^(商品sku|咨询轨迹|客服方案|承诺项)[:：]').hasMatch(value.trim()) ||
        _timestamp.hasMatch(value) ||
        _sidebarRecency.hasMatch(value.trim()) ||
        lower.contains('已读') ||
        lower.contains('未读') ||
        lower.contains('新消息') ||
        lower.contains('加普威旗舰店') ||
        lower == '客服' ||
        lower == '营销';
  }

  bool _isTransferContextBody(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    return RegExp(r'(?:请你)?转给子账号|转接给您|上次会话小结|用户诉求[:：]?.*转接').hasMatch(compact);
  }

  bool _isSellerIdentity(String value) {
    final text = value.trim();
    if (text.contains('旗舰店') && (text.contains(':') || text.contains('：'))) {
      return true;
    }
    // Current JD builds display the signed-in support identity as names such
    // as "格志打印机小甘", often with the timestamp merged into the same Vision
    // observation. These are seller labels, not customer message bodies.
    final withoutTimestamp = text
        .replaceAll(_timestamp, '')
        .replaceAll(RegExp(r'\s*其他客服\s*$'), '')
        .trim();
    return RegExp(r'^格志打印机[\u3400-\u9fffA-Za-z0-9_-]{1,12}$')
        .hasMatch(withoutTimestamp);
  }

  String _fingerprintText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'''[.,!?;:'"`~，。！？；：“”‘’（）()\[\]{}、]'''), '');

  String _fingerprintTimestamp(String? value) {
    if (value == null) return '-';
    return RegExp(r'\d+')
        .allMatches(value)
        .map((match) => int.parse(match.group(0)!))
        .join(':');
  }

  DateTime? _parseTimestamp(String? value, DateTime capturedAt) =>
      parseJdMessageTimestamp(value, capturedAt);

  static final _timestamp = jdMessageTimestampPattern;
  static final _sidebarRecency = RegExp(
      r'^\d+\s*(?:秒|分钟|分|小时|天|second|seconds|min|mins)$',
      caseSensitive: false);
  static const _ignoredIdentifiers = {
    'hello',
    'customer',
    'service',
    'mac',
    'wifi',
  };
}

class _MessageLabel {
  const _MessageLabel({required this.observation, required this.direction});

  final OcrObservation observation;
  final String direction;
}

class OcrExtractionAttempt {
  const OcrExtractionAttempt({
    required this.reason,
    this.capture,
    this.customerId,
    this.copyTarget,
    this.transferNoticeVisible = false,
    this.transferNoticeKey,
    this.latestIncomingHasText = false,
    this.latestVisibleSenderIsIncoming = false,
    this.latestIncomingSenderKey,
    this.latestIncomingSentAt,
    this.bodyConfidenceThreshold = .45,
  });

  final String reason;
  final CapturedConversation? capture;
  final String? customerId;
  final OcrCopyTarget? copyTarget;
  final bool transferNoticeVisible;
  final String? transferNoticeKey;
  final bool latestIncomingHasText;
  final bool latestVisibleSenderIsIncoming;

  /// Stable across scans even when a media-only bubble has no OCR body.
  final String? latestIncomingSenderKey;
  final DateTime? latestIncomingSentAt;
  final double bodyConfidenceThreshold;

  /// Reuse the already approved recovery threshold after excluding media.
  /// Masking must not silently revert a two-scan-approved .30 body to .45.
  CapturedConversation? textExcludingMedia(
          OcrInspection inspection, List<OcrVisualRegion> regions) =>
      OcrCaptureExtractor(bodyConfidenceThreshold: bodyConfidenceThreshold)
          .analyze(inspection, excludedMediaRegions: regions)
          .capture;
}

class OcrCopyTarget {
  const OcrCopyTarget({required this.x, required this.y});
  final double x;
  final double y;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
