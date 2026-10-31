#!/usr/bin/env python3
"""Exercise actual request credential workflows with a synthetic vault boundary.

No Keychain, network, account restoration or personal AppStore initialization.
Only application dependencies are replaced; CloudAuthentication's method bodies
and the real settings/worker values are compiled unchanged.
"""
from pathlib import Path
import subprocess
import tempfile

from standalone_swift import source

PROJECT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
enum VaultFailure: Error { case locked }
@MainActor enum Keychain {
    static var accounts: [String] = []
    static var failure: Error?
    static var value = "synthetic-key"
    static func account(for settings: AppSettings) -> String { "cloud." + settings.cloudProvider }
    static func speechAccount(for settings: AppSettings) -> String { "speech." + settings.speechCloudProvider }
    static func readChecked(account: String) throws -> String {
        accounts.append(account)
        if let failure { throw failure }
        return value
    }
}
@MainActor final class ChatGPTAccount {
    struct Profile { let id: String }
    static let shared = ChatGPTAccount()
    var profile: Profile? = Profile(id: "fixture-account")
    var tokenAccounts: [String] = []
    func accessToken(expectedAccountID: String) async throws -> String {
        tokenAccounts.append(expectedAccountID)
        return "synthetic-session-token"
    }
    func signOut() async { profile = nil }
}
@MainActor final class SyntheticRunner { var cancelled = false; func cancel() { cancelled = true } }
@MainActor final class SyntheticJobs {
    var cancelledAccounts: [String] = []
    func cancelChatGPTAccount(_ id: String) async { cancelledAccounts.append(id) }
}
@MainActor final class AppStore {
    var isPreview = false
    var disconnectingChatGPTAccounts: Set<String> = []
    var cloudCheckAccountID: String?
    var knowledgeRebuildCloudAccountID: String?
    var cancellationRequested = false
    var cloudConnectionStatus: String?
    var rebuildCancelled = false
    let runner = SyntheticRunner()
    let jobs = SyntheticJobs()
    func cancelKnowledgeRebuildGeneration() { rebuildCancelled = true }
}
@main struct CredentialChecks {
    @MainActor static func main() async throws {
        let app = AppStore()
        var config = AppSettings()
        config.mode = "cloud"; config.cloudProvider = "openai"
        config.speechMode = "cloud"; config.speechCloudProvider = "openai"
        Keychain.failure = VaultFailure.locked
        do { _ = try await app.cloudCredential(for: config); preconditionFailure("Locked vault looked like an empty API key") }
        catch VaultFailure.locked {}
        do { _ = try app.speechCredential(for: config); preconditionFailure("Locked vault looked like an empty speech key") }
        catch VaultFailure.locked {}
        precondition(Keychain.accounts == ["cloud.openai", "speech.openai"])
        Keychain.failure = nil; Keychain.value = ""
        let absent = try await app.cloudCredential(for: config)
        precondition(absent.isEmpty, "A genuinely absent key remains distinct from a vault error")
        Keychain.value = "synthetic-key"
        let speech = try app.speechCredential(for: config)
        precondition(speech == "synthetic-key")
        let reads = Keychain.accounts.count
        config.speechMode = "local"
        let localSpeech = try app.speechCredential(for: config)
        precondition(localSpeech == nil)
        app.isPreview = true; config.speechMode = "cloud"
        let previewCloud = try await app.cloudCredential(for: config)
        precondition(previewCloud.isEmpty)
        let previewSpeech = try app.speechCredential(for: config)
        precondition(previewSpeech == nil)
        precondition(Keychain.accounts.count == reads, "Preview/local requests touched the vault")
        print("PASS: locked vault errors propagate; absent keys stay distinct; local/preview requests never read credentials")

        app.isPreview = false; config.cloudProvider = "chatgpt"
        config.chatGPTAccountID = "fixture-account"; config.cloudModel = "fixture-model"
        _ = try await app.cloudCredential(for: config)
        precondition(ChatGPTAccount.shared.tokenAccounts == ["fixture-account"])
        precondition(Keychain.accounts.count == reads, "Subscription request used API-key credentials")
        app.disconnectingChatGPTAccounts.insert("fixture-account")
        do { _ = try await app.cloudCredential(for: config); preconditionFailure("Disconnecting account supplied another token") }
        catch is AppError {}
        precondition(ChatGPTAccount.shared.tokenAccounts.count == 1)
        app.disconnectingChatGPTAccounts.removeAll()
        app.cloudCheckAccountID = "different-account"
        app.knowledgeRebuildCloudAccountID = "fixture-account"
        await app.disconnectChatGPTAccount(.shared)
        precondition(app.cancellationRequested && app.runner.cancelled && app.rebuildCancelled)
        precondition(app.jobs.cancelledAccounts == ["fixture-account"])
        precondition(ChatGPTAccount.shared.profile == nil)
        print("PASS: subscription keeps its selected account; disconnect refuses new credentials and cancels owned work")
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="posle-credential-check-", dir="/private/tmp") as temporary:
        root = Path(temporary)
        workflow = source(PROJECT / "Sources/AfterApp/CloudAuthentication.swift")
        workflow = workflow.replace("import AfterPlatformMacOS\n", "")
        swift = root / "checks.swift"
        contracts = source(PROJECT / "Sources/AfterPlatform/WorkerContracts.swift")
        app_error = contracts[contracts.index("enum AppError:"):contracts.index("struct InstalledLocalModel:")]
        swift.write_text("import Foundation\n" + app_error + workflow + FIXTURE)
        executable = root / "checks"
        subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(root / "module-cache"),
                        *sorted((PROJECT / "Sources/AfterCore").glob("*.swift")),
                        str(PROJECT / "scripts/fixtures/CanonicalLocalization.swift"), str(swift),
                        "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
