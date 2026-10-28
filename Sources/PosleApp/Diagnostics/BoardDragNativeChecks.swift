#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Exercises the production onDrop receiver with real own-process NSItemProviders
/// and real Rust storage. It does not synthesize the macOS pointer drag session.
@MainActor
enum BoardDragNativeChecks {
    private final class ResultBox { var value: Bool? }
    private struct BoardRoot: View {
        @ObservedObject var app: AppStore
        @ObservedObject var notes: NotesStore
        let taskID: String
        let session: TaskBoardDragSession
        var body: some View {
            TaskBoardView(tasks: notes.taskWorkspaces.values.filter { $0.id == taskID }, selectedID: taskID,
                          select: { _ in }, changeStatus: { _, _ in }, suppliedDragSession: session).environmentObject(app)
        }
    }
    static func run(app: AppStore) async throws {
        let root = app.root.resolvingSymlinksInPath()
        try expect(ProcessInfo.processInfo.arguments.contains("--preview")
                   && ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path)
                   && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable board fixture required")
        let notes = app.notes
        app.librarySection = "tasks"; app.folderSelection = nil
        let session = TaskBoardDragSession()
        let task = try require(notes.createWorkspaceTask(title: "Проверить восстановление доступа", text: "Текст остаётся русским.", project: "Пилот"), notes.error)
        let host = Host(AnyView(BoardRoot(app: app, notes: notes, taskID: task.id, session: session)), width: 1120, height: 760)
        defer { host.close() }
        try await settle(host) { ids(host).contains("tasks.board.column.done") && ids(host).contains("tasks.board." + task.id) }
        let columnIDs = TaskWorkspaceStatus.allCases.map { "tasks.board.column." + $0.rawValue }
        try expect(columnIDs.allSatisfy { ids(host).contains($0) }, "Every status, including empty columns, must expose a native drop surface")
        for identifier in columnIDs {
            // AX group frames describe their accessible children, not the native drop view.
            // Read the non-interactive NSView probe attached to the exact onDrop bounds.
            let probeID = "geometry." + identifier
            try await settle(host) { nativeViews(host.view).contains { $0.identifier?.rawValue == probeID } }
            let bounds = nativeViews(host.view).filter { $0.identifier?.rawValue == probeID }.map(\.bounds)
            try expect(bounds.contains { $0.height >= 220 && $0.width >= 236 }, "An empty column needs a full-size native drop target: " + identifier)
        }
        for target in [TaskWorkspaceStatus.doing, .blocked, .done] {
            let current = try fresh(notes, task.id)
            let provider = session.provider(for: current, app: app)
            let box = ResultBox()
            try expect(session.receive([provider], target: target, app: app, completion: { box.value = $0 }), "Production drop receiver must accept its private provider")
            try expect(notes.taskWorkspaces[task.id]?.status == current.status, "Drop must not optimistically move a card before canonical persistence")
            try await wait { box.value != nil }
            try expect(box.value == true, notes.error ?? "Board drop did not persist")
            let saved = try fresh(notes, task.id)
            try expect(saved.status == target && saved.revision > current.revision && saved.history.count > current.history.count
                       && saved.title == task.title && saved.text == task.text,
                       "Drop must use the existing revision/history transition and preserve content")
        }
        try await settle(host) { ids(host).contains("tasks.board.column.done") && ids(host).contains("tasks.board." + task.id) }
        let reopened = NotesStore(root: root)
        try expect(try fresh(reopened, task.id).status == .done, "A dropped status must survive reopening storage")
        let beforeNoOp = try fresh(notes, task.id)
        try expect(try await drop(session.provider(for: beforeNoOp, app: app), session: session, target: .done, app: app), "A same-column drop should succeed as a no-op")
        let afterNoOp = try fresh(notes, task.id)
        try expect(afterNoOp.revision == beforeNoOp.revision && afterNoOp.history == beforeNoOp.history,
                   "A same-column drop must not add revisions, history or revoke claims")
        try snapshot(host.view, root.appendingPathComponent("task-board-drag.png"))
        print("PASS: real private NSItemProviders enter the production drop handler; empty-column targets, all status transitions, history, no-op and persistence are verified")

        let stale = try fresh(notes, task.id)
        let staleProvider = session.provider(for: stale, app: app)
        _ = try require(notes.updateTaskWorkspace(stale, patch: ["owner": "Изменено параллельно"]), notes.error)
        let changed = try fresh(notes, task.id)
        try expect(!(try await drop(staleProvider, session: session, target: .todo, app: app)), "A stale captured revision must be rejected")
        try expect(try fresh(notes, task.id).revision == changed.revision && fresh(notes, task.id).status == .done,
                   "A rejected stale drag cannot overwrite a concurrent edit")
        notes.error = nil
        let claimedTask = try require(notes.createWorkspaceTask(title: "Конкурирующий агент"), notes.error)
        let accessible = try require(notes.updateTaskWorkspace(claimedTask, patch: ["agentAccess": ["enabled": true]]), notes.error)
        let claimProvider = session.provider(for: accessible, app: app)
        let context = try require(notes.taskContext(accessible), notes.error)
        let bridge = try RustBridge.shared.get()
        let rawAgent = try JSONSerialization.jsonObject(with: bridge.request(root: root, command: "task-agent-settings")) as? [String: Any]
        if rawAgent?["enabled"] as? Bool != true {
            _ = try bridge.request(root: root, command: "task-agent-settings", arguments: ["enabled": true, "expectedRevision": rawAgent?["revision"] as? Int ?? 0, "operationID": UUID().uuidString.lowercased()])
        }
        _ = try bridge.request(root: root, command: "task-agent-claim", arguments: ["taskID": accessible.id, "expectedRevision": accessible.revision, "expectedContextVersion": context.contextVersion, "operationID": UUID().uuidString.lowercased(), "agentID": "board-fixture"])
        try expect(!(try await drop(claimProvider, session: session, target: .done, app: app)), "A concurrent agent claim must invalidate the captured drag revision")
        let claimState = try JSONSerialization.jsonObject(with: bridge.request(root: root, command: "task-get", arguments: ["taskID": accessible.id])) as? [String: Any]
        try expect(claimState?["claim"] is [String: Any] && claimState?["status"] as? String == "doing", "A rejected stale drag must preserve the agent claim")
        notes.error = nil
        let foreign = TaskBoardDragSession().provider(for: changed, app: app)
        try expect(!(try await drop(foreign, session: session, target: .todo, app: app)), "Opaque tokens from another board cannot mutate this board")
        let text = NSItemProvider(object: "manual:fake-task" as NSString)
        try expect(!session.receive([text], target: .todo, app: app), "External text is not a task command")
        let firstProvider = session.provider(for: changed, app: app)
        let secondProvider = session.provider(for: changed, app: app)
        try expect(!session.receive([firstProvider, secondProvider], target: .todo, app: app), "A drop must contain exactly one task")
        let malformed = NSItemProvider()
        malformed.registerDataRepresentation(forTypeIdentifier: TaskBoardDragSession.type.identifier, visibility: .ownProcess) { completion in
            completion(Data("{invalid}".utf8), nil); return nil
        }
        try expect(!(try await drop(malformed, session: session, target: .todo, app: app)), "Malformed private payload must not mutate a task")
        try expect(try fresh(notes, task.id).revision == changed.revision, "Rejected providers must preserve the canonical task revision")
        notes.error = nil
        print("PASS: stale revisions, foreign tokens, external text, malformed payloads and multi-task drops preserve canonical data")

        var folder = LibraryFolder(name: "Board policy")
        folder.overrides.features = FolderFeatureOverrides(); folder.overrides.features?.tasks = true
        folder = try require(notes.saveFolder(folder), notes.error)
        let scoped = try require(notes.createWorkspaceTask(title: "Задача с отдельным доступом", folderID: folder.id), notes.error)
        let scopedProvider = session.provider(for: scoped, app: app)
        folder.overrides.features?.tasks = false
        folder = try require(notes.saveFolder(folder), notes.error)
        try expect(app.isFeatureEnabled(.tasks), "Policy fixture requires the all-folders UI to remain available")
        try expect(!(try await drop(scopedProvider, session: session, target: .doing, app: app)), "A revoked source-folder feature must fail inside the canonical Rust mutation")
        try expect(try fresh(notes, scoped.id).revision == scoped.revision && fresh(notes, scoped.id).status == .todo,
                   "Revoked folder policy must preserve the original task status")
        folder.overrides.features?.tasks = true; folder = try require(notes.saveFolder(folder), notes.error)
        let scopeProvider = session.provider(for: try fresh(notes, scoped.id), app: app)
        app.folderSelection = folder.id
        try expect(!(try await drop(scopeProvider, session: session, target: .doing, app: app)), "Changing the selected folder invalidates an in-flight drag")
        app.folderSelection = nil
        let virtualMeeting = Meeting(title: "Scope transfer", source: "synthetic.wav")
        let virtualDirectory = app.meetingDirectory(virtualMeeting.id)
        try FileManager.default.createDirectory(at: virtualDirectory, withIntermediateDirectories: true)
        try app.write(virtualMeeting, virtualDirectory.appendingPathComponent("meta.json"))
        let virtualData = try JSONSerialization.data(withJSONObject: ["overview": "Scope", "items": [["kind": "action", "text": "Не менять после переноса встречи", "owner": "", "due": "", "segmentIDs": [1]]], "cards": [], "provider": "fixture", "model": "synthetic", "generatedAt": 1, "warnings": []])
        try app.write(JSONDecoder().decode(Summary.self, from: virtualData), virtualDirectory.appendingPathComponent("summary.json"))
        try app.write(Transcript(duration: 5, segments: [Segment(id: 1, start: 0, end: 5, speaker: "speaker_1", text: "Не менять после переноса встречи")], warnings: [], model: "synthetic"), virtualDirectory.appendingPathComponent("transcript.json"))
        app.reloadLibrary(); notes.loadTasks(); notes.loadTaskWorkspaces()
        let virtual = try require(notes.taskWorkspaces.values.first { $0.meetingID == virtualMeeting.id && $0.virtual }, notes.error)
        let virtualProvider = session.provider(for: virtual, app: app)
        try expect(notes.assignMeetingFolder(virtualMeeting.id, folderID: folder.id), "Virtual meeting scope fixture move failed")
        let relocated = try fresh(notes, virtual.id)
        try expect(relocated.revision == virtual.revision && relocated.sourceFingerprint == virtual.sourceFingerprint, "Moving a virtual task's meeting must exercise scope beyond ordinary task CAS")
        try expect(!(try await drop(virtualProvider, session: session, target: .done, app: app)), "A moved virtual task must be rejected by the production receiver")
        try expect(notes.updateTaskWorkspace(virtual, patch: ["status": "done"], requireFeature: true, expectedFolderID: nil) == nil,
                   "The canonical Rust lock must also reject a changed source folder independent of the UI precheck")
        try expect(try fresh(notes, virtual.id).virtual && fresh(notes, virtual.id).status == .todo, "Rejected scope transfers cannot materialize a virtual task")
        notes.error = nil
        let missing = try require(notes.createWorkspaceTask(title: "Удалённая во время переноса"), notes.error)
        let missingProvider = session.provider(for: missing, app: app)
        guard let noteID = notes.legacyTask(for: missing)?.noteID,
              let note = notes.workspace.notes.first(where: { $0.id == noteID }) else { throw AppError.message("Missing task note fixture") }
        notes.delete(note)
        try expect(!(try await drop(missingProvider, session: session, target: .doing, app: app)), "A deleted task must remain deleted after a pending drop")
        notes.error = nil
        print("PASS: live source-folder revocation, changed board scope and a removed task reject drops without resurrecting or changing data")

        await notes.refresh(includeTasks: true)
        notes.selectedTaskProject = "Пилот"
        let workspace = Host(AnyView(TasksWorkspaceView(notes: notes).environmentObject(app)), width: 1120, height: 820)
        defer { workspace.close() }
        try await settle(workspace) { ids(workspace).contains("tasks.presentation.board") }
        try press(workspace, "tasks.presentation.board")
        try await settle(workspace) { ids(workspace).contains("tasks.board." + task.id) }
        try expect(try fresh(notes, task.id).status == .done,
                   "The default board filter must show completed cards after a drop while the list can remain open-only")
        try snapshot(workspace.view, root.appendingPathComponent("task-board-all-statuses.png"))
        try expect(!app.busy && !app.isRecording && app.jobs.activeCount == 0 && !app.calendar.requesting,
                   "Board drag workflow must not start inference, capture or external authorization")
        print("PASS: actual board navigation defaults to all statuses and keeps the completed card visible after a persisted drop")
    }
    private static func drop(_ provider: NSItemProvider, session: TaskBoardDragSession, target: TaskWorkspaceStatus, app: AppStore) async throws -> Bool {
        let result = ResultBox()
        guard session.receive([provider], target: target, app: app, completion: { result.value = $0 }) else { return false }
        try await wait { result.value != nil }
        return result.value == true
    }
    private static func fresh(_ notes: NotesStore, _ id: String) throws -> TaskWorkspace {
        try require(notes.loadTaskWorkspace(id), notes.error)
    }
    private static func require<T>(_ value: T?, _ message: String?) throws -> T {
        guard let value else { throw AppError.message(message ?? "Board fixture missing") }; return value
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw AppError.message("Board drop completion timed out")
    }
    private static func settle(_ host: Host, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded()
            if condition() { return }; try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Native board layout did not settle. IDs: " + ids(host).sorted().joined(separator: ", "))
    }
    private static func snapshot(_ view: NSView, _ url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Board snapshot failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Board PNG failed") }; try data.write(to: url)
    }
    private static func nativeViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { nativeViews($0) }
    }
    private static func ids(_ host: Host) -> Set<String> { Set(nodes(host.view).compactMap(\.identifier)) }
    private static func press(_ host: Host, _ identifier: String) throws {
        try NativeTabNavigation.press(identifier, in: host.view)
    }
    @MainActor private final class Host {
        let view: NSHostingView<AnyView>; let window: NSWindow
        init(_ content: AnyView, width: CGFloat, height: CGFloat) {
            view = NSHostingView(rootView: AnyView(content.background(Ink.paper).environment(\.colorScheme, .light))); view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.appearance = NSAppearance(named: .aqua); window.makeKeyAndOrderFront(nil)
        }
        func close() { window.orderOut(nil) }
    }
    private static func nodes(_ root: NSView) -> [NativeTabNavigation.Node] {
        NativeTabNavigation.nodes(in: root)
    }
}
#endif
