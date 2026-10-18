import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// A thread-local, nestable budget for native AX work. A timed-out read poisons
/// its entire snapshot; incomplete identity evidence must never authorize input.
final class AccessibilityBudget {
  private static let key = "com.grozziie.jdAutomation.axBudget"
  static var current: AccessibilityBudget? {
    Thread.current.threadDictionary[key] as? AccessibilityBudget
  }
  private let parent: AccessibilityBudget?
  let deadline: Date
  private let uptimeDeadline: TimeInterval
  private var failed = false

  init(deadline: Date, uptimeDeadline: TimeInterval? = nil) {
    parent = Self.current
    self.deadline = min(deadline, parent?.deadline ?? deadline)
    let localLimit = ProcessInfo.processInfo.systemUptime + max(0, deadline.timeIntervalSinceNow)
    self.uptimeDeadline = min(localLimit, uptimeDeadline ?? localLimit,
                              parent?.uptimeDeadline ?? localLimit)
    Thread.current.threadDictionary[Self.key] = self
  }

  var isCurrent: Bool {
    !failed && (parent?.isCurrent ?? true) &&
      ProcessInfo.processInfo.systemUptime < uptimeDeadline
  }

  func invalidate() {
    failed = true
    parent?.invalidate()
  }

  func close() {
    if let parent { Thread.current.threadDictionary[Self.key] = parent }
    else { Thread.current.threadDictionary.removeObject(forKey: Self.key) }
  }
}

/// Identity evidence is never repaired using OCR lookalikes or prefixes.
enum CustomerSafety {
  struct AttachmentMenuLine {
    let text: String
    let confidence: Float
    let frame: CGRect
  }

  /// Low-confidence icon+label OCR is acceptable only as one complete, ordered
  /// four-row attachment menu. Never authorize a click from a substring alone.
  static func attachmentSaveTarget(_ lines: [AttachmentMenuLine]) -> CGRect? {
    let labels = ["举报", "另存为", "引用", "多选"]
    var rows: [AttachmentMenuLine] = []
    for label in labels {
      let matches = lines.filter { $0.confidence >= 0.25 && mediaMenuLabel($0.text) == label }
      guard matches.count == 1 else { return nil }
      rows.append(matches[0])
    }
    let gaps = (1..<rows.count).map { rows[$0].frame.midY - rows[$0 - 1].frame.midY }
    guard let smallest = gaps.min(), let largest = gaps.max(),
          smallest >= 12, largest <= 200, largest <= smallest * 1.65 else { return nil }
    let xs = rows.map { $0.frame.minX }
    guard (xs.max()! - xs.min()!) < largest * 1.6,
          rows.allSatisfy({ $0.frame.width > 8 && $0.frame.width < largest * 7 }) else { return nil }
    return rows[1].frame
  }

  static func safeAttachmentFilename(_ raw: String) -> String? {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 180, !name.hasPrefix("."),
          !name.contains("/"), !name.contains("\\"), !name.contains(":"),
          !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
    let ext = (name as NSString).pathExtension.lowercased()
    guard ext.isEmpty || ["jpg", "jpeg", "png", "webp", "gif", "heic", "mp4", "mov", "m4v", "webm"].contains(ext) else { return nil }
    return name
  }

  static func attachmentFilenameMatches(_ actual: String, expected: String) -> Bool {
    guard safeAttachmentFilename(expected) != nil, safeAttachmentFilename(actual) != nil else { return false }
    if actual == expected { return true }
    return (expected as NSString).pathExtension.isEmpty &&
      (actual as NSString).deletingPathExtension == expected
  }

  /// Detect the actual payload, never a thumbnail's colour or filename suffix.
  /// A container still needs a real video stream before it becomes a video.
  static func attachmentContainerKind(_ bytes: Data) -> String? {
    if let source = CGImageSourceCreateWithData(bytes as CFData, nil),
       CGImageSourceGetStatus(source) == .statusComplete,
       CGImageSourceGetCount(source) > 0,
       CGImageSourceCreateImageAtIndex(source, 0, nil) != nil { return "image" }
    guard bytes.count >= 12 else { return nil }
    let box = String(data: bytes.subdata(in: 4..<8), encoding: .ascii)
    if ["ftyp", "moov", "mdat", "wide"].contains(box ?? "") ||
        Array(bytes.prefix(4)) == [0x1a, 0x45, 0xdf, 0xa3] { return "video_container" }
    return nil
  }

  /// The old cache-first receive window, with cross-turn ambiguity rejection.
  /// Do not use the newest file or a cache modified clock as the message ID.
  static func cacheVideoClockMatches(modified: Date, expected: Date, now: Date,
                                    competing: [Date]) -> Bool {
    let offset = modified.timeIntervalSince(expected)
    let age = now.timeIntervalSince(modified)
    guard offset >= -5, offset <= 60, age >= -5, age <= 5 * 60 else { return false }
    let delta = abs(offset)
    return !competing.contains { abs(modified.timeIntervalSince($0)) <= delta + 3 }
  }

  /// The accessory workbench can share activation with its verified JingMai
  /// launcher. Parent activation alone is never permission to click: the hit
  /// window must still belong to the exact workbench process.
  static func mediaReferenceForeground(workbenchPID: Int32, launcherPID: Int32?,
      frontmostPID: Int32?, hitPID: Int32?, hitExpectedWindow: Bool,
      hitOwnedMenu: Bool = false, allowOwnedOverlay: Bool = false) -> Bool {
    guard let frontmostPID, workbenchPID > 0,
          hitPID == workbenchPID,
          frontmostPID == workbenchPID || frontmostPID == launcherPID else { return false }
    return hitExpectedWindow || (allowOwnedOverlay && hitOwnedMenu)
  }

  /// Coordinates belong to the OCR screenshot, not merely to a customer ID.
  /// Check the entire strip from its sender through the media so a scroll,
  /// inserted warning/reply, resize, or changed thumbnail requires fresh OCR.
  static func mediaSnapshotMatches(source: CGImage, current: CGImage,
                                   region: CGRect, senderY: Double?) -> Bool {
    guard source.width == current.width, source.height == current.height,
          region.width >= 40, region.height >= 40,
          region.minX >= 0, region.minY >= 0,
          region.maxX <= CGFloat(source.width), region.maxY <= CGFloat(source.height)
    else { return false }
    let anchor = senderY.map { CGFloat($0) * CGFloat(source.height) } ?? region.minY - 80
    guard anchor >= 0, anchor <= region.minY else { return false }
    let x = max(0, region.minX - 16)
    let y = max(0, anchor - 8)
    let proof = CGRect(x: x, y: y,
      width: min(CGFloat(source.width) - x, max(region.width + 16, 600)),
      height: region.maxY - y).integral
    guard let a = source.cropping(to: proof), let b = current.cropping(to: proof) else { return false }
    func pixels(_ image: CGImage) -> Data? {
      let stride = image.width * 4
      var data = Data(count: stride * image.height)
      let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data: bytes.baseAddress, width: image.width,
          height: image.height, bitsPerComponent: 8, bytesPerRow: stride,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
      }
      return rendered ? data : nil
    }
    guard let aBytes = pixels(a), let bBytes = pixels(b) else { return false }
    return aBytes == bBytes
  }

  struct HeaderLabel {
    let text: String
    let frame: CGRect
  }

  /// JD places the customer name above its quick-transfer control, while the
  /// shop name is separately right-aligned on the same line. Do not treat all
  /// header text as identity evidence, and never choose based on the requested
  /// customer's spelling (that would make verification circular).
  static func activeHeaderIdentity(labels: [HeaderLabel], chatFrame: CGRect,
                                   quickTransferFrames: [CGRect]) -> String? {
    guard chatFrame.width > 0, chatFrame.height > 0 else { return nil }
    let anchors = quickTransferFrames.filter { anchor in
      anchor.width > 0 && anchor.height > 0 &&
        anchor.minX >= chatFrame.minX && anchor.maxX <= chatFrame.maxX &&
        anchor.minY >= chatFrame.minY &&
        anchor.maxY <= chatFrame.minY + max(70, anchor.height * 5)
    }
    guard anchors.count == 1, let anchor = anchors.first else { return nil }
    let alignmentTolerance = max(18, anchor.width * 1.5)
    let labelGap = max(36, anchor.height * 2.5)
    let candidates = labels.filter { label in
      let frame = label.frame
      guard frame.width > 0, frame.height > 0,
            frame.minX >= chatFrame.minX, frame.maxX <= chatFrame.maxX,
            frame.minY >= chatFrame.minY,
            frame.maxY <= anchor.minY + 2,
            frame.maxY >= anchor.minY - labelGap,
            abs(frame.minX - anchor.minX) <= alignmentTolerance else { return false }
      return true
    }
    // Incomplete/conflicting evidence in the customer slot cannot be ignored
    // merely because another candidate is complete.
    guard !candidates.isEmpty,
          candidates.allSatisfy({ fullIdentity($0.text) != nil }) else { return nil }
    return uniqueIdentity(candidates.map(\.text))
  }

  static func operationCurrent(_ deadline: Date, now: Date = Date()) -> Bool {
    now < deadline
  }
  static func fullIdentity(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty, !value.contains("…"), !value.contains("..."),
          !["Unknown customer", "unknown", "暂无选中的会话"].contains(value),
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return value
  }

  static func matches(_ left: String?, _ right: String?) -> Bool {
    guard let a = fullIdentity(left), let b = fullIdentity(right) else { return false }
    return a.utf8.elementsEqual(b.utf8)
  }

  /// Allows a screenshot OCR spelling to be reconciled with the independently
  /// read AX header only for a complete JD identity with one edit at most.
  /// Every later capture/send still requires the exact AX identity.
  static func canReconcileSidebarOCR(_ observed: String?, verifiedAX: String?) -> Bool {
    guard let observed = fullIdentity(observed),
          let verified = fullIdentity(verifiedAX) else { return false }
    if observed.utf8.elementsEqual(verified.utf8) { return true }
    let jdPattern = try! NSRegularExpression(pattern: #"^jd_[A-Za-z0-9]{8,}$"#)
    func isJD(_ value: String) -> Bool {
      jdPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
    guard isJD(observed), isJD(verified),
          abs(observed.count - verified.count) <= 1 else { return false }
    let left = Array(observed.utf8)
    let right = Array(verified.utf8)
    var previous = Array(0...right.count)
    for leftIndex in 1...left.count {
      var current = Array(repeating: 0, count: right.count + 1)
      current[0] = leftIndex
      var rowMinimum = current[0]
      for rightIndex in 1...right.count {
        let substitution = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
        current[rightIndex] = min(
          current[rightIndex - 1] + 1,
          previous[rightIndex] + 1,
          previous[rightIndex - 1] + substitution)
        rowMinimum = min(rowMinimum, current[rightIndex])
      }
      if rowMinimum > 1 { return false }
      previous = current
    }
    return previous.last! <= 1
  }

  static func canRecoverOwnedComposer(owner: String, active: String?,
                                      insertedText: String, currentText: String,
                                      sameElement: Bool) -> Bool {
    matches(owner, active) && sameElement && !insertedText.isEmpty &&
      insertedText.utf8.elementsEqual(currentText.utf8)
  }

  static func uniqueIdentity(_ values: [String]) -> String? {
    let full = values.compactMap(fullIdentity)
    let identities = Set(full.map { Array($0.utf8) })
    return identities.count == 1 ? full.first : nil
  }

  static func uniqueVideoDigest(_ digests: [String]) -> String? {
    guard !digests.isEmpty, digests.allSatisfy({ !$0.isEmpty }) else { return nil }
    return Set(digests).count == 1 ? digests.first : nil
  }

  enum PairedVideoCacheMatch {
    case matched(URL)
    case notFound
    case unresolved(String)
  }

  /// The native Save As panel supplies the exact name of the selected message,
  /// independently of preview contrast. Never accept a path, partial name, or
  /// a timestamp-derived guess from the account-wide cache.
  static func videoCacheStem(saveAsName: String) -> String? {
    mediaCacheStem(saveAsName: saveAsName, extensions: ["mp4", "mov", "m4v", "webm"])
  }

  static func mediaCacheStem(saveAsName: String,
                            extensions: Set<String> = ["mp4", "mov", "m4v", "webm", "jpg", "jpeg", "png", "webp"]) -> String? {
    let name = saveAsName.trimmingCharacters(in: .whitespacesAndNewlines)
    let ext = (name as NSString).pathExtension.lowercased()
    guard ext.isEmpty || extensions.contains(ext) else { return nil }
    let stem = (name as NSString).deletingPathExtension.lowercased()
    guard stem.range(of: #"^(?:[a-f0-9]{32}|[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$"#,
                     options: .regularExpression) != nil else { return nil }
    return stem.replacingOccurrences(of: "-", with: "")
  }

  /// OCR sometimes includes the adjacent menu icon in the same observation.
  /// Accept only a known label with bounded control glyphs, never arbitrary
  /// substrings from the underlying customer conversation.
  static func mediaMenuLabel(_ raw: String) -> String? {
    let value = raw.filter { !$0.isWhitespace }
    let controls = CharacterSet(charactersIn: "□▣回◎口日目同囧三④③②①鱼苎☐☑🔖…⋯")
      .union(.symbols).union(.punctuationCharacters)
    for label in ["另存为", "举报", "引用", "多选", "添加到表情", "复制"] {
      guard let range = value.range(of: label) else { continue }
      let remainder = String(value[..<range.lowerBound]) + String(value[range.upperBound...])
      if remainder.count <= 3 && remainder.unicodeScalars.allSatisfy({ controls.contains($0) }) {
        return label
      }
    }
    return nil
  }

  static func referencedCachedVideo(saveAsName: String, candidates: [URL],
                                    deadline: TimeInterval) -> PairedVideoCacheMatch {
    guard let stem = videoCacheStem(saveAsName: saveAsName) else {
      return .unresolved("video_message_reference_invalid")
    }
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    var matches: [(URL, String)] = []
    for url in candidates {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        return .unresolved("video_cache_check_timeout")
      }
      let parent = url.deletingLastPathComponent()
      guard parent.lastPathComponent == "videos",
            parent.deletingLastPathComponent().lastPathComponent.hasPrefix("chat_"),
            videoCacheStem(saveAsName: url.lastPathComponent) == stem,
            ["mp4", "mov", "m4v", "webm"].contains(url.pathExtension.lowercased()),
            url.resolvingSymlinksInPath().deletingLastPathComponent() == parent.standardizedFileURL,
            let before = try? url.resourceValues(forKeys: keys),
            before.isRegularFile == true, before.isSymbolicLink != true,
            let size = before.fileSize, size > 0, size <= 100 * 1024 * 1024,
            let modified = before.contentModificationDate else { continue }
      guard let bytes = try? Data(contentsOf: url), bytes.count == size,
            let after = try? url.resourceValues(forKeys: keys),
            after.fileSize == size, after.contentModificationDate == modified else {
        return .unresolved("video_cache_changed_during_check")
      }
      matches.append((url, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
      if uniqueVideoDigest(matches.map { $0.1 }) == nil {
        return .unresolved("video_message_reference_ambiguous")
      }
    }
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      return .unresolved("video_cache_check_timeout")
    }
    guard let first = matches.first else { return .notFound }
    return .matched(first.0)
  }

  /// Restore cache-first acquisition without assigning the newest shared-cache
  /// file to whichever customer happens to be open. JD's JPEG and original MP4
  /// share a basename within ONE chat bucket. Match that JPEG to the verified
  /// sender's visible bubble, then copy the paired original, not a re-encoded
  /// frame. Cache clocks only bound discovery; they never establish ownership.
  static func pairedCachedVideo(visible: CGImage, candidates: [URL],
                                deadline: TimeInterval) -> PairedVideoCacheMatch {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    var matches: [(URL, String)] = []
    for video in candidates {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        return .unresolved("video_cache_check_timeout")
      }
      let bucket = video.deletingLastPathComponent().deletingLastPathComponent()
      guard video.deletingLastPathComponent().lastPathComponent == "videos",
            bucket.lastPathComponent.hasPrefix("chat_"),
            video.resolvingSymlinksInPath().deletingLastPathComponent() ==
              bucket.appendingPathComponent("videos").standardizedFileURL,
            let before = try? video.resourceValues(forKeys: keys),
            before.isRegularFile == true, before.isSymbolicLink != true,
            let size = before.fileSize, size > 0, size <= 100 * 1024 * 1024,
            let modified = before.contentModificationDate else { continue }
      let imageDirectory = bucket.appendingPathComponent("images", isDirectory: true)
      let stem = video.deletingPathExtension().lastPathComponent
      var paired = false
      for ext in ["jpg", "jpeg", "png", "webp"] {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
          return .unresolved("video_cache_check_timeout")
        }
        let thumbnail = imageDirectory.appendingPathComponent("\(stem).\(ext)")
        guard thumbnail.resolvingSymlinksInPath().deletingLastPathComponent() == imageDirectory,
              let thumbBefore = try? thumbnail.resourceValues(forKeys: keys),
              thumbBefore.isRegularFile == true, thumbBefore.isSymbolicLink != true,
              let thumbSize = thumbBefore.fileSize, thumbSize > 0, thumbSize <= 5 * 1024 * 1024,
              let thumbModified = thumbBefore.contentModificationDate,
              let source = CGImageSourceCreateWithURL(thumbnail as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
              ] as CFDictionary),
              cachedThumbnailMatches(visible, image) else { continue }
        guard let thumbAfter = try? thumbnail.resourceValues(forKeys: keys),
              thumbAfter.fileSize == thumbSize,
              thumbAfter.contentModificationDate == thumbModified else {
          return .unresolved("video_cache_changed_during_check")
        }
        paired = true
        break
      }
      guard paired else { continue }
      guard let bytes = try? Data(contentsOf: video), bytes.count == size,
            let after = try? video.resourceValues(forKeys: keys),
            after.fileSize == size, after.contentModificationDate == modified else {
        return .unresolved("video_cache_changed_during_check")
      }
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      matches.append((video, digest))
      if uniqueVideoDigest(matches.map { $0.1 }) == nil {
        return .unresolved("video_cache_match_ambiguous")
      }
    }
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      return .unresolved("video_cache_check_timeout")
    }
    guard let first = matches.first else { return .notFound }
    return .matched(first.0)
  }

  /// JD stretches/dims its cached thumbnail and overlays a play control. Match
  /// detailed spatial structure with a bounded brightness correction instead
  /// of requiring the JPEG to equal one decoded MP4 frame. No time-only match.
  static func cachedThumbnailMatches(_ visible: CGImage, _ cached: CGImage) -> Bool {
    func signature(_ image: CGImage) -> [Double]? {
      guard let pixels = rgbaPixels(image, width: 48, height: 48) else { return nil }
      var result: [Double] = []
      for y in 1..<11 {
        for x in 1..<11 where !(4...7 ~= x && 4...7 ~= y) {
          for channel in 0..<3 {
            var total = 0
            for py in (y * 4)..<(y * 4 + 4) {
              for px in (x * 4)..<(x * 4 + 4) {
                total += Int(pixels[(py * 48 + px) * 4 + channel])
              }
            }
            result.append(Double(total) / 16)
          }
        }
      }
      guard let lo = result.min(), let hi = result.max(), hi - lo >= 35 else { return nil }
      return result
    }
    guard let reference = signature(cached) else { return false }
    var previews = [visible]
    if let crop = mediaPreviewCrop(visible) { previews.append(crop) }
    for preview in previews {
      let ratioA = Double(preview.width) / Double(max(1, preview.height))
      let ratioB = Double(cached.width) / Double(max(1, cached.height))
      guard abs(log(ratioA / ratioB)) <= 0.8,
            let observed = signature(preview) else { continue }
      var errors: [Double] = []
      var valid = true
      for channel in 0..<3 {
        let a = stride(from: channel, to: reference.count, by: 3).map { reference[$0] }
        let b = stride(from: channel, to: observed.count, by: 3).map { observed[$0] }
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        let varianceA = a.map { pow($0 - meanA, 2) }.reduce(0, +)
        let varianceB = b.map { pow($0 - meanB, 2) }.reduce(0, +)
        let covariance = zip(a, b).map { ($0 - meanA) * ($1 - meanB) }.reduce(0, +)
        guard varianceA / Double(a.count) >= 100,
              varianceB / Double(b.count) >= 64 else { valid = false; break }
        let gain = covariance / varianceA
        let offset = meanB - gain * meanA
        let correlation = covariance / sqrt(varianceA * varianceB)
        guard gain >= 0.65, gain <= 1.35, abs(offset) <= 45,
              correlation >= 0.98 else { valid = false; break }
        errors.append(contentsOf: zip(a, b).map { abs(gain * $0 + offset - $1) })
      }
      if valid && !errors.isEmpty && errors.reduce(0, +) / Double(errors.count) <= 5 &&
          errors.filter({ $0 > 18 }).count <= 6 { return true }
    }
    return false
  }

  // Ignore the central play overlay, but require detailed, closely matching
  // colour evidence elsewhere. Flat placeholder thumbnails are not evidence.
  static func videoSignature(_ image: CGImage) -> [Double]? {
    var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
    let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32,
          bitsPerComponent: 8, bytesPerRow: 128,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
      return true
    }
    guard drawn else { return nil }
    var signature: [Double] = []
    for y in 1..<7 {
      for x in 1..<7 where !(2...5 ~= x && 2...5 ~= y) {
        for channel in 0..<3 {
          var total = 0
          for py in (y * 4)..<(y * 4 + 4) {
            for px in (x * 4)..<(x * 4 + 4) {
              total += Int(pixels[(py * 32 + px) * 4 + channel])
            }
          }
          signature.append(Double(total) / 16)
        }
      }
    }
    guard let lo = signature.min(), let hi = signature.max(), hi - lo >= 35 else { return nil }
    return signature
  }

  static func videoMatches(_ left: CGImage, _ right: CGImage) -> Bool {
    let ratioA = Double(left.width) / Double(max(left.height, 1))
    let ratioB = Double(right.width) / Double(max(right.height, 1))
    guard abs(log(ratioA / ratioB)) <= 0.12,
          let a = videoSignature(left), let b = videoSignature(right), a.count == b.count else { return false }
    let differences = zip(a, b).map { abs($0 - $1) }
    return differences.reduce(0, +) / Double(a.count) <= 12 &&
      differences.filter { $0 > 35 }.count <= 2
  }

  /// A retained preview is visible evidence, NOT ownership of a shared-cache
  /// original or proof of image vs video. The caller must independently prove
  /// the sender, timestamp, actual rectangle and unchanged window snapshot.
  /// Flat white/grey/black is allowed when there are no words. With words,
  /// require structure outside them rather than saving a plain typed bubble.
  static func attachmentPreviewHasVisualEvidence(_ image: CGImage,
                                                  textRegions: [CGRect]) -> Bool {
    guard image.width >= 40, image.height >= 40 else { return false }
    if textRegions.isEmpty { return true }
    let size = 64
    guard let pixels = rgbaPixels(image, width: size, height: size) else { return false }
    let masks = textRegions.map { $0.insetBy(dx: -0.025, dy: -0.025) }
    var samples: [[Double]] = []
    for y in 5..<59 { for x in 5..<59 {
      let point = CGPoint(x: (Double(x) + 0.5) / Double(size),
                          y: (Double(y) + 0.5) / Double(size))
      if masks.contains(where: { $0.contains(point) }) { continue }
      let p = (y * size + x) * 4
      samples.append((0..<3).map { Double(pixels[p + $0]) })
    } }
    guard samples.count >= 100 else { return false }
    let median = (0..<3).map { channel in
      samples.map { $0[channel] }.sorted()[samples.count / 2]
    }
    let background = samples.filter { sample in
      (0..<3).allSatisfy { abs(sample[$0] - median[$0]) <= 18 }
    }.count
    return Double(background) / Double(samples.count) < 0.90
  }

  /// Isolate a single photographic preview from an over-wide OCR crop. Text,
  /// watermarks and blank chat background must not enter cache comparisons.
  /// Missing or multiple substantial bands are deliberately unresolved.
  static func mediaPreviewCrop(_ image: CGImage) -> CGImage? {
    let scale = min(1, 384 / Double(max(image.width, image.height)))
    let width = max(1, Int(Double(image.width) * scale))
    let height = max(1, Int(Double(image.height) * scale))
    guard width >= 60, height >= 60,
          let pixels = rgbaPixels(image, width: width, height: height) else { return nil }
    func dark(_ x: Int, _ y: Int) -> Bool {
      let p = (y * width + x) * 4
      return min(pixels[p], pixels[p + 1], pixels[p + 2]) < 215
    }
    let rows = (0..<height).map { y in
      (0..<width).filter { dark($0, y) }.count >= Int(Double(width) * 0.45)
    }
    var bands: [Range<Int>] = []
    var start: Int?
    var last = 0
    let gap = max(2, height / 100)
    for y in 0..<height {
      if rows[y] {
        if start == nil { start = y }
        last = y
      } else if let beginning = start, y - last > gap {
        if last + 1 - beginning >= 60 { bands.append(beginning..<(last + 1)) }
        start = nil
      }
    }
    if let beginning = start, last + 1 - beginning >= 60 {
      bands.append(beginning..<(last + 1))
    }
    guard bands.count == 1, let band = bands.first else { return nil }
    let columns = (0..<width).filter { x in
      band.filter { dark(x, $0) }.count >= Int(Double(band.count) * 0.45)
    }
    guard let left = columns.first, let right = columns.last,
          right - left >= Int(Double(width) * 0.55) else { return nil }
    let bounds = CGRect(x: Double(left) / scale, y: Double(band.lowerBound) / scale,
                        width: Double(right - left + 1) / scale,
                        height: Double(band.count) / scale).integral
      .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return image.cropping(to: bounds)
  }

  /// JD can stretch a portrait clip's preview into a square card. Compare
  /// detailed colour evidence after isolating that card, not aspect ratios of
  /// the surrounding chat crop. The caller must still reject different clips
  /// that match, and independently verify the exact active customer.
  static func cachedVideoPreviewMatches(_ visible: CGImage, _ frame: CGImage) -> Bool {
    if videoMatches(visible, frame) { return true }
    guard let preview = mediaPreviewCrop(visible),
          let a = videoSignature(preview) else { return false }
    // A viewport can clip the top/bottom of a portrait card. Require at least
    // 70% of the original frame: a tiny matching patch is not ownership proof.
    for top in stride(from: 0.0, through: 0.30, by: 0.025) {
      for bottom in stride(from: 0.0, through: 0.30 - top, by: 0.025) {
        let bounds = CGRect(x: 0, y: CGFloat(frame.height) * CGFloat(top),
                            width: CGFloat(frame.width),
                            height: CGFloat(frame.height) * CGFloat(1 - top - bottom)).integral
        guard let part = frame.cropping(to: bounds),
          let b = videoSignature(part) else { continue }
        let differences = zip(a, b).map { abs($0 - $1) }
        if differences.reduce(0, +) / Double(a.count) <= 8 &&
            differences.filter({ $0 > 24 }).count <= 2 { return true }
      }
    }
    return false
  }

  /// Find the outlined circular play control throughout the supplied crop,
  /// including a thumbnail displaced by clipping or neighboring text. Both
  /// the circle and triangle need contrasting background; white paper alone
  /// must never count as a play button.
  static func hasVideoPlayControl(_ image: CGImage) -> Bool {
    let scale = min(1, 512 / Double(max(image.width, image.height)))
    let width = max(1, Int(Double(image.width) * scale))
    let height = max(1, Int(Double(image.height) * scale))
    guard min(width, height) >= 80,
          let pixels = rgbaPixels(image, width: width, height: height) else { return false }
    func brightness(_ x: Double, _ y: Double) -> Double {
      let px = Int(x.rounded()), py = Int(y.rounded())
      guard px >= 0, px < width, py >= 0, py < height else { return 0 }
      let p = (py * width + px) * 4
      return (0.2126 * Double(pixels[p]) + 0.7152 * Double(pixels[p + 1]) +
              0.0722 * Double(pixels[p + 2])) / 255
    }
    let shortest = Double(min(width, height))
    let step = max(3, Int(shortest * 0.012))
    for radius in stride(from: max(12, shortest * 0.055), through: shortest * 0.13, by: 2) {
      for y in stride(from: Int(radius), to: height - Int(radius), by: step) {
        for x in stride(from: Int(radius), to: width - Int(radius), by: step) {
          let cx = Double(x), cy = Double(y)
          guard brightness(cx, cy) >= 0.82,
                brightness(cx + radius * 0.25, cy) >= 0.82 else { continue }
          let corners = [(-0.35, -0.5), (0.4, -0.45), (0.4, 0.45)]
            .filter { brightness(cx + radius * $0.0, cy + radius * $0.1) < 0.78 }.count
          guard corners >= 2 else { continue }
          var ring = 0, outside = 0
          for sector in 0..<24 {
            let angle = Double(sector) * 2 * Double.pi / 24
            let c = cos(angle), s = sin(angle)
            if (-2...2).contains(where: { offset in
              brightness(cx + c * (radius + Double(offset)),
                         cy + s * (radius + Double(offset))) >= 0.85
            }) { ring += 1 }
            if brightness(cx + c * (radius + 6), cy + s * (radius + 6)) < 0.8 { outside += 1 }
          }
          if ring >= 20 && outside >= 15 { return true }
        }
      }
    }
    return false
  }

  private static func rgbaPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? pixels : nil
  }
}
