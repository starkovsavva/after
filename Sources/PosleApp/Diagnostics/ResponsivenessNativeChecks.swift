#if DEBUG
import Foundation
import PosleCore

@MainActor
enum ResponsivenessNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"],
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Responsiveness checks require an isolated preview library")
        }
        let app = AppStore(preview: true), notes = app.notes
        guard let original = notes.capture(text: "Сохранённая мысль") else { throw AppError.message("Cannot seed responsiveness note") }
        let gate = ReadGate()
        notes.refreshState.load = { root, tasks, selected in
            let snapshot = try NotesRefreshSnapshot.load(root: root, includeTasks: tasks, selectedTaskID: selected)
            gate.afterRead()
            return snapshot
        }
        notes.captureDrafts["inbox"] = "Мысль во время загрузки"
        let requests = (0..<30).map { _ in Task { await notes.refresh(includeTasks: true) } }
        try await wait { gate.started }
        // The disk read is deliberately held on its worker. MainActor work and
        // navigation must complete before the worker is released.
        let heartbeat = Task { @MainActor in
            for section in ["tasks", "inbox", "calendar", "contexts", "meetings"] { app.librarySection = section }
            return app.librarySection
        }
        try expect(await heartbeat.value == "meetings" && !gate.released, "Navigation must run while a workspace read is blocked")
        try expect(notes.notes.contains(where: { $0.id == original.id }) && notes.captureDrafts["inbox"] == "Мысль во время загрузки", "Cached content and typed drafts must stay usable during refresh")
        guard let savedDuringRead = notes.capture(text: "Новая правка во время чтения") else { throw AppError.message("Cannot save during read") }
        gate.release()
        for request in requests { await request.value }
        try expect(gate.readCount == 2, "Thirty concurrent navigation requests must coalesce; only the raced local write requires one reread")
        try expect(notes.notes.contains(where: { $0.id == savedDuringRead.id }), "A delayed snapshot must never overwrite a successful local edit")
        try expect(notes.captureDrafts["inbox"] == "Мысль во время загрузки", "Publishing refreshed content must retain drafts")
        print("PASS: MainActor navigation/heartbeat and cached notes stay usable during a blocked read; 30 requests coalesce and a local write wins the stale-read race")

        let upgrade = ReadGate()
        notes.refreshState.load = { root, tasks, selected in
            let snapshot = try NotesRefreshSnapshot.load(root: root, includeTasks: tasks, selectedTaskID: selected)
            upgrade.afterRead()
            return snapshot
        }
        let first = Task { await notes.refresh() }
        try await wait { upgrade.started }
        let second = Task { await notes.refresh(includeTasks: true) }
        await Task.yield(); upgrade.release()
        await first.value; await second.value
        try expect(upgrade.readCount == 2 && notes.refreshState.task == nil, "A task-list request upgrades the shared read and all callers await completion")
        print("PASS: a pending task request upgrades one notes-only refresh without leaving background work after callers return")

        let saved = notes.workspace
        notes.refreshState.load = { _, _, _ in throw AppError.message("Synthetic unavailable workspace") }
        await notes.refresh(includeTasks: true)
        try expect(notes.workspace == saved && notes.error == "Synthetic unavailable workspace" && notes.refreshState.task == nil, "Read failure preserves usable data and releases the refresh gate")
        notes.refreshState.load = NotesRefreshSnapshot.load
        await notes.refresh(includeTasks: true)
        try expect(notes.workspace == saved && notes.error == nil && notes.refreshState.task == nil, "A failed refresh must remain retryable and clear only its own error")
        notes.captureDrafts = [:]; _ = notes.flushCaptureDrafts()
        print("PASS: failed reads preserve cached data and the next navigation can retry")
        print("3 native responsiveness checks passed (synthetic data, no accounts or models)")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw AppError.message("Responsiveness fixture did not reach its read gate")
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
    private final class ReadGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var count = 0
        private var open = false
        var started: Bool { condition.lock(); defer { condition.unlock() }; return count > 0 }
        var released: Bool { condition.lock(); defer { condition.unlock() }; return open }
        var readCount: Int { condition.lock(); defer { condition.unlock() }; return count }
        func afterRead() {
            condition.lock(); defer { condition.unlock() }; count += 1
            while !open { condition.wait() }
        }
        func release() { condition.lock(); open = true; condition.broadcast(); condition.unlock() }
    }
}
#endif
