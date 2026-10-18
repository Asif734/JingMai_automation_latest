import Foundation
import Darwin

@main struct SupervisorCheck {
  static func main() {
    precondition(CommandLine.arguments.count == 2)
    let client = NativeUiWorkerClient(executableURL:URL(fileURLWithPath:CommandLine.arguments[1]))
    let lock = NSLock()
    var oldPID: Int32 = 0, lateEffect = false
    client.onEvent = { _, value in
      lock.lock(); defer { lock.unlock() }
      if value["event"] as? String == "fake_received", value["customer"] as? String == "A" {
        oldPID = Int32(value["pid"] as! Int)
      }
      if value["event"] as? String == "unsafe_late_effect" { lateEffect = true }
    }
    let deadline = Date().addingTimeInterval(5).timeIntervalSince1970 * 1000
    client.begin(["operationId":"A","deadlineMs":deadline]) { value in
      precondition((value as! [String:Any])["registered"] as? Bool == true)
      client.invoke("sendDraftOnce",arguments:["uiOperationId":"A","expectedCustomer":"A","reply":"hang"]) { result in
        precondition((result as! [String:Any])["error"] as? String == "send_unconfirmed")
      }
      var attempts = 0
      func cancelAfterWorkerEntered() {
        lock.lock(); let started = oldPID > 0; lock.unlock()
        if !started {
          attempts += 1
          precondition(attempts < 150,"Fake worker never entered the hung request")
          DispatchQueue.main.asyncAfter(deadline:.now() + 0.02) { cancelAfterWorkerEntered() }
          return
        }
        client.cancel(["operationId":"A"]) { value in
          precondition((value as! [String:Any])["stopped"] as? Bool == true)
          lock.lock(); let pid = oldPID; lock.unlock()
          let exists = kill(pid,0); let resultError = errno
          precondition(pid > 0 && exists == -1 && resultError == ESRCH,
            "Cancellation acknowledged before the old process was reaped (pid=\(pid),kill=\(exists),errno=\(resultError))")
          client.invoke("openConversation",arguments:["expectedCustomer":"B"]) { value in
            let result = value as! [String:Any]
            precondition(result["customer"] as? String == "B")
            precondition(result["pid"] as? Int != Int(pid))
            precondition((result["carriedClaims"] as? [String:String])?["A"] == "owned text")
            client.invoke("openConversation",arguments:["uiOperationId":"A","expectedCustomer":"A"]) { value in
              precondition((value as! [String:Any])["error"] as? String == "ui_operation_cancelled")
              // A new hang is recovered by the independent native deadline,
              // without the Dart scheduler even asking for cancellation.
              client.invoke("sendDraftOnce",arguments:["expectedCustomer":"A","reply":"hang",
                "operationDeadlineMs":Date().addingTimeInterval(0.2).timeIntervalSince1970 * 1000]) { value in
                precondition((value as! [String:Any])["error"] as? String == "send_unconfirmed")
                client.invoke("openConversation",arguments:["expectedCustomer":"C"]) { value in
                  precondition((value as! [String:Any])["customer"] as? String == "C")
                  lock.lock(); let unsafe = lateEffect; lock.unlock()
                  precondition(!unsafe,"Timed-out worker executed a late effect")
                  print("Isolated UI supervisor: cancellation/reaping, restart, late-job rejection, composer ownership, deadline recovery, and next-customer progress passed; no UI operations.")
                  exit(0)
                }
              }
            }
          }
        }
      }
      cancelAfterWorkerEntered()
    }
    DispatchQueue.global().asyncAfter(deadline:.now() + 8) {
      fatalError("Supervisor test hung")
    }
    let port = Port(); RunLoop.main.add(port,forMode:.default)
    withExtendedLifetime(client) { RunLoop.main.run() }
  }
}
