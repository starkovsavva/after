#if DEBUG
import Foundation
import PosleCore

/// Only disposable data and the real local Rust review command. No models,
/// Keychain, clipboard, calendar, network or capture permissions are used.
@MainActor
enum JobNativeChecks {
    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = environment["POSLE_DATA_DIR"],
              let engine = environment["POSLE_RUST_ENGINE"],
              FileManager.default.isExecutableFile(atPath: engine) else {
            throw AppError.message("Job checks require --preview, POSLE_RUST_ENGINE and a disposable data directory")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Refusing a non-disposable library")
        let store = AppStore(preview: true)
        try expect(store.meetings.isEmpty, "Job checks require an empty library")
        let first = Meeting(title: "Обсуждение поставки", source: "fixture.wav")
        let second = Meeting(title: "Планирование запуска", source: "fixture.wav")
        let bridge = try RustBridge.shared.get()
        for meeting in [first, second] {
            try FileManager.default.createDirectory(at: store.meetingDirectory(meeting.id), withIntermediateDirectories: true)
            try store.write(meeting, store.meetingDirectory(meeting.id).appendingPathComponent("meta.json"))
            let summary: [String: Any] = ["overview": "Срок поставки согласован.", "items": [],
                "cards": [["id": "follow-up", "kind": "phrase", "front": "follow up", "back": "Уточнить результат",
                           "context": "Please follow up tomorrow.", "segmentIDs": [0]]],
                "provider": "local", "model": "fixture", "generatedAt": 1, "warnings": []]
            _ = try bridge.request(root: root, command: "write", arguments: ["path": "meetings/\(meeting.id)/summary.json", "value": summary])
        }
        store.reloadLibrary(); store.selection = first.id; store.loadSelection()
        guard let card = store.summary?.cards.first else { throw AppError.message("Fixture card missing") }
        store.rate(card, 3)
        try expect(store.busy && store.processingID == first.id, "A job must reserve the busy state before returning to the event loop")
        store.rate(card, 3)
        store.installRuntime(); store.discoverASRModels(); store.discoverGGUFModels()
        try await waitUntil { !store.busy }
        try expect(store.error == nil && store.reviews[card.id]?.count == 1, "A double click must record exactly one review and block other operations")
        print("PASS: same-turn duplicate clicks record one real Rust review")

        store.rate(card, 3)
        store.selection = second.id; store.tab = "notes"; store.loadSelection()
        try await waitUntil { !store.busy }
        let saved: [String: ReviewState]? = store.read(store.meetingDirectory(first.id).appendingPathComponent("review-state.json"))
        try expect(saved?[card.id]?.count == 2, "A running review must finish in its original meeting")
        try expect(store.selection == second.id && store.tab == "notes" && store.reviews.isEmpty, "Completion must not overwrite the newly selected meeting")
        print("PASS: navigation during a job preserves its original destination")

        let actions: [() -> Void] = [
            { store.rate(card, 3) }, { store.makeExample(card) }, { store.summarizeSelected() },
            { store.ollama("check") }, { store.discoverLocalModels() },
            { store.discoverGGUFModels() }, { store.discoverASRModels() }
        ]
        for action in actions {
            action()
            try expect(store.busy && store.canCancelJob, "Async action must reserve its job synchronously")
            store.cancelJob()
            try await waitUntil { !store.busy }
            try expect(!store.canCancelJob && store.processingID == nil, "Cancellation must release shared job state")
        }
        let cancelled: [String: ReviewState]? = store.read(store.meetingDirectory(second.id).appendingPathComponent("review-state.json"))
        try expect(cancelled == nil, "Cancellation before execution must not change review history")
        print("PASS: seven operations support immediate cancellation without starting models or downloads")

        var missing = card; missing.id = "missing-card"
        store.rate(missing, 3)
        try await waitUntil { !store.busy }
        try expect(store.error != nil && !store.canCancelJob, "Worker failure must release job state")
        store.rate(card, 4)
        try await waitUntil { !store.busy }
        try expect(store.error == nil && store.reviews[card.id]?.count == 1, "A failed operation must allow a clean retry")
        print("PASS: worker failure and cancellation allow a successful retry")
        appMetadataRace(store: store, meetingID: first.id)
        let committed: Meeting? = store.read(store.meetingDirectory(first.id).appendingPathComponent("meta.json"))
        try expect(committed?.title == "Название после правки" && committed?.source == "committed.mp3" && committed?.hasVideo == true,
                   "UI metadata changes must preserve fields committed by a worker after the UI read")
        print("PASS: native metadata patch preserves a concurrent worker's source and video fields")
        print("5 native adversarial job checks passed")
    }
    private static func appMetadataRace(store: AppStore, meetingID: String) {
        store.updateMeeting(meetingID) { value in
            // Reproduce the read/modify/write interleaving deterministically.
            let url = store.meetingDirectory(meetingID).appendingPathComponent("meta.json")
            guard var worker: Meeting = store.read(url) else { return }
            worker.source = "committed.mp3"; worker.hasVideo = true
            do { try store.write(worker, url) } catch { store.error = error.localizedDescription; return }
            value.title = "Название после правки"
        }
    }
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Native job check timed out")
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AppError.message(message) }
    }
}
#endif
