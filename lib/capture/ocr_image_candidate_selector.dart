import '../platform/macos_capture_adapter.dart';
import '../domain/media_identity.dart';
import 'jd_message_timestamp.dart';
import 'ocr_text_sanitizer.dart';

/// Selects only visual regions owned by a customer message block. A region
/// cannot cross the next customer/seller sender label, which prevents outgoing
/// text bubbles from being promoted to incoming images.
class OcrImageCandidateSelector {
  const OcrImageCandidateSelector();

  /// Sender anchors for re-identifying an already observed attachment after
  /// a scroll/reply. Same-second labels stay separate (e.g. text then video).
  List<OcrCustomerMessageBlock> customerBlocks(
      OcrInspection inspection, String customer) {
    if (!customerIdentitiesMatch(inspection.activeCustomerId, customer)) {
      return const [];
    }
    final left = inspection.chatLeft ?? .15;
    final right = inspection.chatRight ?? .68;
    final bottom = inspection.chatBottom ?? .90;
    final labels = inspection.observations
        .where((item) =>
            item.confidence >= .45 &&
            (item.y >= .14 || jdMessageTimestampPattern.hasMatch(item.text)) &&
            item.y < bottom &&
            item.x + item.width / 2 >= left &&
            item.x + item.width / 2 < right &&
            (_isCustomer(item.text, customer) || _isSeller(item.text)))
        .toList()
      ..sort((a, b) => a.y.compareTo(b.y));
    final stamped = <({OcrObservation label, double bottom, DateTime at})>[];
    for (var index = 0; index < labels.length; index++) {
      final label = labels[index];
      if (!_isCustomer(label.text, customer)) continue;
      final own = jdMessageTimestampPattern.firstMatch(label.text)?.group(0);
      final clocks = own != null
          ? {own}
          : inspection.observations
              .where((item) =>
                  item.confidence >= .45 &&
                  (item.y - label.y).abs() < .018 &&
                  item.x > label.x &&
                  item.x + item.width / 2 < right)
              .map((item) =>
                  jdMessageTimestampPattern.firstMatch(item.text)?.group(0))
              .whereType<String>()
              .toSet();
      if (clocks.length != 1) continue;
      final at = parseJdMessageTimestamp(clocks.single, inspection.capturedAt);
      if (at == null) continue;
      stamped.add((
        label: label,
        bottom: index + 1 < labels.length ? labels[index + 1].y - .002 : bottom,
        at: at
      ));
    }
    final counts = <int, int>{};
    final ordinals = <int, int>{};
    for (final block in stamped) {
      counts.update(mediaMessageSecond(block.at), (n) => n + 1,
          ifAbsent: () => 1);
    }
    return stamped.map((block) {
      final second = mediaMessageSecond(block.at);
      return OcrCustomerMessageBlock(
          sentAt: block.at,
          senderY: block.label.y,
          bodyTop: block.label.y + block.label.height,
          bodyBottom: block.bottom,
          sameTimeIndex:
              ordinals.update(second, (n) => n + 1, ifAbsent: () => 0),
          sameTimeCount: counts[second]!);
    }).toList(growable: false);
  }

  /// A later seller bubble may answer an older generation batch. It is not a
  /// receipt for this media event. Only independently owned, recently stamped
  /// customer media may bypass the historical-viewport guard.
  bool isRecentCustomerMedia(
      OcrInspection inspection, String customer, OcrVisualRegion region) {
    if (!customerIdentitiesMatch(inspection.activeCustomerId, customer)) {
      return false;
    }
    final sentAt = sentAtForRegion(inspection, customer, region);
    return sentAt != null &&
        !sentAt.isBefore(
            inspection.capturedAt.subtract(const Duration(minutes: 10))) &&
        !sentAt.isAfter(inspection.capturedAt.add(const Duration(minutes: 1)));
  }

  /// This is only permission to start a recovery timer, not content dedup.
  /// Already captured media must not reawaken an inactive chat on restart.
  /// Actual acquisition still checks both file digest and JD timestamp.
  bool hasUncapturedRecentCustomerMedia(OcrInspection inspection,
          String customer, Iterable<Map<String, dynamic>> knownMessages) =>
      select(inspection, customer, includeTextDense: true).any((region) =>
          isRecentCustomerMedia(inspection, customer, region) &&
          !knownMessages.any((message) =>
              message['direction'] == 'incoming' &&
              (message['media'] as List<Object?>? ?? const []).isNotEmpty &&
              sameMediaMessageTime(
                  DateTime.tryParse(message['sent_at']?.toString() ?? ''),
                  sentAtForRegion(inspection, customer, region))));

  bool mayCaptureWithLaterActivity(
      OcrInspection inspection, String customer, OcrVisualRegion region) {
    if (isRecentCustomerMedia(inspection, customer, region)) return true;
    final left = inspection.chatLeft ?? .15;
    final right = inspection.chatRight ?? .68;
    return !inspection.observations.any((item) =>
        item.x + item.width / 2 >= left &&
        item.x + item.width / 2 < right &&
        item.y > region.y + region.height + .005 &&
        _isSeller(item.text));
  }

  /// Read this media bubble's own sender timestamp, not a newer text bubble's
  /// clock or the time at which unread recovery/polling happened to start.
  DateTime? sentAtForRegion(
      OcrInspection inspection, String customer, OcrVisualRegion region) {
    final left = inspection.chatLeft ?? .15;
    final right = inspection.chatRight ?? .68;
    final labels = inspection.observations
        .where((item) =>
            item.confidence >= .45 &&
            (item.y >= .14 || jdMessageTimestampPattern.hasMatch(item.text)) &&
            item.y <= region.y &&
            item.x + item.width / 2 >= left &&
            item.x + item.width / 2 < right &&
            (_isCustomer(item.text, customer) || _isSeller(item.text)))
        .toList()
      ..sort((a, b) => b.y.compareTo(a.y));
    if (labels.isEmpty || !_isCustomer(labels.first.text, customer)) {
      return null;
    }
    final sender = labels.first;
    final ownClock =
        jdMessageTimestampPattern.firstMatch(sender.text)?.group(0);
    final clocks = ownClock != null
        ? {ownClock}
        : inspection.observations
            .where((item) =>
                item.confidence >= .45 &&
                (item.y - sender.y).abs() < .018 &&
                item.x > sender.x &&
                item.x + item.width / 2 < right)
            .map((item) =>
                jdMessageTimestampPattern.firstMatch(item.text)?.group(0))
            .whereType<String>()
            .toSet();
    if (clocks.length != 1) return null;
    return parseJdMessageTimestamp(clocks.single, inspection.capturedAt);
  }

  double? senderYForRegion(
      OcrInspection inspection, String customer, OcrVisualRegion region) {
    final labels = inspection.observations
        .where((item) =>
            item.confidence >= .45 &&
            item.y <= region.y &&
            item.x >= (inspection.chatLeft ?? .15) &&
            item.x < (inspection.chatRight ?? .68) &&
            (_isCustomer(item.text, customer) || _isSeller(item.text)))
        .toList()
      ..sort((a, b) => b.y.compareTo(a.y));
    return labels.isNotEmpty && _isCustomer(labels.first.text, customer)
        ? labels.first.y
        : null;
  }

  /// A header need not be confident enough to authorize ownership to prove
  /// that a rectangle crosses another message. Never save platform banners,
  /// receipts, or mixed header/bubble crops as a new customer image.
  bool containsInterfaceMetadata(
          OcrVisualRegion region, List<OcrObservation> observations) =>
      observations.any((item) {
        final centerY = item.y + item.height / 2;
        final centerX = item.x + item.width / 2;
        if (item.confidence < .30 ||
            centerY <= region.y ||
            centerY >= region.y + region.height ||
            centerX < region.x ||
            centerX > region.x + region.width) {
          return false;
        }
        final text = item.text.trim();
        return RegExp(r'当前消息可能包含|当前会话您存在消极服务行为|点击查看规则详情|异常反馈|上次会话小结|转接给您')
                .hasMatch(text) ||
            text == '已读' ||
            text == '未读' ||
            (_isSeller(text) && jdMessageTimestampPattern.hasMatch(text)) ||
            (RegExp(r'jd_[A-Za-z0-9_]{7,}').hasMatch(text) &&
                jdMessageTimestampPattern.hasMatch(text));
      });

  List<OcrVisualRegion> select(
    OcrInspection inspection,
    String customer, {
    bool allowUnlabeledLatestImage = false,
    bool includeTextDense = false,
  }) {
    final left = inspection.chatLeft ?? .15;
    final right = inspection.chatRight ?? .68;
    final bottom = inspection.chatBottom ?? .90;
    final senderLabels = inspection.observations
        .where((item) =>
            item.confidence >= .45 &&
            (item.y >= .14 || jdMessageTimestampPattern.hasMatch(item.text)) &&
            item.x + item.width / 2 >= left &&
            item.x + item.width / 2 < right &&
            (_isCustomer(item.text, customer) || _isSeller(item.text)))
        .toList()
      ..sort((left, right) => left.y.compareTo(right.y));
    final selected = <OcrVisualRegion>[];
    for (var index = 0; index < senderLabels.length; index++) {
      final label = senderLabels[index];
      if (!_isCustomer(label.text, customer)) continue;
      final nextSenderY =
          index + 1 < senderLabels.length ? senderLabels[index + 1].y : .90;
      final matches = inspection.visualRegions
          .where((region) => _validGeometry(region, left, right))
          .where((region) =>
              !containsInterfaceMetadata(region, inspection.observations))
          .where((region) =>
              includeTextDense || !isTextDense(region, inspection.observations))
          .where((region) =>
              label.y <= region.y &&
              // Multiple bubbles may share one JD sender label. The next
              // sender still bounds ownership; do not drop later bubbles.
              region.y + region.height < nextSenderY - .002 &&
              region.y + region.height <= bottom)
          .toList()
        ..sort((left, right) =>
            (right.width * right.height).compareTo(left.width * left.height));
      for (final candidate in matches) {
        // Vision also emits rectangles for labels/play controls inside a
        // thumbnail. Keep every disjoint bubble, not its nested rectangles.
        final overlaps = selected.any((other) {
          final dx = (candidate.x + candidate.width < other.x + other.width
                  ? candidate.x + candidate.width
                  : other.x + other.width) -
              (candidate.x > other.x ? candidate.x : other.x);
          final dy = (candidate.y + candidate.height < other.y + other.height
                  ? candidate.y + candidate.height
                  : other.y + other.height) -
              (candidate.y > other.y ? candidate.y : other.y);
          return dx > 0 && dy > 0;
        });
        if (!overlaps) selected.add(candidate);
      }
    }

    if (selected.isEmpty && allowUnlabeledLatestImage && senderLabels.isEmpty) {
      final unlabeled = inspection.visualRegions
          .where((region) => _validGeometry(region, left, right))
          .where((region) =>
              !containsInterfaceMetadata(region, inspection.observations))
          .where((region) =>
              includeTextDense || !isTextDense(region, inspection.observations))
          .where((region) =>
              region.x >= left &&
              // Customer media is left aligned. An unlabeled rectangle on the
              // seller side cannot be safely attributed to the customer.
              region.x <= left + (right - left) * .25 &&
              region.x + region.width <= right &&
              region.width >= .12 &&
              region.width <= .60 &&
              region.height >= .12)
          .toList();
      final outer = unlabeled.where((candidate) {
        return !unlabeled.any((container) {
          if (identical(candidate, container)) return false;
          const tolerance = .008;
          return container.x <= candidate.x + tolerance &&
              container.y <= candidate.y + tolerance &&
              container.x + container.width >=
                  candidate.x + candidate.width - tolerance &&
              container.y + container.height >=
                  candidate.y + candidate.height - tolerance &&
              container.width * container.height >
                  candidate.width * candidate.height * 1.25;
        });
      }).toList()
        ..sort((left, right) =>
            (right.y + right.height).compareTo(left.y + left.height));
      if (outer.isNotEmpty) selected.add(outer.first);
    }
    selected.sort((left, right) => right.y.compareTo(left.y));
    return selected;
  }

  /// Last-resort screenshot region for an incoming block when Vision did not
  /// emit a rectangle. This is bounded by sender labels, stays on the customer
  /// side, and rejects blocks containing ordinary message text.
  OcrVisualRegion? fallbackLatestCustomerBlock(
      OcrInspection inspection, String customer) {
    final left = inspection.chatLeft ?? .15;
    final right = inspection.chatRight ?? .68;
    final bottom = inspection.chatBottom ?? .90;
    final labels = inspection.observations
        .where((item) =>
            item.x + item.width / 2 >= left &&
            item.x + item.width / 2 < right &&
            (_isCustomer(item.text, customer) || _isSeller(item.text)))
        .toList()
      ..sort((a, b) => a.y.compareTo(b.y));

    for (var index = labels.length - 1; index >= 0; index--) {
      final label = labels[index];
      if (!_isCustomer(label.text, customer)) continue;
      final start = label.y + label.height + .004;
      final end =
          index + 1 < labels.length ? labels[index + 1].y - .004 : bottom;
      final height = end - start;
      if (height < .07) continue;
      final width = (right - left).clamp(.12, .42).toDouble();
      final candidate = OcrVisualRegion(
        x: left,
        y: start,
        width: width,
        height: height.clamp(.07, .60).toDouble(),
        confidence: 0,
      );
      final bodyCharacters = inspection.observations.where((item) {
        final centerX = item.x + item.width / 2;
        final centerY = item.y + item.height / 2;
        if (centerX < candidate.x ||
            centerX > candidate.x + candidate.width ||
            centerY < candidate.y ||
            centerY > candidate.y + candidate.height) {
          return false;
        }
        final text = item.text.trim();
        return !RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$').hasMatch(text) &&
            !text.contains('格志打印机');
      }).fold<int>(
          0,
          (total, item) =>
              total + item.text.replaceAll(RegExp(r'\s+'), '').length);
      // Absence of readable content can justify a read-only cache probe.
      // A short message ("hi", "no", "好") is still text, not an upload.
      if (bodyCharacters == 0 &&
          !containsInterfaceMetadata(candidate, inspection.observations)) {
        return candidate;
      }
    }
    return null;
  }

  bool _validGeometry(OcrVisualRegion region, double left, double right) =>
      region.x >= left &&
      region.x + region.width <= right &&
      region.y >= .14 &&
      region.y + region.height <= .90 &&
      region.width >= .035 &&
      region.height >= .065 &&
      // JD's video previews can occupy about half of the captured window.
      // Rejecting them here prevents both capture and the unanswered-message
      // recovery path from ever seeing the new customer turn.
      region.width <= .60 &&
      region.height <= .76;

  bool isTextDense(OcrVisualRegion region, List<OcrObservation> observations) {
    final contained = observations.where((text) {
      final centerX = text.x + text.width / 2;
      final centerY = text.y + text.height / 2;
      return centerX >= region.x &&
          centerX <= region.x + region.width &&
          centerY >= region.y &&
          centerY <= region.y + region.height;
    }).toList(growable: false);
    if (contained.length < 2) return false;
    final characters = contained.fold<int>(
        0, (total, item) => total + item.text.replaceAll(' ', '').length);
    if (characters < 20) return false;
    final textArea = contained.fold<double>(
        0, (total, item) => total + item.width * item.height);
    final regionArea = region.width * region.height;
    return regionArea > 0 && textArea / regionArea >= .12;
  }

  /// Readable content requires a visual original-file match, not merely a
  /// nearby cache clock. This also protects short text in an oversized region.
  bool hasReadableText(
          OcrVisualRegion region, List<OcrObservation> observations) =>
      observations.any((item) {
        final x = item.x + item.width / 2;
        final y = item.y + item.height / 2;
        return item.confidence >= .30 &&
            x >= region.x &&
            x <= region.x + region.width &&
            y >= region.y &&
            y <= region.y + region.height &&
            RegExp(r'[A-Za-z0-9\u3400-\u9fff]')
                .hasMatch(sanitizeJdOcrText(item.text));
      });

  /// Short typed bubbles are not uploads merely because Vision found a
  /// rectangle. Keep their text unless an original cache file actually matches.
  /// Small numeric/control fragments inside a larger photo do not qualify.
  bool looksLikeShortTypedBubble(
      OcrVisualRegion region, List<OcrObservation> observations) {
    if (region.height > .09 || region.width <= 0 || region.height <= 0) {
      return false;
    }
    final lines = observations.where((item) {
      final x = item.x + item.width / 2;
      final y = item.y + item.height / 2;
      return item.confidence >= .30 &&
          x >= region.x &&
          x <= region.x + region.width &&
          y >= region.y &&
          y <= region.y + region.height;
    }).toList();
    if (lines.isEmpty || lines.length > 3) return false;
    final text = lines.map((line) => line.text.trim()).join(' ');
    if (!RegExp(r'[A-Za-z]{2,}|[A-Za-z]+[0-9]+[A-Za-z0-9]*|[\u3400-\u9fff]{2,}')
        .hasMatch(text)) {
      return false;
    }
    final area = lines.fold<double>(
        0, (total, line) => total + line.width * line.height);
    return area / (region.width * region.height) >= .20;
  }

  /// A cache miss may retain an actual sender-bounded rectangle, not an
  /// invented empty viewport. Native code additionally checks the pixels
  /// outside OCR boxes so long text bubbles cannot become image previews.
  /// No brightness/contrast rule: a white/grey attachment is still evidence.
  bool mayRetainAttachmentPreview(
      OcrInspection inspection, String customer, OcrVisualRegion region) {
    if (!isRecentCustomerMedia(inspection, customer, region) ||
        senderYForRegion(inspection, customer, region) == null ||
        containsInterfaceMetadata(region, inspection.observations) ||
        looksLikeShortTypedBubble(region, inspection.observations)) {
      return false;
    }
    return inspection.visualRegions.any((actual) =>
            (actual.x - region.x).abs() < .001 &&
            (actual.y - region.y).abs() < .001 &&
            (actual.width - region.width).abs() < .001 &&
            (actual.height - region.height).abs() < .001) &&
        customerBlocks(inspection, customer).any((block) => block.owns(region));
  }

  /// Coordinates remain window-normalized across the native boundary. Include
  /// low-confidence words too: an uncertain "hi" is not absence of text.
  List<Map<String, double>> previewTextRegions(
          OcrInspection inspection, OcrVisualRegion region) =>
      inspection.observations
          .where((item) {
            final x = item.x + item.width / 2;
            final y = item.y + item.height / 2;
            return x >= region.x &&
                x <= region.x + region.width &&
                y >= region.y &&
                y <= region.y + region.height &&
                RegExp(r'[A-Za-z0-9\u3400-\u9fff]')
                    .hasMatch(sanitizeJdOcrText(item.text));
          })
          .map((item) => {
                'x': item.x,
                'y': item.y,
                'width': item.width,
                'height': item.height,
              })
          .toList(growable: false);

  /// A cache match is verified against the visible customer-owned pixels, so
  /// readable text inside that image is evidence about the image rather than
  /// evidence that the region is an ordinary chat bubble.
  bool shouldSaveImage(
    OcrVisualRegion region,
    List<OcrObservation> observations, {
    required bool fromVerifiedCache,
  }) =>
      !containsInterfaceMetadata(region, observations) &&
      (fromVerifiedCache || !isTextDense(region, observations));

  bool _isCustomer(String value, String customer) {
    return customerSenderLabelMatches(value, customer);
  }

  bool _isSeller(String value) {
    final text = value.trim();
    return (text.contains('旗舰店') &&
            (text.contains(':') || text.contains('：'))) ||
        RegExp(r'格志打印机[\u3400-\u9fffA-Za-z0-9_-]{1,12}').hasMatch(text);
  }
}

class OcrCustomerMessageBlock {
  const OcrCustomerMessageBlock(
      {required this.sentAt,
      required this.senderY,
      required this.bodyTop,
      required this.bodyBottom,
      required this.sameTimeIndex,
      required this.sameTimeCount});
  final DateTime sentAt;
  final double senderY;
  final double bodyTop;
  final double bodyBottom;
  final int sameTimeIndex;
  final int sameTimeCount;

  bool owns(OcrVisualRegion region) =>
      region.y >= bodyTop - .003 &&
      region.y + region.height <= bodyBottom + .001;
}
