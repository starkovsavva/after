#if DEBUG
import AfterPlatform
import AfterPlatformMacOS
import Foundation
import AfterCore

/// Runs the production AppStore → worker → loopback provider → preview path.
/// The parent harness owns the provider and its synthetic request barrier.
@MainActor
enum KnowledgeRebuildGenerationNativeChecks {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = env["POSLE_DATA_DIR"], let endpoint = env["POSLE_NATIVE_REBUILD_ENDPOINT"],
              let url = URL(string: endpoint), url.host == "127.0.0.1", url.scheme == "http" else {
            throw AppError.message("Production rebuild checks require an owned loopback fixture")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path), root.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Production rebuild checks require an isolated synthetic library")
        }
        let store = AppStore(preview: true)
        store.settings.mode = "local"; store.settings.localProvider = "lmstudio"
        store.settings.localEndpoint = endpoint; store.settings.localModel = "test-model"
        store.settings.features.knowledgeBase = true
        guard let note = store.notes.save(CapturedNote(id: "native-selected", text: "Pilot budget is 42. Do not change the recorded amount.", title: "Pilot")),
              store.notes.save(CapturedNote(id: "native-private", text: "UNSELECTED_NATIVE_PRIVATE_MARKER", title: "Not selected")) != nil else {
            throw AppError.message("Could not seed native rebuild fixtures")
        }
        let before = try RustBridge.shared.get().request(root: root, command: "notes-list")
        func generate(_ instruction: String) async throws -> KnowledgeRebuildPreview {
            let data = try await store.generateKnowledgeRebuild(noteIDs: [note.id], folderID: nil,
                instruction: instruction, event: { _ in })
            return try JSONDecoder().decode(KnowledgeRebuildPreview.self, from: data)
        }
        let preview = try await generate("Group the selected notes by project. Do not edit their text.")
        guard preview.draftRevision == 1, preview.proposal.hasChanges,
              !store.busy, store.knowledgeRebuildRunner == nil else { throw AppError.message("Production preview failed to release ownership") }
        guard try RustBridge.shared.get().request(root: root, command: "notes-list") == before else {
            throw AppError.message("Production generator changed notes before explicit Apply")
        }
        let started = root.appendingPathComponent("provider-started")
        try? FileManager.default.removeItem(at: started)
        let request = Task { try await generate("NATIVE_CANCEL: group selected notes after the controlled delay.") }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(12)
        while !FileManager.default.fileExists(atPath: started.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard FileManager.default.fileExists(atPath: started.path) else {
            request.cancel(); _ = try? await request.value
            throw AppError.message("Controlled provider never received the cancellation request")
        }
        request.cancel()
        do { _ = try await request.value; throw AppError.message("Cancelled generator returned a review") }
        catch is CancellationError {}
        guard !store.busy, store.knowledgeRebuildRunner == nil,
              !store.knowledgeRebuildOwnsLocalRuntime,
              try RustBridge.shared.get().request(root: root, command: "notes-list") == before else {
            throw AppError.message("Cancelled generator leaked ownership or changed notes")
        }
        _ = try await generate("Group selected notes again after cancellation.")
        struct History: Decodable { var operations: [KnowledgeRebuildHistory.Operation] }
        let history = try JSONDecoder().decode(History.self, from: RustBridge.shared.get().request(root: root, command: "kb-rebuild-history"))
        guard history.operations.isEmpty else { throw AppError.message("Generating a review auto-applied an operation") }
        print("PASS: production AppStore → worker → provider → typed preview; cancellation drains and retry succeeds; no automatic edits")
    }
}
#endif
