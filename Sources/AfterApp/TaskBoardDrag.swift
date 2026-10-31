import AfterLocalization
import AppKit
import Foundation
import AfterCore
import SwiftUI
import UniformTypeIdentifiers

/// A drag is a short-lived reference to one row, never a command or user text.
/// Only providers minted by this board instance can resolve the opaque token.
@MainActor
final class TaskBoardDragSession {
    static let type = UTType(exportedAs: "app.posle.task-board-reference", conformingTo: .data)
    private struct Reference: Codable, Equatable {
        let version: Int
        let libraryScope: String
        let nonce: String
        let taskID: String
        let revision: Int
        let sourceFingerprint: String
    }
    private struct Entry {
        let reference: Reference
        let task: TaskWorkspace
        let root: URL
        let folderID: String?
        let taskFolderID: String?
        let created: Date
    }
    private let libraryScope = UUID().uuidString
    private var entries: [String: Entry] = [:]
    private let lifetime: TimeInterval = 300
    private let maximumReferences = 128

    func provider(for task: TaskWorkspace, app: AppStore) -> NSItemProvider {
        prune()
        let reference = Reference(version: 1, libraryScope: libraryScope, nonce: UUID().uuidString,
                                  taskID: task.id, revision: task.revision, sourceFingerprint: task.sourceFingerprint)
        entries[reference.nonce] = Entry(reference: reference, task: task, root: app.root.standardizedFileURL,
                                       folderID: app.folderSelection, taskFolderID: taskFolder(task, app: app), created: Date())
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(reference) {
            provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
                completion(data, nil); return nil
            }
        }
        return provider
    }

    /// Called synchronously by SwiftUI's onDrop closure. Start loading while the
    /// native dragging session is still valid; only completion hops to MainActor.
    @discardableResult
    func receive(_ providers: [NSItemProvider], target: TaskWorkspaceStatus, app: AppStore,
                 completion: (@MainActor (Bool) -> Void)? = nil) -> Bool {
        guard providers.count == 1, let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(Self.type.identifier) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: Self.type.identifier) { [weak self, weak app] data, error in
            Task { @MainActor in
                guard let self, let app else { completion?(false); return }
                guard error == nil, let data else {
                    app.notes.error = L("Не удалось перенести задачу. Обновите доску и повторите."); completion?(false); return
                }
                completion?(self.apply(data, target: target, app: app))
            }
        }
        return true
    }
    private func apply(_ data: Data, target: TaskWorkspaceStatus, app: AppStore) -> Bool {
        prune()
        guard data.count <= 4096, let reference = try? JSONDecoder().decode(Reference.self, from: data),
              reference.version == 1, reference.libraryScope == libraryScope,
              let entry = entries.removeValue(forKey: reference.nonce), entry.reference == reference,
              entry.root == app.root.standardizedFileURL, entry.folderID == app.folderSelection,
              app.librarySection == "tasks", app.isFeatureEnabled(.tasks), !app.isTerminating,
              !app.notes.taskWorkspaceBusy else {
            app.notes.error = L("Перенос устарел. Перетащите задачу с текущей доски ещё раз."); return false
        }
        // task-get revalidates existence and virtual-source identity; the mutation
        // below repeats CAS and the live folder feature policy inside Rust's lock.
        app.notes.reload()
        guard let current = app.notes.loadTaskWorkspace(reference.taskID) else { return false }
        guard current.id == entry.task.id, current.revision == reference.revision,
              current.sourceFingerprint == reference.sourceFingerprint, current.status == entry.task.status,
              taskFolder(current, app: app) == entry.taskFolderID else {
            app.notes.error = L("Задача изменилась во время переноса. Обновите доску и повторите."); return false
        }
        if current.status == target { app.notes.error = nil; return true }
        guard let saved = app.notes.updateTaskWorkspace(entry.task, patch: ["status": target.rawValue], requireFeature: true, expectedFolderID: entry.taskFolderID) else { return false }
        app.reloadLibrary()
        if app.selection == saved.meetingID { app.refreshResults(saved.meetingID ?? "") }
        app.notes.notice = LF("Статус изменён: {0}", arguments: [L(target.title)])
        return true
    }
    private func taskFolder(_ task: TaskWorkspace, app: AppStore) -> String? {
        let noteID = app.notes.legacyTask(for: task)?.noteID ?? (task.id.hasPrefix("manual:") ? String(task.id.dropFirst("manual:".count)) : nil)
        if let noteID, let note = app.notes.workspace.notes.first(where: { $0.id == noteID }), let folderID = note.folderID { return folderID }
        return task.meetingID.flatMap { app.folderID(for: $0) }
    }
    private func prune() {
        let deadline = Date().addingTimeInterval(-lifetime)
        entries = entries.filter { $0.value.created >= deadline }
        if entries.count >= maximumReferences {
            let oldest = entries.sorted { $0.value.created < $1.value.created }.prefix(entries.count - maximumReferences + 1)
            for item in oldest { entries.removeValue(forKey: item.key) }
        }
    }
}

/// The native drag affordance describes a status move rather than a copy.
@MainActor
struct TaskBoardColumnDropDelegate: DropDelegate {
    let session: TaskBoardDragSession
    let status: TaskWorkspaceStatus
    let app: AppStore
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [TaskBoardDragSession.type.identifier])
        return providers.count == 1 && providers[0].hasItemConformingToTypeIdentifier(TaskBoardDragSession.type.identifier)
    }
    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
    }
    func dropExited(info: DropInfo) {
        isTargeted = false
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard validateDrop(info: info) else { return false }
        // Start the provider load within this native callback, before returning.
        return session.receive(info.itemProviders(for: [TaskBoardDragSession.type.identifier]), target: status, app: app)
    }
}
