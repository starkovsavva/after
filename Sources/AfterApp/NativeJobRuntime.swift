import AfterPlatform
import AfterCore
import AfterPlatformMacOS
import AfterLocalization
import Foundation

/// One actor owns this bridge. State is opaque, transient and never Codable or
/// written to disk. Rust decisions are interpreted serially before the next event.
struct NativeJobRuntime {
    let root: URL
    private var state: [String: Any] = [:]
    init(root: URL) { self.root = root }
    var stopping: Bool { state["stopping"] as? Bool == true }
    // Host transport failures must fail closed even when Rust is unreachable.
    mutating func transportFailed() { state["halted"] = true }
    mutating func shutdownUnreachable() { state["stopping"] = true; transportFailed() }

    struct Key: Decodable { let jobID: String; let attempt: Int }
    struct Claim: Decodable { let allowedResources: [String]; let excludedAccounts: [String] }
    struct Discard: Decodable { let kind: String; let states: [String] }
    struct Update: Decodable {
        let jobID: String
        let expectedAttempt: Int
        let state: String
        let progress: Double?
        let message: String?
        var arguments: [String: Any] {
            var value: [String: Any] = ["jobID": jobID, "expectedAttempt": expectedAttempt, "state": state]
            if let progress { value["progress"] = progress }
            if let message { value["message"] = L(message) }
            return value
        }
    }
    struct Decision: Decodable {
        let accepted: Bool
        let recover: Bool
        let discard: Discard?
        let claim: Claim?
        let update: Update?
        let cancel: [Key]
        let deliverCancelled: Bool
    }
    mutating func transition(_ event: [String: Any]) throws -> Decision {
        let data = try RustBridge.shared.get().request(root: root, command: "job-runtime-event", arguments: ["runtime": state, "event": event])
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nextState = response["runtime"] as? [String: Any], let decision = response["decision"] else {
            throw AppError.message(L("Некорректный ответ Rust-ядра"))
        }
        let decoded = try JSONDecoder().decode(Decision.self, from: JSONSerialization.data(withJSONObject: decision))
        state = nextState
        return decoded
    }
}
