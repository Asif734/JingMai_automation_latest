import '../domain/media_identity.dart';
import '../platform/macos_capture_adapter.dart';
import 'ocr_image_candidate_selector.dart';

/// Session-only geometry of an observed upload, NOT a cache ownership proof.
/// A refresh must re-find the exact customer/window/sender block. Never apply
/// old absolute screen coordinates, or mask every message at the same second.
class OcrMediaMasks {
  final List<_Footprint> _footprints = [];
  static const _lifetime = Duration(minutes: 10);

  List<OcrVisualRegion> regions(OcrInspection inspection, String customer) {
    _footprints.removeWhere((entry) =>
        inspection.capturedAt.difference(entry.firstSeen) > _lifetime);
    final blocks =
        const OcrImageCandidateSelector().customerBlocks(inspection, customer);
    return [
      for (final entry in _footprints)
        if (entry.matches(inspection, customer))
          for (final block in blocks)
            if (entry.matchesBlock(block))
              if (entry.project(block) case final region?) region,
    ];
  }

  void remember(
      OcrInspection inspection, String customer, OcrVisualRegion region) {
    if (inspection.windowId == 0) return;
    final blocks = const OcrImageCandidateSelector()
        .customerBlocks(inspection, customer)
        .where((block) => block.owns(region));
    if (blocks.length != 1) return;
    final block = blocks.single;
    // A later Vision scan may return just the play/button row. Do not shrink
    // the already known full thumbnail to that nested control rectangle.
    if (regions(inspection, customer)
        .any((known) => _contains(known, region))) {
      return;
    }
    _footprints.removeWhere((entry) {
      if (!entry.matches(inspection, customer) || !entry.matchesBlock(block)) {
        return false;
      }
      final known = entry.project(block);
      return known != null && _contains(region, known);
    });
    _footprints.add(_Footprint(inspection, customer, block, region));
  }

  /// Restore a full media envelope only where a fresh Vision rectangle still
  /// supports it. OCR masking may survive missing rectangles; clicking cannot
  /// be authorized by historical geometry alone. Native snapshot/AX checks
  /// remain mandatory for every actual acquisition.
  List<OcrVisualRegion> restoreCandidates(OcrInspection inspection,
      String customer, List<OcrVisualRegion> candidates) {
    final masks = regions(inspection, customer);
    final result = <OcrVisualRegion>[];
    for (final candidate in candidates) {
      final matching = masks.where((mask) => _contains(mask, candidate));
      final region = matching.length == 1 ? matching.single : candidate;
      if (!result.any((other) => _contains(other, region))) result.add(region);
    }
    return result;
  }

  static bool _contains(OcrVisualRegion outer, OcrVisualRegion inner) =>
      inner.x >= outer.x - .004 &&
      inner.y >= outer.y - .004 &&
      inner.x + inner.width <= outer.x + outer.width + .004 &&
      inner.y + inner.height <= outer.y + outer.height + .004;
}

class _Footprint {
  _Footprint(OcrInspection inspection, this.customer,
      OcrCustomerMessageBlock block, OcrVisualRegion region)
      : window = inspection.windowId,
        width = inspection.imageWidth,
        height = inspection.imageHeight,
        chatLeft = inspection.chatLeft,
        chatRight = inspection.chatRight,
        firstSeen = inspection.capturedAt,
        second = mediaMessageSecond(block.sentAt),
        ordinal = block.sameTimeIndex,
        count = block.sameTimeCount,
        x = region.x,
        offsetY = region.y - block.senderY,
        regionWidth = region.width,
        regionHeight = region.height;
  final String customer;
  final int window, width, height, second, ordinal, count;
  final double? chatLeft, chatRight;
  final DateTime firstSeen;
  final double x, offsetY, regionWidth, regionHeight;

  bool matches(OcrInspection inspection, String owner) =>
      customer == owner &&
      inspection.activeCustomerId == customer &&
      inspection.windowId == window &&
      inspection.imageWidth == width &&
      inspection.imageHeight == height &&
      inspection.chatLeft == chatLeft &&
      inspection.chatRight == chatRight &&
      !inspection.capturedAt.isBefore(firstSeen);
  bool matchesBlock(OcrCustomerMessageBlock block) =>
      mediaMessageSecond(block.sentAt) == second &&
      block.sameTimeIndex == ordinal &&
      block.sameTimeCount == count;
  OcrVisualRegion? project(OcrCustomerMessageBlock block) {
    final top = block.senderY + offsetY;
    final bottom = (top + regionHeight).clamp(0.0, block.bodyBottom);
    if (top < block.bodyTop - .003 || bottom - top < .04) return null;
    return OcrVisualRegion(
        x: x, y: top, width: regionWidth, height: bottom - top, confidence: 0);
  }
}
