import Foundation
import Darwin

/// Fault-injection helper: never imports AppKit/AX and cannot operate JD.
@main struct FakeUiWorker {
  static func main() {
    while let line = readLine() {
      let request = try! JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
      let args = request["arguments"] as! [String:Any]
      func emit(_ value: [String:Any]) {
        let data = try! JSONSerialization.data(withJSONObject:value)
        FileHandle.standardOutput.write(data + Data([10]))
      }
      emit(["event":"diagnostic","payload":["event":"fake_received",
        "pid":Int(getpid()),"customer":args["expectedCustomer"] ?? ""]])
      if args["reply"] as? String == "hang" {
        emit(["event":"ownedComposers","payload":["claims":["A":"owned text"]]])
        // A late effect would happen if the supervisor merely unlocked.
        Thread.sleep(forTimeInterval:1.0)
        emit(["event":"diagnostic","payload":["event":"unsafe_late_effect"]])
        Thread.sleep(forTimeInterval:30)
      }
      emit(["id":request["id"]!,"result":["opened":true,
        "customer":args["expectedCustomer"] ?? "", "pid":Int(getpid()),
        "carriedClaims": request["ownedComposers"] ?? [:]]])
    }
  }
}
