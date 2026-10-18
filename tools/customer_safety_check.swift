import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import AppKit

@main
struct CustomerSafetyCheck {
  static func main() throws {
    let ids = ["jd_6c67c99371fa4", "jd_frqocwtljjob", "格志打印机贝贝",
               "jd_vpliogabtzoy", "上海世亦小关", "jd_41aeec7741d05"]
    var checks = 0
    func verify(_ passed: Bool, _ message: String) {
      precondition(passed, message)
      checks += 1
    }
    // Replay the exact low-confidence menu from the Oct 18 screenshot.
    let menuRows = [
      CustomerSafety.AttachmentMenuLine(text: "举报", confidence: 0.30,
        frame: CGRect(x: 493, y: 532, width: 29, height: 19)),
      CustomerSafety.AttachmentMenuLine(text: "囧 另存为", confidence: 0.30,
        frame: CGRect(x: 469, y: 575, width: 67, height: 19)),
      CustomerSafety.AttachmentMenuLine(text: "引用", confidence: 1,
        frame: CGRect(x: 487, y: 619, width: 33, height: 19)),
      CustomerSafety.AttachmentMenuLine(text: "三 多选", confidence: 0.30,
        frame: CGRect(x: 469, y: 662, width: 52, height: 17)),
    ]
    verify(CustomerSafety.attachmentSaveTarget(menuRows) == menuRows[1].frame,
      "Actual low-confidence icon+Save As row was rejected")
    verify(CustomerSafety.attachmentSaveTarget(Array(menuRows.dropLast())) == nil,
      "Incomplete menu authorized an attachment action")
    verify(CustomerSafety.attachmentSaveTarget(menuRows + [menuRows[1]]) == nil,
      "Ambiguous duplicate Save As row authorized a click")
    let reversed = menuRows.enumerated().map { index, line in
      CustomerSafety.AttachmentMenuLine(text: line.text, confidence: line.confidence,
        frame: CGRect(x: 469, y: 662 - index * 43, width: 67, height: 19))
    }
    verify(CustomerSafety.attachmentSaveTarget(reversed) == nil,
      "Out-of-order underlying chat text was treated as an attachment menu")
    for bad in ["", "../video.mp4", "/private/video.mp4", "video\\other.mp4",
                ".hidden.mp4", "file.mp4.exe", "video\n.mp4"] {
      verify(CustomerSafety.safeAttachmentFilename(bad) == nil, "Unsafe exported filename accepted")
    }
    verify(CustomerSafety.attachmentFilenameMatches("actual.mp4", expected: "actual"),
      "Hidden Save-panel extension prevented recovery")
    verify(!CustomerSafety.attachmentFilenameMatches("other.mp4", expected: "actual"),
      "A different attachment name was selected")
    verify(!CustomerSafety.attachmentFilenameMatches("actual.jpg", expected: "actual.mp4"),
      "An image poster replaced an explicitly named video")
    let received = Date(timeIntervalSince1970: 1792297924) // JD 12:32:04
    let cachedAt = received.addingTimeInterval(2)
    verify(CustomerSafety.cacheVideoClockMatches(modified: cachedAt, expected: received,
      now: received.addingTimeInterval(8), competing: []), "12:32:04 cache video rejected")
    for other in [received, received.addingTimeInterval(1), received.addingTimeInterval(4)] {
      verify(!CustomerSafety.cacheVideoClockMatches(modified: cachedAt, expected: received,
        now: received.addingTimeInterval(8), competing: [other]), "Competing buyer/turn accepted")
    }
    verify(CustomerSafety.cacheVideoClockMatches(modified: cachedAt, expected: received,
      now: received.addingTimeInterval(8), competing: [received.addingTimeInterval(-33)]),
      "An earlier greeting blocked its customer's later video")
    verify(!CustomerSafety.cacheVideoClockMatches(modified: cachedAt,
      expected: received.addingTimeInterval(-33), now: received.addingTimeInterval(8),
      competing: [received]), "Video was attributed to an older misread greeting")
    for delta in [-6.0, 61.0] {
      verify(!CustomerSafety.cacheVideoClockMatches(modified: received.addingTimeInterval(delta),
        expected: received, now: received.addingTimeInterval(70), competing: []),
        "Out-of-window cache file accepted")
    }
    verify(!CustomerSafety.cacheVideoClockMatches(modified: cachedAt, expected: received,
      now: cachedAt.addingTimeInterval(301), competing: []), "Stale cache revived an inactive chat")
    for foreground in [Int32(10), Int32(20)] {
      verify(CustomerSafety.mediaReferenceForeground(workbenchPID: 10, launcherPID: 20,
        frontmostPID: foreground, hitPID: 10, hitExpectedWindow: true),
        "Verified workbench/launcher activation rejected")
    }
    verify(!CustomerSafety.mediaReferenceForeground(workbenchPID: 10, launcherPID: 20,
      frontmostPID: 30, hitPID: 10, hitExpectedWindow: true),
      "Foreign foreground app authorized a media click")
    verify(!CustomerSafety.mediaReferenceForeground(workbenchPID: 10, launcherPID: 20,
      frontmostPID: 20, hitPID: 20, hitExpectedWindow: true),
      "Launcher window mistaken for workbench")
    verify(!CustomerSafety.mediaReferenceForeground(workbenchPID: 10, launcherPID: 20,
      frontmostPID: 20, hitPID: 30, hitExpectedWindow: true),
      "Covering foreign window authorized a media click")
    verify(!CustomerSafety.mediaReferenceForeground(workbenchPID: 10, launcherPID: 20,
      frontmostPID: 20, hitPID: 10, hitExpectedWindow: false),
      "Wrong workbench window authorized the initial click")
    verify(CustomerSafety.mediaReferenceForeground(workbenchPID: 10, launcherPID: 20,
      frontmostPID: 20, hitPID: 10, hitExpectedWindow: false, hitOwnedMenu: true, allowOwnedOverlay: true),
      "Verified workbench menu rejected")
    verify(!CustomerSafety.mediaReferenceForeground(workbenchPID: 10, launcherPID: nil,
      frontmostPID: 20, hitPID: 10, hitExpectedWindow: true),
      "Unverified launcher accepted")
    verify(!CustomerSafety.mediaReferenceForeground(workbenchPID: 10, launcherPID: 20,
      frontmostPID: 20, hitPID: 424, hitExpectedWindow: false, allowOwnedOverlay: true),
      "Actual Dock icon hit authorized a media click")
    verify(!CustomerSafety.mediaReferenceForeground(workbenchPID: 10, launcherPID: 20,
      frontmostPID: 20, hitPID: 10, hitExpectedWindow: false, allowOwnedOverlay: true),
      "Arbitrary same-process window authorized as a menu")
    verify(!CustomerSafety.mediaReferenceForeground(workbenchPID: 10, launcherPID: 20,
      frontmostPID: 20, hitPID: 10, hitExpectedWindow: false, hitOwnedMenu: true),
      "Menu authorized the initial message click")
    for a in ids { for b in ids {
      verify(CustomerSafety.matches(a, b) == (a == b), "Cross-customer identity accepted")
      if a != b { verify(CustomerSafety.uniqueIdentity([a, b]) == nil, "Conflicting header accepted") }
    } }
    for bad in ["jd_4laeec7741d05", "JD_41AEEC7741D05", "jd_41aeec7741d0S", "jd_41aee…", "jd_41aee...", ""] {
      verify(!CustomerSafety.matches(bad, ids.last!), "Lookalike or prefix accepted")
    }
    verify(CustomerSafety.uniqueIdentity(["jd_41aee…"]) == nil, "Truncated identity accepted")
    verify(!CustomerSafety.matches(nil, nil), "Missing identity accepted")
    verify(!CustomerSafety.matches("caf\u{00e9}", "cafe\u{0301}"), "Different ID bytes merged by Unicode normalization")
    verify(CustomerSafety.uniqueIdentity(["caf\u{00e9}", "cafe\u{0301}"]) == nil, "Unicode ID ambiguity accepted")
    let clock = Date(timeIntervalSince1970: 100)
    verify(!CustomerSafety.operationCurrent(clock, now: clock), "Expired operation accepted")
    verify(CustomerSafety.operationCurrent(clock.addingTimeInterval(1), now: clock), "Current operation rejected")
    verify(!CustomerSafety.matches("Unknown customer", "Unknown customer"), "Unknown identity accepted")
    verify(CustomerSafety.canReconcileSidebarOCR(
      "jd_4laeec7741d05", verifiedAX: "jd_41aeec7741d05"),
      "A unique 1/l AX correction was rejected")
    verify(CustomerSafety.canReconcileSidebarOCR(
      "jd_frqocwtljob", verifiedAX: "jd_frqocwtljjob"),
      "A one-character AX insertion correction was rejected")
    verify(!CustomerSafety.canReconcileSidebarOCR(
      "上海世亦小关", verifiedAX: "上海世亦小闭"),
      "A non-JD identity was fuzzily redirected")
    verify(!CustomerSafety.canReconcileSidebarOCR(
      "jd_4laeec7741d05", verifiedAX: "jd_unrelated123"),
      "An unrelated AX identity was accepted")
    verify(CustomerSafety.uniqueVideoDigest(["same", "same"]) == "same", "Identical MP4 copies treated as different clips")
    verify(CustomerSafety.uniqueVideoDigest(["first", "second"]) == nil, "Different matching clips did not remain ambiguous")
    verify(CustomerSafety.uniqueVideoDigest([]) == nil, "Empty cache check accepted")
    verify(CustomerSafety.uniqueVideoDigest([""]) == nil, "Missing MP4 digest accepted")
    // Cache-first regression: no JD UI, decoder, or customer database is needed.
    // Two customers can share the same cache bucket or even the same basename.
    func photo(_ variant: Double) -> CGImage {
      let width = 216, height = 384
      var pixels = [UInt8](repeating: 255, count: width * height * 4)
      for y in 0..<height { for x in 0..<width { for c in 0..<3 {
        let value = 105 + 46 * sin(Double(x) / (25 + variant) + Double(c)) +
          36 * cos(Double(y) / (38 + variant) + Double(c) * 0.7 + variant)
        pixels[(y * width + x) * 4 + c] = UInt8(max(0, min(255, value)))
      } } }
      return pixels.withUnsafeMutableBytes { bytes in
        CGContext(data: bytes.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
      }
    }
    func renderedPreview(_ image: CGImage, border: Int = 0,
                         dim: CGFloat = 0.12, play: Bool = true) -> CGImage {
      let width = 320 + border * 2, height = 400 + border * 2
      let context = CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let card = CGRect(x: border, y: border, width: 320, height: 400)
      context.interpolationQuality = .high
      context.draw(image, in: card)
      context.setFillColor(CGColor(gray: 0, alpha: dim))
      context.fill(card)
      if play {
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(4)
        context.strokeEllipse(in: CGRect(x: card.midX - 28, y: card.midY - 28, width: 56, height: 56))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.move(to: CGPoint(x: card.midX - 9, y: card.midY - 16))
        context.addLine(to: CGPoint(x: card.midX + 17, y: card.midY))
        context.addLine(to: CGPoint(x: card.midX - 9, y: card.midY + 16))
        context.closePath()
        context.fillPath()
      }
      return context.makeImage()!
    }
    let originalMediaSnapshot = photo(0)
    let mediaRegion = CGRect(x: 20, y: 100, width: 160, height: 150)
    verify(CustomerSafety.mediaSnapshotMatches(source: originalMediaSnapshot,
      current: originalMediaSnapshot, region: mediaRegion, senderY: 0.10),
      "Unchanged sender/media snapshot rejected")
    verify(!CustomerSafety.mediaSnapshotMatches(source: originalMediaSnapshot,
      current: photo(5), region: mediaRegion, senderY: 0.10),
      "Changed or shifted media accepted at stale coordinates")
    verify(!CustomerSafety.mediaSnapshotMatches(source: originalMediaSnapshot,
      current: renderedPreview(originalMediaSnapshot), region: mediaRegion, senderY: 0.10),
      "Resized window accepted with obsolete OCR coordinates")
    verify(!CustomerSafety.mediaSnapshotMatches(source: originalMediaSnapshot,
      current: originalMediaSnapshot, region: mediaRegion, senderY: 0.9),
      "Sender anchor below the media accepted")
    verify(!CustomerSafety.mediaSnapshotMatches(source: originalMediaSnapshot,
      current: originalMediaSnapshot, region: CGRect(x: 200, y: 100, width: 100, height: 150), senderY: 0.1),
      "Out-of-bounds source proof accepted")
    let snapshotPNG = NSBitmapImageRep(cgImage: originalMediaSnapshot)
      .representation(using: .png, properties: [:])!
    let decodedSnapshot = NSImage(data: snapshotPNG)!
      .cgImage(forProposedRect: nil, context: nil, hints: nil)!
    verify(CustomerSafety.mediaSnapshotMatches(source: decodedSnapshot,
      current: originalMediaSnapshot, region: mediaRegion, senderY: 0.10),
      "PNG transport/color conversion invalidated unchanged OCR pixels")
    let changedContext = CGContext(data: nil, width: originalMediaSnapshot.width,
      height: originalMediaSnapshot.height, bitsPerComponent: 8,
      bytesPerRow: originalMediaSnapshot.width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    changedContext.draw(originalMediaSnapshot, in: CGRect(x: 0, y: 0,
      width: originalMediaSnapshot.width, height: originalMediaSnapshot.height))
    // Change only the sender strip, leaving the media pixels untouched.
    changedContext.setFillColor(CGColor(gray: 0, alpha: 1))
    changedContext.fill(CGRect(x: 25, y: 324, width: 100, height: 20))
    verify(!CustomerSafety.mediaSnapshotMatches(source: originalMediaSnapshot,
      current: changedContext.makeImage()!, region: mediaRegion, senderY: 0.10),
      "Changed sender accepted merely because the media pixels still match")
    let ownPhoto = photo(0), foreignPhoto = photo(6)
    let ownPreview = renderedPreview(ownPhoto)
    verify(CustomerSafety.cachedThumbnailMatches(ownPreview, ownPhoto),
           "Stretched/dimmed cached JPEG with play overlay was rejected")
    verify(CustomerSafety.cachedThumbnailMatches(renderedPreview(ownPhoto, border: 35), ownPhoto),
           "Chat margins prevented paired-thumbnail cache recovery")
    verify(CustomerSafety.cachedThumbnailMatches(renderedPreview(ownPhoto, play: false), ownPhoto),
           "Image original could not be recovered from a dimmed cache preview")
    verify(!CustomerSafety.cachedThumbnailMatches(ownPreview, foreignPhoto),
           "Another customer's thumbnail matched")
    let flatContext = CGContext(data: nil, width: 216, height: 384, bitsPerComponent: 8,
      bytesPerRow: 216 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    verify(!CustomerSafety.cachedThumbnailMatches(flatContext.makeImage()!, ownPhoto),
           "Empty cache placeholder accepted")
    let cacheRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("jd-cache-pair-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }
    // Actual media bytes, not filename/preview colour, decide the type.
    for shade: CGFloat in [0, 0.65, 1] {
      flatContext.setFillColor(CGColor(gray: shade, alpha: 1))
      flatContext.fill(CGRect(x: 0, y: 0, width: 216, height: 384))
      let bytes = NSBitmapImageRep(cgImage: flatContext.makeImage()!)
        .representation(using: .png, properties: [:])!
      verify(CustomerSafety.attachmentContainerKind(bytes) == "image",
        "A genuine grey/white/black image was rejected as a placeholder")
      verify(CustomerSafety.attachmentPreviewHasVisualEvidence(flatContext.makeImage()!, textRegions: []),
        "A genuine grey/white/black visible attachment preview was discarded")
      verify(!CustomerSafety.attachmentPreviewHasVisualEvidence(flatContext.makeImage()!,
        textRegions: [CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.4)]),
        "Uniform ordinary text-bubble background became an attachment preview")
    }
    verify(CustomerSafety.attachmentPreviewHasVisualEvidence(ownPhoto,
      textRegions: [CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.2)]),
      "A photograph containing readable text lost its visual preview")
    verify(CustomerSafety.attachmentContainerKind(Data("not media".utf8)) == nil,
      "Arbitrary bytes became customer media")
    for shade: UInt8 in [0, 255] {
      let url = cacheRoot.appendingPathComponent("solid-\(shade).mp4")
      let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
      writer.add(input)
      precondition(writer.startWriting())
      writer.startSession(atSourceTime: .zero)
      var pixel: CVPixelBuffer?
      precondition(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
        nil, &pixel) == kCVReturnSuccess)
      CVPixelBufferLockBaseAddress(pixel!, [])
      memset(CVPixelBufferGetBaseAddress(pixel!), Int32(shade), CVPixelBufferGetBytesPerRow(pixel!) * 64)
      CVPixelBufferUnlockBaseAddress(pixel!, [])
      let readyAt = Date().addingTimeInterval(2)
      while !input.isReadyForMoreMediaData && Date() < readyAt { usleep(1_000) }
      precondition(input.isReadyForMoreMediaData && adaptor.append(pixel!, withPresentationTime: .zero))
      input.markAsFinished()
      let complete = DispatchSemaphore(value: 0)
      writer.finishWriting { complete.signal() }
      precondition(complete.wait(timeout: .now() + 3) == .success && writer.status == .completed)
      verify(CustomerSafety.attachmentContainerKind(try Data(contentsOf: url)) == "video_container",
        "A genuine white/black MP4 was treated as an image")
    }
    func cachedVideo(_ bucket: String, _ image: CGImage, _ bytes: [UInt8],
                     stem: String = "same-name") throws -> URL {
      let root = cacheRoot.appendingPathComponent(bucket, isDirectory: true)
      for folder in ["videos", "images"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder),
                                               withIntermediateDirectories: true)
      }
      let url = root.appendingPathComponent("videos/\(stem).mp4")
      try Data(bytes).write(to: url)
      let thumbnail = root.appendingPathComponent("images/\(stem).png")
      let destination = CGImageDestinationCreateWithURL(thumbnail as CFURL, "public.png" as CFString, 1, nil)!
      CGImageDestinationAddImage(destination, image, nil)
      precondition(CGImageDestinationFinalize(destination))
      return url
    }
    let ownVideo = try cachedVideo("chat_owner", ownPhoto, [1, 2, 3])
    let foreignVideo = try cachedVideo("chat_foreign", foreignPhoto, [4, 5, 6])
    func selectedVideo(_ candidates: [URL], preview: CGImage? = nil) -> CustomerSafety.PairedVideoCacheMatch {
      CustomerSafety.pairedCachedVideo(visible: preview ?? ownPreview, candidates: candidates,
                                      deadline: ProcessInfo.processInfo.systemUptime + 10)
    }
    if case let .matched(url) = selectedVideo([foreignVideo, ownVideo]) {
      verify(url == ownVideo, "Newer foreign video redirected cache acquisition")
    } else { verify(false, "Paired cached original was not recovered") }
    if case .notFound = selectedVideo([foreignVideo]) { checks += 1 }
    else { verify(false, "Foreign cache was assigned to this customer") }
    let duplicateVideo = try cachedVideo("chat_duplicate", ownPhoto, [1, 2, 3])
    if case .matched = selectedVideo([ownVideo, duplicateVideo]) { checks += 1 }
    else { verify(false, "Identical cache copies blocked video acquisition") }
    let ambiguousVideo = try cachedVideo("chat_ambiguous", ownPhoto, [7, 8, 9])
    if case .unresolved("video_cache_match_ambiguous") = selectedVideo([ownVideo, ambiguousVideo]) { checks += 1 }
    else { verify(false, "Different videos with identical previews were assigned by time") }
    let wrongStem = try cachedVideo("chat_other_stem", ownPhoto, [7], stem: "other")
    try FileManager.default.moveItem(
      at: wrongStem.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("images/other.png"),
      to: wrongStem.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("images/unrelated.png"))
    if case .notFound = selectedVideo([wrongStem]) { checks += 1 }
    else { verify(false, "Unpaired cached JPEG proved video ownership") }
    let linkedVideo = try cachedVideo("chat_link", ownPhoto, [9])
    try FileManager.default.removeItem(at: linkedVideo)
    try FileManager.default.createSymbolicLink(at: linkedVideo, withDestinationURL: ownVideo)
    if case .notFound = selectedVideo([linkedVideo]) { checks += 1 }
    else { verify(false, "Video symlink bypassed the chat-bucket boundary") }
    let linkedThumbVideo = try cachedVideo("chat_link_thumb", ownPhoto, [10])
    let linkedThumb = linkedThumbVideo.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("images/same-name.png")
    try FileManager.default.removeItem(at: linkedThumb)
    try FileManager.default.createSymbolicLink(at: linkedThumb, withDestinationURL:
      ownVideo.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("images/same-name.png"))
    if case .notFound = selectedVideo([linkedThumbVideo]) { checks += 1 }
    else { verify(false, "Thumbnail symlink bypassed the chat-bucket boundary") }
    if case .unresolved("video_cache_check_timeout") = CustomerSafety.pairedCachedVideo(
      visible: ownPreview, candidates: [ownVideo], deadline: ProcessInfo.processInfo.systemUptime - 1) { checks += 1 }
    else { verify(false, "Expired cache operation continued") }
    let greyStem = "263873c9f28844b58fbc649bd000a5e8"
    for name in [greyStem, "\(greyStem).mp4", "\(greyStem.uppercased()).MP4"] {
      verify(CustomerSafety.videoCacheStem(saveAsName: name) == greyStem,
             "Native message Save As reference was not accepted")
    }
    let actualUUID = "1a5ae418-102e-2c41-30cc-75153f65e67f"
    for name in [actualUUID, "\(actualUUID).mp4", "\(actualUUID.uppercased()).MP4"] {
      verify(CustomerSafety.videoCacheStem(saveAsName: name) == actualUUID.replacingOccurrences(of: "-", with: ""),
        "JD's actual UUID filename was rejected for a blank video")
    }
    verify(CustomerSafety.mediaCacheStem(saveAsName: "\(actualUUID).jpeg") == actualUUID.replacingOccurrences(of: "-", with: ""),
      "Verified image filename could not identify its cached original")
    for name in ["../\(actualUUID).mp4", "\(actualUUID).jpg.exe", "https://example.com/\(actualUUID).mp4"] {
      verify(CustomerSafety.mediaCacheStem(saveAsName: name) == nil, "Untrusted path accepted as a native filename")
    }
    for label in ["另存为", "另存为日", "同 另存为", "鱼举报", "引用三", "三多选"] {
      verify(CustomerSafety.mediaMenuLabel(label) != nil, "A bounded menu icon prevented exact label verification")
    }
    for label in ["请另存为图片", "不要举报", "我的引用内容", "客户说另存为"] {
      verify(CustomerSafety.mediaMenuLabel(label) == nil, "Underlying chat text authorized a menu click")
    }
    for name in ["", "263873c9f28844b58fbc649bd000a5e", "../\(greyStem).mp4",
                 "/tmp/\(greyStem).mp4", "\(greyStem).jpg", "\(greyStem).mp4.exe",
                 "https://example.com/\(greyStem).mp4", "\(greyStem)/other.mp4"] {
      verify(CustomerSafety.videoCacheStem(saveAsName: name) == nil,
             "A path, URL, partial stem or non-video name authorized a cache file")
    }
    flatContext.setFillColor(CGColor(gray: 0.65, alpha: 1))
    flatContext.fill(CGRect(x: 0, y: 0, width: 216, height: 384))
    let greyPreview = flatContext.makeImage()!
    let greyVideo = try cachedVideo("chat_grey_owner", greyPreview, [2, 1, 6], stem: greyStem)
    let foreignGrey = try cachedVideo("chat_grey_foreign", greyPreview, [9, 8, 7],
      stem: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    let uuidVideo = try cachedVideo("chat_uuid_owner", greyPreview, [3, 4, 5], stem: actualUUID)
    if case let .matched(url) = CustomerSafety.referencedCachedVideo(saveAsName: "\(actualUUID).mp4",
        candidates: [foreignGrey, uuidVideo], deadline: ProcessInfo.processInfo.systemUptime + 5) {
      verify(url == uuidVideo, "Blank UUID video resolved to a foreign customer's file")
    } else { verify(false, "Blank UUID video required a visible play button") }
    if case let .matched(url) = CustomerSafety.referencedCachedVideo(
        saveAsName: actualUUID.replacingOccurrences(of: "-", with: ""), candidates: [uuidVideo],
        deadline: ProcessInfo.processInfo.systemUptime + 5) {
      verify(url == uuidVideo, "Hidden-extension/compact UUID reference missed the hyphenated cached original")
    } else { verify(false, "Equivalent UUID spellings prevented exact cache binding") }
    func reference(_ urls: [URL], name: String = greyStem) -> CustomerSafety.PairedVideoCacheMatch {
      CustomerSafety.referencedCachedVideo(saveAsName: name, candidates: urls,
                                          deadline: ProcessInfo.processInfo.systemUptime + 10)
    }
    verify(!CustomerSafety.cachedThumbnailMatches(greyPreview, greyPreview),
           "Flat pixels alone must not establish cache ownership")
    if case let .matched(url) = reference([foreignGrey, greyVideo]) {
      verify(url == greyVideo, "Grey video reference selected another customer's grey video")
    } else { verify(false, "Grey video rejected despite an exact native message reference") }
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                         ofItemAtPath: greyVideo.path)
    if case .matched = reference([greyVideo]) { checks += 1 }
    else { verify(false, "An exact current-message reference incorrectly required a new cache modification time") }
    if case .notFound = reference([foreignGrey]) { checks += 1 }
    else { verify(false, "Missing exact video reference fell back to another grey clip") }
    let collidingGrey = try cachedVideo("chat_grey_collision", greyPreview, [4, 5, 6], stem: greyStem)
    if case .unresolved("video_message_reference_ambiguous") = reference([greyVideo, collidingGrey]) { checks += 1 }
    else { verify(false, "Conflicting cached originals sharing a filename were assigned") }
    let copiedGrey = try cachedVideo("chat_grey_copy", greyPreview, [2, 1, 6], stem: greyStem)
    if case .matched = reference([greyVideo, copiedGrey]) { checks += 1 }
    else { verify(false, "Byte-identical copies of a referenced grey video were rejected") }
    if case .unresolved("video_message_reference_invalid") = reference([greyVideo], name: "../\(greyStem)") { checks += 1 }
    else { verify(false, "Unsafe message reference authorized a cache path") }
    // Optional replay of the actual missed 2026-10-16 clip. Never check real
    // customer media into source control or mutate the live JD cache.
    if let bucket = ProcessInfo.processInfo.environment["JD_CACHE_REPLAY_BUCKET"] {
      let root = URL(fileURLWithPath: bucket, isDirectory: true)
      let stem = "689e6d104aa74c919ab8025bbadac520"
      let thumbnail = root.appendingPathComponent("images/\(stem).jpg")
      let source = CGImageSourceCreateWithURL(thumbnail as CFURL, nil)!
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
      let video = root.appendingPathComponent("videos/\(stem).mp4")
      let replayPreview = renderedPreview(image, border: 25)
      if case let .matched(url) = selectedVideo([video], preview: replayPreview) {
        verify(url == video, "Missed clip replay selected another MP4")
      } else { verify(false, "Actual missed clip could not use paired-thumbnail cache acquisition") }
      let earlierVideo = root.appendingPathComponent("videos/6a6a2501e1b946369f468d9f163086aa.mp4")
      if FileManager.default.fileExists(atPath: earlierVideo.path) {
        if case let .matched(url) = selectedVideo([earlierVideo, video], preview: replayPreview) {
          verify(url == video, "Earlier cache video redirected the missed clip")
        } else { verify(false, "Actual missed clip was not distinguished from the preceding cached video") }
      }
      let grey = root.appendingPathComponent("videos/\(greyStem).mp4")
      if FileManager.default.fileExists(atPath: grey.path) {
        let source = CGImageSourceCreateWithURL(
          root.appendingPathComponent("images/\(greyStem).jpg") as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        verify(CustomerSafety.videoSignature(image) == nil,
               "Actual grey regression clip is no longer the low-contrast fixture")
        if case let .matched(url) = reference([earlierVideo, video, grey]) {
          verify(url == grey, "The 11:48 grey clip did not resolve through its verified Save As filename")
        } else { verify(false, "Actual grey clip is still blocked by thumbnail contrast") }
      }
    }
    // Exact AX geometry from JD 10.4.5.600 on 2026-10-13. The previous selector
    // incorrectly treated both labels in the first 70 points as customer IDs.
    let chatFrame = CGRect(x: 346, y: 129, width: 511, height: 763)
    let customerFrame = CGRect(x: 408, y: 135, width: 120, height: 18)
    let shopFrame = CGRect(x: 742, y: 136, width: 105, height: 16)
    let transferFrame = CGRect(x: 408, y: 159, width: 16, height: 16)
    let shop = CustomerSafety.HeaderLabel(text: "grozziie格志专卖店", frame: shopFrame)
    func selected(_ labels: [CustomerSafety.HeaderLabel],
                  anchors: [CGRect]? = nil,
                  bounds: CGRect? = nil) -> String? {
      CustomerSafety.activeHeaderIdentity(labels: labels, chatFrame: bounds ?? chatFrame,
                                           quickTransferFrames: anchors ?? [transferFrame])
    }
    for owner in ids {
      let label = CustomerSafety.HeaderLabel(text: owner, frame: customerFrame)
      verify(selected([label, shop]) == owner, "Shop header blocked the correct customer")
      verify(selected([shop, label]) == owner, "AX enumeration order redirected customer selection")
      for other in ids {
        verify(CustomerSafety.matches(selected([label, shop]), other) == (owner == other),
               "Header verification accepted another customer")
      }
    }
    verify(selected([shop]) == nil, "Shop-only header was accepted as a customer")
    let label = CustomerSafety.HeaderLabel(text: ids.last!, frame: customerFrame)
    verify(selected([label, shop], anchors: []) == nil, "Header accepted without customer control anchor")
    verify(selected([label, shop], anchors: [transferFrame, transferFrame]) == nil,
           "Ambiguous customer control anchors accepted")
    let conflicting = CustomerSafety.HeaderLabel(text: ids.first!, frame: customerFrame)
    verify(selected([label, conflicting, shop]) == nil, "Conflicting customer-slot IDs accepted")
    let truncated = CustomerSafety.HeaderLabel(text: "jd_41aee…", frame: customerFrame)
    verify(selected([truncated, shop]) == nil, "Truncated customer header accepted")
    verify(selected([label, truncated, shop]) == nil, "Incomplete conflicting header ignored")
    verify(selected([label, label, shop]) == ids.last!, "Identical customer evidence rejected")
    let invalid = CustomerSafety.HeaderLabel(text: "unknown", frame: customerFrame)
    verify(selected([invalid, shop]) == nil, "Unknown customer header accepted")
    let message = CustomerSafety.HeaderLabel(text: ids.first!,
        frame: CGRect(x: 408, y: 235, width: 120, height: 18))
    verify(selected([label, message, shop]) == ids.last!, "Transcript message became header identity")
    let sidebar = CustomerSafety.HeaderLabel(text: ids.first!,
        frame: CGRect(x: 114, y: 135, width: 120, height: 18))
    verify(selected([label, sidebar, shop]) == ids.last!, "Sidebar identity became active identity")
    let shopNamedCustomer = CustomerSafety.HeaderLabel(text: shop.text, frame: customerFrame)
    verify(selected([shopNamedCustomer, shop]) == shop.text, "Shop-name blacklist replaced geometric customer proof")
    for scale: CGFloat in [0.5, 1, 2] {
      func moved(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * scale - 1400, y: r.minY * scale + 500,
               width: r.width * scale, height: r.height * scale)
      }
      verify(selected([
        CustomerSafety.HeaderLabel(text: ids.last!, frame: moved(customerFrame)),
        CustomerSafety.HeaderLabel(text: shop.text, frame: moved(shopFrame)),
      ], anchors: [moved(transferFrame)], bounds: moved(chatFrame)) == ids.last!,
             "Scaled/moved JD window broke customer header selection")
    }
    for owner in ids { for active in ids {
      verify(CustomerSafety.canRecoverOwnedComposer(owner: owner, active: active,
        insertedText: "owned reply", currentText: "owned reply", sameElement: true) == (owner == active),
        "Composer recovery crossed customer ownership")
    } }
    verify(!CustomerSafety.canRecoverOwnedComposer(owner: ids[0], active: ids[0],
      insertedText: "owned reply", currentText: "operator edit", sameElement: true), "Operator text erased")
    verify(!CustomerSafety.canRecoverOwnedComposer(owner: ids[0], active: ids[0],
      insertedText: "owned reply", currentText: "owned reply", sameElement: false), "Stale composer erased")
    verify(!CustomerSafety.canRecoverOwnedComposer(owner: ids[0], active: nil,
      insertedText: "owned reply", currentText: "owned reply", sameElement: true), "Unknown composer owner accepted")
    let outer = AccessibilityBudget(deadline: Date().addingTimeInterval(10))
    verify(outer.isCurrent, "Fresh AX budget rejected")
    let expired = AccessibilityBudget(deadline: Date().addingTimeInterval(-1))
    verify(!expired.isCurrent, "Expired AX budget accepted")
    expired.invalidate()
    expired.close()
    verify(AccessibilityBudget.current === outer, "AX budget did not restore parent")
    verify(!outer.isCurrent, "Timed-out child AX snapshot did not invalidate operation")
    outer.close()
    verify(AccessibilityBudget.current == nil, "AX budget leaked into next operation")
    let fresh = AccessibilityBudget(deadline: Date().addingTimeInterval(10))
    verify(fresh.isCurrent, "Failed AX request poisoned unrelated later request")
    fresh.close()
    let expiredQueueItem = AccessibilityBudget(deadline: Date().addingTimeInterval(3600),
      uptimeDeadline: ProcessInfo.processInfo.systemUptime - 1)
    verify(!expiredQueueItem.isCurrent, "Wall-clock change revived an expired native queue item")
    expiredQueueItem.close()
    if let project = ProcessInfo.processInfo.environment["JD_REPLAY_PROJECT"] {
      func image(_ path: String) throws -> CGImage {
        let url = URL(fileURLWithPath: project).appendingPathComponent(path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
          throw NSError(domain: "missing_replay_frame", code: 1)
        }
        return image
      }
      let windows = try image("data/media/jd_6c67c99371fa4/videos/frames_62bffbb019f1ada0/frame_01.jpg")
      let m880 = try image("data/media/jd_6c67c99371fa4/videos/frames_f84d688641ffed13/frame_13.jpg")
      verify(CustomerSafety.videoMatches(windows, windows), "Identical Windows frame rejected")
      verify(CustomerSafety.videoMatches(m880, m880), "Identical M880 frame rejected")
      verify(!CustomerSafety.videoMatches(windows, m880), "Yesterday's unrelated Windows video accepted for M880")
      let printer = try image("data/media/jd_41aeec7741d05/videos/frames_a9e0db5e199199d6/frame_01.jpg")
      let clip = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: project)
        .appendingPathComponent("data/media/jd_41aeec7741d05/videos/9aaf6ed0d1e44ba595401291b9a73dc8.mp4")))
      clip.appliesPreferredTrackTransform = true
      clip.maximumSize = CGSize(width: 360, height: 360)
      let clipFrames = try [0.0, 0.5, 1.0].map {
        try clip.copyCGImage(at: CMTime(seconds: $0, preferredTimescale: 600), actualTime: nil)
      }
      for path in ["data/media/jd_41aeec7741d05/9a954a8e6ccc1185.png",
                   "data/media/jd_41aeec7741d05/1384b39b2d7467b6.png"] {
        let preview = try image(path)
        verify(CustomerSafety.hasVideoPlayControl(preview), "Off-center customer video classified as image")
        verify(!CustomerSafety.cachedVideoPreviewMatches(preview, windows), "Printer preview accepted unrelated Windows clip")
        verify(!CustomerSafety.cachedVideoPreviewMatches(preview, m880), "Printer preview accepted unrelated M880 clip")
        let matched = clipFrames.contains { CustomerSafety.cachedVideoPreviewMatches(preview, $0) }
        verify(matched == (preview.height == 454),
               "Cache cross-check must recover the complete preview but reject insufficient clipped-frame evidence")
      }
      verify(!CustomerSafety.hasVideoPlayControl(windows), "Windows screenshot classified as video")
      verify(!CustomerSafety.hasVideoPlayControl(m880), "M880 frame classified as video")
      verify(!CustomerSafety.hasVideoPlayControl(printer), "Printer frame without play button classified as video")
      verify(CustomerSafety.cachedVideoPreviewMatches(printer, printer), "Cache cross-check cannot recover video when its play overlay is absent")
      let bitmap = CGContext(data: nil, width: 360, height: 454, bitsPerComponent: 8,
        bytesPerRow: 360 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      for grey in [0.3, 1.0] {
        bitmap.setFillColor(CGColor(gray: grey, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 360, height: 454))
        let flat = bitmap.makeImage()!
        verify(!CustomerSafety.hasVideoPlayControl(flat), "Flat background mistaken for a play control")
        verify(!CustomerSafety.cachedVideoPreviewMatches(flat, printer), "Flat placeholder assigned to cached printer clip")
      }
    }
    print("Native customer/video safety: \(checks) checks passed; no UI operations or sends.")
  }
}
