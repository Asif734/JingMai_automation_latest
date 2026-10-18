import ApplicationServices
import Cocoa
import CryptoKit
#if JD_UI_WORKER
typealias FlutterResult = (Any?) -> Void
#else
import FlutterMacOS
#endif
import Speech
import Vision
import AVFoundation

struct NativeAutomationRequest {
  let method: String
  let arguments: Any?
}

#if !JD_UI_WORKER
/// UI mutations never execute in the Flutter process. A lost callback can be
/// recovered by terminating only our own helper, not JD or the operator's app.
final class AccessibilityBridge {
  private let channel: FlutterMethodChannel
  private let endpoint = NativeAutomationEndpoint()
  private let worker = NativeUiWorkerClient()
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.grozziie.jdAutomation/accessibility", binaryMessenger: messenger)
    endpoint.onEvent = { [weak self] method, payload in
      DispatchQueue.main.async { self?.channel.invokeMethod(method, arguments: payload) }
    }
    worker.onEvent = endpoint.onEvent
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "status":
        self.endpoint.handle(NativeAutomationRequest(method: "status", arguments: nil)) { value in
          self.worker.inspectStatus { workerValue in
            var status = value as? [String: Any] ?? [:]
            let helper = workerValue as? [String: Any] ?? [:]
            status["uiWorkerAvailable"] = helper["available"] as? Bool ?? false
            status["uiWorkerTrusted"] = helper["trusted"] as? Bool ?? false
            status["uiWorkerScreenRecording"] = helper["screenRecording"] as? Bool ?? false
            status["uiWorkerError"] = helper["error"]
            if let helperPID = helper["appProcessId"] as? Int {
              status["competingApps"] = (status["competingApps"] as? [[String: Any]] ?? []).filter { $0["pid"] as? Int != helperPID }
            }
            result(status)
          }
        }
      case "beginUiOperation": self.worker.begin(args, completion: result)
      case "endUiOperation": self.worker.end(args, completion: result)
      case "cancelUiOperation": self.worker.cancel(args, completion: result)
      default:
        if NativeAutomationEndpoint.workerMethods.contains(call.method) {
          self.worker.invoke(call.method, arguments: args, completion: result)
        } else {
          self.endpoint.handle(NativeAutomationRequest(method: call.method, arguments: call.arguments), result: result)
        }
      }
    }
  }
}
#endif

/// Same capture/cache/identity implementation in both the app and its helper.
/// The helper dispatch changes isolation, not media selection or send checks.
final class NativeAutomationEndpoint {
  static let workerMethods: Set<String> = [
    "ensureReceptionWindow", "openConversation", "captureImageRegion",
    "classifyMessageAt", "downloadImageAt", "downloadVideoAt",
    "beginAttachmentDownload", "captureRecentCachedVideo", "workerStatus",
    "probeRecentCachedMedia", "sendDraftOnce", "retryFailedOutgoingMessage",
    "listActiveTransferAccounts", "transferConversation", "cancelTransferSelection",
    "scrollConversation"
  ]
  var onEvent: ((String, [String: Any]) -> Void)?
  private let collector = QianniuAXCollector()
  private let ocrInspector = QianniuOCRInspector()
  private let audioTranscriber = VideoAudioTranscriber()
  private let unreadSignalQueue = DispatchQueue(label: "jd.ax.unread-signals", qos: .userInitiated)
  private let unreadSignalLock = NSLock()
  private var unreadSignalInFlight = false
  private var unreadSignalWaiters: [FlutterResult] = []

  init() {
    // Setting an application root affects only that object. The system-wide
    // object sets the default for every AX element in this process, including
    // children created during traversal. Never use the OS's long default wait.
    _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.75)
    collector.onCapture = { [weak self] capture in
      self?.onEvent?("capture", capture)
    }
    collector.onDiagnostic = { [weak self] diagnostic in
      self?.onEvent?("diagnostic", diagnostic)
    }
    collector.onOwnedComposerClaims = { [weak self] claims in
      self?.onEvent?("ownedComposers", ["claims": claims])
    }
    ocrInspector.onFailedSendInspection = { [weak self] inspection in
      self?.onEvent?("failedSendCandidates", inspection)
    }
    ocrInspector.customerIdentityProvider = { [weak collector] in
      collector?.activeCustomerIdentity()
    }
    ocrInspector.chatFrameProvider = { [weak collector] in
      collector?.activeChatFrame()
    }
    ocrInspector.messageBottomProvider = { [weak collector] in
      collector?.activeMessageBottom()
    }
  }

  func restoreOwnedComposerClaims(_ claims: [String: String]) {
    collector.restoreOwnedComposerClaims(claims)
  }

  func handle(_ call: NativeAutomationRequest, result: @escaping FlutterResult) {
    switch call.method {
    case "workerStatus":
      var value = collector.status()
      value["available"] = true
      result(value)
    case "status": result(collector.status())
    case "requestAccessibility": result(collector.requestAccessibility())
    case "requestScreenRecording": result(ocrInspector.requestScreenRecording())
    case "listOCRWindows": result(ocrInspector.availableWindows())
    case "inspectOCR":
      let args = call.arguments as? [String: Any]
      let requestedWindowID = (args?["windowId"] as? NSNumber)
        .map { CGWindowID($0.uint32Value) }
      ocrInspector.inspect(
        windowID: requestedWindowID,
        recognitionLevel: args?["recognitionLevel"] as? String ?? "accurate",
        completion: result)
    case "captureImageRegion":
      let args = call.arguments as? [String: Any]
      collector.captureImageRegion(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        windowID: CGWindowID((args?["windowId"] as? NSNumber)?.uint32Value ?? 0),
        normalizedX: (args?["x"] as? NSNumber)?.doubleValue ?? -1,
        normalizedY: (args?["y"] as? NSNumber)?.doubleValue ?? -1,
        normalizedWidth: (args?["width"] as? NSNumber)?.doubleValue ?? -1,
        normalizedHeight: (args?["height"] as? NSNumber)?.doubleValue ?? -1,
        expectedMediaAt: (args?["expectedMediaAtMs"] as? NSNumber)
          .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
        allowActivationForVideoDetection:
          args?["allowActivationForVideoDetection"] as? Bool ?? false,
        allowMessageReferenceLookup: args?["allowMessageReferenceLookup"] as? Bool ?? true,
        allowAttachmentPreview: args?["allowAttachmentPreview"] as? Bool ?? false,
        previewTextRegions: (args?["previewTextRegions"] as? [[String: NSNumber]] ?? []).map {
          CGRect(x: $0["x"]?.doubleValue ?? -1, y: $0["y"]?.doubleValue ?? -1,
                 width: $0["width"]?.doubleValue ?? 0, height: $0["height"]?.doubleValue ?? 0)
        },
        sourcePNG: (args?["sourcePngBase64"] as? String).flatMap { Data(base64Encoded: $0) },
        sourceSenderY: (args?["sourceSenderY"] as? NSNumber)?.doubleValue,
        completion: result)
    case "probeRecentCachedMedia":
      let args = call.arguments as? [String: Any]
      collector.probeRecentCachedMedia(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        expectedMediaAt: (args?["expectedMediaAtMs"] as? NSNumber)
          .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
        completion: result)
    case "captureRecentCachedVideo":
      let args = call.arguments as? [String: Any]
      collector.captureRecentCachedVideo(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        windowID: CGWindowID((args?["windowId"] as? NSNumber)?.uint32Value ?? 0),
        expectedMediaAt: (args?["expectedMediaAtMs"] as? NSNumber)
          .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
        competingMessageTimes: (args?["competingMessageTimesMs"] as? [NSNumber] ?? [])
          .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
        destinationDirectory: args?["destinationDirectory"] as? String ?? "",
        completion: result)
    case "beginAttachmentDownload":
      collector.beginAttachmentDownload(call.arguments as? [String: Any] ?? [:], completion: result)
    case "pollAttachmentDownload":
      collector.pollAttachmentDownload(call.arguments as? [String: Any] ?? [:], completion: result)
    case "classifyMessageAt":
      let args = call.arguments as? [String: Any]
      collector.classifyMessageAt(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        windowID: CGWindowID((args?["windowId"] as? NSNumber)?.uint32Value ?? 0),
        normalizedX: (args?["x"] as? NSNumber)?.doubleValue ?? -1,
        normalizedY: (args?["y"] as? NSNumber)?.doubleValue ?? -1,
        completion: result)
    case "downloadImageAt":
      let args = call.arguments as? [String: Any]
      collector.downloadImageAt(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        windowID: CGWindowID((args?["windowId"] as? NSNumber)?.uint32Value ?? 0),
        normalizedX: (args?["x"] as? NSNumber)?.doubleValue ?? -1,
        normalizedY: (args?["y"] as? NSNumber)?.doubleValue ?? -1,
        completion: result)
    case "downloadVideoAt":
      let args = call.arguments as? [String: Any]
      collector.downloadVideoAt(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        windowID: CGWindowID((args?["windowId"] as? NSNumber)?.uint32Value ?? 0),
        normalizedX: (args?["x"] as? NSNumber)?.doubleValue ?? -1,
        normalizedY: (args?["y"] as? NSNumber)?.doubleValue ?? -1,
        normalizedWidth: (args?["width"] as? NSNumber)?.doubleValue ?? -1,
        normalizedHeight: (args?["height"] as? NSNumber)?.doubleValue ?? -1,
        expectedMediaAt: (args?["expectedMediaAtMs"] as? NSNumber)
          .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
        destinationDirectory: args?["destinationDirectory"] as? String ?? "",
        cacheReferenceToken: args?["cacheReferenceToken"] as? String,
        sourcePNG: (args?["sourcePngBase64"] as? String).flatMap { Data(base64Encoded: $0) },
        sourceSenderY: (args?["sourceSenderY"] as? NSNumber)?.doubleValue,
        completion: result)
    case "transcribeAudio":
      let args = call.arguments as? [String: Any]
      audioTranscriber.transcribe(
        path: args?["path"] as? String ?? "", completion: result)
    case "sendDraftOnce":
      let args = call.arguments as? [String: Any]
      collector.sendDraftOnce(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        reply: args?["reply"] as? String ?? "",
        mediaPaths: args?["mediaPaths"] as? [String] ?? [],
        deadline: (args?["operationDeadlineMs"] as? NSNumber)
          .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date().addingTimeInterval(12),
        completion: result)
    case "retryFailedOutgoingMessage":
      let args = call.arguments as? [String: Any]
      collector.retryFailedOutgoingMessage(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        candidate: args?["candidate"] as? [String: Any] ?? [:], completion: result)
    case "startCapture":
      collector.start(); result(nil)
    case "stopCapture":
      collector.stop(); result(nil)
    case "inspectTree":
      let args = call.arguments as? [String: Any]
      unreadSignalQueue.async {
        let value = self.collector.inspectTree(maxDepth: args?["maxDepth"] as? Int ?? 12)
        DispatchQueue.main.async { result(value) }
      }
    case "listConversations":
      unreadSignalQueue.async {
        let value = self.collector.conversationIdentities()
        DispatchQueue.main.async { result(value) }
      }
    case "listConversationRows":
      // AX traversal plus badge OCR can take seconds. Running it on the
      // Flutter method-channel (main) thread prevents Dart's 20-second SLA
      // timers from firing at all under load. Dart has two callers for this
      // snapshot; coalesce them so a timeout cannot leave an ever-growing
      // native queue of obsolete sidebar scans.
      unreadSignalLock.lock()
      unreadSignalWaiters.append(result)
      if unreadSignalInFlight {
        unreadSignalLock.unlock()
        // Both Dart pollers need the same current snapshot. Returning an empty
        // list here can permanently starve the capture cycle because their
        // two-second timers remain synchronized.
        break
      }
      unreadSignalInFlight = true
      unreadSignalLock.unlock()
      unreadSignalQueue.async { [weak self] in
        guard let self else { return }
        let rows = self.collector.conversationRows()
        self.unreadSignalLock.lock()
        self.unreadSignalInFlight = false
        let waiters = self.unreadSignalWaiters
        self.unreadSignalWaiters.removeAll()
        self.unreadSignalLock.unlock()
        DispatchQueue.main.async {
          for waiter in waiters { waiter(rows) }
        }
      }
    case "ensureReceptionWindow":
      let args = call.arguments as? [String: Any]
      collector.ensureReceptionWindow(
        allowActivation: args?["allowActivation"] as? Bool ?? true,
        completion: result)
    case "openConversation":
      let args = call.arguments as? [String: Any]
      collector.openConversation(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        allowActivation: args?["allowActivation"] as? Bool ?? true,
        allowObservedIdentityResolution:
          args?["allowObservedIdentityResolution"] as? Bool ?? false,
        deadline: (args?["operationDeadlineMs"] as? NSNumber)
          .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date().addingTimeInterval(8),
        completion: result)
    case "listActiveTransferAccounts":
      let args = call.arguments as? [String: Any]
      collector.listActiveTransferAccounts(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        completion: result)
    case "transferConversation":
      let args = call.arguments as? [String: Any]
      collector.transferConversation(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        targetAccount: args?["targetAccount"] as? String ?? "",
        completion: result)
    case "cancelTransferSelection":
      collector.cancelTransferSelection(completion: result)
    case "scrollConversation":
      let args = call.arguments as? [String: Any]
      collector.scrollConversation(
        expectedCustomer: args?["expectedCustomer"] as? String ?? "",
        deltaY: (args?["deltaY"] as? NSNumber)?.int32Value ?? 0,
        completion: result)
    default: result(["error": "native_method_not_implemented"])
    }
  }
}

/// Transcribes a local speech-ready WAV with macOS Speech. Chinese and English
/// are evaluated independently and the higher-confidence non-empty result is
/// returned. This API never records from the microphone.
final class VideoAudioTranscriber {
  private struct Candidate {
    let transcript: String
    let language: String
    let confidence: Double
  }

  func transcribe(path: String, completion: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard !path.isEmpty, FileManager.default.fileExists(atPath: url.path) else {
      completion(["error": "audio_missing",
                  "message": "The extracted video audio file is missing."])
      return
    }
    SFSpeechRecognizer.requestAuthorization { status in
      guard status == .authorized else {
        DispatchQueue.main.async {
          completion(["error": "speech_recognition_not_allowed",
                      "message": "Speech Recognition permission is required to transcribe video audio."])
        }
        return
      }
      self.recognize(url: url, languages: ["zh-CN", "en-US"],
                     candidates: [], completion: completion)
    }
  }

  private func recognize(url: URL, languages: [String],
                         candidates: [Candidate],
                         completion: @escaping FlutterResult) {
    guard let language = languages.first else {
      let best = candidates.max { left, right in
        if left.confidence == right.confidence {
          return left.transcript.count < right.transcript.count
        }
        return left.confidence < right.confidence
      }
      DispatchQueue.main.async {
        completion([
          "transcript": best?.transcript ?? "",
          "language": best?.language ?? "",
          "confidence": best?.confidence ?? 0,
          "speechDetected": best?.transcript.isEmpty == false,
        ])
      }
      return
    }
    let remaining = Array(languages.dropFirst())
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
          recognizer.isAvailable else {
      recognize(url: url, languages: remaining, candidates: candidates,
                completion: completion)
      return
    }
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false
    var finished = false
    recognizer.recognitionTask(with: request) { result, error in
      guard !finished else { return }
      if let result, result.isFinal {
        finished = true
        let transcript = result.bestTranscription.formattedString
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = result.bestTranscription.segments
        let confidence = segments.isEmpty ? 0 :
          segments.reduce(0) { $0 + Double($1.confidence) } /
            Double(segments.count)
        let next = transcript.isEmpty ? candidates : candidates + [Candidate(
          transcript: transcript, language: language, confidence: confidence)]
        self.recognize(url: url, languages: remaining, candidates: next,
                       completion: completion)
      } else if error != nil {
        finished = true
        self.recognize(url: url, languages: remaining,
                       candidates: candidates, completion: completion)
      }
    }
  }
}

/// Window-only screenshot and Apple Vision diagnostics. This inspector never
/// clicks, types, inserts, or sends anything to Qianniu.
final class QianniuOCRInspector {
  var customerIdentityProvider: (() -> String?)?
  var chatFrameProvider: (() -> CGRect?)?
  var messageBottomProvider: (() -> CGFloat?)?
  var onFailedSendInspection: (([String: Any]) -> Void)?
  private let bundleIdentifier = "com.jd.jdmddwb"
  // The three-pass accurate inspection can take several seconds. Keep the
  // lightweight incoming-sender signal on its own queue so it cannot sit
  // behind a full media scan and miss the response deadline.
  private let accurateQueue = DispatchQueue(label: "jd.ocr.inspect.accurate", qos: .userInitiated)
  private let fastQueue = DispatchQueue(label: "jd.ocr.inspect.fast", qos: .userInitiated)
  // Dart timeouts do not cancel a MethodChannel invocation. Without
  // coalescing, every two-second poll can leave another synchronous Vision
  // request queued here; later callers then wait minutes for screenshots that
  // are already obsolete. Keep at most one request in flight per recognition
  // level and give every overlapping caller the same freshly completed
  // inspection. Customer identity is independently verified before and after
  // the screenshot, so a caller still rejects a result for the wrong chat.
  private let inspectionLock = NSLock()
  private var accurateInspectionInFlight = false
  private var fastInspectionInFlight = false
  private var accurateInspectionWaiters: [FlutterResult] = []
  private var fastInspectionWaiters: [FlutterResult] = []
  private let failedSendInspectionQueue = DispatchQueue(label: "jd.retry.inspect", qos: .utility)
  private let failedSendInspectionLock = NSLock()
  private var failedSendInspectionBusy = false
  private var lastFailedSendInspectionAt = Date.distantPast

  /// Reuse captured pixels, but never make incoming OCR wait for pixel scans.
  /// Drop overlapping/obsolete work instead of accumulating queued scans.
  func inspectFailedSends(image: CGImage, windowBounds: CGRect, windowID: CGWindowID,
      transcript: CGRect, customer: String, capturedAt: Date) {
    failedSendInspectionLock.lock()
    guard !failedSendInspectionBusy,
          Date().timeIntervalSince(lastFailedSendInspectionAt) >= 5 else {
      failedSendInspectionLock.unlock(); return
    }
    failedSendInspectionBusy = true
    lastFailedSendInspectionAt = Date()
    failedSendInspectionLock.unlock()
    failedSendInspectionQueue.async { [weak self] in
      guard let self else { return }
      defer {
        self.failedSendInspectionLock.lock()
        self.failedSendInspectionBusy = false
        self.failedSendInspectionLock.unlock()
      }
      let candidates = failedSendBubbles(image: image,
          windowBounds: windowBounds, chatFrame: transcript).map {
        ["x": Double($0.point.x), "y": Double($0.point.y),
         "left": Double($0.frame.minX), "top": Double($0.frame.minY),
         "width": Double($0.frame.width), "height": Double($0.frame.height),
         "fingerprint": $0.fingerprint, "windowId": Int(windowID)] as [String: Any]
      }
      guard !candidates.isEmpty else { return }
      DispatchQueue.main.async {
        self.onFailedSendInspection?([
          "customer": customer,
          "capturedAtMs": Int(capturedAt.timeIntervalSince1970 * 1000),
          "candidates": candidates])
      }
    }
  }

  func requestScreenRecording() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    return CGRequestScreenCaptureAccess()
  }

  func availableWindows() -> [[String: Any]] {
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first(where: { !$0.isTerminated })?.processIdentifier else { return [] }
    return windows(pid: pid).map(\.payload)
  }

  func inspect(windowID: CGWindowID?, recognitionLevel: String, completion: @escaping FlutterResult) {
    let fast = recognitionLevel == "fast"
    inspectionLock.lock()
    if fast {
      fastInspectionWaiters.append(completion)
      if fastInspectionInFlight {
        inspectionLock.unlock()
        return
      }
      fastInspectionInFlight = true
    } else {
      accurateInspectionWaiters.append(completion)
      if accurateInspectionInFlight {
        inspectionLock.unlock()
        return
      }
      accurateInspectionInFlight = true
    }
    inspectionLock.unlock()

    let workQueue = fast ? fastQueue : accurateQueue
    workQueue.async { [weak self] in
      guard let self else { return }
      var response: [String: Any]
      do {
        response = try self.captureAndRecognize(
          windowID: windowID,
          recognitionLevel: recognitionLevel)
      } catch let error as OCRInspectorError {
        response = error.payload
      } catch {
        response = ["error": "ocr_failed", "message": error.localizedDescription]
      }
      self.inspectionLock.lock()
      let waiters: [FlutterResult]
      if fast {
        waiters = self.fastInspectionWaiters
        self.fastInspectionWaiters.removeAll()
        self.fastInspectionInFlight = false
      } else {
        waiters = self.accurateInspectionWaiters
        self.accurateInspectionWaiters.removeAll()
        self.accurateInspectionInFlight = false
      }
      self.inspectionLock.unlock()
      response["coalescedRequests"] = waiters.count
      DispatchQueue.main.async {
        for waiter in waiters { waiter(response) }
      }
    }
  }

  private func captureAndRecognize(windowID: CGWindowID?, recognitionLevel: String) throws -> [String: Any] {
    guard CGPreflightScreenCaptureAccess() else {
      throw OCRInspectorError(
        code: "screen_recording_not_allowed",
        message: "Grant Screen Recording permission to JD Automation, then restart the app.")
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first(where: { !$0.isTerminated }) else {
      throw OCRInspectorError(code: "jd_not_running", message: "JD 咚咚工作台 is not running.")
    }
    let availableWindows = windows(pid: app.processIdentifier)
    guard let window = windowID.flatMap({ selectedID in
      availableWindows.first(where: { $0.id == selectedID })
    }) ?? availableWindows.max(by: { $0.area < $1.area }) else {
      throw OCRInspectorError(
        code: "jd_window_missing",
        message: "No visible JD 咚咚 window was found. Open its customer-service window and retry.")
    }
    guard let customerBeforeCapture = customerIdentityProvider?() else {
      throw OCRInspectorError(code: "customer_identity_unverified",
                              message: "The active customer's complete header ID could not be verified; no screenshot was assigned to a customer.")
    }
    guard let chatFrame = chatFrameProvider?(), window.bounds.contains(chatFrame) else {
      throw OCRInspectorError(code: "capture_window_identity_unverified",
          message: "The selected window does not contain the verified active chat viewport.")
    }
    let snapshotAt = Date()
    guard let image = CGWindowListCreateImage(
      .null,
      .optionIncludingWindow,
      window.id,
      [.boundsIgnoreFraming, .bestResolution]) else {
      throw OCRInspectorError(code: "window_capture_failed", message: "macOS could not capture the JD 咚咚 window.")
    }

    var observations: [[String: Any]] = []
    var visualRegions: [[String: Any]] = []
    let request = VNRecognizeTextRequest()
      request.recognitionLevel = recognitionLevel == "fast" ? .fast : .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

      // A second English pass recovers short wrapped lines that the mixed
      // language pass can omit. The shared Dart extractor then joins every
      // sender-bounded line using the recent workflow.
      let englishRequest = VNRecognizeTextRequest()
      englishRequest.recognitionLevel = request.recognitionLevel
      englishRequest.usesLanguageCorrection = false
      englishRequest.recognitionLanguages = ["en-US"]

      // Use an independent Chinese pass so a short Chinese bubble cannot be
      // reduced to a Latin placeholder such as `D` by the mixed pass.
      let chineseRequest = VNRecognizeTextRequest()
      chineseRequest.recognitionLevel = request.recognitionLevel
      chineseRequest.usesLanguageCorrection = false
      chineseRequest.recognitionLanguages = ["zh-Hans", "zh-Hant"]

      let rectangles = VNDetectRectanglesRequest()
      rectangles.maximumObservations = 24
      rectangles.minimumSize = 0.06
      rectangles.minimumAspectRatio = 0.25
      rectangles.maximumAspectRatio = 4.0
      rectangles.quadratureTolerance = 18
      try VNImageRequestHandler(cgImage: image, orientation: .up)
        .perform([request, englishRequest, chineseRequest, rectangles])

      struct RecognizedLine {
        let text: String
        let confidence: Float
        let box: CGRect
      }
      func lines(from results: [VNRecognizedTextObservation]?) -> [RecognizedLine] {
        (results ?? []).compactMap { observation in
          guard let candidate = observation.topCandidates(1).first else { return nil }
          return RecognizedLine(
            text: candidate.string,
            confidence: candidate.confidence,
            box: observation.boundingBox)
        }
      }
      func sameVisualLine(_ left: CGRect, _ right: CGRect) -> Bool {
        let intersection = left.intersection(right)
        guard !intersection.isNull else { return false }
        let smallerArea = min(left.width * left.height, right.width * right.height)
        return smallerArea > 0 && intersection.width * intersection.height / smallerArea >= 0.45
      }

      func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
          (0x3400...0x9FFF).contains(Int(scalar.value))
        }
      }

      var mergedLines = lines(from: request.results)
      func merge(_ fallbackLines: [RecognizedLine]) {
        for fallback in fallbackLines {
          if let index = mergedLines.firstIndex(where: { sameVisualLine($0.box, fallback.box) }) {
            let current = mergedLines[index]
            let currentHasHan = containsHan(current.text)
            let fallbackHasHan = containsHan(fallback.text)
            let currentLength = current.text.replacingOccurrences(of: " ", with: "").count
            let fallbackLength = fallback.text.replacingOccurrences(of: " ", with: "").count
            if (fallbackHasHan && !currentHasHan) ||
                (fallbackHasHan == currentHasHan &&
                  (fallbackLength > currentLength ||
                    (fallbackLength == currentLength && fallback.confidence > current.confidence))) {
              mergedLines[index] = fallback
            }
          } else {
            mergedLines.append(fallback)
          }
        }
      }
      merge(lines(from: englishRequest.results))
      merge(lines(from: chineseRequest.results))

      observations = mergedLines.map { line -> [String: Any] in
        let box = line.box
        return [
          "text": line.text,
          "confidence": Double(line.confidence),
          "x": Double(box.minX),
          "y": Double(1 - box.maxY),
          "width": Double(box.width),
          "height": Double(box.height),
        ]
      }.sorted {
        let leftY = $0["y"] as? Double ?? 0
        let rightY = $1["y"] as? Double ?? 0
        if abs(leftY - rightY) > 0.01 { return leftY < rightY }
        return ($0["x"] as? Double ?? 0) < ($1["x"] as? Double ?? 0)
      }
    visualRegions = (rectangles.results ?? []).map { observation -> [String: Any] in
        let box = observation.boundingBox
        return [
          "x": Double(box.minX),
          "y": Double(1 - box.maxY),
          "width": Double(box.width),
          "height": Double(box.height),
          "confidence": Double(observation.confidence),
        ]
    }

    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      throw OCRInspectorError(code: "png_encoding_failed", message: "Could not encode the captured window image.")
    }
    let customerAfterRecognition = customerIdentityProvider?()
    guard let customerAfterRecognition else {
      throw OCRInspectorError(code: "customer_identity_unverified",
                              message: "The active customer's complete header ID became unavailable after OCR; this screenshot was discarded.")
    }
    guard exactCustomerIdentityMatches(customerBeforeCapture, customerAfterRecognition) else {
      throw OCRInspectorError(code: "customer_changed_during_capture",
                              message: "The JD conversation changed during OCR; this screenshot was discarded.")
    }
    var payload: [String: Any] = [
      "pid": Int(app.processIdentifier),
      "windowId": Int(window.id),
      "windowTitle": window.title,
      "windowBounds": [
        "x": Double(window.bounds.minX), "y": Double(window.bounds.minY),
        "width": Double(window.bounds.width), "height": Double(window.bounds.height),
      ],
      "imageWidth": image.width,
      "imageHeight": image.height,
      "pngBase64": png.base64EncodedString(),
      "observations": observations,
      "visualRegions": visualRegions,
      "recognizedText": observations.compactMap { $0["text"] as? String }.joined(separator: "\n"),
      "ocrEngine": "apple_vision",
      "activeCustomerId": customerAfterRecognition,
      "activeCustomerIdentitySource": "ax_header_before_and_after",
      "capturedAtMs": Int(Date().timeIntervalSince1970 * 1000),
    ]
    if let chatFrame = chatFrameProvider?(), window.bounds.width > 0 {
      let messageBottom = messageBottomProvider?() ?? chatFrame.maxY
      let left = max(0, min(1,
        (chatFrame.minX - window.bounds.minX) / window.bounds.width))
      let right = max(left, min(1,
        (chatFrame.maxX - window.bounds.minX) / window.bounds.width))
      payload["chatRegion"] = [
        "left": Double(left),
        "right": Double(right),
        "bottom": Double(max(0, min(1,
          (messageBottom - window.bounds.minY) /
          window.bounds.height))),
      ]
      if recognitionLevel == "fast" {
        let bottom = messageBottom
        let transcript = CGRect(x: chatFrame.minX, y: chatFrame.minY,
            width: chatFrame.width, height: max(0, bottom - chatFrame.minY))
        inspectFailedSends(image: image, windowBounds: window.bounds,
            windowID: window.id, transcript: transcript,
            customer: customerAfterRecognition, capturedAt: snapshotAt)
      }
    }
    return payload
  }

  private func windows(pid: pid_t) -> [OCRWindow] {
    // CGWindowListCopyWindowInfo returns windows from front to back. Preserve
    // that order: Qianniu's detached reception window floats above its main UI.
    guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return [] }
    return raw.compactMap { info -> OCRWindow? in
      guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
            (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
            bounds.width >= 300, bounds.height >= 200 else { return nil }
      return OCRWindow(
        id: CGWindowID(id),
        title: info[kCGWindowName as String] as? String ?? "JD 咚咚工作台",
        bounds: bounds)
    }
  }
}

private struct OCRWindow {
  let id: CGWindowID
  let title: String
  let bounds: CGRect

  var area: CGFloat { bounds.width * bounds.height }

  var payload: [String: Any] {
    [
      "windowId": Int(id),
      "title": title,
      "x": Double(bounds.minX),
      "y": Double(bounds.minY),
      "width": Double(bounds.width),
      "height": Double(bounds.height),
    ]
  }
}

private struct UnreadScreenshot {
  let bounds: CGRect
  let image: CGImage
}

private struct TransferTextLine {
  let text: String
  let confidence: Float
  /// Pixel coordinates with a top-left origin, matching the captured image.
  let frame: CGRect
}

private struct TransferDialogSnapshot {
  let windowID: CGWindowID
  let bounds: CGRect
  let image: CGImage
  let lines: [TransferTextLine]

  var imageWidth: CGFloat { CGFloat(image.width) }
  var imageHeight: CGFloat { CGFloat(image.height) }

  func globalPoint(for imagePoint: CGPoint) -> CGPoint {
    CGPoint(
      x: bounds.minX + imagePoint.x * bounds.width / max(imageWidth, 1),
      y: bounds.minY + imagePoint.y * bounds.height / max(imageHeight, 1))
  }
}

private struct TransferAccountCandidate {
  let name: String
  let frame: CGRect
  let greenPixelEvidence: Int
  let redPixelEvidence: Int

  var isActive: Bool {
    greenPixelEvidence >= 3 && redPixelEvidence < 3
  }
}

private struct DownloadedImageCandidate {
  let url: URL
  let modified: Date
  let size: Int
}

private struct DownloadedVideoCandidate {
  let url: URL
  let modified: Date
  let size: Int
  var matchBasis = "decoded_frame"
}

private struct JDCachedImageCandidate {
  let url: URL
  let modified: Date
  let size: Int
  let fingerprint: String
  let hashDistance: Int
  let score: Double
}

private struct JDRecentCachedMediaCandidate {
  let kind: String
  let url: URL
  let modified: Date
  let size: Int
  let timeDelta: TimeInterval
}

private struct JDRecentCachedMediaSelection {
  let candidate: JDRecentCachedMediaCandidate
  let ambiguous: Bool
  let candidateCount: Int
}

/// Shared-cache discovery. Callers must independently enforce the exact
/// customer, competing clocks and file stability before copying any payload.
private func recentJDCachedMedia(
  expectedAt: Date,
  now: Date = Date(),
  maximumDelta: TimeInterval = 3 * 60,
  timeout: TimeInterval = 5,
  strictReceiveWindow: Bool = false
) -> JDRecentCachedMediaSelection? {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JingDong/咚咚工作台",
                           isDirectory: true)
  let keys: Set<URLResourceKey> = [
    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
  ]
  guard let enumerator = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: Array(keys),
    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
  let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "heic"])
  let videoExtensions = Set(["mp4", "mov", "m4v", "webm"])
  var candidates: [JDRecentCachedMediaCandidate] = []
  for case let url as URL in enumerator {
    guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
    let parent = url.deletingLastPathComponent()
    let chatDirectory = parent.deletingLastPathComponent().lastPathComponent
    let ext = url.pathExtension.lowercased()
    let kind: String
    let maximumSize: Int
    if parent.lastPathComponent == "images" && imageExtensions.contains(ext) {
      kind = "image"
      maximumSize = 25 * 1024 * 1024
    } else if parent.lastPathComponent == "videos" && videoExtensions.contains(ext) {
      kind = "video"
      maximumSize = 100 * 1024 * 1024
    } else {
      continue
    }
    guard chatDirectory.hasPrefix("chat_"),
          let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true,
          let modified = values.contentModificationDate,
          let size = values.fileSize,
          size > 0, size <= maximumSize else { continue }
    let age = now.timeIntervalSince(modified)
    let delta = abs(modified.timeIntervalSince(expectedAt))
    guard age >= -5, age <= 10 * 60, delta <= maximumDelta else { continue }
    if strictReceiveWindow && !CustomerSafety.cacheVideoClockMatches(
        modified: modified, expected: expectedAt, now: now, competing: []) { continue }
    candidates.append(JDRecentCachedMediaCandidate(
      kind: kind, url: url, modified: modified, size: size, timeDelta: delta))
  }
  guard !candidates.isEmpty else { return nil }

  // JD stores a JPEG thumbnail beside many cached videos under the same base
  // name. Treat that pair as one video, not two competing customer messages.
  let videoKeys = Set(candidates.filter { $0.kind == "video" }.map {
    $0.url.deletingLastPathComponent().deletingLastPathComponent().path + "/" +
      $0.url.deletingPathExtension().lastPathComponent.lowercased()
  })
  let logical = candidates.filter {
    $0.kind == "video" ||
      !videoKeys.contains($0.url.deletingLastPathComponent().deletingLastPathComponent().path + "/" +
        $0.url.deletingPathExtension().lastPathComponent.lowercased())
  }.sorted {
    if $0.timeDelta != $1.timeDelta { return $0.timeDelta < $1.timeDelta }
    if $0.modified != $1.modified { return $0.modified > $1.modified }
    return $0.url.path < $1.url.path
  }
  guard let best = logical.first else { return nil }
  let ambiguous = logical.dropFirst().first.map {
    $0.timeDelta < best.timeDelta + 4
  } ?? false
  return JDRecentCachedMediaSelection(
    candidate: best, ambiguous: ambiguous, candidateCount: logical.count)
}


private func downloadableImages(in directory: URL) -> [String: DownloadedImageCandidate] {
  let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
  guard let urls = try? FileManager.default.contentsOfDirectory(
    at: directory, includingPropertiesForKeys: Array(keys),
    options: [.skipsHiddenFiles]) else { return [:] }
  let extensions = Set(["jpg", "jpeg", "png", "webp", "heic", "gif"])
  var result: [String: DownloadedImageCandidate] = [:]
  for url in urls where extensions.contains(url.pathExtension.lowercased()) {
    guard let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true else { continue }
    result[url.path] = DownloadedImageCandidate(
      url: url,
      modified: values.contentModificationDate ?? .distantPast,
      size: values.fileSize ?? 0)
  }
  return result
}

/// Finds an original cached image only when its pixels, dimensions, and cache
/// time agree with the sender-bounded image visible in the verified customer
/// conversation. JD keeps multiple customers below the same account cache, so
/// a merely "newest file" lookup is not safe enough.
private func matchingRecentJDCachedImage(
  visibleImage: CGImage,
  expectedAt: Date?,
  now: Date = Date(),
  maximumAge: TimeInterval = 15 * 60
) -> JDCachedImageCandidate? {
  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JingDong/咚咚工作台",
                           isDirectory: true)
  let keys: Set<URLResourceKey> = [
    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
  ]
  guard let enumerator = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: Array(keys),
    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
  let extensions = Set(["jpg", "jpeg", "png", "webp"])
  let visibleFingerprint = averageImageHash(visibleImage)
  guard let visibleBits = UInt64(visibleFingerprint, radix: 16) else { return nil }
  let visibleRatio = Double(visibleImage.width) / Double(max(visibleImage.height, 1))
  let referenceTime = expectedAt ?? now
  var candidates: [JDCachedImageCandidate] = []
  let deadline = ProcessInfo.processInfo.systemUptime + 1.5

  for case let url as URL in enumerator {
    guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
    let parent = url.deletingLastPathComponent()
    let chatDirectory = parent.deletingLastPathComponent().lastPathComponent
    guard parent.lastPathComponent == "images",
          chatDirectory.hasPrefix("chat_"),
          extensions.contains(url.pathExtension.lowercased()),
          let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true,
          let modified = values.contentModificationDate,
          let size = values.fileSize,
          size > 0, size <= 25 * 1024 * 1024 else { continue }
    let age = now.timeIntervalSince(modified)
    guard age >= -5, age <= maximumAge else { continue }
    let timeDelta = abs(referenceTime.timeIntervalSince(modified))
    guard timeDelta <= maximumAge,
          let image = NSImage(contentsOf: url),
          let cgImage = image.cgImage(
            forProposedRect: nil, context: nil, hints: nil) else { continue }
    let ratio = Double(cgImage.width) / Double(max(cgImage.height, 1))
    let ratioDelta = abs(log(max(ratio, 0.001) / max(visibleRatio, 0.001)))
    guard ratioDelta <= 0.80 else { continue }
    let fingerprint = averageImageHash(cgImage)
    guard let candidateBits = UInt64(fingerprint, radix: 16) else { continue }
    let hashDistance = (visibleBits ^ candidateBits).nonzeroBitCount
    // Prefer the cached original as in the fastest version, but bind it to
    // visible customer pixels, not merely the newest shared-cache timestamp.
    // JD may stretch/dim previews; a 64-bit hash alone is neither necessary
    // nor sufficient evidence. Ambiguous originals still use the verified crop.
    guard CustomerSafety.cachedThumbnailMatches(visibleImage, cgImage) ||
      (hashDistance <= 4 && CustomerSafety.videoMatches(visibleImage, cgImage)) else { continue }
    let score = Double(hashDistance) * 4 + timeDelta / 5 + ratioDelta * 30
    candidates.append(JDCachedImageCandidate(
      url: url, modified: modified, size: size,
      fingerprint: fingerprint, hashDistance: hashDistance, score: score))
  }

  let ranked = candidates.sorted {
    if $0.score != $1.score { return $0.score < $1.score }
    return $0.modified > $1.modified
  }
  guard let best = ranked.first else { return nil }
  // A small perceptual hash cannot establish byte identity. If different
  // originals resemble this bubble, keep the verified crop instead of choosing
  // another customer's original by file time.
  var digests = Set<String>()
  for candidate in ranked {
    guard let bytes = try? Data(contentsOf: candidate.url), bytes.count == candidate.size else { return nil }
    digests.insert(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    if digests.count > 1 { return nil }
  }
  return best
}

/// JD 10.4 downloads an incoming video into its own per-chat media cache before
/// rendering the thumbnail. Restrict discovery to that cache shape and a short
/// freshness window so automatic analysis never needs to click inside JD.
private enum JDVideoCacheCheck {
  case matched(DownloadedVideoCandidate)
  case notFound
  case unresolved(String)
}

private enum JDMessageVideoReference {
  case verified(String)
  case unavailable(String)
}

private func referencedJDCachedVideo(saveAsName: String) -> JDVideoCacheCheck {
  guard let stem = CustomerSafety.videoCacheStem(saveAsName: saveAsName) else {
    return .unresolved("video_message_reference_invalid")
  }
  let deadline = ProcessInfo.processInfo.systemUptime + 2
  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JingDong/咚咚工作台", isDirectory: true)
  guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
    return .unresolved("video_cache_unavailable")
  }
  var candidates: [URL] = []
  for case let url as URL in enumerator {
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      return .unresolved("video_cache_check_timeout")
    }
    if url.deletingLastPathComponent().lastPathComponent == "videos" &&
        CustomerSafety.videoCacheStem(saveAsName: url.lastPathComponent) == stem {
      candidates.append(url)
      if candidates.count > 40 { return .unresolved("video_message_reference_ambiguous") }
    }
  }
  switch CustomerSafety.referencedCachedVideo(
    saveAsName: saveAsName, candidates: candidates, deadline: deadline) {
  case let .matched(url):
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modified = values.contentModificationDate, let size = values.fileSize else {
      return .unresolved("video_cache_changed_during_check")
    }
    return .matched(DownloadedVideoCandidate(
      url: url, modified: modified, size: size, matchBasis: "verified_message_save_as_reference"))
  case let .unresolved(reason): return .unresolved(reason)
  case .notFound: return .notFound
  }
}

/// A filename read from this exact message can identify a low-information
/// image too. Do not choose by shared-cache time or preview colour.
private func referencedJDCachedImage(saveAsName: String) -> URL? {
  guard let stem = CustomerSafety.mediaCacheStem(saveAsName: saveAsName,
      extensions: ["jpg", "jpeg", "png", "webp"]) else { return nil }
  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JingDong/咚咚工作台")
  let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
  guard let files = FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
  let deadline = ProcessInfo.processInfo.systemUptime + 2
  var matches: [(URL, String)] = []
  for case let url as URL in files {
    guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
    let parent = url.deletingLastPathComponent()
    guard parent.lastPathComponent == "images",
          parent.deletingLastPathComponent().lastPathComponent.hasPrefix("chat_"),
          CustomerSafety.mediaCacheStem(saveAsName: url.lastPathComponent) == stem,
          ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased()),
          url.resolvingSymlinksInPath().deletingLastPathComponent() == parent.standardizedFileURL,
          let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size > 0, size <= 25 * 1024 * 1024,
          let bytes = try? Data(contentsOf: url), bytes.count == size,
          CGImageSourceCreateWithData(bytes as CFData, nil) != nil else { continue }
    matches.append((url, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
  }
  guard CustomerSafety.uniqueVideoDigest(matches.map { $0.1 }) != nil else { return nil }
  return matches.first?.0
}

private func matchingJDCachedVideo(
  visibleImage: CGImage, expectedAt: Date? = nil,
  now: Date = Date(), maximumAge: TimeInterval = 5 * 60,
  timeout: TimeInterval = 8
) -> JDVideoCacheCheck {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JingDong/咚咚工作台",
                           isDirectory: true)
  let keys: Set<URLResourceKey> = [
    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
  ]
  guard let enumerator = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: Array(keys),
    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return .unresolved("video_cache_unavailable") }
  let extensions = Set(["mp4", "mov", "m4v", "webm"])
  var candidates: [DownloadedVideoCandidate] = []
  for case let url as URL in enumerator {
    guard ProcessInfo.processInfo.systemUptime < deadline else { return .unresolved("video_cache_check_timeout") }
    let parent = url.deletingLastPathComponent()
    let chatDirectory = parent.deletingLastPathComponent().lastPathComponent
    guard parent.lastPathComponent == "videos",
          chatDirectory.hasPrefix("chat_"),
          extensions.contains(url.pathExtension.lowercased()),
          let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true,
          let modified = values.contentModificationDate,
          let size = values.fileSize,
          size > 0, size <= 100 * 1024 * 1024 else { continue }
    let age = now.timeIntervalSince(modified)
    guard age >= -5, age <= maximumAge else { continue }
    candidates.append(DownloadedVideoCandidate(
      url: url, modified: modified, size: size))
  }
  let referenceTime = expectedAt ?? now
  let ordered = candidates.sorted {
    let left = abs($0.modified.timeIntervalSince(referenceTime))
    let right = abs($1.modified.timeIntervalSince(referenceTime))
    if left != right { return left < right }
    return $0.modified > $1.modified
  }
  guard ordered.count <= 40 else { return .unresolved("video_cache_candidates_exceeded") }
  // Cache-first, as in 819ce2a: use JD's original payload directly. The paired
  // cached JPEG is the preview JD actually rendered; it need not equal any of
  // the first three decoded MP4 frames. Verify all candidates before choosing.
  switch CustomerSafety.pairedCachedVideo(
    visible: visibleImage, candidates: ordered.map(\.url), deadline: deadline) {
  case let .matched(url):
    guard var candidate = ordered.first(where: { $0.url == url }) else { return .notFound }
    candidate.matchBasis = "paired_cache_thumbnail"
    return .matched(candidate)
  case let .unresolved(reason):
    return .unresolved(reason)
  case .notFound:
    break
  }
  // Older cache entries can lack a paired thumbnail. Retain decoded-frame
  // verification as a secondary route, never a newest-file ownership shortcut.
  guard CustomerSafety.videoSignature(visibleImage) != nil else { return .notFound }
  var matches: [(candidate: DownloadedVideoCandidate, digest: String)] = []
  for candidate in ordered {
    guard ProcessInfo.processInfo.systemUptime < deadline else { return .unresolved("video_cache_check_timeout") }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: candidate.url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 360, height: 360)
    var visuallyMatches = false
    var decodedFrames = 0
    for seconds in [0.0, 0.5, 1.0] {
      guard ProcessInfo.processInfo.systemUptime < deadline else { return .unresolved("video_cache_check_timeout") }
      if let frame = try? generator.copyCGImage(
          at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) {
        decodedFrames += 1
        if CustomerSafety.cachedVideoPreviewMatches(visibleImage, frame) {
          visuallyMatches = true
          break
        }
      }
    }
    guard decodedFrames > 0 else { return .unresolved("video_cache_decode_failed") }
    guard visuallyMatches else { continue }
    guard let bytes = try? Data(contentsOf: candidate.url),
          let values = try? candidate.url.resourceValues(forKeys: keys),
          bytes.count == candidate.size, values.fileSize == candidate.size,
          values.contentModificationDate == candidate.modified else {
      return .unresolved("video_cache_changed_during_check")
    }
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    matches.append((candidate, digest))
  }
  guard ProcessInfo.processInfo.systemUptime < deadline else { return .unresolved("video_cache_check_timeout") }
  guard !matches.isEmpty else { return .notFound }
  let ranked = matches.sorted {
    let left = abs($0.candidate.modified.timeIntervalSince(referenceTime))
    let right = abs($1.candidate.modified.timeIntervalSince(referenceTime))
    if left != right { return left < right }
    return $0.candidate.modified > $1.candidate.modified
  }
  guard CustomerSafety.uniqueVideoDigest(ranked.map(\.digest)) != nil else {
    return .unresolved("video_cache_match_ambiguous")
  }
  return .matched(ranked[0].candidate)
}

private func windowBounds(_ id: CGWindowID) -> CGRect? {
  guard let raw = CGWindowListCopyWindowInfo(.optionIncludingWindow, id)
          as? [[String: Any]], let info = raw.first,
        let dictionary = info[kCGWindowBounds as String] as? [String: Any]
  else { return nil }
  return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
}

private func windowIsOwnedBy(_ id: CGWindowID, pid: pid_t) -> Bool {
  guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
        let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id })
  else { return false }
  return (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
}

private func namedWindowBounds(pid: pid_t, containing title: String) -> CGRect? {
  guard let raw = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
          as? [[String: Any]] else { return nil }
  for info in raw where
    (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
    ((info[kCGWindowName as String] as? String)?.contains(title) == true) {
    guard let dictionary = info[kCGWindowBounds as String] as? [String: Any]
    else { continue }
    if let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
      return bounds
    }
  }
  return nil
}

private func compactTransferText(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
}

private func recognizeTransferText(in image: CGImage) -> [TransferTextLine] {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
  request.usesLanguageCorrection = false
  try? VNImageRequestHandler(cgImage: image, orientation: .up)
    .perform([request])
  let width = CGFloat(image.width)
  let height = CGFloat(image.height)
  return (request.results ?? []).compactMap { observation in
    guard let candidate = observation.topCandidates(1).first else { return nil }
    let box = observation.boundingBox
    return TransferTextLine(
      text: candidate.string.trimmingCharacters(in: .whitespacesAndNewlines),
      confidence: candidate.confidence,
      frame: CGRect(
        x: box.minX * width,
        y: (1 - box.maxY) * height,
        width: box.width * width,
        height: box.height * height))
  }.sorted {
    if abs($0.frame.midY - $1.frame.midY) > height * 0.015 {
      return $0.frame.midY < $1.frame.midY
    }
    return $0.frame.minX < $1.frame.minX
  }
}

private func captureTransferDialog(pid: pid_t) -> TransferDialogSnapshot? {
  guard CGPreflightScreenCaptureAccess(),
        let raw = CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
          as? [[String: Any]] else { return nil }
  let candidates = raw.compactMap { info -> (CGWindowID, CGRect, String)? in
    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
          let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
          let dictionary = info[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
          bounds.width >= 320, bounds.width <= 1_100,
          bounds.height >= 260, bounds.height <= 1_100 else { return nil }
    return (CGWindowID(number), bounds,
            info[kCGWindowName as String] as? String ?? "")
  }
  let ordered = candidates.sorted {
    let leftTitle = $0.2.contains("请选择转接对象")
    let rightTitle = $1.2.contains("请选择转接对象")
    if leftTitle != rightTitle { return leftTitle }
    return $0.1.width * $0.1.height < $1.1.width * $1.1.height
  }
  for candidate in ordered {
    guard let image = CGWindowListCreateImage(
      .null, .optionIncludingWindow, candidate.0,
      [.boundsIgnoreFraming, .bestResolution]) else { continue }
    let lines = recognizeTransferText(in: image)
    let hasVerifiedTitle = candidate.2.contains("请选择转接对象") ||
      lines.contains { compactTransferText($0.text).contains("请选择转接对象") }
    guard hasVerifiedTitle else { continue }
    return TransferDialogSnapshot(
      windowID: candidate.0, bounds: candidate.1, image: image, lines: lines)
  }
  return nil
}

private func transferAccountName(from compact: String,
                                 line: TransferTextLine,
                                 imageWidth: CGFloat) -> String? {
  // Vision sometimes merges the small Latin Grozziie logo inside the avatar
  // with the Chinese account name. Keep the real name from its stable marker.
  if let marker = compact.range(of: "格志打印机") {
    return String(compact[marker.lowerBound...])
  }
  // A standalone logo sits farther left than a normal account label and must
  // not become a transfer target by itself.
  guard line.frame.minX > imageWidth * 0.18 else { return nil }
  return compact
}

private func transferBadgePixelEvidence(line: TransferTextLine,
                                        image: CGImage) -> (green: Int, red: Int) {
  let width = CGFloat(image.width)
  let height = CGFloat(image.height)
  let nameRelative = CGRect(
    x: line.frame.minX - width * 0.045,
    y: line.frame.midY - height * 0.008,
    width: width * 0.043,
    height: height * 0.055)
  // When Vision merges the avatar logo and account name, line.minX points to
  // the logo. JD's status badge itself remains in this stable dialog band.
  let dialogRelative = CGRect(
    x: width * 0.165,
    y: line.frame.midY - height * 0.020,
    width: width * 0.045,
    height: height * 0.065)
  let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
  let bitmap = NSBitmapImageRep(cgImage: image)

  func count(in candidate: CGRect) -> (green: Int, red: Int) {
    let rect = candidate.integral.intersection(imageBounds)
    guard rect.width >= 4, rect.height >= 4 else { return (0, 0) }
    var greenResult = 0
    var redResult = 0
    for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 1) {
      for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 1) {
        guard let color = bitmap.colorAt(x: x, y: y)?
          .usingColorSpace(.deviceRGB) else { continue }
        let red = Int(color.redComponent * 255)
        let green = Int(color.greenComponent * 255)
        let blue = Int(color.blueComponent * 255)
        // JD 10.4 renders the online badge as turquoise on some display
        // scales, where the blue channel can be close to (or slightly above)
        // green. Keep the strong red separation so offline red badges cannot
        // pass, while accepting both green and turquoise antialiasing.
        if green >= 105 && red <= 140 && blue <= 240 &&
            green >= red + 35 && green + 25 >= blue {
          greenResult += 1
        }
        if red >= 170 && green <= 145 && blue <= 150 && red >= green + 35 {
          redResult += 1
        }
      }
    }
    return (greenResult, redResult)
  }

  func evidence(in rect: CGRect) -> (green: Int, red: Int) {
    let direct = count(in: rect)
    let flippedRect = CGRect(
      x: rect.minX, y: height - rect.maxY,
      width: rect.width, height: rect.height)
    let flipped = count(in: flippedRect)
    return direct.green + direct.red >= flipped.green + flipped.red
      ? direct : flipped
  }

  let nearName = evidence(in: nameRelative)
  let stableBand = evidence(in: dialogRelative)
  return nearName.green + nearName.red >= stableBand.green + stableBand.red
    ? nearName : stableBand
}

private func transferAccountCandidates(
  in dialog: TransferDialogSnapshot
) -> [TransferAccountCandidate] {
  let width = dialog.imageWidth
  let height = dialog.imageHeight
  let groupBottom = dialog.lines.first(where: {
    compactTransferText($0.text).contains("默认咨询组")
  })?.frame.maxY ?? height * 0.31
  let ignored = [
    "请选择转接对象", "指定客服", "指定咨询组", "搜索账号/名字",
    "转接", "备注原因", "默认咨询组",
  ]
  var seen = Set<String>()
  return dialog.lines.compactMap { line -> TransferAccountCandidate? in
    let compact = compactTransferText(line.text)
    guard let accountName = transferAccountName(
      from: compact, line: line, imageWidth: width) else { return nil }
    guard line.confidence >= 0.35,
          line.frame.midY > groupBottom + height * 0.025,
          line.frame.midY < height * 0.96,
          line.frame.minX > width * 0.08,
          line.frame.midX < width * 0.64,
          line.frame.height >= height * 0.018,
          line.frame.height <= height * 0.075,
          accountName.count >= 2, accountName.count <= 48,
          !ignored.contains(where: { compact.contains($0) }),
          accountName.range(of: #"^\d+/\d+$"#, options: .regularExpression) == nil,
          seen.insert(normalizedCustomerIdentity(accountName)).inserted else {
      return nil
    }
    let evidence = transferBadgePixelEvidence(line: line, image: dialog.image)
    return TransferAccountCandidate(
      name: accountName,
      frame: line.frame,
      greenPixelEvidence: evidence.green,
      redPixelEvidence: evidence.red)
  }
}

private func unreadScreenshot(pid: pid_t, matching target: CGRect) -> UnreadScreenshot? {
  guard CGPreflightScreenCaptureAccess(),
        let raw = CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
          as? [[String: Any]] else { return nil }
  // CGWindowName is sometimes empty even while AX exposes the named JD
  // reception window. Select the actual AX window by geometry as well as PID;
  // requiring the CG title silently disabled unread detection in that case.
  let candidates = raw.filter {
    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
    ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
  }
  let info = candidates.max { left, right in
    func score(_ value: [String: Any]) -> CGFloat {
      guard let dictionary = value[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
      else { return -.infinity }
      let overlap = bounds.intersection(target)
      let overlapRatio = overlap.isNull ? 0 :
        (overlap.width * overlap.height) / max(1, target.width * target.height)
      let titleMatch = (value[kCGWindowName as String] as? String)?
        .contains("咚咚融合工作台") == true
      return overlapRatio + (titleMatch ? 0.05 : 0)
    }
    return score(left) < score(right)
  }
  guard let info,
        let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        let dictionary = info[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
        let image = CGWindowListCreateImage(
          .null, .optionIncludingWindow, CGWindowID(id),
          [.boundsIgnoreFraming, .bestResolution]) else { return nil }
  return UnreadScreenshot(bounds: bounds, image: image)
}

private func unreadRedPixels(frame: CGRect, windowBounds: CGRect,
                             image: CGImage, flipped: Bool) -> Int {
  guard windowBounds.width > 0, windowBounds.height > 0 else { return 0 }
  let scaleX = CGFloat(image.width) / windowBounds.width
  let scaleY = CGFloat(image.height) / windowBounds.height
  let localX = (frame.minX - windowBounds.minX + frame.width * 0.65) * scaleX
  let localY = (frame.minY - windowBounds.minY) * scaleY
  let width = frame.width * 0.35 * scaleX
  let height = frame.height * scaleY
  let bitmap = NSBitmapImageRep(cgImage: image)

  func count(in rect: CGRect) -> Int {
    let minX = max(0, Int(rect.minX))
    let maxX = min(image.width, Int(rect.maxX))
    let minY = max(0, Int(rect.minY))
    let maxY = min(image.height, Int(rect.maxY))
    guard minX < maxX, minY < maxY else { return 0 }
    var result = 0
    for y in stride(from: minY, to: maxY, by: 2) {
      for x in stride(from: minX, to: maxX, by: 2) {
        guard let color = bitmap.colorAt(x: x, y: y)?
                .usingColorSpace(.deviceRGB) else { continue }
        let red = Int(color.redComponent * 255)
        let green = Int(color.greenComponent * 255)
        let blue = Int(color.blueComponent * 255)
        if red >= 185 && green <= 125 && blue <= 125 && red >= green + 60 {
          result += 1
        }
      }
    }
    return result
  }
  let rect = flipped
    ? CGRect(x: localX, y: CGFloat(image.height) - localY - height,
             width: width, height: height)
    : CGRect(x: localX, y: localY, width: width, height: height)
  return count(in: rect)
}

/// The red JD badge shows elapsed time as mm:ss. Read it only inside a row
/// already proven unread by its red pixels; a grey wall-clock label must not
/// backdate a new-message deadline.
private func unreadElapsedSeconds(frame: CGRect, windowBounds: CGRect,
                                  image: CGImage, flipped: Bool) -> Int? {
  guard windowBounds.width > 0, windowBounds.height > 0 else { return nil }
  let scaleX = CGFloat(image.width) / windowBounds.width
  let scaleY = CGFloat(image.height) / windowBounds.height
  let x = (frame.minX - windowBounds.minX + frame.width * 0.65) * scaleX
  let y = (frame.minY - windowBounds.minY) * scaleY
  let width = frame.width * 0.35 * scaleX
  let height = frame.height * scaleY
  let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
  let candidates = [flipped
    ? CGRect(x: x, y: CGFloat(image.height) - y - height,
             width: width, height: height)
    : CGRect(x: x, y: y, width: width, height: height)]
  for candidate in candidates {
    let cropBounds = candidate.integral.intersection(imageBounds)
    guard cropBounds.width >= 30, cropBounds.height >= 18,
          let crop = image.cropping(to: cropBounds) else { continue }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
    for result in request.results ?? [] {
      guard let rawText = result.topCandidates(1).first?.string else { continue }
      let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "：", with: ":")
        .replacingOccurrences(of: "O", with: "0")
        .replacingOccurrences(of: "o", with: "0")
        .replacingOccurrences(of: "I", with: "1")
        .replacingOccurrences(of: "l", with: "1")
      if text.range(of: #"^\d{1,2}:\d{2}$"#,
                    options: .regularExpression) != nil {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]),
              let seconds = Int(parts[1]), seconds < 60 else { continue }
        return minutes * 60 + seconds
      }
      // During the first minute JD renders badges as `51秒`; afterward it
      // switches to `01:00`. Vision may retain the suffix, translate it to an
      // English abbreviation, or return only the digits from the red pill.
      let secondsText = text.replacingOccurrences(
        of: #"(?:秒|s|sec|secs|second|seconds)$"#, with: "",
        options: [.regularExpression, .caseInsensitive])
      if secondsText.range(of: #"^\d{1,3}$"#,
                           options: .regularExpression) != nil,
         let seconds = Int(secondsText), seconds <= 600 {
        return seconds
      }
    }
  }
  return nil
}

private func normalizedCustomerIdentity(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines)
    .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

private func exactCustomerIdentityMatches(_ left: String, _ right: String) -> Bool {
  CustomerSafety.matches(left, right)
}


private func cleanedRowCustomerIdentity(_ raw: String) -> String? {
  var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  text = text.replacingOccurrences(
    of: #"\s+(?:20\d{2}[-/.]\d{1,2}[-/.]\d{1,2}\s+)?\d{1,2}:\d{2}(?::\d{2})?\s*$"#,
    with: "", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !text.isEmpty, text.count <= 80,
        !text.contains("..."), !text.contains("…"),
        text.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
  let compact = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
  let ignored: Set<String> = [
    "在线咨询", "留言", "排序", "清除", "紧凑布局", "客服助手", "暂无选中的会话",
  ]
  guard !ignored.contains(compact),
        text.range(of: #"^\d{1,2}:\d{2}(?::\d{2})?$"#,
                   options: .regularExpression) == nil else { return nil }
  return text
}

/// JD exposes each conversation as an untitled pressable AXGroup. Read the
/// first-line display identity from that group's screenshot crop; the active
/// header is still used independently after a click to verify the selection.
private struct SidebarRowIdentity {
  let customer: String
  let flipped: Bool
}

private func customerIdentityInRow(frame: CGRect, windowBounds: CGRect,
                                   image: CGImage) -> SidebarRowIdentity? {
  guard windowBounds.width > 0, windowBounds.height > 0 else { return nil }
  let scaleX = CGFloat(image.width) / windowBounds.width
  let scaleY = CGFloat(image.height) / windowBounds.height
  let x = (frame.minX - windowBounds.minX) * scaleX
  let y = (frame.minY - windowBounds.minY) * scaleY
  let width = frame.width * scaleX
  let height = frame.height * scaleY
  let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
  let candidates: [(rect: CGRect, flipped: Bool)] = [
    (CGRect(x: x, y: y, width: width, height: height)
      .integral.intersection(bounds), false),
    (CGRect(x: x, y: CGFloat(image.height) - y - height,
            width: width, height: height).integral.intersection(bounds), true),
  ]
  for candidate in candidates
    where candidate.rect.width >= 40 && candidate.rect.height >= 20 {
    let rect = candidate.rect
    guard let crop = image.cropping(to: rect) else { continue }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
    let ranked = (request.results ?? []).compactMap { observation -> (String, Double)? in
      guard observation.boundingBox.midY >= 0.46,
            observation.boundingBox.minX >= 0.10,
            observation.boundingBox.minX < 0.84,
            let candidate = observation.topCandidates(1).first,
            let identity = cleanedRowCustomerIdentity(candidate.string) else { return nil }
      // Prefer the upper-left text line. This separates the identity from the
      // lower message preview and the right-aligned recency/timestamp label.
      let score = Double(observation.boundingBox.midY) * 100 -
        Double(observation.boundingBox.minX) * 20 + Double(candidate.confidence)
      return (identity, score)
    }.sorted { $0.1 > $1.1 }
    if let identity = ranked.first?.0 {
      return SidebarRowIdentity(customer: identity, flipped: candidate.flipped)
    }
  }
  return nil
}

private struct OCRInspectorError: Error {
  let code: String
  let message: String

  var payload: [String: Any] { ["error": code, "message": message] }
}

private struct AXNode {
  let element: AXUIElement
  let path: String
  let role: String
  let subrole: String?
  let identifier: String?
  let title: String?
  let description: String?
  let value: String?
  let help: String?
  let frame: CGRect?
  let actions: [String]
  let children: [AXUIElement]

  var text: String? {
    [title, value, description].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }
}

/// AX discovery and conservative capture for JD Dingdong (Qianniu-style desktop).
/// It uses structural traits only; install-specific labels must be learned from Inspect Tree output.
final class QianniuAXCollector {
  var onCapture: (([String: Any]) -> Void)?
  var onDiagnostic: (([String: Any]) -> Void)?
  var onOwnedComposerClaims: (([String: String]) -> Void)?
  private var failedSendRetries: [String: (attempts: Int, next: Date)] = [:]

  private let bundleIdentifier = "com.jd.jdmddwb"
  private let queue = DispatchQueue(label: "jd.ax.capture", qos: .userInitiated)
  // JD's cache tree can be slow to enumerate. It must not block the serial
  // AX queue used to send a time-bound customer holding message.
  private let videoCacheQueue = DispatchQueue(label: "jd.ax.video-cache", qos: .userInitiated)
  private let attachmentFileQueue = DispatchQueue(label: "jd.ax.attachment-files",
      qos: .userInitiated, attributes: .concurrent)
  private var pendingAttachmentCleanup: (() -> Bool)?
  private var timer: DispatchSourceTimer?
  private var seenFingerprints = Set<String>()
  private var lastActiveConversation: String?
  private var pendingTransferCustomer: String?
  private struct VerifiedVideoReference {
    let customer: String
    let window: CGWindowID
    let snapshotDigest: String
    let region: CGRect
    let candidate: DownloadedVideoCandidate
    let expires: TimeInterval
  }
  // Short-lived capability issued only after native message/cache verification.
  // Reusing it avoids opening Save As a second time for a blank video preview.
  private var verifiedVideoReferences: [String: VerifiedVideoReference] = [:]
  private struct OwnedComposer {
    let element: AXUIElement
    let text: String
  }
  // Queue-confined insertion ownership allows safe cleanup after a timed-out
  // read. Never erase unrelated operator text or another customer's composer.
  private var restoredComposerClaims: [String: String] = [:]
  private var ownedComposers: [String: OwnedComposer] = [:] {
    didSet { publishComposerClaims() }
  }
  func restoreOwnedComposerClaims(_ claims: [String: String]) {
    // Called before dispatching a new request, never while a UI call is active.
    restoredComposerClaims = claims.filter { ownedComposers[$0.key] == nil }
  }
  private func publishComposerClaims() {
    onOwnedComposerClaims?(restoredComposerClaims.merging(ownedComposers.mapValues(\.text)) { _, current in current })
  }

  func status() -> [String: Any] {
    let pid = runningPID()
    let competing = NSWorkspace.shared.runningApplications.filter {
      $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
        !$0.isTerminated &&
        ["com.grozziie.jdAutomation", "com.grozziie.jdAutomation.standalone",
         "com.grozziie.jdAutomation.review"]
          .contains($0.bundleIdentifier ?? "")
    }.map { ["pid": Int($0.processIdentifier), "bundle": $0.bundleIdentifier ?? ""] as [String: Any] }
    return [
      "trusted": AXIsProcessTrusted(),
      "screenRecording": CGPreflightScreenCaptureAccess(),
      "appBundleIdentifier": Bundle.main.bundleIdentifier ?? "",
      "appBundlePath": Bundle.main.bundlePath,
      "appProcessId": Int(ProcessInfo.processInfo.processIdentifier),
      "running": pid != nil,
      "pid": pid.map(Int.init) as Any,
      "bundleIdentifier": bundleIdentifier,
      "captureRunning": timer != nil,
      "competingApps": competing,
    ]
  }

  func requestAccessibility() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  /// Captures a validated image-bubble region from the Qianniu window when its
  /// embedded web view does not expose image bytes through the pasteboard.
  func captureImageRegion(expectedCustomer: String, windowID: CGWindowID,
                          normalizedX: Double, normalizedY: Double,
                          normalizedWidth: Double, normalizedHeight: Double,
                          expectedMediaAt: Date? = nil,
                          allowActivationForVideoDetection: Bool = false,
                          allowMessageReferenceLookup: Bool = true,
                          allowAttachmentPreview: Bool = false,
                          previewTextRegions: [CGRect] = [],
                          sourcePNG: Data? = nil, sourceSenderY: Double? = nil,
                          completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard AXIsProcessTrusted(), !expected.isEmpty,
            normalizedX >= 0, normalizedY >= 0,
            normalizedWidth > 0, normalizedHeight > 0,
            normalizedX + normalizedWidth <= 1,
            normalizedY + normalizedHeight <= 1,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            let ownerPID = runningPID(), windowIsOwnedBy(windowID, pid: ownerPID) else {
        finish(["error": "image_crop_precondition_failed",
                "message": "The expected customer or image region could not be verified."])
        return
      }
      guard let fullImage = CGWindowListCreateImage(
              .null, .optionIncludingWindow, windowID,
              [.boundsIgnoreFraming, .bestResolution]) else {
        finish(["error": "image_crop_window_failed",
                "message": "Could not capture the selected JingMai window."])
        return
      }
      let crop = CGRect(
        x: CGFloat(normalizedX) * CGFloat(fullImage.width),
        y: CGFloat(normalizedY) * CGFloat(fullImage.height),
        width: CGFloat(normalizedWidth) * CGFloat(fullImage.width),
        height: CGFloat(normalizedHeight) * CGFloat(fullImage.height)).integral
      guard let sourcePNG, let source = NSImage(data: sourcePNG)?.cgImage(
              forProposedRect: nil, context: nil, hints: nil),
            CustomerSafety.mediaSnapshotMatches(source: source, current: fullImage,
              region: crop, senderY: sourceSenderY) else {
        finish(["error": "media_snapshot_changed",
                "message": "The sender/media pixels no longer match the OCR snapshot; refresh OCR before using any coordinates."])
        return
      }
      guard crop.width >= 40, crop.height >= 40,
            let image = fullImage.cropping(to: crop),
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            let png = NSBitmapImageRep(cgImage: image)
              .representation(using: .png, properties: [:]) else {
        finish(["error": "image_crop_verification_failed",
                "message": "The image region or active customer changed during capture."])
        return
      }
      // An absent play overlay is not proof of an image. Independently check
      // video-cache bytes before accepting the image path. Keep disk/decoder
      // work off the serial AX queue so reply delivery can continue.
      self.videoCacheQueue.async {
        let check = matchingJDCachedVideo(
          visibleImage: image, expectedAt: expectedMediaAt, timeout: 3)
        func verifiedFinish(_ payload: [String: Any]) {
          self.queue.async {
            guard self.activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
                  windowIsOwnedBy(windowID, pid: ownerPID) else {
              finish(["error": "media_customer_changed_during_cache_check",
                      "message": "The verified customer changed during cache cross-check; nothing was assigned."])
              return
            }
            var verified = payload
            verified["verifiedCustomerId"] = expected
            verified["ownershipVerification"] = "visible_customer_region"
            finish(verified)
          }
        }
        func finishVideo(_ candidate: DownloadedVideoCandidate) {
          guard !AVURLAsset(url: candidate.url).tracks(withMediaType: .video).isEmpty else {
            verifiedFinish(["error": "video_cache_invalid_original"])
            return
          }
          self.queue.async {
            guard self.activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
                  windowIsOwnedBy(windowID, pid: ownerPID) else {
              finish(["error": "media_customer_changed_during_cache_check"])
              return
            }
            let now = ProcessInfo.processInfo.systemUptime
            self.verifiedVideoReferences = self.verifiedVideoReferences.filter { $0.value.expires > now }
            let token = UUID().uuidString
            self.verifiedVideoReferences[token] = VerifiedVideoReference(
              customer: expected, window: windowID,
              snapshotDigest: SHA256.hash(data: sourcePNG).map { String(format: "%02x", $0) }.joined(),
              region: crop, candidate: candidate, expires: now + 15)
            finish(["kind": "video", "mimeType": "image/png", "extension": "png",
              "dataBase64": png.base64EncodedString(), "visualFingerprint": averageImageHash(image),
              "captureSource": "verified-video-cache-reference", "cacheReferenceToken": token,
              "originalName": candidate.url.lastPathComponent,
              "verifiedCustomerId": expected, "ownershipVerification": "visible_customer_region"])
          }
        }
        func finishImage(_ url: URL) {
          let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
          guard let before = try? url.resourceValues(forKeys: keys),
                let data = try? Data(contentsOf: url), data.count == before.fileSize,
                let after = try? url.resourceValues(forKeys: keys),
                before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let cachedCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            verifiedFinish(["error": "image_cache_changed_during_copy"])
            return
          }
          let ext = url.pathExtension.lowercased()
          let mime = ext == "png" ? "image/png" : (ext == "webp" ? "image/webp" : "image/jpeg")
          verifiedFinish([
            "kind": "image", "mimeType": mime, "extension": ext,
            "originalName": url.lastPathComponent,
            "dataBase64": data.base64EncodedString(),
            "visualFingerprint": averageImageHash(cachedCGImage),
            "captureSource": "jd-image-cache", "cacheCrossCheck": "verified_original",
          ])
        }
        if case let .matched(candidate) = check { finishVideo(candidate); return }
        if let cached = matchingRecentJDCachedImage(visibleImage: image, expectedAt: expectedMediaAt) {
          // The images directory also contains video posters. A paired MP4
          // wins over its JPEG; a poster is never a new image upload.
          switch referencedJDCachedVideo(saveAsName: cached.url.deletingPathExtension().lastPathComponent) {
          case let .matched(candidate): finishVideo(candidate); return
          case .unresolved: break
          case .notFound: finishImage(cached.url); return
          }
        }
        // Retain this customer's visible evidence when its original cannot be
        // identified. Never select a flat shared-cache file by colour/time or
        // misrepresent a possible video poster as an original image.
        if allowAttachmentPreview, expectedMediaAt != nil,
           let senderY = sourceSenderY, senderY < normalizedY {
          let localText = previewTextRegions.map {
            CGRect(x: ($0.minX - normalizedX) / normalizedWidth,
                   y: ($0.minY - normalizedY) / normalizedHeight,
                   width: $0.width / normalizedWidth, height: $0.height / normalizedHeight)
          }
          if CustomerSafety.attachmentPreviewHasVisualEvidence(image, textRegions: localText) {
            let reason: String
            if case let .unresolved(value) = check { reason = value }
            else { reason = "media_original_not_verified" }
            verifiedFinish([
              "kind": "attachment_preview", "mimeType": "image/png", "extension": "png",
              "dataBase64": png.base64EncodedString(),
              "visualFingerprint": averageImageHash(image),
              "captureSource": "verified-window-preview", "cacheCrossCheck": reason,
            ])
            return
          }
        }
        // No menus, Save As, speculative empty-block images or newest-file
        // assignment. Other messages/customers continue after a bounded miss.
        switch check {
        case let .unresolved(reason): verifiedFinish(["error": reason])
        default: verifiedFinish(["error": "media_original_not_verified"])
        }
      }
    }
  }

  /// Discovery only. Customer ownership must be established separately against
  /// a sender-bounded visible bubble; this method never reads/copies payloads.
  func probeRecentCachedMedia(expectedCustomer: String,
                                expectedMediaAt: Date?,
                                completion: @escaping FlutterResult) {
    videoCacheQueue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard AXIsProcessTrusted(), !expected.isEmpty,
            let expectedMediaAt,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true else {
        finish(["candidateFound": false, "reason": "cache_probe_precondition_failed"])
        return
      }
      guard let selection = recentJDCachedMedia(expectedAt: expectedMediaAt) else {
        finish(["candidateFound": false, "reason": "no_recent_cache_candidate"])
        return
      }
      guard activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true else {
        finish(["candidateFound": false, "reason": "cache_customer_changed"])
        return
      }
      finish([
        "candidateFound": true,
        "verifiedCustomerId": expected,
        "kind": selection.candidate.kind,
        "cacheSelectionAmbiguous": selection.ambiguous,
        "cacheCandidateCount": selection.candidateCount,
        "reason": "visible_customer_media_verification_required",
      ])
    }
  }

  /// Cache-first acquisition restored from 819ce2a. Only actual video files
  /// qualify, so white/black posters and missing play overlays do not matter.
  /// This method performs no screenshot, activation, click, or keyboard input.
  func captureRecentCachedVideo(expectedCustomer: String, windowID: CGWindowID,
                                expectedMediaAt: Date?, competingMessageTimes: [Date],
                                destinationDirectory: String,
                                completion: @escaping FlutterResult) {
    videoCacheQueue.async { [weak self] in
      guard let self else { return }
      let budget = AccessibilityBudget(deadline: Date().addingTimeInterval(6))
      defer { budget.close() }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      let destination = URL(fileURLWithPath: destinationDirectory, isDirectory: true).standardizedFileURL
      guard AXIsProcessTrusted(), !expected.isEmpty, let expectedMediaAt,
            let pid = runningPID(), windowIsOwnedBy(windowID, pid: pid),
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            FileManager.default.fileExists(atPath: destination.path) else {
        finish(["error": "video_download_precondition_failed"])
        return
      }
      guard let selection = recentJDCachedMedia(expectedAt: expectedMediaAt,
              maximumDelta: 60, timeout: 2, strictReceiveWindow: true),
            !selection.ambiguous, selection.candidate.kind == "video" else {
        finish(["kind": "none", "reason": "no_unique_recent_cache_video"])
        return
      }
      let cached = selection.candidate
      guard CustomerSafety.cacheVideoClockMatches(modified: cached.modified,
              expected: expectedMediaAt, now: Date(), competing: competingMessageTimes) else {
        finish(["kind": "none", "reason": "cache_video_competing_turn"])
        return
      }
      let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
      guard budget.isCurrent,
            cached.url.resolvingSymlinksInPath().deletingLastPathComponent() ==
              cached.url.deletingLastPathComponent().standardizedFileURL,
            let before = try? cached.url.resourceValues(forKeys: keys),
            before.fileSize == cached.size, before.contentModificationDate == cached.modified,
            let bytes = try? Data(contentsOf: cached.url), bytes.count == cached.size,
            let after = try? cached.url.resourceValues(forKeys: keys),
            after.fileSize == before.fileSize, after.contentModificationDate == before.contentModificationDate,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true else {
        finish(["error": "video_cache_changed_during_check"])
        return
      }
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      let cacheKey = sha256("\(cached.url.standardizedFileURL.path)\u{1f}\(cached.modified.timeIntervalSince1970)\u{1f}\(cached.size)")
      let file = destination.appendingPathComponent("\(digest).\(cached.url.pathExtension.lowercased())")
      var created = false
      do {
        if FileManager.default.fileExists(atPath: file.path) {
          guard file.resolvingSymlinksInPath().deletingLastPathComponent() == destination.resolvingSymlinksInPath(),
                (try? Data(contentsOf: file)) == bytes else {
            finish(["error": "video_copy_owner_mismatch"])
            return
          }
        } else {
          try bytes.write(to: file, options: .atomic)
          created = true
        }
      } catch {
        finish(["error": "video_copy_failed"])
        return
      }
      guard budget.isCurrent, windowIsOwnedBy(windowID, pid: pid),
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == cached.size else {
        if created { try? FileManager.default.removeItem(at: file) }
        finish(["error": "video_copy_verification_failed"])
        return
      }
      let ext = cached.url.pathExtension.lowercased()
      finish(["kind": "video", "path": file.path,
        "originalName": cached.url.lastPathComponent,
        "mimeType": ext == "mov" || ext == "m4v" ? "video/quicktime" :
          (ext == "webm" ? "video/webm" : "video/mp4"),
        "size": cached.size, "cacheKey": cacheKey, "createdCopy": created,
        "cacheModifiedAtMs": Int(cached.modified.timeIntervalSince1970 * 1000),
        "expectedMediaAtMs": Int(expectedMediaAt.timeIntervalSince1970 * 1000),
        "verifiedCustomerId": expected, "ownershipVerification": "exact_customer_unique_cache_clock",
        "captureSource": "jd-video-cache", "cacheMatchBasis": "819ce2a_cache_first"])
    }
  }

  private func mediaSavePanelNodes(pid: pid_t) -> [AXNode] {
    var nodes: [AXNode] = []
    walk(AXUIElementCreateApplication(pid), path: "app", depth: 0,
         maxDepth: 18, maxNodes: 2_500) { node, _ in nodes.append(node) }
    // Remote NSSavePanel elements can have another PID but are still reached
    // through JD's own AX hierarchy. Never search unrelated apps for a dialog.
    let names = nodes.filter { $0.identifier == "saveAsNameTextField" }
    let panels = nodes.filter { node in node.identifier == "save-panel" ||
      ((node.role == kAXSheetRole as String || node.role == kAXWindowRole as String) &&
       node.title?.contains("咚咚融合工作台") != true &&
       names.contains { $0.path.hasPrefix(node.path + "/") }) }
    return nodes.filter { node in panels.contains {
      node.path == $0.path || node.path.hasPrefix($0.path + "/")
    } }
  }

  /// Bounded exact-message export. Called only by the explicit fallback after
  /// cache acquisition fails; menu/dialog cleanup is mandatory before return.
  private func videoReferenceFromMessage(expected: String, windowID: CGWindowID,
                                         region: CGRect, originalImage: CGImage,
                                         sourceSenderY: Double?,
                                         exportDirectory: URL,
                                         allowActivation: Bool = true,
                                         expiresAt: TimeInterval) -> JDMessageVideoReference {
    let budget = AccessibilityBudget(deadline: Date().addingTimeInterval(8),
                                     uptimeDeadline: expiresAt)
    defer { budget.close() }
    guard budget.isCurrent, let pid = runningPID(),
          windowIsOwnedBy(windowID, pid: pid), let bounds = windowBounds(windowID),
          activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
          mediaSavePanelNodes(pid: pid).isEmpty,
          let app = NSRunningApplication(processIdentifier: pid) else {
      return .unavailable("video_message_reference_precondition_failed")
    }
    let point = CGPoint(x: bounds.minX + region.midX * bounds.width / CGFloat(originalImage.width),
                        y: bounds.minY + region.midY * bounds.height / CGFloat(originalImage.height))
    // JingMai embeds this LSUIElement/accessory process inside its regular
    // launcher. macOS can report the launcher as frontmost while the exact
    // child window owns the click. Verify BOTH process family and hit window.
    let launcher = NSRunningApplication.runningApplications(withBundleIdentifier: "com.jd.jingmaiMac")
      .first { parent in
        guard !parent.isTerminated, let root = parent.bundleURL?.standardizedFileURL.path,
              let child = app.bundleURL?.standardizedFileURL.path else { return false }
        return child.hasPrefix(root + "/Contents/")
      }
    func matchesReceptionWindow(_ element: AXUIElement) -> Bool {
      guard stringAttribute(element, kAXRoleAttribute) == kAXWindowRole as String,
            stringAttribute(element, kAXTitleAttribute)?.contains("咚咚融合工作台") == true,
            let frame = frameAttribute(element) else { return false }
      return abs(frame.minX - bounds.minX) <= 2 && abs(frame.minY - bounds.minY) <= 2 &&
        abs(frame.width - bounds.width) <= 2 && abs(frame.height - bounds.height) <= 2
    }
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 0.3)
    let windows = elementArrayAttribute(axApp, kAXWindowsAttribute).filter(matchesReceptionWindow)
    let receptionWindow = windows.count == 1 ? windows[0] :
      (windows.isEmpty ? receptionNodes(pid: pid)?.first(where: { matchesReceptionWindow($0.element) })?.element : nil)
    guard let receptionWindow else { return .unavailable("video_message_reference_window_unverified") }
    func foreground(at point: CGPoint, allowOwnedOverlay: Bool = false) -> Bool {
      // Window rectangles are NOT pointer hit tests: the Dock owns a nearly
      // transparent full-screen layer. Ask AX which element actually receives
      // this point, and prove its process and exact reception window instead.
      let system = AXUIElementCreateSystemWide()
      AXUIElementSetMessagingTimeout(system, 0.3)
      var hit: AXUIElement?
      guard budget.isCurrent,
            accessibilityReadSucceeded(AXUIElementCopyElementAtPosition(system,
              Float(point.x), Float(point.y), &hit)), let hit else { return false }
      var hitPID: pid_t = 0
      guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid else { return false }
      var node: AXUIElement? = hit
      var exactWindow = false
      var ownedMenu = false
      for _ in 0..<12 {
        guard budget.isCurrent, let current = node else { break }
        AXUIElementSetMessagingTimeout(current, 0.3)
        var owner: pid_t = 0
        guard AXUIElementGetPid(current, &owner) == .success, owner == pid else { return false }
        let role = stringAttribute(current, kAXRoleAttribute)
        ownedMenu = ownedMenu || role == kAXMenuRole as String || role == kAXMenuItemRole as String
        if CFEqual(current, receptionWindow) ||
            elementAttribute(current, kAXWindowAttribute).map({ CFEqual($0, receptionWindow) }) == true {
          exactWindow = true
          break
        }
        if role == kAXWindowRole as String || role == kAXApplicationRole as String { break }
        node = elementAttribute(current, kAXParentAttribute)
      }
      return CustomerSafety.mediaReferenceForeground(workbenchPID: pid,
        launcherPID: launcher?.processIdentifier,
        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        hitPID: hitPID, hitExpectedWindow: exactWindow, hitOwnedMenu: ownedMenu,
        allowOwnedOverlay: allowOwnedOverlay)
    }
    if !foreground(at: point) {
      guard allowActivation else { return .unavailable("media_reference_requires_activation") }
      // Raise only the already-verified workbench window. No stale coordinates
      // or arbitrary window-title click is used to obtain focus.
      guard budget.isCurrent, matchesReceptionWindow(receptionWindow) else {
        return .unavailable("video_message_reference_raise_unverified")
      }
      DispatchQueue.main.sync {
        _ = (app.activationPolicy == .regular ? app : (launcher ?? app))
          .activate(options: [.activateIgnoringOtherApps])
      }
      _ = AXUIElementPerformAction(receptionWindow, kAXRaiseAction as CFString)
      for _ in 0..<24 {
        if foreground(at: point) { break }
        if !budget.isCurrent { break }
        usleep(50_000)
      }
      guard foreground(at: point) else {
        return .unavailable("video_message_reference_activation_failed")
      }
    }
    // A user scroll/switch between native classification and menu opening must
    // not silently redirect the selected message, even within the same buyer.
    guard budget.isCurrent,
          foreground(at: point),
          let current = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
              [.boundsIgnoreFraming, .bestResolution]),
          current.width == originalImage.width, current.height == originalImage.height,
          windowBounds(windowID) == bounds,
          CustomerSafety.mediaSnapshotMatches(source: originalImage, current: current,
            region: region, senderY: sourceSenderY),
          activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true else {
      return .unavailable("video_message_changed_before_reference")
    }
    let menuBounds = CGRect(x: point.x - 300, y: point.y - 300, width: 700, height: 650)
      .intersection(bounds)
    guard let baseline = CGWindowListCreateImage(menuBounds, .optionOnScreenOnly,
        kCGNullWindowID, [.boundsIgnoreFraming, .bestResolution]),
        CustomerSafety.attachmentSaveTarget(recognizeTransferText(in: baseline).map {
          CustomerSafety.AttachmentMenuLine(text: $0.text, confidence: $0.confidence, frame: $0.frame)
        }) == nil, budget.isCurrent,
        postRightClick(at: point) else { return .unavailable("video_message_menu_failed") }
    self.pendingAttachmentCleanup = { [weak self] in
      self?.closeAttachmentMenu(expected: expected, pid: pid, windowID: windowID,
          menuBounds: menuBounds, baseline: baseline) ?? false
    }
    var savePoint: CGPoint?
    // JD's menu often has not rendered 120 ms after the click. A bounded
    // resnapshot is safe; clicking the former menu position is not.
    for _ in 0..<3 {
      guard budget.isCurrent,
            windowBounds(windowID) == bounds,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            foreground(at: point, allowOwnedOverlay: true),
            let menuImage = CGWindowListCreateImage(menuBounds, .optionOnScreenOnly, kCGNullWindowID,
                [.boundsIgnoreFraming, .bestResolution]) else { break }
      let lines = recognizeTransferText(in: menuImage)
      if let save = CustomerSafety.attachmentSaveTarget(lines.map {
        CustomerSafety.AttachmentMenuLine(text: $0.text, confidence: $0.confidence, frame: $0.frame)
      }) {
          savePoint = CGPoint(
            x: menuBounds.minX + save.midX * menuBounds.width / CGFloat(menuImage.width),
            y: menuBounds.minY + save.midY * menuBounds.height / CGFloat(menuImage.height))
          break
      }
      usleep(100_000)
    }
    guard budget.isCurrent, let savePoint,
          windowBounds(windowID) == bounds,
          activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
          foreground(at: savePoint, allowOwnedOverlay: true) else {
      return .unavailable("video_message_save_action_unverified")
    }
    let accessibleSave = receptionNodes(pid: pid)?.filter { node in
      (node.role == kAXMenuItemRole as String || node.role == kAXButtonRole as String) &&
        CustomerSafety.mediaMenuLabel(node.title ?? node.value ?? "") == "另存为" &&
        node.actions.contains(kAXPressAction as String) && node.frame?.contains(savePoint) == true
    } ?? []
    let pressed = accessibleSave.count == 1
      ? AXUIElementPerformAction(accessibleSave[0].element, kAXPressAction as CFString) == .success
      : postClick(at: savePoint)
    guard pressed else { return .unavailable("video_message_save_action_failed") }
    for _ in 0..<6 {
      guard budget.isCurrent else { break }
      usleep(100_000)
      let panel = mediaSavePanelNodes(pid: pid)
      let names = panel.filter { $0.identifier == "saveAsNameTextField" }
      let cancels = panel.filter { $0.identifier == "CancelButton" && $0.actions.contains(kAXPressAction as String) }
      if names.count == 1 && cancels.count == 1 {
        self.pendingAttachmentCleanup = { [weak self] in
          self?.cancelOwnedAttachmentPanel(pid: pid, cancel: cancels[0].element) ?? false
        }
      }
      guard names.count == 1, cancels.count == 1 else { continue }
      let name = stringAttribute(names[0].element, kAXValueAttribute) ?? ""
      guard let filename = CustomerSafety.safeAttachmentFilename(name),
            self.setAttachmentExportDirectory(pid: pid, name: names[0].element,
                directory: exportDirectory, budget: budget),
            budget.isCurrent,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true else {
        return .unavailable("video_message_reference_invalid")
      }
      let finalPanel = mediaSavePanelNodes(pid: pid)
      let saveButtons = finalPanel.filter { node in
        node.role == kAXButtonRole as String && node.actions.contains(kAXPressAction as String) &&
          ["存储", "保存", "Save"].contains(node.title ?? "")
      }
      guard saveButtons.count == 1,
            stringAttribute(names[0].element, kAXValueAttribute) == name,
            AXUIElementPerformAction(saveButtons[0].element, kAXPressAction as CFString) == .success else {
        return .unavailable("attachment_export_save_unverified")
      }
      for _ in 0..<6 {
        if !budget.isCurrent || mediaSavePanelNodes(pid: pid).isEmpty { break }
        usleep(60_000)
      }
      guard budget.isCurrent, mediaSavePanelNodes(pid: pid).isEmpty,
            windowIsOwnedBy(windowID, pid: pid),
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true else {
        return .unavailable("video_message_reference_final_verification_failed")
      }
      self.pendingAttachmentCleanup = nil
      return .verified(filename)
    }
    return .unavailable("video_message_save_panel_unavailable")
  }

  private func cancelOwnedAttachmentPanel(pid: pid_t, cancel: AXUIElement) -> Bool {
    let budget = AccessibilityBudget(deadline: Date().addingTimeInterval(1.5))
    defer { budget.close() }
    for _ in 0..<3 {
      let nodes = mediaSavePanelNodes(pid: pid)
      if nodes.isEmpty && budget.isCurrent { return true }
      // Cancel a nested Go To sheet before its containing Save panel. All
      // candidates come from JD's owned panel hierarchy, not the global AX tree.
      let enabled = nodes.filter { node in
        (node.identifier == "CancelButton" || node.identifier == "CloseButton" ||
          ["取消", "Cancel"].contains(node.title ?? "")) &&
          node.role == kAXButtonRole as String && node.actions.contains(kAXPressAction as String) &&
          boolAttribute(node.element, kAXEnabledAttribute) == true
      }
      let deepest = enabled.sorted { $0.path.count > $1.path.count }
      let target = deepest.first?.element ?? cancel
      guard budget.isCurrent,
            AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { return false }
      usleep(100_000)
    }
    return budget.isCurrent && mediaSavePanelNodes(pid: pid).isEmpty
  }

  private func closeAttachmentMenu(expected: String, pid: pid_t, windowID: CGWindowID,
                                   menuBounds: CGRect, baseline: CGImage) -> Bool {
    let budget = AccessibilityBudget(deadline: Date().addingTimeInterval(1.5))
    defer { budget.close() }
    guard windowIsOwnedBy(windowID, pid: pid),
          activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true else { return false }
    // A delayed Save panel must be cancelled through its owned AX control.
    // Never capture the screen while the native Save panel is present.
    let panels = mediaSavePanelNodes(pid: pid)
    let cancels = panels.filter { $0.identifier == "CancelButton" && $0.actions.contains(kAXPressAction as String) }
    if !panels.isEmpty {
      return cancels.count == 1 && cancelOwnedAttachmentPanel(pid: pid, cancel: cancels[0].element)
    }
    guard budget.isCurrent,
          let image = CGWindowListCreateImage(menuBounds, .optionOnScreenOnly, kCGNullWindowID,
              [.boundsIgnoreFraming, .bestResolution]) else { return false }
    func sameAsBaseline(_ current: CGImage) -> Bool {
      CustomerSafety.mediaSnapshotMatches(source: baseline, current: current,
          region: CGRect(x: 0, y: 0, width: baseline.width, height: baseline.height), senderY: 0)
    }
    if sameAsBaseline(image) { return true } // No popup actually opened.
    let menu = CustomerSafety.attachmentSaveTarget(recognizeTransferText(in: image).map {
      CustomerSafety.AttachmentMenuLine(text: $0.text, confidence: $0.confidence, frame: $0.frame)
    })
    guard menu != nil, budget.isCurrent,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    // This Escape is PID-targeted and requires a newly verified complete menu.
    // It is not the former unconditional/global Escape that closed a chat.
    guard postKeyToPID(pid, key: 53, flags: []) else { return false }
    usleep(80_000)
    guard budget.isCurrent,
          activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
          let after = CGWindowListCreateImage(menuBounds, .optionOnScreenOnly, kCGNullWindowID,
              [.boundsIgnoreFraming, .bestResolution]) else { return false }
    return sameAsBaseline(after)
  }

  private func setAttachmentExportDirectory(pid: pid_t, name: AXUIElement,
      directory: URL, budget: AccessibilityBudget) -> Bool {
    let before = mediaSavePanelNodes(pid: pid)
    guard budget.isCurrent,
          AXUIElementSetAttributeValue(name, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
          attachmentPanelIsFrontmost(pid: pid, focused: name),
          postCommandShiftG() else { return false }
    for _ in 0..<8 {
      guard budget.isCurrent else { return false }
      usleep(60_000)
      let nodes = mediaSavePanelNodes(pid: pid)
      let newFields = nodes.filter { node in
        (node.role == kAXTextFieldRole as String || node.role == kAXComboBoxRole as String) &&
          node.identifier != "saveAsNameTextField" &&
          !before.contains(where: { CFEqual($0.element, node.element) })
      }
      let leaves = newFields.filter { field in
        !newFields.contains { $0.path.hasPrefix(field.path + "/") }
      }
      let go = nodes.filter { node in node.role == kAXButtonRole as String &&
        ["前往", "Go", "转到"].contains(node.title ?? "") && node.actions.contains(kAXPressAction as String) }
      guard leaves.count == 1 else { continue }
      let path = leaves[0]
      // Modern macOS has no Go button. Its advertised AXConfirm can return
      // success without navigating; Return works, but only in this exact,
      // owned Go To field with its verified path and actual keyboard focus.
      let modernPath = path.identifier == "PathTextField" &&
        nodes.contains { $0.identifier == "GoToWindow" && path.path.hasPrefix($0.path + "/") }
      guard modernPath || go.count == 1 else { continue }
      guard AXUIElementSetAttributeValue(path.element, kAXValueAttribute as CFString,
              directory.path as CFTypeRef) == .success,
            stringAttribute(path.element, kAXValueAttribute) == directory.path else { return false }
      if modernPath {
        guard budget.isCurrent,
              AXUIElementSetAttributeValue(path.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              stringAttribute(path.element, kAXValueAttribute) == directory.path,
              attachmentPanelIsFrontmost(pid: pid, focused: path.element),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else { return false }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
      } else if AXUIElementPerformAction(go[0].element, kAXPressAction as CFString) != .success {
        return false
      }
      for _ in 0..<8 {
        guard budget.isCurrent else { return false }
        usleep(60_000)
        let ready = mediaSavePanelNodes(pid: pid)
        // The destination's random operation-directory name is unique. Accept
        // only its selected-folder/path control, never the Go To text field.
        let selected = ready.contains { node in
          [kAXPopUpButtonRole as String, kAXMenuButtonRole as String, "AXPathControl"].contains(node.role) &&
            (node.title == directory.lastPathComponent || node.value == directory.lastPathComponent || node.value == directory.path ||
             node.value == directory.absoluteString)
        }
        if selected { return true }
      }
      return false
    }
    return false
  }

  private func attachmentPanelIsFrontmost(pid: pid_t, focused: AXUIElement) -> Bool {
    guard let frontmost = NSWorkspace.shared.frontmostApplication,
          let workbench = NSRunningApplication(processIdentifier: pid) else { return false }
    if frontmost.processIdentifier != pid {
      guard frontmost.bundleIdentifier == "com.jd.jingmaiMac",
            let parent = frontmost.bundleURL?.standardizedFileURL.path,
            workbench.bundleURL?.standardizedFileURL.path.hasPrefix(parent + "/Contents/") == true else { return false }
    }
    // A verified modal text field must actually own keyboard focus immediately
    // before Cmd-Shift-G. No shortcut is posted into an unverified chat/app.
    guard boolAttribute(focused, kAXFocusedAttribute) == true else { return false }
    // AXFocusedUIElement is an application attribute; some macOS versions
    // expose no such value on the system-wide element. Verify the field's
    // focused state plus its owned Save-panel ancestry instead.
    var target: AXUIElement? = focused
    for _ in 0..<8 {
      guard let node = target else { break }
      if stringAttribute(node, kAXIdentifierAttribute) == "save-panel" { return true }
      target = elementAttribute(node, kAXParentAttribute)
    }
    return false
  }

  /// UI-only preparation. Return as soon as the exact-message export is
  /// started and all menus/panels are closed. No file waiting on this queue.
  func beginAttachmentDownload(_ args: [String: Any], completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      let deadline = (args["operationDeadlineMs"] as? NSNumber).map {
        Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
      let budget = AccessibilityBudget(deadline: min(deadline, Date().addingTimeInterval(8)))
      let expected = args["expectedCustomer"] as? String ?? ""
      let windowID = CGWindowID((args["windowId"] as? NSNumber)?.uint32Value ?? 0)
      let directory = URL(fileURLWithPath: args["destinationDirectory"] as? String ?? "", isDirectory: true).standardizedFileURL
      var uiAttempted = false
      let payload: [String: Any] = {
        guard budget.isCurrent, AXIsProcessTrusted(), !expected.isEmpty,
              let pid = self.runningPID(), windowIsOwnedBy(windowID, pid: pid),
              self.activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
              let sentAt = args["expectedMediaAtMs"] as? NSNumber,
              let eventKey = args["eventKey"] as? String, !eventKey.isEmpty,
              directory.lastPathComponent.hasPrefix("attachment_"),
              directory.deletingLastPathComponent().lastPathComponent == "attachment_exports",
              directory.resolvingSymlinksInPath() == directory,
              (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true,
              self.pendingAttachmentCleanup == nil,
              let encoded = args["sourcePngBase64"] as? String,
              let png = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let current = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                  [.boundsIgnoreFraming, .bestResolution]) else {
          return ["error": "attachment_precondition_failed", "uiAttempted": false]
        }
        let x = (args["x"] as? NSNumber)?.doubleValue ?? -1
        let y = (args["y"] as? NSNumber)?.doubleValue ?? -1
        let width = (args["width"] as? NSNumber)?.doubleValue ?? -1
        let height = (args["height"] as? NSNumber)?.doubleValue ?? -1
        let senderY = (args["sourceSenderY"] as? NSNumber)?.doubleValue
        guard x >= 0, y >= 0, width > 0, height > 0, x + width <= 1, y + height <= 1 else {
          return ["error": "attachment_region_invalid", "uiAttempted": false]
        }
        let region = CGRect(x: x * Double(original.width), y: y * Double(original.height),
            width: width * Double(original.width), height: height * Double(original.height)).integral
        guard CustomerSafety.mediaSnapshotMatches(source: original, current: current, region: region, senderY: senderY) else {
          return ["error": "media_snapshot_changed", "uiAttempted": false]
        }
        let reference = self.videoReferenceFromMessage(expected: expected, windowID: windowID,
            region: region, originalImage: original, sourceSenderY: senderY,
            exportDirectory: directory, expiresAt: ProcessInfo.processInfo.systemUptime + max(0, deadline.timeIntervalSinceNow))
        switch reference {
        case let .unavailable(reason):
          uiAttempted = self.pendingAttachmentCleanup != nil
          return ["error": reason, "uiAttempted": uiAttempted]
        case let .verified(filename):
          uiAttempted = true
          let token = UUID().uuidString
          let receipt: [String: Any] = ["token": token, "customer": expected,
            "event_key": eventKey, "expectedMediaAtMs": sentAt,
            "original_name": filename, "directory": directory.path,
            "startedAtMs": Int(Date().timeIntervalSince1970 * 1000)]
          do {
            try JSONSerialization.data(withJSONObject: receipt).write(
              to: directory.appendingPathComponent(".jd-attachment-export.json"), options: .atomic)
          } catch { return ["error": "attachment_receipt_write_failed", "uiAttempted": true] }
          return ["state": "started", "token": token, "directory": directory.path,
            "originalName": filename, "verifiedCustomerId": expected,
            "expectedMediaAtMs": sentAt, "ownershipVerification": "exact_customer_attachment_reference"]
        }
      }()
      budget.close()
      var response = payload
      if let cleanup = self.pendingAttachmentCleanup {
        if cleanup() { self.pendingAttachmentCleanup = nil }
        else { response = ["error": "attachment_ui_cleanup_failed", "uiAttempted": true] }
      }
      response["uiAttempted"] = uiAttempted
      DispatchQueue.main.async { completion(response) }
    }
  }

  /// File-only completion, scoped by a durable exact-message export receipt.
  func pollAttachmentDownload(_ args: [String: Any], completion: @escaping FlutterResult) {
    attachmentFileQueue.async {
      func finish(_ value: [String: Any]) { DispatchQueue.main.async { completion(value) } }
      let folder = URL(fileURLWithPath: args["directory"] as? String ?? "", isDirectory: true).standardizedFileURL
      guard folder.lastPathComponent.hasPrefix("attachment_"),
            folder.deletingLastPathComponent().lastPathComponent == "attachment_exports",
            folder.resolvingSymlinksInPath() == folder,
            let receiptData = try? Data(contentsOf: folder.appendingPathComponent(".jd-attachment-export.json")),
            let receipt = (try? JSONSerialization.jsonObject(with: receiptData)) as? [String: Any],
            let token = args["token"] as? String, token == receipt["token"] as? String,
            let customer = args["customer"] as? String, customer == receipt["customer"] as? String,
            args["event_key"] as? String == receipt["event_key"] as? String,
            let sent = args["sent_at"] as? String,
            let date = ISO8601DateFormatter.fractional.date(from: sent),
            Int(date.timeIntervalSince1970 * 1000) == (receipt["expectedMediaAtMs"] as? NSNumber)?.intValue,
            receipt["directory"] as? String == folder.path,
            let original = receipt["original_name"] as? String,
            CustomerSafety.safeAttachmentFilename(original) != nil else {
        finish(["error": "attachment_receipt_unverified"]); return
      }
      let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
      let files = ((try? FileManager.default.contentsOfDirectory(at: folder,
        includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []).filter {
          CustomerSafety.attachmentFilenameMatches($0.lastPathComponent, expected: original)
        }
      guard files.count == 1, let file = files.first,
            file.resolvingSymlinksInPath().deletingLastPathComponent() == folder,
            let before = try? file.resourceValues(forKeys: keys),
            before.isRegularFile == true, before.isSymbolicLink != true,
            let size = before.fileSize, size > 0, size <= 100 * 1024 * 1024,
            let modified = before.contentModificationDate,
            Date().timeIntervalSince(modified) >= 0.4,
            let data = try? Data(contentsOf: file), data.count == size,
            let after = try? file.resourceValues(forKeys: keys),
            after.fileSize == size, after.contentModificationDate == modified,
            let kind = CustomerSafety.attachmentContainerKind(data) else {
        finish(["state": "pending"]); return
      }
      var result: [String: Any] = ["state": "ready", "token": token,
        "verifiedCustomerId": customer, "expectedMediaAtMs": receipt["expectedMediaAtMs"]!,
        "ownershipVerification": "exact_customer_attachment_reference",
        "captureSource": "jd-attachment-export", "originalName": original]
      if kind == "image" {
        guard size <= 25 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else {
          finish(["state": "pending"]); return
        }
        let ext = type.contains("jpeg") ? "jpg" : type.contains("gif") ? "gif" :
          type.contains("webp") ? "webp" : type.contains("heic") ? "heic" : "png"
        result["kind"] = "image"; result["extension"] = ext
        result["mimeType"] = ext == "jpg" ? "image/jpeg" : "image/\(ext)"
        result["originalName"] = (original as NSString).deletingPathExtension + "." + ext
        result["dataBase64"] = data.base64EncodedString()
      } else {
        let asset = AVURLAsset(url: file)
        let ready = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { ready.signal() }
        guard ready.wait(timeout: .now() + 1) == .success else {
          asset.cancelLoading(); finish(["state": "pending"]); return
        }
        var error: NSError?
        guard asset.statusOfValue(forKey: "tracks", error: &error) == .loaded,
              !asset.tracks(withMediaType: .video).isEmpty else {
          finish(["state": "pending"]); return
        }
        result["kind"] = "video"; result["path"] = file.path
        result["mimeType"] = file.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
      }
      finish(result)
    }
  }

  /// Copy a visually matched cached original without any JD menu interaction.
  func downloadVideoAt(expectedCustomer: String, windowID: CGWindowID,
                       normalizedX: Double, normalizedY: Double,
                       normalizedWidth: Double, normalizedHeight: Double,
                       expectedMediaAt: Date? = nil,
                       destinationDirectory: String,
                       cacheReferenceToken: String? = nil,
                       sourcePNG: Data? = nil, sourceSenderY: Double? = nil,
                       completion: @escaping FlutterResult) {
    videoCacheQueue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      let destination = URL(fileURLWithPath: destinationDirectory, isDirectory: true)
        .standardizedFileURL
      guard AXIsProcessTrusted(), !expected.isEmpty,
            normalizedX >= 0, normalizedY >= 0,
            normalizedWidth > 0, normalizedHeight > 0,
            normalizedX + normalizedWidth <= 1,
            normalizedY + normalizedHeight <= 1,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            let ownerPID = runningPID(), windowIsOwnedBy(windowID, pid: ownerPID), windowBounds(windowID) != nil,
            FileManager.default.fileExists(atPath: destination.path) else {
        finish(["error": "video_download_precondition_failed",
                "message": "Keep the verified customer video visible while its local cache is inspected."])
        return
      }
      guard let fullImage = CGWindowListCreateImage(
          .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]),
          let visibleImage = fullImage.cropping(to: CGRect(
            x: CGFloat(normalizedX) * CGFloat(fullImage.width),
            y: CGFloat(normalizedY) * CGFloat(fullImage.height),
            width: CGFloat(normalizedWidth) * CGFloat(fullImage.width),
            height: CGFloat(normalizedHeight) * CGFloat(fullImage.height)).integral) else {
        finish(["error": "video_preview_capture_failed"])
        return
      }
      let sourceRegion = CGRect(
        x: CGFloat(normalizedX) * CGFloat(fullImage.width),
        y: CGFloat(normalizedY) * CGFloat(fullImage.height),
        width: CGFloat(normalizedWidth) * CGFloat(fullImage.width),
        height: CGFloat(normalizedHeight) * CGFloat(fullImage.height)).integral
      guard let sourcePNG, let source = NSImage(data: sourcePNG)?.cgImage(
              forProposedRect: nil, context: nil, hints: nil),
            CustomerSafety.mediaSnapshotMatches(source: source, current: fullImage,
              region: sourceRegion, senderY: sourceSenderY) else {
        finish(["error": "media_snapshot_changed",
                "message": "The video no longer occupies the sender-bounded OCR region; refresh OCR before cache matching or UI actions."])
        return
      }
      func copyCachedVideo(_ cached: DownloadedVideoCandidate) {
        guard activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
              windowIsOwnedBy(windowID, pid: ownerPID) else {
          finish(["error": "video_copy_customer_changed"])
          return
        }
        guard let bytes = try? Data(contentsOf: cached.url), bytes.count == cached.size,
              let sourceValues = try? cached.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              sourceValues.fileSize == cached.size,
              sourceValues.contentModificationDate == cached.modified else {
          finish(["error": "video_cache_changed_during_check"])
          return
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = destination.appendingPathComponent("\(digest).\(cached.url.pathExtension.lowercased())")
        var created = false
        do {
          if FileManager.default.fileExists(atPath: file.path) {
            guard file.resolvingSymlinksInPath().deletingLastPathComponent() == destination.resolvingSymlinksInPath(),
                  let existing = try? Data(contentsOf: file), existing == bytes else {
              finish(["error": "video_copy_owner_mismatch"])
              return
            }
          } else {
            try bytes.write(to: file, options: .atomic)
            created = true
          }
        } catch {
          finish(["error": "video_copy_failed",
                  "message": "JD's cached video could not be copied into private storage."])
          return
        }
        guard activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
              let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size == cached.size else {
          if created { try? FileManager.default.removeItem(at: file) }
          finish(["error": "video_copy_verification_failed",
                  "message": "The cached video changed during copying; the partial copy was removed."])
          return
        }
        let ext = file.pathExtension.lowercased()
        let mime = ext == "mov" || ext == "m4v" ? "video/quicktime" :
          (ext == "webm" ? "video/webm" : "video/mp4")
        finish([
          "kind": "video",
          "verifiedCustomerId": expected,
          "ownershipVerification": "visible_customer_region",
          "path": file.path,
          "originalName": file.lastPathComponent,
          "mimeType": mime,
          "size": size,
          "captureSource": "jd-video-cache",
          "cacheMatchBasis": cached.matchBasis,
        ])
      }
      var authorized: DownloadedVideoCandidate?
      if let token = cacheReferenceToken {
        // Access to native capabilities is serialized with the AX queue.
        self.queue.sync {
          if let reference = self.verifiedVideoReferences.removeValue(forKey: token),
             reference.expires > ProcessInfo.processInfo.systemUptime,
             reference.customer == expected, reference.window == windowID,
             reference.region == sourceRegion,
             reference.snapshotDigest == SHA256.hash(data: sourcePNG).map({ String(format: "%02x", $0) }).joined() {
            authorized = reference.candidate
          }
        }
      }
      if let authorized { copyCachedVideo(authorized); return }
      switch matchingJDCachedVideo(visibleImage: visibleImage, expectedAt: expectedMediaAt, timeout: 3) {
      case let .matched(candidate):
        copyCachedVideo(candidate)
      case let .unresolved(reason): finish(["error": reason])
      case .notFound:
        finish(["error": "video_download_not_found",
                "message": "No unambiguous matching cache video is available; JD was left untouched."])
      }
    }
  }

  /// Uses copy only to classify the selected Qianniu item. No clipboard
  /// content is returned and the user's previous clipboard is restored.
  func classifyMessageAt(expectedCustomer: String, windowID: CGWindowID,
                         normalizedX: Double, normalizedY: Double,
                         completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard AXIsProcessTrusted(), !expected.isEmpty,
            normalizedX >= 0, normalizedX <= 1,
            normalizedY >= 0, normalizedY <= 1,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            let pid = runningPID(),
            let jdApp = NSRunningApplication(processIdentifier: pid) else {
        finish(["kind": "unavailable", "reason": "jingmai_unavailable"])
        return
      }
      let previouslyFrontmost = NSWorkspace.shared.frontmostApplication
      let activatedForImageCheck = previouslyFrontmost?.processIdentifier != pid
      if activatedForImageCheck {
        _ = jdApp.activate(options: [.activateIgnoringOtherApps])
        usleep(300_000)
      }
      defer {
        if activatedForImageCheck,
           let previous = previouslyFrontmost,
           !previous.isTerminated {
          _ = previous.activate(options: [.activateIgnoringOtherApps])
        }
      }
      guard let raw = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
              as? [[String: Any]],
            let info = raw.first,
            let dictionary = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else {
        finish(["kind": "unavailable", "reason": "window_missing"])
        return
      }
      let pasteboard = NSPasteboard.general
      let snapshot = PasteboardSnapshot(pasteboard)
      defer { snapshot.restore(to: pasteboard) }
      pasteboard.clearContents()
      let point = CGPoint(x: bounds.minX + bounds.width * normalizedX,
                          y: bounds.minY + bounds.height * normalizedY)
      guard postClick(at: point), postCommandC() else {
        finish(["kind": "unavailable", "reason": "copy_failed"])
        return
      }
      usleep(300_000)
      let types = pasteboard.types ?? []
      let imageTypes: Set<NSPasteboard.PasteboardType> = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), .fileURL,
      ]
      let kind: String
      var visualFingerprint = ""
      var copiedPNG: Data?
      if types.contains(where: { imageTypes.contains($0) }) {
        kind = "image"
        let imageData = pasteboard.data(forType: .png) ??
          pasteboard.data(forType: .tiff) ??
          pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg"))
        if let imageData, let image = NSImage(data: imageData),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
          visualFingerprint = averageImageHash(cgImage)
          copiedPNG = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .png, properties: [:])
        } else if let fileURL = pasteboard.string(forType: .fileURL),
                  let url = URL(string: fileURL),
                  let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
          visualFingerprint = averageImageHash(cgImage)
          copiedPNG = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .png, properties: [:])
        }
      } else if pasteboard.string(forType: .string) != nil {
        kind = "text"
      } else {
        kind = "unknown"
      }
      var payload: [String: Any] = [
        "kind": kind,
        "types": types.map(\.rawValue),
        "visualFingerprint": visualFingerprint,
      ]
      if let copiedPNG {
        payload["mimeType"] = "image/png"
        payload["extension"] = "png"
        payload["dataBase64"] = copiedPNG.base64EncodedString()
      }
      finish(payload)
    }
  }

  /// Opens a verified buyer image in JD's 图片浏览器 and downloads the original.
  /// Only a newly created image in Downloads is returned; the viewer is closed
  /// before the result crosses the Flutter boundary.
  func downloadImageAt(expectedCustomer: String, windowID: CGWindowID,
                       normalizedX: Double, normalizedY: Double,
                       completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard AXIsProcessTrusted(), !expected.isEmpty,
            normalizedX >= 0, normalizedX <= 1,
            normalizedY >= 0, normalizedY <= 1,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            let pid = runningPID(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            let sourceBounds = windowBounds(windowID) else {
        finish(["error": "image_download_precondition_failed",
                "message": "The active customer, JD focus, or source window could not be verified."])
        return
      }
      let downloads = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)
      let before = downloadableImages(in: downloads)
      let sourcePoint = CGPoint(
        x: sourceBounds.minX + sourceBounds.width * normalizedX,
        y: sourceBounds.minY + sourceBounds.height * normalizedY)
      guard postDoubleClick(at: sourcePoint) else {
        finish(["error": "image_viewer_open_failed",
                "message": "Could not open the verified JD image bubble."])
        return
      }
      var viewer: CGRect?
      for _ in 0..<16 {
        usleep(125_000)
        viewer = namedWindowBounds(pid: pid, containing: "图片浏览器")
        if viewer != nil { break }
      }
      guard let viewerBounds = viewer else {
        finish(["error": "image_viewer_missing",
                "message": "JD did not expose its 图片浏览器 window."])
        return
      }
      var viewerClosed = false
      defer {
        if !viewerClosed {
          _ = closeJDImageViewer(pid: pid, bounds: viewerBounds)
        }
      }
      // In JD 9.95 the download control is the rightmost item in the centered
      // bottom toolbar. Keep this coordinate scoped to the verified viewer.
      let downloadPoint = CGPoint(
        x: viewerBounds.minX + viewerBounds.width * 0.590,
        y: viewerBounds.minY + viewerBounds.height * 0.944)
      guard postClick(at: downloadPoint) else {
        finish(["error": "image_download_click_failed",
                "message": "Could not press the JD image download control."])
        return
      }
      var downloaded: URL?
      // Keep JD's modal viewer open for no more than one second after the
      // download click. The Flutter layer falls back to a screenshot if the
      // original file does not become available within this bounded window.
      for _ in 0..<8 {
        usleep(125_000)
        let after = downloadableImages(in: downloads)
        downloaded = after.values
          .filter { candidate in
            guard let old = before[candidate.url.path] else { return true }
            return candidate.modified > old.modified || candidate.size != old.size
          }
          .sorted { $0.modified > $1.modified }
          .first?.url
        if downloaded != nil { break }
      }
      viewerClosed = closeJDImageViewer(pid: pid, bounds: viewerBounds)
      guard viewerClosed else {
        finish(["error": "image_viewer_close_failed",
                "message": "The JD image was captured, but 图片浏览器 could not be closed safely."])
        return
      }
      guard let file = downloaded,
            let data = try? Data(contentsOf: file),
            !data.isEmpty, data.count <= 25 * 1024 * 1024 else {
        finish(["error": "image_download_not_found",
                "message": "No new JD image appeared in Downloads."])
        return
      }
      let ext = file.pathExtension.lowercased()
      let mime = ext == "png" ? "image/png" :
        (ext == "webp" ? "image/webp" : "image/jpeg")
      let visualFingerprint: String
      if let image = NSImage(data: data),
         let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        visualFingerprint = averageImageHash(cgImage)
      } else {
        visualFingerprint = SHA256.hash(data: data).description
      }
      finish([
        "kind": "image",
        "mimeType": mime,
        "extension": ext.isEmpty ? "jpg" : ext,
        "originalName": file.lastPathComponent,
        "dataBase64": data.base64EncodedString(),
        "visualFingerprint": visualFingerprint,
        "captureSource": "jd-image-viewer-download",
      ])
    }
  }

  func start() {
    guard timer == nil else { return }
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now(), repeating: .milliseconds(700), leeway: .milliseconds(150))
    source.setEventHandler { [weak self] in self?.poll() }
    timer = source
    source.resume()
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  /// Performs one explicitly requested send. The expected conversation is
  /// opened and verified before insertion, then verified again before the
  /// physical Send control is clicked. No caller can omit the expected ID.
  func sendDraftOnce(expectedCustomer: String, reply: String,
                     mediaPaths: [String] = [],
                     deadline: Date,
                     completion: @escaping FlutterResult) {
    let expiresAt = ProcessInfo.processInfo.systemUptime + min(12, max(0, deadline.timeIntervalSinceNow))
    queue.async { [weak self] in
      guard let self else { return }
      let budget = AccessibilityBudget(deadline: deadline, uptimeDeadline: expiresAt)
      defer { budget.close() }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
      guard budget.isCurrent, CustomerSafety.operationCurrent(deadline) else {
        finish(["error": "operation_expired", "message": "Queued send expired before native execution; nothing was inserted or sent."])
        return
      }
      guard !expected.isEmpty, !text.isEmpty else {
        finish(["error": "invalid_send_request", "message": "Expected customer and reply are required."])
        return
      }
      guard AXIsProcessTrusted(), let pid = runningPID() else {
        finish(["error": "jd_unavailable", "message": "JD 咚咚 or Accessibility access is unavailable."])
        return
      }
      guard mediaPaths.isEmpty else {
        finish(["error": "outbound_media_disabled",
                "message": "JD automation is text-only; photos, videos, and files are disabled."])
        return
      }
      let allowedExtensions = Set(["png", "jpg", "jpeg", "webp", "gif", "mp4", "mov"])
      let requestedMedia = Array(mediaPaths.prefix(3)).map {
        URL(fileURLWithPath: $0).standardizedFileURL
      }
      guard requestedMedia.count == mediaPaths.count,
            requestedMedia.allSatisfy({
              FileManager.default.fileExists(atPath: $0.path) &&
                allowedExtensions.contains($0.pathExtension.lowercased())
            }) else {
        finish(["error": "invalid_media_attachment",
                "message": "One or more approved media files are missing, unsupported, or exceed the three-file limit."])
        return
      }

      func scopedNodes() -> [AXNode]? {
        receptionNodes(pid: pid)
      }

      guard let opened = scopedNodes(), activeCustomerMatches(expected, nodes: opened),
            self.clearOwnedComposer(in: opened) else {
        finish(["error": "expected_conversation_missing",
                "message": "The exact active JD customer \(expected) was not verified; nothing was inserted or sent."])
        return
      }

      guard CustomerSafety.operationCurrent(deadline) else {
        finish(["error": "operation_expired", "message": "Send verification exceeded its deadline; nothing was inserted or sent."])
        return
      }

      guard let composer = opened.first(where: { $0.role == kAXTextAreaRole as String }) else {
        finish(["error": "pre_insert_verification_failed",
                "message": "Could not verify \(expected) and its composer after opening the chat."])
        return
      }
      guard let composerValue = stringAttribute(composer.element, kAXValueAttribute),
            budget.isCurrent else {
        finish(["error": "composer_read_failed", "message": "The verified customer's composer could not be read; no text was inserted."])
        return
      }
      let existing = composerValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard existing.isEmpty else {
        finish(["error": "composer_not_empty",
                "message": "JD's composer already contains text. It was left unchanged."])
        return
      }
      if requestedMedia.isEmpty {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(composer.element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue,
              budget.isCurrent,
              AXUIElementSetAttributeValue(composer.element, kAXValueAttribute as CFString, text as CFTypeRef) == .success else {
          finish(["error": "composer_not_settable",
                  "message": "JingMai did not allow safe AX insertion; nothing was sent."])
          return
        }
        self.ownedComposers[expected] = OwnedComposer(element: composer.element, text: text)
      } else {
        // Qianniu's rich composer does not expose image insertion through AX.
        // Paste only caller-verified local files, then append the reply text.
        // Preserve the user's clipboard and verify the expected conversation
        // throughout the operation.
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        usleep(180_000)
        _ = AXUIElementSetAttributeValue(composer.element, kAXFocusedAttribute as CFString,
                                         kCFBooleanTrue)
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        defer { snapshot.restore(to: pasteboard) }
        let beforePaste = composerVisualFingerprint(pid: pid, frame: composer.frame)
        for mediaURL in requestedMedia {
          pasteboard.clearContents()
          let inserted: Bool
          if ["png", "jpg", "jpeg", "webp", "gif"].contains(mediaURL.pathExtension.lowercased()),
             let image = NSImage(contentsOf: mediaURL) {
            inserted = pasteboard.writeObjects([image])
          } else {
            inserted = pasteboard.writeObjects([mediaURL as NSURL])
          }
          guard inserted, postCommandV() else {
            finish(["error": "media_paste_failed",
                    "message": "JingMai did not accept an approved media attachment; nothing was sent."])
            return
          }
          usleep(550_000)
          guard let current = scopedNodes(), activeCustomerMatches(expected, nodes: current) else {
            finish(["error": "media_customer_verification_failed",
                    "message": "The active customer changed while inserting media; nothing was sent."])
            return
          }
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), postCommandV() else {
          finish(["error": "reply_paste_failed",
                  "message": "The reply text could not be appended after media; nothing was sent."])
          return
        }
        usleep(350_000)
        let afterPaste = composerVisualFingerprint(pid: pid, frame: composer.frame)
        guard beforePaste != nil, afterPaste != nil, beforePaste != afterPaste else {
          finish(["error": "media_insert_unverified",
                  "message": "JingMai did not visibly confirm the media insertion; nothing was sent."])
          return
        }
      }

      guard let verified = scopedNodes(), activeCustomerMatches(expected, nodes: verified),
            let verifiedComposer = verified.first(where: { $0.role == kAXTextAreaRole as String }),
            (requestedMedia.isEmpty
              ? stringAttribute(verifiedComposer.element, kAXValueAttribute) == text
              : true),
            let send = verified.first(where: {
              ($0.role == kAXButtonRole as String || $0.role == kAXMenuButtonRole as String) &&
                $0.title == "发送"
            }), send.frame != nil else {
        // A stale AX composer can refer to a newly selected customer's input.
        // Only clear our exact text while the exact owner is still verified.
        if let current = scopedNodes(), activeCustomerMatches(expected, nodes: current),
           let currentComposer = current.first(where: { $0.role == kAXTextAreaRole as String }),
           stringAttribute(currentComposer.element, kAXValueAttribute) == text {
          if AXUIElementSetAttributeValue(currentComposer.element, kAXValueAttribute as CFString, "" as CFTypeRef) == .success {
            self.ownedComposers.removeValue(forKey: expected)
          }
        }
        finish(["error": "pre_send_verification_failed",
                "message": "Customer, inserted text, or Send control verification failed. Only verified text owned by this customer may be cleared."])
        return
      }

      // A coordinate click is used only after bringing Qianniu frontmost and
      // re-verifying the exact customer and composer state.
      _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
      usleep(150_000)
      guard let finalNodes = scopedNodes(), activeCustomerMatches(expected, nodes: finalNodes),
            let finalComposer = finalNodes.first(where: { $0.role == kAXTextAreaRole as String }),
            stringAttribute(finalComposer.element, kAXValueAttribute) == text,
            let finalSend = finalNodes.first(where: {
              ($0.role == kAXButtonRole as String || $0.role == kAXMenuButtonRole as String) &&
                $0.title == "发送"
            }), let finalFrame = finalSend.frame,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            budget.isCurrent else {
        finish(["error": "final_customer_verification_failed",
                "message": "The expected customer was no longer active; nothing was sent."])
        return
      }
      guard CustomerSafety.operationCurrent(deadline) else {
        if let currentComposer = finalNodes.first(where: { $0.role == kAXTextAreaRole as String }),
           stringAttribute(currentComposer.element, kAXValueAttribute) == text {
          if AXUIElementSetAttributeValue(currentComposer.element, kAXValueAttribute as CFString, "" as CFTypeRef) == .success {
            self.ownedComposers.removeValue(forKey: expected)
          }
        }
        finish(["error": "operation_expired", "message": "Send deadline expired before clicking Send; the verified unsent text was cleared."])
        return
      }
      let point = CGPoint(x: finalFrame.midX, y: finalFrame.midY)
      guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                               mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                             mouseCursorPosition: point, mouseButton: .left) else {
        finish(["error": "send_click_failed", "message": "Could not create the Send click event."])
        return
      }
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)

      // JingMai can take longer than one UI frame to commit a send. Poll for
      // up to three seconds instead of turning a slow composer clear into a
      // permanently frozen delivery. If the exact inserted reply is still in
      // the verified customer's composer after that window, the click did not
      // commit: clear only that known text and let Dart return the draft to its
      // serial retry queue. A customer change or unexpected composer value is
      // reported as ambiguous so Dart can reconcile any observed receipt
      // before the serial retry fires.
      let confirmationDeadline = Date().addingTimeInterval(3.0)
      var lastComposer: AXNode?
      var lastComposerText: String?
      repeat {
        usleep(250_000)
        guard budget.isCurrent else {
          finish(["error": "send_unconfirmed", "message": "Native confirmation exceeded its deadline after clicking Send; the reply remains pending for reconciliation."])
          return
        }
        guard let after = scopedNodes(), activeCustomerMatches(expected, nodes: after),
              let afterComposer = after.first(where: { $0.role == kAXTextAreaRole as String }) else {
          finish(["error": "send_unconfirmed",
                  "message": "Send was clicked, but the expected JingMai conversation could not be verified. The queued draft will retry unless delivery is reconciled first."])
          return
        }
        let composerText = (stringAttribute(afterComposer.element, kAXValueAttribute) ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if composerText.isEmpty {
          self.ownedComposers.removeValue(forKey: expected)
          finish(["sent": true, "customer": expected, "reply": text,
                  "mediaCount": requestedMedia.count])
          return
        }
        lastComposer = afterComposer
        lastComposerText = composerText
      } while Date() < confirmationDeadline

      if requestedMedia.isEmpty, lastComposerText == text,
         let lastComposer = lastComposer {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(lastComposer.element,
                                          kAXValueAttribute as CFString,
                                          &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(lastComposer.element,
                                        kAXValueAttribute as CFString,
                                        "" as CFTypeRef) == .success {
          self.ownedComposers.removeValue(forKey: expected)
          finish(["error": "send_not_committed",
                  "message": "JingMai kept the exact reply in the composer after Send. The unsent text was cleared and the queued draft will retry."])
          return
        }
      }
      finish(["error": "send_unconfirmed",
              "message": "Send was clicked, but JingMai's resulting state was ambiguous. The queued draft will retry unless delivery is reconciled first."])
    }
  }

  /// Called only after the background OCR pass found an existing red icon.
  /// Normal sends retain their original serial queue and verification routine.
  func retryFailedOutgoingMessage(expectedCustomer: String,
      candidate: [String: Any], completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) { DispatchQueue.main.async { completion(payload) } }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !expected.isEmpty, AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
            let pid = self.runningPID(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            let x = candidate["x"] as? Double, let y = candidate["y"] as? Double,
            let left = candidate["left"] as? Double, let top = candidate["top"] as? Double,
            let width = candidate["width"] as? Double, let height = candidate["height"] as? Double,
            [x, y, left, top, width, height].allSatisfy({ $0.isFinite }),
            width > 0, height > 0,
            let fingerprint = candidate["fingerprint"] as? String, !fingerprint.isEmpty,
            let windowID = candidate["windowId"] as? NSNumber else {
        finish(["retried": false]); return
      }
      let point = CGPoint(x: x, y: y)
      let frame = CGRect(x: left, y: top, width: width, height: height)
      let key = sha256(expected + "\u{1f}" + fingerprint)
      let previous = self.failedSendRetries[key]
      if let previous, previous.next > Date() { finish(["retried": false]); return }
      func snapshot() -> [AXNode]? {
        var nodes: [AXNode] = []
        self.walk(AXUIElementCreateApplication(pid), path: "app", depth: 0,
            maxDepth: 22, maxNodes: 5_000) { node, _ in nodes.append(node) }
        guard let window = nodes.first(where: {
          $0.role == kAXWindowRole as String && $0.title?.contains("咚咚融合工作台") == true
        }) else { return nil }
        return nodes.filter { $0.path == window.path || $0.path.hasPrefix(window.path + "/") }
      }
      func safeToClick(_ nodes: [AXNode]) -> Bool {
        guard self.activeCustomerMatches(expected, nodes: nodes),
              !nodes.contains(where: { $0.role == kAXSheetRole as String ||
                $0.subrole == "AXDialog" || $0.subrole == "AXSystemDialog" }),
              let composer = nodes.first(where: { $0.role == kAXTextAreaRole as String }),
              let composerFrame = composer.frame,
              (stringAttribute(composer.element, kAXValueAttribute) ?? "").isEmpty,
              let split = nodes.filter({ $0.role == kAXSplitGroupRole as String &&
                composer.path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }),
              let chat = split.frame else { return false }
        return chat.contains(point) && chat.contains(frame) && frame.maxY < composerFrame.minY
      }
      guard let nodes = snapshot(), safeToClick(nodes),
            let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
              as? [[String: Any]],
            let row = rows.first(where: {
              ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID.uint32Value &&
              ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            }),
            let raw = row[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
            bounds.contains(frame),
            let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                CGWindowID(windowID.uint32Value), [.boundsIgnoreFraming, .bestResolution]) else {
        finish(["retried": false]); return
      }
      // Revalidate only the candidate's small region, not the entire chat.
      let region = frame.union(CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48))
        .insetBy(dx: -8, dy: -8).intersection(bounds)
      guard failedSendBubbles(image: image, windowBounds: bounds, chatFrame: region).contains(where: {
        $0.fingerprint == fingerprint &&
        abs($0.point.x - point.x) < 2 && abs($0.point.y - point.y) < 2
      }), let finalNodes = snapshot(), safeToClick(finalNodes),
         NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        finish(["retried": false]); return
      }
      let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]] ?? []
      let owner = visible.first { row in
        guard let raw = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
        return bounds.contains(point)
      }?[kCGWindowOwnerPID as String] as? NSNumber
      guard owner?.int32Value == pid, postClick(at: point) else {
        finish(["retried": false]); return
      }
      let attempts = previous?.attempts ?? 0
      self.failedSendRetries[key] = (attempts + 1,
          Date().addingTimeInterval(failedSendRetryDelay(attempts: attempts)))
      // Icon disappearance is not proof of delivery. The regular OCR capture
      // reconciles a matching bubble only after JD exposes its receipt.
      finish(["retried": true, "customer": expected])
    }
  }

  /// Hashes the visible composer before and after paste. This does not inspect
  /// customer media content; it only proves that Qianniu visibly changed the
  /// verified composer before the single Send action is allowed.
  private func composerVisualFingerprint(pid: pid_t, frame: CGRect?) -> String? {
    guard let frame, CGPreflightScreenCaptureAccess(),
          let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    for row in rows where (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
      guard let number = row[kCGWindowNumber as String] as? NSNumber,
            let dictionary = row[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
            bounds.intersects(frame),
            let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                CGWindowID(number.uint32Value),
                                                [.boundsIgnoreFraming, .bestResolution]) else { continue }
      let scaleX = CGFloat(image.width) / max(bounds.width, 1)
      let scaleY = CGFloat(image.height) / max(bounds.height, 1)
      let local = CGRect(x: (frame.minX - bounds.minX) * scaleX,
                         y: (frame.minY - bounds.minY) * scaleY,
                         width: frame.width * scaleX,
                         height: frame.height * scaleY).integral
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard local.width >= 20, local.height >= 20,
            let crop = image.cropping(to: local),
            let data = NSBitmapImageRep(cgImage: crop)
              .representation(using: .png, properties: [:]) else { continue }
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return nil
  }

  private func activeCustomerMatches(_ expected: String, nodes: [AXNode]) -> Bool {
    guard let actual = activeCustomerIdentity(in: nodes) else { return false }
    return CustomerSafety.matches(actual, expected)
  }


  /// Reads the signed-in service account from the reception window's account
  /// header. This label is exposed by AX even though transfer rows are not.
  private func currentServiceAccount(in reception: AXNode,
                                     nodes: [AXNode],
                                     excluding customer: String) -> String {
    guard let window = reception.frame else { return "当前客服账号" }
    let ignored = ["接待", "未授权", "搜索", "官方", "联系人", "工具", "数据", "待办"]
    let candidates = nodes.compactMap { node -> (String, CGRect)? in
      guard node.role == kAXStaticTextRole as String,
            let text = node.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            let frame = node.frame,
            !text.isEmpty, text.count >= 2, text.count <= 40,
            !exactCustomerIdentityMatches(text, customer),
            !ignored.contains(where: { text == $0 || text.hasPrefix($0 + " ") }),
            frame.minX >= window.minX,
            frame.maxX <= window.minX + window.width * 0.32,
            frame.minY >= window.minY,
            frame.maxY <= window.minY + 115 else { return nil }
      return (text, frame)
    }
    return candidates.sorted {
      if abs($0.1.minY - $1.1.minY) > 2 { return $0.1.minY < $1.1.minY }
      return $0.1.minX < $1.1.minX
    }.first?.0 ?? "当前客服账号"
  }

  func inspectTree(maxDepth: Int) -> [String: Any] {
    guard AXIsProcessTrusted() else { return ["error": "accessibility_not_trusted", "tree": "Grant Accessibility access, then retry."] }
    guard let pid = runningPID() else { return ["error": "jd_not_running", "tree": "JD 咚咚工作台 is not running."] }
    let app = AXUIElementCreateApplication(pid)
    var lines: [String] = ["bundle=\(bundleIdentifier) pid=\(pid)"]
    var count = 0
    var snapshot: [AXNode] = []
    walk(app, path: "app", depth: 0, maxDepth: min(maxDepth, 30), maxNodes: 4_000) { node, depth in
      count += 1
      snapshot.append(node)
      lines.append(String(repeating: "  ", count: depth) + describe(node))
    }
    let reception = snapshot.first(where: {
      $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
    })
    let scoped = reception.map { window in
      snapshot.filter { $0.path == window.path || $0.path.hasPrefix(window.path + "/") }
    } ?? []
    let identity = activeCustomerIdentity(in: scoped)
    lines.insert("activeCustomerId=\(identity ?? "unverified")", at: 1)
    let output = lines.joined(separator: "\n")
    return ["pid": Int(pid), "nodeCount": count, "tree": output,
            "activeCustomerId": identity.map { $0 as Any } ?? NSNull()]
  }

  private func runningPID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first(where: { !$0.isTerminated })?.processIdentifier
  }

  private func clearOwnedComposer(in nodes: [AXNode]) -> Bool {
    // No Send/switch may run through a dialog our fallback failed to close.
    if let cleanup = pendingAttachmentCleanup {
      guard cleanup() else { return false }
      pendingAttachmentCleanup = nil
    }
    if let owner = activeCustomerIdentity(in: nodes),
       let claimed = restoredComposerClaims.removeValue(forKey: owner) {
      if let composer = nodes.first(where: { $0.role == kAXTextAreaRole as String }),
         stringAttribute(composer.element, kAXValueAttribute) == claimed,
         activeCustomerMatches(owner, nodes: nodes) {
        ownedComposers[owner] = OwnedComposer(element: composer.element, text: claimed)
      } else { publishComposerClaims() }
    }
    guard let owner = activeCustomerIdentity(in: nodes),
          let owned = ownedComposers[owner] else { return true }
    guard accessibilityReadAllowed(),
          let composer = nodes.first(where: { $0.role == kAXTextAreaRole as String }),
          let current = stringAttribute(composer.element, kAXValueAttribute) else { return false }
    if current.isEmpty {
      ownedComposers.removeValue(forKey: owner)
      return true
    }
    guard CustomerSafety.canRecoverOwnedComposer(owner: owner, active: activeCustomerIdentity(in: nodes),
                                                 insertedText: owned.text, currentText: current,
                                                 sameElement: CFEqual(composer.element, owned.element)) else {
      // Operator edits are not ours to erase, even in the same customer chat.
      ownedComposers.removeValue(forKey: owner)
      return true
    }
    guard accessibilityReadAllowed(), activeCustomerMatches(owner, nodes: nodes),
          AXUIElementSetAttributeValue(composer.element, kAXValueAttribute as CFString,
                                       "" as CFTypeRef) == .success,
          stringAttribute(composer.element, kAXValueAttribute) == "" else { return false }
    ownedComposers.removeValue(forKey: owner)
    return true
  }

  /// Traverse only Dingdong's reception window. Walking every JD window at
  /// each verification multiplies capture and send latency. Resolve the
  /// window afresh each time; never cache the active customer for sending.
  private func receptionNodes(pid: pid_t) -> [AXNode]? {
    let budget = AccessibilityBudget(deadline: Date().addingTimeInterval(4))
    defer { budget.close() }
    let root = AXUIElementCreateApplication(pid)
    if let window = elementArrayAttribute(root, kAXWindowsAttribute).first(where: {
      stringAttribute($0, kAXTitleAttribute)?.contains("咚咚融合工作台") == true
    }) {
      var nodes: [AXNode] = []
      walk(window, path: "app/reception", depth: 0, maxDepth: 22, maxNodes: 5_000) {
        node, _ in nodes.append(node)
      }
      return nodes
    }
    // Preserve support for JD builds that omit AXWindows.
    var nodes: [AXNode] = []
    walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) {
      node, _ in nodes.append(node)
    }
    guard let window = nodes.first(where: {
      $0.role == kAXWindowRole as String &&
        ($0.title?.contains("咚咚融合工作台") == true)
    }) else { return nil }
    return nodes.filter { $0.path == window.path || $0.path.hasPrefix(window.path + "/") }
  }

  /// Returns the AX split that owns the active conversation and composer.
  /// Its horizontal bounds exclude both the customer sidebar and details
  /// panel, allowing OCR to reject text that belongs to another row.
  func activeChatFrame() -> CGRect? {
    guard AXIsProcessTrusted(), let pid = runningPID(),
          let scoped = receptionNodes(pid: pid) else { return nil }
    guard let composer = scoped.first(where: { $0.role == kAXTextAreaRole as String }) else {
      return nil
    }
    return scoped
      .filter({
        $0.role == kAXSplitGroupRole as String &&
          composer.path.hasPrefix($0.path + "/") && $0.frame != nil
      })
      .max(by: { $0.path.count < $1.path.count })?.frame
  }

  /// Bound OCR to the transcript, excluding the emoji toolbar and composer.
  /// Prefer the accessibility scroll area; its size follows JD's layout.
  func activeMessageBottom() -> CGFloat? {
    guard AXIsProcessTrusted(), let pid = runningPID(),
          let nodes = receptionNodes(pid: pid),
          let composer = nodes.first(where: {
      $0.role == kAXTextAreaRole as String && $0.frame != nil
    }), let composerFrame = composer.frame,
      let split = nodes.filter({
        $0.role == kAXSplitGroupRole as String &&
        composer.path.hasPrefix($0.path + "/") && $0.frame != nil
      }).max(by: { $0.path.count < $1.path.count }),
      let chatFrame = split.frame else { return nil }
    let transcripts = nodes.compactMap { node -> CGRect? in
      guard node.path.hasPrefix(split.path + "/"),
            node.role == kAXScrollAreaRole as String,
            let frame = node.frame,
            frame.width >= chatFrame.width * 0.55,
            frame.minX >= chatFrame.minX,
            frame.maxX <= chatFrame.maxX,
            frame.maxY <= composerFrame.minY + 12 else { return nil }
      return frame
    }
    return transcripts.max(by: { $0.height < $1.height })?.maxY ?? composerFrame.minY
  }

  /// Resolves one complete ID in the active chat header. Sidebar candidates
  /// and truncated prefixes are never used to prove the active customer.
  func activeCustomerIdentity() -> String? {
    guard AXIsProcessTrusted(), let pid = runningPID(),
          let scoped = receptionNodes(pid: pid) else { return nil }
    return activeCustomerIdentity(in: scoped)
  }

  private func activeCustomerIdentity(in scoped: [AXNode]) -> String? {
    guard let composer = scoped.first(where: { $0.role == kAXTextAreaRole as String }),
          let split = scoped
            .filter({ $0.role == kAXSplitGroupRole as String && composer.path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }),
          let frame = split.frame else { return nil }
    let headerNodes = scoped.filter { $0.path.hasPrefix(split.path + "/") }
    let labels = headerNodes.compactMap { node -> CustomerSafety.HeaderLabel? in
      guard node.role == kAXStaticTextRole as String,
            let text = node.text, let bounds = node.frame else { return nil }
      return CustomerSafety.HeaderLabel(text: text, frame: bounds)
    }
    let quickTransferFrames = headerNodes.compactMap { node -> CGRect? in
      guard node.role == kAXButtonRole as String,
            (node.title?.contains("快捷转接") == true ||
             node.description?.contains("快捷转接") == true) else { return nil }
      return node.frame
    }
    return CustomerSafety.activeHeaderIdentity(labels: labels, chatFrame: frame,
                                               quickTransferFrames: quickTransferFrames)
  }

  func conversationIdentities() -> [String] {
    conversationRows().compactMap { $0["customer"] as? String }
  }

  /// Launches Qianniu when needed and opens its verified Accessibility button
  /// for the customer-service reception center. This never selects a customer,
  /// changes the composer, or sends a message.
  func ensureReceptionWindow(allowActivation: Bool = true,
                              completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      func launchOrReopen(at url: URL) {
        DispatchQueue.main.async {
          let configuration = NSWorkspace.OpenConfiguration()
          configuration.activates = true
          NSWorkspace.shared.openApplication(
            at: url, configuration: configuration
          ) { [weak self] app, error in
            guard let self else { return }
            self.queue.async {
              if let error {
                finish(["error": "jingmai_launch_failed",
                        "message": error.localizedDescription])
                return
              }
              guard let app else {
                finish(["error": "jingmai_launch_failed",
                        "message": "JingMai did not launch."])
                return
              }
              // Reopening the already-running bundle can take noticeably
              // longer than a normal AX button press on recent Jingmai builds.
              for _ in 0..<80 {
                let response = self.openReceptionWindow(app: app)
                if response["ready"] as? Bool == true {
                  finish(response)
                  return
                }
                usleep(250_000)
              }
              finish(["error": "reception_window_missing",
                      "message": "JingMai launched, but its reception center did not become available."])
            }
          }
        }
      }
      guard AXIsProcessTrusted() else {
        finish(["error": "accessibility_not_allowed",
                "message": "Accessibility permission is required to open JingMai's reception center."])
        return
      }
      if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .first(where: { !$0.isTerminated }) {
        if !allowActivation {
          let root = AXUIElementCreateApplication(app.processIdentifier)
          var nodes: [AXNode] = []
          self.walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) {
            node, _ in nodes.append(node)
          }
          guard let reception = nodes.first(where: {
            $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
          }) else {
            finish(["error": "reception_window_missing",
                    "message": "JingMai is running, but the reception window is not open. Passive monitoring will not activate it."])
            return
          }
          var minimizedValue: CFTypeRef?
          let minimized = AXUIElementCopyAttributeValue(
            reception.element, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
            (minimizedValue as? NSNumber)?.boolValue == true
          guard !minimized, !app.isHidden else {
            finish(["error": "reception_window_hidden",
                    "message": "JingMai's reception window is hidden or minimized. Passive monitoring will not restore it."])
            return
          }
          finish(["ready": true, "opened": false, "method": "passive_existing_window"])
          return
        }
        let response = self.openReceptionWindow(app: app)
        if response["ready"] as? Bool == true {
          finish(response)
          return
        }
        guard let url = app.bundleURL ??
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
          finish(response)
          return
        }
        // The Dingdong helper can stay running after its last window closes.
        // Opening its bundle again is the reliable way to recreate that
        // window; activation alone does not invoke the application's reopen
        // handler.
        launchOrReopen(at: url)
        return
      }
      guard allowActivation else {
        finish(["error": "jingmai_not_running",
                "message": "JingMai is not running. Passive monitoring will not launch it."])
        return
      }
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
        finish(["error": "jingmai_not_installed",
                "message": "The installed JingMai application could not be located."])
        return
      }
      launchOrReopen(at: url)
    }
  }

  private func openReceptionWindow(app: NSRunningApplication) -> [String: Any] {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    func snapshot() -> [AXNode] {
      var nodes: [AXNode] = []
      walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) {
        node, _ in nodes.append(node)
      }
      return nodes
    }
    var nodes = snapshot()
    if let reception = nodes.first(where: {
      $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
    }) {
      var minimizedValue: CFTypeRef?
      let minimized = AXUIElementCopyAttributeValue(
        reception.element, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
        (minimizedValue as? NSNumber)?.boolValue == true
      if minimized {
        _ = app.unhide()
        _ = app.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementSetAttributeValue(
          reception.element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        usleep(250_000)
        return ["ready": true, "opened": true, "method": "restored_minimized_window"]
      }
      return ["ready": true, "opened": false, "method": "already_open"]
    }
    // A minimized/hidden main workbench may omit all of its child buttons from
    // the AX snapshot. Restore it once, then resolve the exact named control.
    _ = app.unhide()
    _ = app.activate(options: [.activateIgnoringOtherApps])
    usleep(300_000)
    nodes = snapshot()
    guard let button = nodes.first(where: {
      $0.role == kAXButtonRole as String && $0.title == "接待中心" &&
        $0.actions.contains(kAXPressAction as String)
    }) else {
      return ["error": "reception_button_missing",
              "message": "JingMai is running, but its verified 接待中心 button is unavailable."]
    }
    _ = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
    for _ in 0..<12 {
      usleep(125_000)
      nodes = snapshot()
      if nodes.contains(where: {
        $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
      }) {
        return ["ready": true, "opened": true, "method": "verified_ax_press"]
      }
    }
    return ["error": "reception_open_failed",
            "message": "JingMai did not expose a reception window after the verified 接待中心 button was pressed."]
  }

  /// Returns exact AX identities plus screenshot-derived unread evidence.
  /// The red-pixel detector is only a priority hint; Flutter still performs a
  /// fallback scan of every visible row to avoid losing messages.
  func conversationRows() -> [[String: Any]] {
    guard AXIsProcessTrusted(), let pid = runningPID(),
          let nodes = receptionNodes(pid: pid) else { return [] }
    guard let window = nodes.first(where: {
      $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
    }) else { return [] }
    guard let windowFrame = window.frame else { return [] }
    let activeFallback: () -> [[String: Any]] = { [weak self] in
      guard let customer = self?.activeCustomerIdentity(), !customer.isEmpty else {
        return []
      }
      return [[
        "customer": customer,
        "unread": false,
        "unreadEvidence": 0,
        "evidenceAvailable": false,
      ]]
    }
    // A one-customer JD layout can expose the active identity in the verified
    // chat header while omitting a usable screenshot/pressable sidebar row.
    // Keep monitoring that active conversation instead of reporting zero rows.
    guard let evidence = unreadScreenshot(pid: pid, matching: windowFrame) else {
      return activeFallback()
    }
    let customerGroups = nodes.compactMap {
      node -> (customer: String, frame: CGRect, flipped: Bool)? in
      guard node.path.hasPrefix(window.path + "/"),
            node.role == kAXGroupRole as String,
            node.actions.contains(kAXPressAction as String),
            let frame = node.frame,
            frame.minX >= windowFrame.minX,
            frame.maxX <= windowFrame.minX + windowFrame.width * 0.35,
            frame.minY >= windowFrame.minY + 180,
            frame.maxY <= windowFrame.maxY - 30,
            frame.width >= 140, frame.width <= 360,
            frame.height >= 35, frame.height <= 100,
            let identity = customerIdentityInRow(
              frame: frame, windowBounds: evidence.bounds, image: evidence.image)
      else { return nil }
      return (identity.customer, frame, identity.flipped)
    }
    var seen = Set<String>()
    let unique = customerGroups.filter { seen.insert($0.customer).inserted }
    if unique.isEmpty { return activeFallback() }
    return unique.map { customer, frame, flipped in
      let redPixels = unreadRedPixels(
        frame: frame, windowBounds: evidence.bounds, image: evidence.image,
        flipped: flipped)
      let unread = redPixels >= 8
      let elapsed: Any = unread
        ? (unreadElapsedSeconds(frame: frame, windowBounds: evidence.bounds,
                                image: evidence.image, flipped: flipped)
            .map { $0 as Any } ?? NSNull())
        : NSNull()
      return [
        "customer": customer,
        "unread": unread,
        "unreadEvidence": redPixels,
        "unreadAgeSeconds": elapsed,
        "evidenceAvailable": true,
      ]
    }
  }

  func openConversation(expectedCustomer: String, allowActivation: Bool = true,
                        allowObservedIdentityResolution: Bool = false,
                        deadline: Date,
                        completion: @escaping FlutterResult) {
    let expiresAt = ProcessInfo.processInfo.systemUptime + min(8, max(0, deadline.timeIntervalSinceNow))
    queue.async { [weak self] in
      guard let self else { return }
      let budget = AccessibilityBudget(deadline: deadline, uptimeDeadline: expiresAt)
      defer { budget.close() }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard budget.isCurrent, CustomerSafety.operationCurrent(deadline) else {
        finish(["error": "operation_expired", "message": "Queued customer switch expired; JD was left untouched."])
        return
      }
      guard !expected.isEmpty, AXIsProcessTrusted(), let pid = runningPID() else {
        finish(["error": "conversation_unavailable", "message": "JingMai, Accessibility, or customer ID is unavailable."])
        return
      }
      guard let nodes = receptionNodes(pid: pid) else {
        finish(["error": "conversation_window_missing",
                "message": "JingMai's reception window is not available."])
        return
      }
      guard let window = nodes.first(where: {
        $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
      }) else {
        finish(["error": "conversation_window_missing",
                "message": "JingMai's reception window is not available."])
        return
      }
      let scoped = nodes.filter {
        $0.path == window.path || $0.path.hasPrefix(window.path + "/")
      }
      guard self.clearOwnedComposer(in: scoped) else {
        finish(["error": "owned_composer_recovery_failed", "message": "Could not safely clear this app's previous verified insertion. The reply remains queued."])
        return
      }
      if activeCustomerMatches(expected, nodes: scoped) {
        finish(["opened": true, "customer": expected, "method": "already_active"])
        return
      }
      let evidence = window.frame.flatMap {
        unreadScreenshot(pid: pid, matching: $0)
      }
      let rowCandidates = scoped.compactMap { node -> (AXNode, String)? in
        guard node.role == kAXGroupRole as String,
              node.actions.contains(kAXPressAction as String),
              let frame = node.frame,
              let evidence,
              let identity = customerIdentityInRow(
                frame: frame, windowBounds: evidence.bounds, image: evidence.image)
        else { return nil }
        return (node, identity.customer)
      }
      let exact = rowCandidates.filter { exactCustomerIdentityMatches($0.1, expected) }
      let reconciled = exact.isEmpty
        ? rowCandidates.filter {
            CustomerSafety.canReconcileSidebarOCR($0.1, verifiedAX: expected)
          }
        : []
      // A unique one-edit OCR spelling may identify which row to press, but it
      // never becomes the customer identity. After the press, the independent
      // AX header below must still equal `expected` exactly before capture or
      // send can continue.
      let candidates = (exact.count == 1 ? exact : reconciled.count == 1 ? reconciled : []).map(\.0)
      guard candidates.count == 1 else {
        finish(["error": "conversation_identity_ambiguous",
                "message": "Exactly one exact or uniquely reconciled sidebar row must match \(expected); found exact=\(exact.count), near=\(reconciled.count)."])
        return
      }
      guard let target = candidates.min(by: {
        ($0.frame?.minX ?? .greatestFiniteMagnitude) <
          ($1.frame?.minX ?? .greatestFiniteMagnitude)
      }) else {
        finish(["error": "conversation_not_found", "message": "Exact conversation \(expected) was not found."])
        return
      }

      var observedCustomer = activeCustomerIdentity(in: scoped)
      let identityBeforeSelection = observedCustomer
      let targetWasSelected =
        boolAttribute(target.element, kAXSelectedAttribute as String) == true
      func verifiedIdentity(allowOCRReconciliation: Bool = false) -> String? {
        guard let current = receptionNodes(pid: pid) else { return nil }
        observedCustomer = activeCustomerIdentity(in: current)
        if CustomerSafety.matches(observedCustomer, expected) {
          return observedCustomer
        }
        if allowObservedIdentityResolution && allowOCRReconciliation &&
            (targetWasSelected ||
             !CustomerSafety.matches(observedCustomer, identityBeforeSelection)) &&
            CustomerSafety.canReconcileSidebarOCR(
              expected, verifiedAX: observedCustomer) {
          return observedCustomer
        }
        return nil
      }

      if let verified = verifiedIdentity() {
        finish(["opened": true, "customer": verified, "method": "already_active"])
        return
      }

      // Switching an embedded Qianniu chat ultimately requires keyboard/mouse
      // focus on builds that ignore AXPress. A background monitor must defer
      // instead of interrupting typing in VS Code or another application.
      guard allowActivation ||
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        finish(["error": "qianniu_not_frontmost",
                "message": "Unread conversation is queued until JingMai is frontmost; focus was not stolen."])
        return
      }

      // Try the verified AX action in the background first. Qianniu may accept
      // it without stealing focus. Only the guarded coordinate fallback below
      // activates Qianniu when its embedded web view ignores AXPress.
      if let composer = scoped.first(where: { $0.role == kAXTextAreaRole as String }),
         !(stringAttribute(composer.element, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
        finish(["error": "composer_not_empty",
                "message": "Automatic switching paused because the current composer contains text."])
        return
      }

      guard CustomerSafety.operationCurrent(deadline) else {
        finish(["error": "operation_expired", "message": "Customer verification exceeded the switch deadline; JD was left untouched."])
        return
      }
      _ = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
      for _ in 0..<8 {
        guard budget.isCurrent else { break }
        usleep(125_000)
        if let verified = verifiedIdentity(allowOCRReconciliation: true) {
          finish(["opened": true, "customer": verified, "method": "ax_press"])
          return
        }
      }

      // Qianniu's embedded web view sometimes advertises AXPress but ignores it.
      // Fall back to one click on the already identity-matched sidebar row, then
      // verify the active customer again before OCR is allowed to continue.
      guard let frame = target.frame else {
        finish(["error": "conversation_verification_failed",
                "message": "JingMai ignored AXPress for \(expected), and the verified sidebar row had no clickable frame."])
        return
      }
      // Reaching this point proves either activation was explicitly allowed or
      // Qianniu was already frontmost. Passive monitoring may click a verified
      // row only in the latter case; it still never steals focus.
      guard CustomerSafety.operationCurrent(deadline) else {
        finish(["error": "operation_expired", "message": "Customer switch deadline expired before the fallback click."])
        return
      }
      if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        usleep(150_000)
      }
      let point = CGPoint(x: frame.midX, y: frame.midY)
      guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                               mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                             mouseCursorPosition: point, mouseButton: .left) else {
        finish(["error": "conversation_click_failed",
                "message": "Could not create a guarded click for \(expected)."])
        return
      }
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      for _ in 0..<12 {
        guard budget.isCurrent else { break }
        usleep(125_000)
        if let verified = verifiedIdentity(allowOCRReconciliation: true) {
          finish(["opened": true, "customer": verified, "method": "guarded_click"])
          return
        }
      }
      finish(["error": "conversation_verification_failed",
              "observedCustomer": observedCustomer.map { $0 as Any } ?? NSNull(),
              "message": "JingMai did not activate the expected customer \(expected) after AXPress and a guarded row click."])
    }
  }

  /// Opens the verified active customer's transfer dialog and returns only
  /// visible service accounts with a green online badge. JD's account rows are
  /// canvas-rendered and absent from AX, so names come from Vision OCR while
  /// status comes from an independent pixel-color check beside each name.
  func listActiveTransferAccounts(expectedCustomer: String,
                                  completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      self.pendingTransferCustomer = nil
      guard !expected.isEmpty, AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
            let pid = self.runningPID() else {
        finish(["error": "transfer_precondition_failed",
                "message": "JingMai, Accessibility, Screen Recording, or the customer ID is unavailable."])
        return
      }

      let root = AXUIElementCreateApplication(pid)
      var nodes: [AXNode] = []
      self.walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) {
        node, _ in nodes.append(node)
      }
      guard let reception = nodes.first(where: {
        $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
      }) else {
        finish(["error": "transfer_window_missing",
                "message": "The JD Dingdong reception window is not available."])
        return
      }
      let scoped = nodes.filter {
        $0.path == reception.path || $0.path.hasPrefix(reception.path + "/")
      }
      guard self.activeCustomerMatches(expected, nodes: scoped) else {
        finish(["error": "transfer_customer_mismatch",
                "message": "The exact customer \(expected) is not the active JD conversation."])
        return
      }
      let sourceAccount = self.currentServiceAccount(
        in: reception, nodes: scoped, excluding: expected)
      guard let composer = scoped.first(where: { $0.role == kAXTextAreaRole as String }),
            (stringAttribute(composer.element, kAXValueAttribute)?
              .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
        finish(["error": "transfer_composer_not_empty",
                "message": "Clear the current JD composer before transferring this chat."])
        return
      }
      guard let transferButton = scoped.first(where: {
        $0.role == kAXButtonRole as String &&
          ($0.description?.contains("快捷转接") == true) &&
          $0.actions.contains(kAXPressAction as String)
      }) else {
        finish(["error": "transfer_button_missing",
                "message": "JD's verified 快捷转接 button is unavailable for this conversation."])
        return
      }

      _ = NSRunningApplication(processIdentifier: pid)?
        .activate(options: [.activateIgnoringOtherApps])
      usleep(150_000)
      let pressed = AXUIElementPerformAction(
        transferButton.element, kAXPressAction as CFString) == .success
      if !pressed, let frame = transferButton.frame {
        _ = postClick(at: CGPoint(x: frame.midX, y: frame.midY))
      }

      var snapshot: TransferDialogSnapshot?
      // The modal title is painted before the canvas body. Do not treat that
      // first title-only frame as a ready dialog: it can make Vision miss the
      // group label and force coordinate fallback while the body is blank.
      for _ in 0..<24 {
        usleep(125_000)
        guard let observed = captureTransferDialog(pid: pid) else { continue }
        snapshot = observed
        if observed.lines.contains(where: {
          compactTransferText($0.text).contains("默认咨询组")
        }) { break }
      }
      guard var dialog = snapshot else {
        finish(["error": "transfer_dialog_missing",
                "message": "JD did not open the verified transfer dialog."])
        return
      }

      var candidates = transferAccountCandidates(in: dialog)
      func waitForStableExpandedAccounts() {
        var bestDialog = dialog
        var bestCandidates = candidates
        var latestDialog = dialog
        var previousActiveKey: String?
        var consecutiveActiveFrames = 0

        for _ in 0..<16 {
          usleep(125_000)
          guard let expanded = captureTransferDialog(pid: pid) else { continue }
          latestDialog = expanded
          let observed = transferAccountCandidates(in: expanded)
          let observedActive = observed.filter(\.isActive)
          let bestActive = bestCandidates.filter(\.isActive)
          if observedActive.count > bestActive.count ||
              (observedActive.count == bestActive.count &&
                observed.count > bestCandidates.count) {
            bestDialog = expanded
            bestCandidates = observed
          }

          let activeKey = observedActive
            .map { normalizedCustomerIdentity($0.name) }
            .sorted()
            .joined(separator: "|")
          if !activeKey.isEmpty && activeKey == previousActiveKey {
            consecutiveActiveFrames += 1
          } else {
            previousActiveKey = activeKey.isEmpty ? nil : activeKey
            consecutiveActiveFrames = activeKey.isEmpty ? 0 : 1
          }
          // JD renders the account text before its status badges during the
          // expansion animation. Require the same non-empty green set twice
          // so a transient name-only frame cannot become an agents-busy result.
          if consecutiveActiveFrames >= 2 {
            dialog = expanded
            candidates = observed
            return
          }
        }
        // When no row is recognized, retain the latest frame for diagnostics
        // instead of reporting the title-only frame captured during opening.
        dialog = bestCandidates.isEmpty ? latestDialog : bestDialog
        candidates = bestCandidates
      }

      var expansionClickPoint: CGPoint?
      if candidates.isEmpty {
        let group = dialog.lines.first(where: {
          compactTransferText($0.text).contains("默认咨询组")
        })
        // This JD build expands the group by clicking its visible name/row.
        // Its top offset is stable while the modal height changes between
        // collapsed and expanded states. Never normalize Y by window height:
        // on a 506-point collapsed modal that clicked the search field at
        // y=104 instead of the verified group row at y=157.
        let globalGroupPoint: CGPoint
        if let group {
          globalGroupPoint = dialog.globalPoint(for: CGPoint(
            x: group.frame.midX, y: group.frame.midY))
        } else {
          globalGroupPoint = CGPoint(
            x: dialog.bounds.minX + dialog.bounds.width * 0.215,
            y: dialog.bounds.minY + min(157, dialog.bounds.height - 24))
        }
        expansionClickPoint = globalGroupPoint
        _ = postHover(at: globalGroupPoint)
        _ = postClick(at: globalGroupPoint)
        waitForStableExpandedAccounts()
      }

      guard !candidates.isEmpty else {
        let recognized = dialog.lines
          .map { compactTransferText($0.text) }
          .filter { !$0.isEmpty }
          .joined(separator: " | ")
        let boundsSummary = String(
          format: "bounds=(%.0f,%.0f %.0fx%.0f), image=%.0fx%.0f",
          dialog.bounds.minX, dialog.bounds.minY,
          dialog.bounds.width, dialog.bounds.height,
          dialog.imageWidth, dialog.imageHeight)
        let clickSummary = expansionClickPoint.map {
          String(format: "click=(%.0f,%.0f), local=(%.0f,%.0f)",
                 $0.x, $0.y,
                 $0.x - dialog.bounds.minX, $0.y - dialog.bounds.minY)
        } ?? "click=not-required"
        _ = postEscape()
        finish(["error": "transfer_group_not_expanded",
                "message": "JD's 默认咨询组 did not expose recognizable account rows after one deliberate group-row click. No second toggle was sent. \(boundsSummary), \(clickSummary). OCR: \(recognized.prefix(500))"])
        return
      }

      let active = candidates.filter(\.isActive)
      var seen = Set<String>()
      let accounts = active.map(\.name).filter {
        seen.insert(normalizedCustomerIdentity($0)).inserted
      }
      guard !accounts.isEmpty else {
        let evidence = candidates.map {
          "\($0.name)[green=\($0.greenPixelEvidence),red=\($0.redPixelEvidence)]"
        }.joined(separator: ", ")
        _ = postEscape()
        finish(["error": "no_active_transfer_accounts",
                "message": evidence.isEmpty
                  ? "No JD sub-account rows were recognized after expanding the consultation group."
                  : "No visible JD sub-account had a confirmed green active badge. Observed: \(evidence)"])
        return
      }
      self.pendingTransferCustomer = expected
      finish(["accounts": accounts, "customer": expected,
              "sourceAccount": sourceAccount])
    }
  }

  /// Revalidates the selected account's green badge, selects its row to reveal
  /// actions, and clicks only that row's explicit blue 转接 control. The
  /// adjacent 备注原因 control is never used.
  func transferConversation(expectedCustomer: String, targetAccount: String,
                            completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      let target = targetAccount.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !expected.isEmpty, !target.isEmpty, AXIsProcessTrusted(),
            CGPreflightScreenCaptureAccess(), let pid = self.runningPID(),
            self.pendingTransferCustomer.map({
              exactCustomerIdentityMatches($0, expected)
            }) == true else {
        finish(["error": "transfer_selection_expired",
                "message": "The verified JD transfer selection expired. Inspect active accounts again."])
        return
      }
      guard var dialog = captureTransferDialog(pid: pid),
            let candidate = transferAccountCandidates(in: dialog).first(where: {
              $0.isActive && exactCustomerIdentityMatches($0.name, target)
            }) else {
        self.pendingTransferCustomer = nil
        finish(["error": "transfer_target_not_active",
                "message": "The selected account \(target) no longer has a confirmed green badge."])
        return
      }

      _ = NSRunningApplication(processIdentifier: pid)?
        .activate(options: [.activateIgnoringOtherApps])
      usleep(150_000)
      // Click inside the account-name portion of the row. This reveals the
      // row-specific 转接 and 备注原因 actions; neither exists while collapsed.
      // Keep the click well left of the action area observed in JD 10.4.5 so
      // selecting the account can never accidentally invoke 转接 itself.
      let rowSelectionX = min(
        max(candidate.frame.midX, dialog.imageWidth * 0.24),
        dialog.imageWidth * 0.50)
      _ = postClick(at: dialog.globalPoint(for: CGPoint(
        x: rowSelectionX,
        y: candidate.frame.midY)))

      var actionPoint: CGPoint?
      for _ in 0..<12 {
        usleep(125_000)
        guard let selected = captureTransferDialog(pid: pid) else { break }
        dialog = selected
        guard let selectedCandidate = transferAccountCandidates(in: selected).first(where: {
          $0.isActive && exactCustomerIdentityMatches($0.name, target)
        }) else { continue }
        // Re-anchor to the freshly captured row. Selecting an account can
        // slightly change row geometry when JD reveals 转接 / 备注原因.
        if let action = selected.lines
          .filter({
            compactTransferText($0.text) == "转接" &&
              $0.frame.midX > selected.imageWidth * 0.55 &&
              $0.frame.midX < selected.imageWidth * 0.85 &&
              abs($0.frame.midY - selectedCandidate.frame.midY) <
                selected.imageHeight * 0.06
          })
          .min(by: {
            abs($0.frame.midY - selectedCandidate.frame.midY) <
              abs($1.frame.midY - selectedCandidate.frame.midY)
          }) {
          actionPoint = selected.globalPoint(for: CGPoint(
            x: action.frame.midX, y: action.frame.midY))
          break
        }
      }
      guard let actionPoint else {
        self.pendingTransferCustomer = nil
        finish(["error": "transfer_action_missing",
                "message": "JD did not reveal the selected row's explicit 转接 action. Nothing was transferred."])
        return
      }

      // The caller showed an explicit confirmation before invoking this
      // method. Clear the one-shot token before the external transfer click so
      // an unconfirmed outcome can never be retried automatically.
      self.pendingTransferCustomer = nil
      guard postClick(at: actionPoint) else {
        finish(["error": "transfer_click_failed",
                "message": "Could not click JD's explicit 转接 action."])
        return
      }
      for _ in 0..<20 {
        usleep(150_000)
        if captureTransferDialog(pid: pid) == nil {
          finish(["transferred": true, "customer": expected,
                  "targetAccount": target, "verification": "dialog_closed"])
          return
        }
      }
      finish(["error": "transfer_unconfirmed",
              "message": "JD's 转接 action was clicked once, but the dialog did not close. Do not retry automatically; verify in JD."])
    }
  }

  func cancelTransferSelection(completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      self.pendingTransferCustomer = nil
      guard let pid = self.runningPID() else {
        finish(["closed": true])
        return
      }
      guard captureTransferDialog(pid: pid) != nil else {
        finish(["closed": true])
        return
      }
      let root = AXUIElementCreateApplication(pid)
      var nodes: [AXNode] = []
      self.walk(root, path: "app", depth: 0, maxDepth: 12, maxNodes: 1_000) {
        node, _ in nodes.append(node)
      }
      if let close = nodes.first(where: {
        $0.role == kAXButtonRole as String && $0.description == "关闭" &&
          $0.actions.contains(kAXPressAction as String)
      }) {
        _ = AXUIElementPerformAction(close.element, kAXPressAction as CFString)
      } else {
        _ = postEscape()
      }
      for _ in 0..<8 {
        usleep(100_000)
        if captureTransferDialog(pid: pid) == nil {
          finish(["closed": true])
          return
        }
      }
      finish(["error": "transfer_dialog_close_failed",
              "message": "The JD transfer dialog is still open."])
    }
  }

  /// Scrolls only the verified active chat viewport. Positive values reveal
  /// older/upper content; negative values return toward the newest message.
  func scrollConversation(expectedCustomer: String, deltaY: Int32,
                          completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !expected.isEmpty, deltaY != 0, AXIsProcessTrusted(),
            let pid = runningPID() else {
        finish(["error": "scroll_precondition_failed",
                "message": "Customer, scroll amount, or Accessibility is unavailable."])
        return
      }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        finish(["error": "qianniu_not_frontmost",
                "message": "JingMai is not active. Chat scrolling was deferred without stealing focus."])
        return
      }
      let root = AXUIElementCreateApplication(pid)
      var nodes: [AXNode] = []
      walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) {
        node, _ in nodes.append(node)
      }
      guard activeCustomerMatches(expected, nodes: nodes),
            let composer = nodes.first(where: { $0.role == kAXTextAreaRole as String }),
            let composerFrame = composer.frame,
            (stringAttribute(composer.element, kAXValueAttribute)?
              .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            let split = nodes
              .filter({ $0.role == kAXSplitGroupRole as String && composer.path.hasPrefix($0.path + "/") })
              .max(by: { $0.path.count < $1.path.count }),
            let splitFrame = split.frame else {
        finish(["error": "scroll_verification_failed",
                "message": "The exact active chat viewport or empty composer could not be verified."])
        return
      }
      let messageBottom = min(composerFrame.minY, splitFrame.maxY)
      let point = CGPoint(x: splitFrame.midX,
                          y: splitFrame.minY + (messageBottom - splitFrame.minY) * 0.55)
      guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left),
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                 wheelCount: 1, wheel1: deltaY,
                                 wheel2: 0, wheel3: 0) else {
        finish(["error": "scroll_event_failed",
                "message": "Could not create a guarded chat scroll event."])
        return
      }
      move.post(tap: .cghidEventTap)
      scroll.post(tap: .cghidEventTap)
      usleep(450_000)
      var after: [AXNode] = []
      walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) {
        node, _ in after.append(node)
      }
      guard activeCustomerMatches(expected, nodes: after) else {
        finish(["error": "scroll_customer_changed",
                "message": "The active customer changed during scrolling."])
        return
      }
      finish(["scrolled": true, "customer": expected, "deltaY": Int(deltaY)])
    }
  }

  private func poll() {
    guard AXIsProcessTrusted(), let pid = runningPID() else { return }
    let root = AXUIElementCreateApplication(pid)
    var nodes: [AXNode] = []
    walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) { node, _ in nodes.append(node) }

    // Validated against Qianniu macOS 9.95.01. Scope all matching to the reception
    // window so similarly named controls in the workbench window cannot be selected.
    guard let receptionWindow = nodes.first(where: {
      $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
    }) else {
      onDiagnostic?(["event": "reception_window_missing",
                     "hint": "Open JingMai's customer-service reception center."])
      return
    }
    let scopedNodes = nodes.filter {
      $0.path == receptionWindow.path || $0.path.hasPrefix(receptionWindow.path + "/")
    }
    guard let composer = scopedNodes.first(where: { $0.role == kAXTextAreaRole as String }),
          let splitGroup = scopedNodes
            .filter({ $0.role == kAXSplitGroupRole as String && composer.path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) else {
      onDiagnostic?(["event": "composer_missing",
                     "hint": "Keep an active conversation open and inspect the AX tree again."])
      return
    }

    guard let splitFrame = splitGroup.frame,
          let customerNode = scopedNodes
            .filter({ node in
              guard node.role == "AXStaticText", let frame = node.frame,
                    let text = node.text, !text.isEmpty else { return false }
              return frame.minX >= splitFrame.minX && frame.maxX <= splitFrame.maxX &&
                frame.maxY <= splitFrame.minY && frame.minY >= splitFrame.minY - 100
            })
            .max(by: { ($0.frame?.minY ?? 0) < ($1.frame?.minY ?? 0) }),
          let customerName = activeCustomerIdentity(in: scopedNodes),
          CustomerSafety.fullIdentity(customerName) != nil else {
      onDiagnostic?(["event": "customer_identity_missing",
                     "splitFrame": normalizedFrame(splitGroup.frame)])
      return
    }
    let conversationKey = stableConversationKey(customerNode, customerName: customerName)
    lastActiveConversation = conversationKey

    // The live dump exposes message history as AXSplitGroup/AXGroup/AXList and the
    // composer as AXTextArea. Restricting the list to this split group excludes the
    // sidebar and the customer/product panels.
    guard let composerFrame = composer.frame,
          let messageArea = scopedNodes
            .filter({ node in
              guard node.role == "AXList", let frame = node.frame else { return false }
              return node.path.hasPrefix(splitGroup.path + "/") && frame.maxY <= composerFrame.minY
            })
            .max(by: { ($0.frame?.width ?? 0) < ($1.frame?.width ?? 0) }) else {
      onDiagnostic?(["event": "message_list_missing", "customer": customerName])
      return
    }
    let messageNodes = scopedNodes.filter {
      $0.path.hasPrefix(messageArea.path + "/") && $0.role == "AXStaticText" && $0.text != nil
    }
    let captures: [[String: Any]] = messageNodes.compactMap { node in
      guard let body = node.text, body != customerName, body.count <= 20_000 else { return nil }
      let fingerprint = sha256([conversationKey, node.identifier ?? "", body, normalizedFrame(node.frame), node.path].joined(separator: "\u{1f}"))
      guard !seenFingerprints.contains(fingerprint) else { return nil }
      return [
        "stableId": "fp:\(fingerprint)",
        "direction": inferDirection(node: node, container: messageArea),
        "body": body,
        "axPath": node.path,
      ]
    }
    guard !captures.isEmpty else {
      onDiagnostic?(["event": "capture_ready", "customer": customerName,
                     "messageList": messageArea.path, "visibleMessages": messageNodes.count,
                     "note": "No unseen accessible messages are currently visible."])
      return
    }
    guard let after = activeCustomerIdentity(), CustomerSafety.matches(after, customerName) else {
      onDiagnostic?(["event": "customer_changed_during_capture",
                     "expectedCustomer": customerName])
      return
    }
    for capture in captures {
      if let id = capture["stableId"] as? String { seenFingerprints.insert(String(id.dropFirst(3))) }
    }
    onCapture?([
      "stableKey": conversationKey,
      "customerName": customerName,
      "customerExternalId": customerName,
      "verifiedCustomerId": after,
      "messages": captures,
      "capturedAtMs": Int(Date().timeIntervalSince1970 * 1000),
    ])
  }

  private func inferDirection(node: AXNode, container: AXNode) -> String {
    guard let x = node.frame?.midX, let middle = container.frame?.midX else { return "unknown" }
    return x < middle ? "incoming" : "outgoing"
  }

  private func stableConversationKey(_ identity: AXNode, customerName: String) -> String {
    if let identifier = identity.identifier, !identifier.isEmpty { return "customer:\(sha256(customerName)):ax:\(identifier)" }
    return "customer:\(sha256(customerName))"
  }

  private func descendantTexts(of ancestor: AXNode, in nodes: [AXNode]) -> [String] {
    nodes.lazy.filter { $0.path.hasPrefix(ancestor.path + "/") }
      .compactMap(\.text).filter { !$0.isEmpty }
  }

  private func walk(_ element: AXUIElement, path: String, depth: Int, maxDepth: Int,
                    maxNodes: Int, visit: (AXNode, Int) -> Void) {
    let budget = AccessibilityBudget(deadline: Date().addingTimeInterval(4))
    defer { budget.close() }
    guard depth <= maxDepth else { return }
    var visited = 0
    var snapshot: [(AXNode, Int)] = []
    func recurse(_ current: AXUIElement, _ currentPath: String, _ currentDepth: Int) {
      guard currentDepth <= maxDepth, budget.isCurrent else { return }
      guard visited < maxNodes else { budget.invalidate(); return }
      visited += 1
      let node = makeNode(current, path: currentPath)
      snapshot.append((node, currentDepth))
      var roleCounts: [String: Int] = [:]
      for child in node.children {
        guard budget.isCurrent else { break }
        let role = stringAttribute(child, kAXRoleAttribute) ?? "AXUnknown"
        let index = roleCounts[role, default: 0]
        roleCounts[role] = index + 1
        recurse(child, "\(currentPath)/\(role)[\(index)]", currentDepth + 1)
      }
    }
    recurse(element, path, depth)
    // Do not leak a partial tree to customer/header matching after a timeout.
    guard budget.isCurrent else { budget.invalidate(); return }
    for (node, depth) in snapshot { visit(node, depth) }
  }

  private func makeNode(_ element: AXUIElement, path: String) -> AXNode {
    var names: CFArray?
    if accessibilityReadAllowed() {
      _ = accessibilityReadSucceeded(AXUIElementCopyActionNames(element, &names))
    }
    return AXNode(
      element: element,
      path: path,
      role: stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown",
      subrole: stringAttribute(element, kAXSubroleAttribute),
      identifier: stringAttribute(element, kAXIdentifierAttribute),
      title: stringAttribute(element, kAXTitleAttribute),
      description: stringAttribute(element, kAXDescriptionAttribute),
      value: stringAttribute(element, kAXValueAttribute),
      help: stringAttribute(element, kAXHelpAttribute),
      frame: frameAttribute(element),
      actions: names as? [String] ?? [],
      children: elementArrayAttribute(element, kAXChildrenAttribute))
  }
}

private func accessibilityReadAllowed() -> Bool {
  AccessibilityBudget.current?.isCurrent ?? true
}

private func accessibilityReadSucceeded(_ result: AXError) -> Bool {
  if result == .cannotComplete { AccessibilityBudget.current?.invalidate() }
  return result == .success && accessibilityReadAllowed()
}

private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
  var value: CFTypeRef?
  guard accessibilityReadAllowed(),
        accessibilityReadSucceeded(AXUIElementCopyAttributeValue(element, attribute as CFString, &value)) else { return nil }
  if let string = value as? String { return string }
  if let number = value as? NSNumber { return number.stringValue }
  return nil
}

private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
  var value: CFTypeRef?
  guard accessibilityReadAllowed(),
        accessibilityReadSucceeded(AXUIElementCopyAttributeValue(element, attribute as CFString, &value)) else { return nil }
  return (value as? NSNumber)?.boolValue
}

private func elementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
  var value: CFTypeRef?
  guard accessibilityReadAllowed(),
        accessibilityReadSucceeded(AXUIElementCopyAttributeValue(element, attribute as CFString, &value)) else { return [] }
  return value as? [AXUIElement] ?? []
}

private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
  var value: CFTypeRef?
  guard accessibilityReadAllowed(),
        accessibilityReadSucceeded(AXUIElementCopyAttributeValue(element, attribute as CFString, &value)),
        let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
  return (value as! AXUIElement)
}

private func frameAttribute(_ element: AXUIElement) -> CGRect? {
  var positionValue: CFTypeRef?
  var sizeValue: CFTypeRef?
  guard accessibilityReadAllowed(),
        accessibilityReadSucceeded(AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)),
        accessibilityReadSucceeded(AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)),
        let positionAX = positionValue, let sizeAX = sizeValue,
        CFGetTypeID(positionAX) == AXValueGetTypeID(), CFGetTypeID(sizeAX) == AXValueGetTypeID() else { return nil }
  var point = CGPoint.zero
  var size = CGSize.zero
  guard AXValueGetValue(positionAX as! AXValue, .cgPoint, &point),
        AXValueGetValue(sizeAX as! AXValue, .cgSize, &size) else { return nil }
  return CGRect(origin: point, size: size)
}

private func normalizedFrame(_ frame: CGRect?) -> String {
  guard let frame else { return "-" }
  return "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
}

private func sha256(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private struct PasteboardSnapshot {
  private let items: [[NSPasteboard.PasteboardType: Data]]

  init(_ pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
      })
    }
  }

  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let restored = items.map { values -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in values { item.setData(data, forType: type) }
      return item
    }
    if !restored.isEmpty { pasteboard.writeObjects(restored) }
  }
}

private func postCommandC() -> Bool {
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else { return false }
  down.flags = .maskCommand
  up.flags = .maskCommand
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  return true
}

/// Keyboard input is delivered only to the verified owning process, never to
/// whichever unrelated app happens to become frontmost during cleanup.
private func postKeyToPID(_ pid: pid_t, key: CGKeyCode, flags: CGEventFlags) -> Bool {
  guard pid > 0,
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
  down.flags = flags; up.flags = flags
  down.postToPid(pid); up.postToPid(pid)
  return true
}

private extension ISO8601DateFormatter {
  static var fractional: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }
}

private func postCommandV() -> Bool {
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return false }
  down.flags = .maskCommand
  up.flags = .maskCommand
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  return true
}

private func averageImageHash(_ image: CGImage) -> String {
  var pixels = [UInt8](repeating: 0, count: 64)
  let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8,
                                  bitsPerComponent: 8, bytesPerRow: 8,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
      return false
    }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
    return true
  }
  guard rendered else { return "" }
  let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
  var hash: UInt64 = 0
  for (index, pixel) in pixels.enumerated() where Int(pixel) >= average {
    hash |= UInt64(1) << UInt64(index)
  }
  return String(format: "%016llx", hash)
}

/// JD video thumbnails use a bright circular play ring near the media center.
/// OCR crops may include the sender avatar and surrounding whitespace, so scan
/// a small center area rather than assuming the ring is at the crop midpoint.
/// Requiring most angular sectors plus the center triangle avoids promoting
/// ordinary product photos merely because they contain one white control.
private func looksLikeVideoThumbnail(_ image: CGImage) -> Bool {
  CustomerSafety.hasVideoPlayControl(image)
}

func failedSendRetryDelay(attempts: Int) -> TimeInterval {
  let delays: [TimeInterval] = [15, 30, 60, 120, 300]
  return delays[min(max(attempts, 0), delays.count - 1)]
}

struct FailedSendBubble {
  let point: CGPoint
  let frame: CGRect
  let image: CGImage
  let fingerprint: String
}

/// Locate JD's white-exclamation/red-circle next to a light-blue outgoing
/// bubble. No AX text layout, receipt, or network probe is needed.
func failedSendBubbles(image: CGImage, windowBounds: CGRect,
    chatFrame: CGRect) -> [FailedSendBubble] {
  let sx = CGFloat(image.width) / max(windowBounds.width, 1)
  let sy = CGFloat(image.height) / max(windowBounds.height, 1)
  let region = CGRect(x: (chatFrame.minX - windowBounds.minX) * sx,
      y: (chatFrame.minY - windowBounds.minY) * sy,
      width: chatFrame.width * sx, height: chatFrame.height * sy).integral
    .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
  guard region.width > 20, region.height > 20,
        let crop = image.cropping(to: region) else { return [] }
  let w = crop.width, h = crop.height
  var pixels = [UInt8](repeating: 0, count: w * h * 4)
  let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
          CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  guard rendered else { return [] }
  func red(_ i: Int) -> Bool {
    let p = i * 4, r = Int(pixels[p]), g = Int(pixels[p + 1]), b = Int(pixels[p + 2])
    return r > 165 && r - g > 65 && r - b > 50
  }
  func white(_ x: Int, _ y: Int) -> Bool {
    let p = (y * w + x) * 4
    return pixels[p] > 235 && pixels[p + 1] > 235 && pixels[p + 2] > 235
  }
  func blue(_ x: Int, _ y: Int) -> Bool {
    let p = (y * w + x) * 4
    let r = Int(pixels[p]), g = Int(pixels[p + 1]), b = Int(pixels[p + 2])
    return r > 165 && r < 238 && g > 185 && b > 240 && b - r > 18 && g >= r
  }
  var visited = [Bool](repeating: false, count: w * h)
  var results: [FailedSendBubble] = []
  for seed in 0..<(w * h) where !visited[seed] && red(seed) {
    visited[seed] = true
    var pending = [seed], count = 0
    var left = seed % w, right = left, top = seed / w, bottom = top
    while let i = pending.popLast() {
      count += 1
      let x = i % w, y = i / w
      left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
      let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
      for (nx, ny) in neighbors where nx >= 0 && nx < w && ny >= 0 && ny < h {
        let n = ny * w + nx
        if !visited[n] && red(n) { visited[n] = true; pending.append(n) }
      }
    }
    let bw = right - left + 1, bh = bottom - top + 1
    let logicalW = CGFloat(bw) / sx, logicalH = CGFloat(bh) / sy
    let fill = Double(count) / Double(bw * bh)
    guard logicalW >= 8, logicalW <= 40, logicalH >= 8, logicalH <= 40,
          logicalW / logicalH > 0.8, logicalW / logicalH < 1.25,
          fill > 0.5, fill < 0.9 else { continue }
    // Require the white vertical stem and separate dot inside the red circle.
    // Avatars, red text, notification counts, and solid red shapes are rejected.
    let cx = (left + right) / 2, cy = (top + bottom) / 2
    func centerWhite(at fraction: Double) -> Bool {
      let y = top + Int(Double(bh - 1) * fraction)
      return ((cx - max(1, bw / 12))...(cx + max(1, bw / 12))).contains { white($0, y) }
    }
    guard centerWhite(at: 0.25), centerWhite(at: 0.45),
          centerWhite(at: 0.73), !centerWhite(at: 0.65) else { continue }
    let searchEnd = min(w - 1, right + Int(60 * sx))
    guard right + 1 < searchEnd,
          let bubbleLeft = ((right + 1)...searchEnd).first(where: { blue($0, cy) }) else { continue }
    // Inspect the left padding column, not message glyphs or AX line frames.
    let column = min(w - 1, bubbleLeft + max(2, Int(4 * sx)))
    func paddingBlue(_ y: Int) -> Bool {
      [3, 5, 7, 9].filter {
        blue(min(w - 1, bubbleLeft + max(1, Int(CGFloat($0) * sx))), y)
      }.count >= 2
    }
    // JD overlays a faint watermark on the bubble. A few non-blue pixels
    // must not truncate a multiline message in the middle of that watermark.
    func edge(_ direction: Int) -> Int {
      var y = cy, lastBlue = cy, gap = 0
      while y + direction >= 0 && y + direction < h {
        y += direction
        if paddingBlue(y) { lastBlue = y; gap = 0 } else { gap += 1 }
        if gap >= max(3, Int(6 * sy)) { break }
      }
      return lastBlue
    }
    let bubbleTop = edge(-1), bubbleBottom = edge(1)
    let paddingRow = min(bubbleBottom, bubbleTop + max(2, Int(3 * sy)))
    var bubbleRight = column
    while bubbleRight + 1 < w && blue(bubbleRight + 1, paddingRow) { bubbleRight += 1 }
    guard CGFloat(bubbleRight - bubbleLeft) / sx >= 45,
          CGFloat(bubbleBottom - bubbleTop) / sy >= 20,
          // Outgoing bubbles terminate in the right half of the transcript.
          bubbleRight > w / 2, bubbleTop > 0, bubbleBottom < h - 1 else { continue }
    let rect = CGRect(x: region.minX + CGFloat(bubbleLeft),
        y: region.minY + CGFloat(bubbleTop),
        width: CGFloat(bubbleRight - bubbleLeft + 1),
        height: CGFloat(bubbleBottom - bubbleTop + 1))
    guard let message = image.cropping(to: rect),
          let data = NSBitmapImageRep(cgImage: message).representation(using: .png, properties: [:])
    else { continue }
    results.append(FailedSendBubble(
        point: CGPoint(x: windowBounds.minX + (region.minX + CGFloat(cx)) / sx,
                       y: windowBounds.minY + (region.minY + CGFloat(cy)) / sy),
        frame: CGRect(x: windowBounds.minX + rect.minX / sx,
                      y: windowBounds.minY + rect.minY / sy,
                      width: rect.width / sx, height: rect.height / sy),
        image: message,
        fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
  }
  return results.sorted { $0.point.y > $1.point.y }
}


private func postClick(at point: CGPoint) -> Bool {
  guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left),
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left) else { return false }
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  usleep(100_000)
  return true
}

private func postRightClick(at point: CGPoint) -> Bool {
  guard let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                           mouseCursorPosition: point, mouseButton: .right),
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                         mouseCursorPosition: point, mouseButton: .right) else { return false }
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  usleep(120_000)
  return true
}

private func postHover(at point: CGPoint) -> Bool {
  guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left)
  else { return false }
  move.post(tap: .cghidEventTap)
  usleep(250_000)
  return true
}

private func postCommandShiftG() -> Bool {
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 5, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 5, keyDown: false)
  else { return false }
  down.flags = [.maskCommand, .maskShift]
  up.flags = [.maskCommand, .maskShift]
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  return true
}

private func postDoubleClick(at point: CGPoint) -> Bool {
  guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left),
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left) else { return false }
  down.setIntegerValueField(.mouseEventClickState, value: 1)
  up.setIntegerValueField(.mouseEventClickState, value: 1)
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  usleep(80_000)
  down.setIntegerValueField(.mouseEventClickState, value: 2)
  up.setIntegerValueField(.mouseEventClickState, value: 2)
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  return true
}

private func postEscape() -> Bool {
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
  else { return false }
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  return true
}

private func closeJDImageViewer(pid: pid_t, bounds: CGRect) -> Bool {
  let app = AXUIElementCreateApplication(pid)
  for window in elementArrayAttribute(app, kAXWindowsAttribute) {
    let title = stringAttribute(window, kAXTitleAttribute) ?? ""
    guard title.contains("图片浏览器") else { continue }
    var closeValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      window, kAXCloseButtonAttribute as CFString, &closeValue) == .success,
       let closeValue,
       CFGetTypeID(closeValue) == AXUIElementGetTypeID() {
      _ = AXUIElementPerformAction(
        unsafeBitCast(closeValue, to: AXUIElement.self),
        kAXPressAction as CFString)
      usleep(100_000)
    }
  }
  if namedWindowBounds(pid: pid, containing: "图片浏览器") == nil { return true }

  // JD builds that do not expose AXCloseButton still use the standard macOS
  // close control at the top-left of this already verified viewer window.
  _ = postClick(at: CGPoint(x: bounds.minX + 20, y: bounds.minY + 20))
  usleep(100_000)
  if namedWindowBounds(pid: pid, containing: "图片浏览器") == nil { return true }

  _ = postEscape()
  usleep(100_000)
  return namedWindowBounds(pid: pid, containing: "图片浏览器") == nil
}

private func describe(_ node: AXNode) -> String {
  var fields = [node.role]
  if let subrole = node.subrole { fields.append("subrole=\(quoted(subrole))") }
  if let id = node.identifier { fields.append("id=\(quoted(id))") }
  if let title = node.title { fields.append("title=\(quoted(title))") }
  if let value = node.value { fields.append("value=\(quoted(value))") }
  if let description = node.description { fields.append("description=\(quoted(description))") }
  if let help = node.help { fields.append("help=\(quoted(help))") }
  if let frame = node.frame { fields.append("frame=\(normalizedFrame(frame))") }
  if !node.actions.isEmpty { fields.append("actions=\(node.actions)") }
  fields.append("path=\(node.path)")
  return fields.joined(separator: " ")
}

private func quoted(_ value: String) -> String {
  let clipped = value.count > 240 ? String(value.prefix(240)) + "…" : value
  return "\"\(clipped.replacingOccurrences(of: "\n", with: "\\n"))\""
}
