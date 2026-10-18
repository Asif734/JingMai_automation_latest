import Foundation
import AppKit
import Darwin

/// No Flutter engine, UI windows, timers that click, shell commands, or
/// autonomous polling. It serves only allowlisted, dated parent requests.
@main
struct UiWorkerMain {
  static func main() {
    let endpoint = NativeAutomationEndpoint()
    let writer = WorkerWriter()
    endpoint.onEvent = { method, payload in writer.emit(["event":method,"payload":payload]) }
    DispatchQueue.global(qos:.userInitiated).async {
      while let line = readLine() {
        guard line.utf8.count < 40 * 1024 * 1024,
              let data = line.data(using:.utf8),
              let request = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              request["version"] as? Int == 1,
              let id = request["id"] as? String,
              let method = request["method"] as? String,
              NativeAutomationEndpoint.workerMethods.contains(method),
              let deadline = request["deadlineMs"] as? Double,
              let arguments = request["arguments"] as? [String:Any] else { exit(74) }
        let remaining = min(30,max(0,(deadline - Date().timeIntervalSince1970 * 1000)/1000))
        guard remaining > 0 else {
          writer.emit(["id":id,"result":["error":"operation_expired"]]); continue
        }
        let completed = WorkerCompletion()
        // A native AX call can block its own dispatch queue. The independent
        // process deadline still terminates it, even if the parent disappears.
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now() + remaining + 0.2) {
          if !completed.isFinished { exit(75) }
        }
        DispatchQueue.main.async {
          guard !completed.isFinished else { return }
          endpoint.restoreOwnedComposerClaims(request["ownedComposers"] as? [String:String] ?? [:])
          endpoint.handle(NativeAutomationRequest(method:method,arguments:arguments)) { result in
            guard completed.finishOnce() else { return }
            writer.emit(["id":id,"result":result ?? NSNull()])
          }
        }
      }
      // Parent pipe closed: do not leave an orphan able to click later.
      exit(0)
    }
    let port = Port()
    RunLoop.main.add(port,forMode:.default)
    withExtendedLifetime(port) { RunLoop.main.run() }
  }
}

private final class WorkerWriter {
  private let lock = NSLock()
  func emit(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object) else { exit(72) }
    lock.lock(); defer { lock.unlock() }
    do { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
    catch { exit(73) }
  }
}

private final class WorkerCompletion {
  private let lock = NSLock()
  private var finished = false
  var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
  func finishOnce() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !finished else { return false }
    finished = true
    return true
  }
}
