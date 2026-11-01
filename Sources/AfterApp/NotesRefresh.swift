import AfterPlatformMacOS
import Foundation
import AfterCore

/// Navigation reads never hold the main actor while waiting for the workspace
/// lock or scanning summaries. One shared refresh keeps cached content usable.
struct NotesRefreshSnapshot {
    let workspace: NotesWorkspace
    var tasks: [LibraryTask]?
    var taskWorkspaces: [String: TaskWorkspace]?

    static func load(root: URL, includeTasks: Bool, selectedTaskID: String?) throws -> Self {
        let bridge = try RustBridge.shared.get()
        let workspace = try JSONDecoder().decode(NotesWorkspace.self, from: bridge.request(root: root, command: "notes-list"))
        guard includeTasks else { return Self(workspace: workspace) }
        let tasks = try JSONDecoder().decode(LibraryTasksResponse.self, from: bridge.request(root: root, command: "notes-tasks")).tasks
        let metadata = try JSONDecoder().decode(TaskWorkspacesResponse.self, from: bridge.request(root: root, command: "task-list", arguments: ["includeDetails": false]))
        var details = Dictionary(uniqueKeysWithValues: metadata.tasks.map { ($0.id, $0) })
        if let selectedTaskID {
            let canonical = tasks.first { $0.id == selectedTaskID || $0.noteID == selectedTaskID || $0.taskOrigin?.summaryTaskID == selectedTaskID }?.id ?? selectedTaskID
            // A task can disappear between the list and detail read. Keep the
            // list authoritative; a stale selection must not fail the refresh.
            if let data = try? bridge.request(root: root, command: "task-get", arguments: ["taskID": canonical]),
               let detail = try? JSONDecoder().decode(TaskWorkspace.self, from: data) { details[detail.id] = detail }
        }
        return Self(workspace: workspace, tasks: tasks, taskWorkspaces: details)
    }
}

@MainActor
final class NotesRefreshState {
    var revision: UInt64 = 0
    var task: Task<Void, Never>?
    var includesTasks = false
    var pendingTasks = false
    var selectedTaskID: String?
    var lastError: String?
    var load: @Sendable (URL, Bool, String?) throws -> NotesRefreshSnapshot = NotesRefreshSnapshot.load
}

extension NotesStore {
    /// Concurrent tabs await the same read. If a local edit wins the race, read
    /// again instead of publishing an obsolete snapshot over the saved edit.
    func refresh(includeTasks: Bool = false) async {
        let state = refreshState
        if let running = state.task {
            if includeTasks && (!state.includesTasks || state.selectedTaskID != selectedTaskID) { state.pendingTasks = true }
            await running.value
            return
        }
        state.pendingTasks = includeTasks
        let operation = Task { [weak self] in
            guard let self else { return }
            var retry = false
            repeat {
                let withTasks = state.pendingTasks
                state.pendingTasks = false; state.includesTasks = withTasks
                let revision = state.revision
                let root = self.root, selected = self.selectedTaskID, load = state.load
                state.selectedTaskID = selected
                retry = false
                do {
                    let snapshot = try await Task.detached(priority: .userInitiated) {
                        try load(root, withTasks, selected)
                    }.value
                    if state.revision != revision {
                        retry = true; state.pendingTasks = state.pendingTasks || withTasks
                    } else {
                        if let previous = state.lastError, self.error == previous { self.error = nil }; state.lastError = nil
                        if self.workspace != snapshot.workspace { self.workspace = snapshot.workspace }
                        if let tasks = snapshot.tasks, self.tasks != tasks { self.tasks = tasks; self.reconcileTaskDrafts() }
                        if let workspaces = snapshot.taskWorkspaces, self.taskWorkspaces != workspaces { self.taskWorkspaces = workspaces }
                    }
                } catch {
                    if state.revision == revision { state.lastError = error.localizedDescription; self.error = error.localizedDescription }
                    else { retry = true; state.pendingTasks = state.pendingTasks || withTasks }
                }
            } while retry || state.pendingTasks
            state.includesTasks = false; state.selectedTaskID = nil; state.task = nil
        }
        state.task = operation
        await operation.value
    }
}
