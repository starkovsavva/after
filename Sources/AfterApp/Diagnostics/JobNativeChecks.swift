import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import Foundation
import AfterCore

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
            let transcript = Transcript(duration: 5, segments: [Segment(id: 0, start: 0, end: 5, speaker: "speaker_1", text: "Please follow up tomorrow.")], warnings: [], model: "fixture")
            try store.write(transcript, store.meetingDirectory(meeting.id).appendingPathComponent("transcript.json"))
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
            { store.rate(card, 3) },
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
        print("PASS: five exclusive maintenance/review operations support immediate cancellation without starting models or downloads")

        // Local inference is paused behind a synthetic recording admission gate.
        // This enqueues the real operations without starting a model or server.
        store.jobs.setRecording(true)
        let firstSummaryURL = store.meetingDirectory(first.id).appendingPathComponent("summary.json")
        let secondSummaryURL = store.meetingDirectory(second.id).appendingPathComponent("summary.json")
        let firstBefore = try Data(contentsOf: firstSummaryURL)
        let secondBefore = try Data(contentsOf: secondSummaryURL)
        store.selection = first.id; store.loadSelection()
        store.makeExample(card)
        try expect(!store.busy, "Queued generation must not reserve the global UI busy flag")
        try await waitUntil { store.jobs.jobs.contains { $0.kind == "example" && $0.objectID == first.id && $0.active } }
        store.selection = second.id; store.loadSelection(); store.tab = "notes"
        store.summarizeSelected()
        try expect(!store.busy && store.selection == second.id && store.tab == "notes", "A second meeting must remain navigable while generation is queued")
        // activeCount includes pending submitters before SQLite admission has
        // published its rows on MainActor. Await the actual persisted targets,
        // not that earlier activity reservation.
        try await waitUntil {
            store.jobs.jobs.contains { $0.kind == "example" && $0.objectID == first.id && $0.state == "queued" }
                && store.jobs.jobs.contains { $0.kind == "summarize" && $0.objectID == second.id && $0.state == "queued" }
                && store.jobs.activeCount == 2
        }
        guard let exampleJob = store.jobs.jobs.first(where: { $0.kind == "example" && $0.objectID == first.id }),
              let summaryJob = store.jobs.jobs.first(where: { $0.kind == "summarize" && $0.objectID == second.id }) else {
            throw AppError.message("Two distinct queued generation attempts required")
        }
        try expect(exampleJob.id != summaryJob.id, "Distinct meeting operations must retain independent durable identities")
        store.jobs.cancel(exampleJob.id)
        try await waitUntil { store.jobs.jobs.contains { $0.id == exampleJob.id && $0.state == "cancelled" } }
        try expect(store.jobs.jobs.contains { $0.id == summaryJob.id && $0.active }, "Cancelling one meeting's example must leave the other meeting's summary queued")
        try expect(store.selection == second.id && store.tab == "notes" && !store.busy, "Per-job cancellation must not navigate or block the current meeting")
        store.jobs.cancel(summaryJob.id)
        try await waitUntil { store.jobs.activeCount == 0 }
        store.jobs.setRecording(false)
        let firstAfter = try Data(contentsOf: firstSummaryURL)
        let secondAfter = try Data(contentsOf: secondSummaryURL)
        try expect(firstAfter == firstBefore && secondAfter == secondBefore, "Cancelling queued operations must preserve both original summaries")
        try expect(!FileManager.default.fileExists(atPath: store.meetingDirectory(first.id).appendingPathComponent("examples.json").path),
                   "A cancelled queued example must not publish a result")
        print("PASS: two meeting jobs remain independent; per-job cancellation preserves navigation, both sources and the surviving queued operation")

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
        print("6 native adversarial job checks passed")
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
