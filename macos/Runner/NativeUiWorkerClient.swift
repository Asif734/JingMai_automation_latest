import Foundation
import Darwin

/// State and watchdogs never share the queue that runs AX. The child owns all
/// mutating AX work and can be reaped even when its AX queue never returns.
final class NativeUiWorkerClient {
  init(executableURL: URL? = nil) { self.executableURL = executableURL }
  private let executableURL: URL?
  var onEvent: ((String, [String: Any]) -> Void)?
  private let state = DispatchQueue(label: "jd.ui-worker.supervisor")
  private let writes = DispatchQueue(label: "jd.ui-worker.pipe-writes")
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var errors: FileHandle?
  private var buffer = Data()
  private var generation = UUID().uuidString
  private var stopping = false
  private var leases: [String: Double] = [:]
  private var pending: [Request] = []
  private var active: Request?
  private var timer: DispatchSourceTimer?
  private var stopWaiters: [() -> Void] = []
  private var ownedComposerClaims: [String: String] = [:]
  private var cachedStatus: [String: Any] = [:]
  private var stopReason = "worker_exit"
  struct Request {
    let id: String, operation: String, method: String
    let arguments: [String: Any]
    let deadline: Double
    let completion: (Any?) -> Void
  }

  private func finish(_ completion: @escaping (Any?) -> Void, _ value: Any?) {
    DispatchQueue.main.async { completion(value) }
  }
  func inspectStatus(completion: @escaping (Any?) -> Void) {
    state.async {
      if self.active != nil || self.stopping {
        self.finish(completion,self.cachedStatus.merging(["available": self.process != nil]) { _, new in new })
      } else {
        self.invoke("workerStatus",arguments:[:]) { value in
          let status = value as? [String:Any] ?? [:]
          self.state.async { self.cachedStatus = status }
          self.finish(completion,status)
        }
      }
    }
  }
  func begin(_ args: [String: Any], completion: @escaping (Any?) -> Void) {
    state.async {
      guard let id = args["operationId"] as? String, !id.isEmpty,
            let deadline = args["deadlineMs"] as? Double,
            deadline > Date().timeIntervalSince1970 * 1000,
            deadline < Date().addingTimeInterval(120).timeIntervalSince1970 * 1000 else {
        self.finish(completion,["error":"invalid_ui_operation"]); return
      }
      self.leases[id] = deadline
      self.finish(completion,["registered":true,"operationId":id])
    }
  }
  func end(_ args: [String: Any], completion: @escaping (Any?) -> Void) {
    // Revocation also fences unawaited/late native requests from a finished job.
    cancel(args, completion: completion)
  }
  func cancel(_ args: [String: Any], completion: @escaping (Any?) -> Void) {
    state.async {
      guard let id = args["operationId"] as? String, !id.isEmpty else {
        self.finish(completion,["error":"invalid_ui_operation"]); return
      }
      self.leases.removeValue(forKey:id)
      let removed = self.pending.filter { $0.operation == id }
      self.pending.removeAll { $0.operation == id }
      for request in removed { self.finish(request.completion,["error":"ui_operation_cancelled"]) }
      let acknowledge = { self.finish(completion,["stopped":true,"operationId":id]) }
      if self.active?.operation == id {
        self.stopWaiters.append(acknowledge)
        self.stopWorker(reason:"ui_operation_cancelled")
      } else if self.stopping {
        self.stopWaiters.append(acknowledge)
      } else { acknowledge() }
    }
  }
  func invoke(_ method: String, arguments: [String: Any], completion: @escaping (Any?) -> Void) {
    state.async {
      let now = Date().timeIntervalSince1970 * 1000
      let scope = arguments["uiOperationId"] as? String
      if let scope, !(self.leases[scope].map { $0 > now } ?? false) {
        self.finish(completion,["error":"ui_operation_cancelled"]); return
      }
      let limit = method == "workerStatus" ? 3000.0 : method == "sendDraftOnce" ? 15000.0 :
        method == "openConversation" ? 10000.0 : 25000.0
      let requested = (arguments["operationDeadlineMs"] as? Double) ?? now + limit
      let deadline = min(now + limit, requested, scope.flatMap { self.leases[$0] } ?? now + limit)
      let request = Request(id:UUID().uuidString,operation:scope ?? UUID().uuidString,
        method:method,arguments:arguments,deadline:deadline,completion:completion)
      self.pending.append(request)
      self.pump()
    }
  }
  private func pump() {
    guard active == nil, !stopping else { return }
    while !pending.isEmpty {
      let next = pending.removeFirst()
      let now = Date().timeIntervalSince1970 * 1000
      if next.deadline <= now ||
          (next.arguments["uiOperationId"] != nil && leases[next.operation] == nil) {
        finish(next.completion,["error":"operation_expired"]); continue
      }
      do { try startWorker() } catch {
        finish(next.completion,["error":"ui_worker_unavailable","message":error.localizedDescription]); continue
      }
      active = next
      let timer = DispatchSource.makeTimerSource(queue:state)
      timer.schedule(deadline:.now() + max(0.01,(next.deadline - now)/1000))
      timer.setEventHandler { [weak self] in self?.stopWorker(reason:"native_worker_timeout") }
      self.timer = timer; timer.resume()
      var args = next.arguments
      args["operationDeadlineMs"] = next.deadline
      // Exact insertion claims are emitted only after AX insertion succeeds.
      // A replacement helper may clean only the same text under the same owner.
      let payload: [String:Any] = ["version":1,"id":next.id,"method":next.method,
        "arguments":args,"deadlineMs":next.deadline,"ownedComposers":ownedComposerClaims]
      guard let data = try? JSONSerialization.data(withJSONObject:payload), let input else {
        stopWorker(reason:"native_worker_protocol_error"); return
      }
      let workerGeneration = generation
      writes.async { [weak self] in
        do { try input.write(contentsOf:data + Data([10])) }
        catch { self?.state.async {
          guard self?.generation == workerGeneration, self?.active?.id == next.id else { return }
          self?.stopWorker(reason:"native_worker_pipe_failed")
        } }
      }
      return
    }
  }
  private func startWorker() throws {
    if process != nil { return }
    let helper = executableURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/JDUiWorker")
    guard FileManager.default.isExecutableFile(atPath:helper.path) else {
      throw NSError(domain:"JDUiWorker",code:1,userInfo:[NSLocalizedDescriptionKey:"The bundled UI helper is missing. Rebuild the complete app; no in-process UI fallback is allowed."])
    }
    let child = Process()
    child.executableURL = helper
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
    generation = UUID().uuidString
    let token = generation
    output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
    buffer.removeAll(keepingCapacity:true)
    output?.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      self?.state.async { self?.received(data,generation:token) }
    }
    errors?.readabilityHandler = { handle in
      if handle.availableData.isEmpty { handle.readabilityHandler = nil }
    }
    child.terminationHandler = { [weak self] _ in
      self?.state.async { self?.workerExited(generation:token) }
    }
    process = child; input = stdin.fileHandleForWriting
    do { try child.run() } catch {
      output?.readabilityHandler = nil; errors?.readabilityHandler = nil
      process = nil; input = nil; output = nil; errors = nil
      throw error
    }
  }
  private func received(_ data: Data, generation token: String) {
    guard token == generation else { return }
    var searchFrom = buffer.count
    buffer.append(data)
    guard buffer.count < 48 * 1024 * 1024 else { stopWorker(reason:"native_worker_response_too_large"); return }
    while let newline = buffer.dropFirst(searchFrom).firstIndex(of:10) {
      let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
      searchFrom = 0
      guard let json = (try? JSONSerialization.jsonObject(with:line)) as? [String:Any] else {
        stopWorker(reason:"native_worker_protocol_error"); return
      }
      if let event = json["event"] as? String, let payload = json["payload"] as? [String:Any] {
        if event == "ownedComposers", let claims = payload["claims"] as? [String:String] {
          ownedComposerClaims = claims
        } else { onEvent?(event,payload) }
        continue
      }
      guard !stopping, let current = active, json["id"] as? String == current.id else { continue }
      timer?.cancel(); timer = nil; active = nil
      finish(current.completion,json["result"])
      pump()
    }
  }
  private func stopWorker(reason: String) {
    guard !stopping else { return }
    timer?.cancel(); timer = nil
    stopping = true
    stopReason = reason
    if let child = process, child.isRunning {
      // Never signal JD, a process name, or a reused arbitrary PID. This is
      // the Process object we created and still own; no next job until reaped.
      kill(child.processIdentifier,SIGKILL)
    } else { workerExited(generation:generation) }
  }
  private func workerExited(generation token: String) {
    guard token == generation else { return }
    timer?.cancel(); timer = nil
    output?.readabilityHandler = nil; errors?.readabilityHandler = nil
    try? input?.close(); try? output?.close(); try? errors?.close()
    process = nil; input = nil; output = nil; errors = nil
    stopping = false
    let stoppedRequest = active
    if let current = active {
      active = nil
      let code = current.method == "sendDraftOnce" ? "send_unconfirmed" :
        current.method == "transferConversation" ? "transfer_unconfirmed" : "native_worker_restarted"
      finish(current.completion,["error":code,
        "message":"The isolated UI helper stopped. Durable work is retained; any send must be reconciled before retrying."])
    }
    let waiters = stopWaiters; stopWaiters.removeAll()
    for waiter in waiters { waiter() }
    onEvent?("diagnostic",["event":"ui.worker_reaped","reason":stopReason,"no_jd_restart":true,
      "operationId":stoppedRequest?.operation ?? "", "method":stoppedRequest?.method ?? "",
      "expectedCustomer":stoppedRequest?.arguments["expectedCustomer"] ?? ""])
    pump()
  }
  deinit {
    timer?.cancel()
    output?.readabilityHandler = nil; errors?.readabilityHandler = nil
    if let child = process, child.isRunning { kill(child.processIdentifier,SIGKILL) }
  }
}
