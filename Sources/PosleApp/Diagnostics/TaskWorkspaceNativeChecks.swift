#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

@MainActor
private final class TaskCreationCheckPresentation: ObservableObject { @Published var showing = true }
@MainActor private final class TaskEditingReadGate { var released = false; var attempts = 0 }
private struct TaskCreationCheckSheet<Content: View>: View {
    @ObservedObject var state: TaskCreationCheckPresentation
    let content: Content
    var body: some View {
        Color.clear.frame(width: 850, height: 720).sheet(isPresented: $state.showing) { content }
    }
}

/// Disposable native workflow. No accounts, capture devices, file pickers or
/// personal windows are used; every file and model belongs to the fixture root.
@MainActor
enum TaskWorkspaceNativeChecks {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = env["POSLE_DATA_DIR"] else {
            throw AppError.message("Task workspace checks require --preview and a disposable POSLE_DATA_DIR")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable task root required")
        let app = AppStore(preview: true); let notes = app.notes
        try expect(TaskWorkspaceDescription.body(title: "План", text: "План на пятницу") == "План на пятницу", "A title prefix in a description sentence must not be removed")
        try expect(TaskWorkspaceDescription.body(title: "План", text: "План\nСогласовать сроки") == "Согласовать сроки", "Only an exact first-line title can be removed from a legacy task body")
        try expect(notes.notes.isEmpty && app.meetings.isEmpty, "An empty task workspace fixture is required")
        let first = try required(notes.createWorkspaceTask(title: "Проверить совместимость входа", text: "Сохранить действующие ссылки и проверить восстановление.", project: "Пилот", due: "2026-10-30", owner: "Анна"), notes.error)
        let linked = try required(notes.createWorkspaceTask(title: "Согласовать условия пилота", project: "Пилот", source: .manual, externalURL: "https://tracker.example.test/PROJECT-42"), notes.error)
        let blocked = try required(notes.createWorkspaceTask(title: "Уточнить перевод фраз", project: "Английский"), notes.error)
        let done = try required(notes.createWorkspaceTask(title: "Сверить экспорт карточек", project: "Пилот"), notes.error)
        _ = try required(notes.updateTaskWorkspace(fresh(notes, first.id), patch: ["status": "doing"]), notes.error)
        _ = try required(notes.updateTaskWorkspace(fresh(notes, blocked.id), patch: ["status": "blocked"]), notes.error)
        _ = try required(notes.updateTaskWorkspace(fresh(notes, done.id), patch: ["status": "done"]), notes.error)
        try expect(Set(notes.taskWorkspaces.values.map(\.status)) == Set(TaskWorkspaceStatus.allCases), "All four task statuses must persist")
        let linkedTask = fresh(notes, linked.id)
        try expect(linkedTask.source == .manual && linkedTask.externalURL == "https://tracker.example.test/PROJECT-42", "External fallback must preserve the source link")
        print("PASS: real Rust task creation, four statuses and manual external source")

        let originalNote = try required(notes.capture(text: "Материал до принятия задачи: проверить старые ссылки.", kind: "note"), notes.error)
        _ = try required(notes.linkTaskMaterial(TaskMaterial(kind: "note", title: originalNote.displayTitle, noteID: originalNote.id), to: fresh(notes, first.id)), notes.error)
        notes.setTaskThought("Личная мысль, не отправлять агенту.", task: fresh(notes, first.id)); notes.saveTaskThought(fresh(notes, first.id))
        try expect(fresh(notes, first.id).materials.count == 2 && fresh(notes, first.id).materials.allSatisfy { !$0.shared }, "New references and private thoughts must initially remain private")
        let folder = root.appendingPathComponent("selected-folder", isDirectory: true)
        let repository = root.appendingPathComponent("selected-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try required(notes.linkTaskMaterial(TaskMaterial(kind: "folder", title: "Материалы пилота", path: folder.path), to: fresh(notes, first.id)), notes.error)
        _ = try required(notes.linkTaskMaterial(TaskMaterial(kind: "repository", title: "client-app", path: repository.path), to: fresh(notes, first.id)), notes.error)
        let file = root.appendingPathComponent("brief.txt")
        try "Сценарий проверки входа.\n".write(to: file, atomically: true, encoding: .utf8)
        notes.attachTaskFile(file, to: fresh(notes, first.id))
        try await wait { !notes.attachmentBusy }
        try expect(fresh(notes, first.id).materials.contains { $0.kind == "file" && $0.noteID != nil && $0.attachmentID != nil && $0.available == true }, notes.error ?? "Real file attachment did not finish")
        let folderContents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let repositoryContents = try FileManager.default.contentsOfDirectory(atPath: repository.path)
        try expect(folderContents.isEmpty && repositoryContents.isEmpty, "Workspace references cannot create files")
        print("PASS: existing note, private thought, folder/repository references and real asynchronous note attachment")

        _ = try required(notes.updateTaskWorkspace(fresh(notes, first.id), patch: ["agentAccess": ["enabled": true]]), notes.error)
        let reference = try required(fresh(notes, first.id).materials.first { $0.noteID == originalNote.id }, nil)
        _ = try required(notes.shareTaskMaterial(reference, task: fresh(notes, first.id), shared: true), notes.error)
        notes.setTaskThought("Контекст для агента: проверить повторный вход.", task: fresh(notes, first.id)); notes.saveTaskThought(fresh(notes, first.id))
        try expect(fresh(notes, first.id).materials.contains { $0.text == "Контекст для агента: проверить повторный вход." && $0.shared }, "A new thought must follow the task's enabled access")
        let preview = try required(notes.taskContext(fresh(notes, first.id)), notes.error)
        let previewText = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        try expect(!previewText.contains("Личная мысль") && !preview.materials.contains(where: \.isWorkspace), "Shared context must omit private thoughts and unshared paths")
        struct AgentSettings: Decodable { let enabled: Bool; let revision: Int }
        let settings: AgentSettings = try request(notes, "task-agent-settings", [:])
        let _: AgentSettings = try request(notes, "task-agent-settings", ["enabled": true, "expectedRevision": settings.revision, "operationID": operation()])
        let context: TaskContextSnapshot = try request(notes, "task-context", ["taskID": first.id, "agentOnly": true])
        let claimData = try RustBridge.shared.get().request(root: root, command: "task-agent-claim", arguments: ["taskID": first.id, "expectedRevision": context.task.revision, "expectedContextVersion": context.contextVersion, "operationID": operation(), "agentID": "Codex"])
        struct ClaimResponse: Decodable { struct Claim: Decodable { var id: String }; var revision: Int; var claim: Claim }
        let claimed = try JSONDecoder().decode(ClaimResponse.self, from: claimData)
        let _: TaskWorkspace = try request(notes, "task-agent-report", ["taskID": first.id, "expectedRevision": claimed.revision, "operationID": operation(), "agentID": "Codex", "claimID": claimed.claim.id, "text": "Подготовлены изменения и проверка.", "artifacts": [["title": "Отчёт о проверке", "kind": "checks", "text": "Проверены старые ссылки и повторный вход. 3 проверки пройдены."]]])
        notes.reload(); notes.loadTasks(); notes.loadTaskWorkspaces()
        var changed = try required(notes.notes.first { $0.id == originalNote.id }, nil)
        changed.text = "Материал изменился после принятия задачи."
        _ = try required(notes.save(changed), notes.error); notes.loadTaskWorkspaces()
        let history = fresh(notes, first.id).history
        let frozen = try required(history.first { $0.snapshot != nil }?.snapshot, nil)
        try expect(frozen.materials.contains { $0.text?.contains("Материал до принятия") == true } && !frozen.materials.contains { $0.text?.contains("Материал изменился") == true }, "Claim history must keep the immutable accepted context")
        try expect(history.contains { !$0.artifacts.isEmpty }, "An actual agent report must expose an artifact")
        print("PASS: explicit per-task/material access, private-context filtering, immutable claim snapshot and report artifacts")

        notes.setTaskThought("Черновик первой задачи", task: fresh(notes, first.id))
        notes.setTaskThought("Другой черновик", task: fresh(notes, linked.id))
        let stale = fresh(notes, first.id)
        _ = try required(notes.updateTaskWorkspace(stale, patch: ["owner": "Мария"]), notes.error)
        try expect(notes.updateTaskWorkspace(stale, patch: ["title": "Устаревшая правка"]) == nil && notes.error != nil, "A stale workspace edit must fail through Rust CAS")
        try expect(notes.taskThought(for: fresh(notes, first.id)) == "Черновик первой задачи", "A conflict must preserve the pending thought")
        notes.error = nil
        try expect(notes.flushCaptureDrafts(), notes.error ?? "Draft persistence failed")
        let reopened = NotesStore(root: root); reopened.loadTasks(); reopened.loadTaskWorkspaces()
        try expect(reopened.taskThought(for: fresh(reopened, first.id)) == "Черновик первой задачи" && reopened.taskThought(for: fresh(reopened, linked.id)) == "Другой черновик", "Per-task drafts must survive navigation and restart")
        try staleVirtualSource(app, notes)
        print("PASS: independent task drafts survive switching/restart, stale revisions and changed virtual sources")

        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(true, forAttribute: ax)
        defer { NSApp.accessibilitySetValue(previousAX, forAttribute: ax) }
        try await creationDraft(notes)
        try await authoritativeEditing(notes)
        try hiddenProjectScope(app, notes: notes, noteID: originalNote.id, taskID: first.id)
        try await freshMountNavigation(app, notes: notes, completedTaskID: done.id)
        let searchMarker = "УНИКАЛЬНЫЙ_ХВОСТ_ПОИСКА"
        let longTask = try required(notes.createWorkspaceTask(title: "Проверить длинное описание", text: String(repeating: "Исходное условие. ", count: 80) + searchMarker, project: "Пилот"), notes.error)
        notes.selectedTaskID = first.id; notes.loadTaskWorkspaces(); notes.notice = nil
        try expect(notes.taskWorkspaces[longTask.id]?.text.contains(searchMarker) == false, "Search regression needs a non-selected metadata excerpt")
        let view = TasksWorkspaceView(notes: notes).environmentObject(app).environment(\.locale, Locale(identifier: "ru_RU")).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view.frame(width: 1120, height: 820).background(Ink.paper).tint(Ink.accent))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 1120, height: 820)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host; window.appearance = NSAppearance(named: .aqua); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await settle(host, window)
        try expect(nodes(host).contains { $0.identifier == "tasks.row." + first.id && $0.value == "Выбрана" }, "Native list must expose exactly the selected task")
        try expect(nodes(host).contains { $0.identifier == "tasks.more" } && nodes(host).contains { $0.identifier == "tasks.attach" }, "Task actions and materials picker must be accessible")
        try expect(nodes(host).contains { $0.identifier == "tasks.append-text" }, "Thought composer must be available without scrolling through materials")
        try await nativeArrowSelection(host, window: window, notes: notes)
        notes.selectedTaskID = first.id; try await settle(host, window)
        try editTaskSearch(host, window: window, text: searchMarker)
        try await waitForLayout(host, window) {
            nodes(host).contains { $0.identifier == "tasks.row." + longTask.id && $0.value == "Выбрана" }
                && !nodes(host).contains { $0.identifier == "tasks.row." + first.id }
        }
        try editTaskSearch(host, window: window, text: "НЕТ_ТАКОЙ_ЗАДАЧИ_В_БИБЛИОТЕКЕ")
        try await waitForLayout(host, window) { nodes(host).contains { $0.identifier == "tasks.empty-reset" } }
        try expect(!nodes(host).contains { $0.identifier == "tasks.empty-create" }, "Filtered empty state cannot pretend the library has no tasks")
        try press(host, identifier: "tasks.empty-reset")
        try await waitForLayout(host, window) { nodes(host).contains { $0.identifier == "tasks.row." + first.id } && notes.selectedTaskID != nil }
        notes.selectedTaskID = first.id
        try await settle(host, window)
        print("PASS: native search finds canonical task text beyond the metadata excerpt without eager detail loading")
        try expect(!nodes(host).contains { $0.label == "Codex" && $0.role == "AXRadioButton" }, "Task details cannot add a separate Codex tab")
        try press(host, identifier: "tasks.tab.history")
        try await waitForLayout(host, window) { nodes(host).contains { $0.identifier == "tasks.tab.history" && $0.value == "Выбрана" } }
        try capture(host, at: root.appendingPathComponent("task-workspace-history-light.png"))
        let visibleHistory = nodes(host)
        if !visibleHistory.contains(where: { $0.identifier?.hasPrefix("tasks.history.snapshot.") == true }) || !visibleHistory.contains(where: { $0.identifier?.hasPrefix("tasks.history.artifact.") == true }) {
            print("TASK HISTORY diagnostics selected=\(notes.selectedTaskID ?? "nil") expected=\(first.id) modelEvents=\(notes.taskWorkspaces[first.id]?.history.count ?? -1)")
            for node in visibleHistory {
                if node.identifier?.hasPrefix("tasks.") == true || node.label?.contains("Контекст") == true || node.label?.contains("Отчёт") == true {
                    print("TASK HISTORY AX id=\(node.identifier ?? "nil") role=\(node.role ?? "nil") label=\(node.label ?? "nil") value=\(node.value ?? "nil")")
                }
            }
        }
        try expect(visibleHistory.contains { $0.identifier?.hasPrefix("tasks.history.snapshot.") == true } && visibleHistory.contains { $0.identifier?.hasPrefix("tasks.history.artifact.") == true }, "Native history must expose snapshot and artifact actions")
        try press(host, identifier: "tasks.tab.materials"); try await settle(host, window)
        try capture(host, at: root.appendingPathComponent("task-workspace-light.png"))
        let boardControl = nodes(host).first { ($0.label == "Доска" || $0.value == "Доска") && ["AXRadioButton", "AXButton"].contains($0.role ?? "") }
        if let boardControl, boardControl.press() { try await settle(host, window) }
        app.openTask(id: done.id); try await settle(host, window)
        try expect(notes.selectedTaskID == done.id && nodes(host).contains { $0.identifier == "tasks.row." + done.id && $0.value == "Выбрана" }, "External navigation must open the exact completed task through hidden filters/board")
        window.orderOut(nil)
        try await render(app: app, notes: notes, taskID: first.id, root: root, dark: true, width: 1120, height: 820, name: "task-workspace-dark.png")
        try await render(app: app, notes: notes, taskID: first.id, root: root, dark: false, width: 760, height: 760, name: "task-workspace-narrow.png")
        let board = NSHostingView(rootView: TaskBoardView(tasks: notes.taskWorkspaces.values.sorted { $0.title < $1.title }, selectedID: first.id, select: { _ in }, changeStatus: { _, _ in }).frame(width: 1120, height: 760).background(Ink.paper).tint(Ink.accent))
        board.frame = NSRect(x: 0, y: 0, width: 1120, height: 760)
        let boardWindow = NSWindow(contentRect: board.frame, styleMask: [.titled], backing: .buffered, defer: false)
        boardWindow.contentView = board; boardWindow.makeKeyAndOrderFront(nil)
        try await settle(board, boardWindow); try capture(board, at: root.appendingPathComponent("task-workspace-board.png")); boardWindow.orderOut(nil)
        try expect(nodes(board).filter { $0.identifier?.hasPrefix("tasks.board.") == true }.count >= 4, "Board must expose real cards across the four statuses")
        notes.captureDrafts.removeAll(); _ = notes.flushCaptureDrafts()
        print("PASS: real native list/history/materials, exact external navigation, board and light/dark/narrow renders")
        print("11 native task workspace E2E groups passed")
    }

    private static func nativeArrowSelection(_ host: NSView, window: NSWindow, notes: NotesStore) async throws {
        func tables(_ view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        guard let table = tables(host).first(where: { $0.numberOfRows >= 2 }) else { throw AppError.message("Tasks must use a native selectable list") }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await settle(host, window)
        let initial = notes.selectedTaskID
        try expect(initial != nil && table.selectedRow == 0, "Native task list must accept its first row")
        window.makeFirstResponder(table)
        func arrow(code: UInt16, character: String) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                                               isARepeat: false, keyCode: code) else { throw AppError.message("Could not create an owned-window arrow event") }
            table.keyDown(with: event)
        }
        try arrow(code: 125, character: "\u{F701}")
        try await waitForLayout(host, window) { table.selectedRow == 1 && notes.selectedTaskID != initial }
        try arrow(code: 126, character: "\u{F700}")
        try await waitForLayout(host, window) { table.selectedRow == 0 && notes.selectedTaskID == initial }
        try expect(nodes(host).filter { $0.identifier?.hasPrefix("tasks.row.") == true && $0.value == "Выбрана" }.count == 1,
                   "Arrow navigation must retain one selected accessible task action")
        print("PASS: native task list Up/Down changes the detail selection and preserves selected accessibility semantics")
    }

    private static func creationDraft(_ notes: NotesStore) async throws {
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Task creation fixture must begin without an active editor")
        let originalTaskIDs = Set(notes.tasks.map(\.id))
        let state = TaskCreationCheckPresentation()
        let host = NSHostingView(rootView: TaskCreationCheckSheet(state: state, content: TaskCreationSheet(notes: notes) { _ in }))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 850, height: 720)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func activeRoot() -> NSView { window.attachedSheet?.contentView ?? host }
        func ownedNodes() -> [AXNode] {
            var all = nodes(host); var sheet = window.attachedSheet
            while let current = sheet { if let content = current.contentView { all += nodes(content) }; sheet = current.attachedSheet }
            return all
        }
        func waitForSheet(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); activeRoot().layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw AppError.message("Native task creation draft did not settle")
        }
        try await waitForSheet { ownedNodes().contains { $0.identifier == "tasks.form.cancel" } }
        try expect(!UnsavedEditorRegistry.hasUnsaved, "An unchanged new-task sheet cannot block exit")
        func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
        }
        let description = "Несохранённые условия задачи из нативного редактора"
        let editor: NSTextView
        if let field = descendants(activeRoot(), as: NSTextField.self).first(where: { $0.placeholderString == "Детали задачи" }) {
            window.attachedSheet?.makeFirstResponder(field)
            guard let fieldEditor = field.currentEditor() as? NSTextView else { throw AppError.message("Native task description field editor missing") }
            editor = fieldEditor
        } else if let multiline = descendants(activeRoot(), as: NSTextView.self).first(where: { $0.isEditable && !$0.isFieldEditor }) {
            window.attachedSheet?.makeFirstResponder(multiline); editor = multiline
        } else { throw AppError.message("Native task description editor missing") }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.shouldChangeText(in: range, replacementString: description) else { throw AppError.message("Task description rejected native editing") }
        editor.replaceCharacters(in: range, with: description); editor.didChangeText()
        try await waitForSheet { UnsavedEditorRegistry.hasUnsaved }
        guard let cancel = ownedNodes().first(where: { $0.identifier == "tasks.form.cancel" }), cancel.press() else { throw AppError.message("Native task creation Cancel missing") }
        try await waitForSheet { ownedNodes().contains { $0.identifier == "tasks.form.discard" } }
        try expect(UnsavedEditorRegistry.hasUnsaved, "Cancel must preserve the task draft until explicit discard")
        guard let discard = ownedNodes().first(where: { $0.identifier == "tasks.form.discard" }), discard.press() else { throw AppError.message("Native task draft Discard missing") }
        try await waitForSheet { window.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        try expect(Set(notes.tasks.map(\.id)) == originalTaskIDs, "Discarding a task draft cannot create or change persisted tasks")
        print("PASS: native new-task sheet stays clean until description edit and clears the exit guard only after explicit discard")
    }

    /// A slow or failed detail read cannot turn a list excerpt into an editable
    /// authoritative body. The native form must still preserve CAS afterwards.
    private static func authoritativeEditing(_ notes: NotesStore) async throws {
        let body = String(repeating: "Подробные условия проверки. ", count: 80) + "ПОЛНЫЙ_ХВОСТ"
        let original = try required(notes.createWorkspaceTask(title: "Длинная задача", text: body), notes.error)
        let metadata: TaskWorkspacesResponse = try request(notes, "task-list", ["includeDetails": false])
        let excerpt = try required(metadata.tasks.first { $0.id == original.id }, nil)
        try expect(excerpt.text.count <= 600 && !excerpt.text.contains("ПОЛНЫЙ_ХВОСТ"), "Edit regression requires an actual Rust metadata excerpt")
        let gate = TaskEditingReadGate()
        let state = TaskCreationCheckPresentation()
        var saved: TaskWorkspace?
        let form = TaskCreationSheet(notes: notes, task: excerpt, detailLoader: { id in
            gate.attempts += 1
            let attempt = gate.attempts
            while !gate.released { try await Task.sleep(for: .milliseconds(20)) }
            if attempt == 1 { throw AppError.message("Проверочная ошибка чтения задачи") }
            return try await notes.taskWorkspaceForEditing(id)
        }) { saved = $0 }
        let host = NSHostingView(rootView: TaskCreationCheckSheet(state: state, content: form))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 850, height: 720)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func activeRoot() -> NSView { window.attachedSheet?.contentView ?? host }
        func formNodes() -> [AXNode] { nodes(activeRoot()) }
        var phase = "initial loading"
        func waitForForm(_ condition: () -> Bool) async throws {
            for _ in 0..<250 {
                host.layoutSubtreeIfNeeded(); activeRoot().layoutSubtreeIfNeeded(); window.displayIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            print("TASK EDIT phase=\(phase) attempts=\(gate.attempts) saved=\(saved != nil) sheet=\(window.attachedSheet != nil)")
            for node in formNodes() where node.identifier?.hasPrefix("tasks.form.") == true {
                print("TASK EDIT AX id=\(node.identifier ?? "nil") role=\(node.role ?? "nil") enabled=\(node.enabled) value=\(String((node.value ?? "nil").prefix(120)))")
            }
            throw AppError.message("Native authoritative task edit did not settle: " + phase)
        }
        func saveButton() -> AXNode? { formNodes().first { $0.identifier == "tasks.form.save" } }
        try await waitForForm { gate.attempts == 1 && saveButton() != nil }
        try expect(saveButton()?.enabled == false, "Save must be disabled before a full task read completes")
        _ = saveButton()?.press()
        let activeWindow = window.attachedSheet ?? window
        if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: activeWindow.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
            activeWindow.sendEvent(enter)
        } else { throw AppError.message("Could not create the owned task Return event") }
        let beforeLoad = fresh(notes, original.id)
        try expect(saved == nil && beforeLoad.text == body && beforeLoad.revision == original.revision, "An early native Save/Return cannot persist a metadata excerpt or change its revision")
        phase = "failed read"
        gate.released = true
        try await waitForForm { formNodes().contains { $0.identifier == "tasks.form.retry" } }
        try expect(saveButton()?.enabled == false, "A failed detail read must keep Save disabled")
        phase = "retry loading"
        gate.released = false
        try press(activeRoot(), identifier: "tasks.form.retry")
        try await waitForForm { gate.attempts == 2 }
        try expect(saveButton()?.enabled == false, "Retry must not enable the form before the new detail arrives")
        _ = try required(notes.updateTaskWorkspace(fresh(notes, original.id), patch: ["owner": "Роман"]), notes.error)
        phase = "complete read"
        gate.released = true
        try await waitForForm {
            !formNodes().contains { $0.identifier == "tasks.form.loading" }
                && formNodes().contains { $0.identifier == "tasks.form.description" && $0.value == body }
        }
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Loading the complete task cannot create an unsaved draft")
        phase = "native title edit"
        try editTaskTitle(activeRoot(), window: window.attachedSheet ?? window, text: "Проверить полное описание")
        try await waitForForm { UnsavedEditorRegistry.hasUnsaved }
        phase = "save and dismiss"
        try press(activeRoot(), identifier: "tasks.form.save")
        try await waitForForm { saved != nil && window.attachedSheet == nil }
        let persisted = fresh(notes, original.id)
        try expect(persisted.text == body && persisted.owner == "Роман" && persisted.title == "Проверить полное описание", "Saving after detail retry must retain the full body and latest revision fields")
        try expect(!UnsavedEditorRegistry.hasUnsaved, "A successful full-body save must clear the edit guard")
        window.orderOut(nil); window.contentView = nil
        print("PASS: delayed/failed task detail retry and full-body native Save preserve complete data and the latest revision")

        // The loaded revision remains fixed while typing. A concurrent writer
        // must reject the save and leave the complete native draft recoverable.
        let conflictState = TaskCreationCheckPresentation()
        var conflictSaved = false
        let conflictHost = NSHostingView(rootView: TaskCreationCheckSheet(state: conflictState,
            content: TaskCreationSheet(notes: notes, task: excerpt) { _ in conflictSaved = true }))
        conflictHost.sizingOptions = []; conflictHost.frame = NSRect(x: 0, y: 0, width: 850, height: 720)
        let conflictWindow = NSWindow(contentRect: conflictHost.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        conflictWindow.contentView = conflictHost; conflictWindow.makeKeyAndOrderFront(nil)
        defer { conflictWindow.orderOut(nil); conflictWindow.contentView = nil }
        func conflictRoot() -> NSView { conflictWindow.attachedSheet?.contentView ?? conflictHost }
        var conflictPhase = "complete detail"
        func waitForConflict(_ condition: () -> Bool) async throws {
            for _ in 0..<250 {
                conflictHost.layoutSubtreeIfNeeded(); conflictRoot().layoutSubtreeIfNeeded(); conflictWindow.displayIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw AppError.message("Native conflicting task edit did not settle: " + conflictPhase)
        }
        try await waitForConflict { nodes(conflictRoot()).contains { $0.identifier == "tasks.form.description" && $0.value == body } }
        try editTaskTitle(conflictRoot(), window: conflictWindow.attachedSheet ?? conflictWindow, text: "Несохранённое название после конфликта")
        conflictPhase = "typed draft guard"
        try await waitForConflict { UnsavedEditorRegistry.hasUnsaved }
        _ = try required(notes.updateTaskWorkspace(fresh(notes, original.id), patch: ["owner": "Мария"]), notes.error)
        conflictPhase = "CAS error"
        try press(conflictRoot(), identifier: "tasks.form.save")
        try await waitForConflict { notes.error != nil }
        try expect(!conflictSaved && UnsavedEditorRegistry.hasUnsaved, "A stale revision must retain the open native edit draft")
        try expect(nodes(conflictRoot()).contains { $0.value == "Несохранённое название после конфликта" }, "The conflicting save cannot reset typed fields")
        let afterConflict = fresh(notes, original.id)
        try expect(afterConflict.text == body && afterConflict.title == persisted.title && afterConflict.owner == "Мария", "A stale form cannot replace the canonical complete task")
        // The Cancel/Discard workflow is covered by creationDraft above. End
        // this disposable presentation after verifying the conflicting draft.
        conflictPhase = "fixture teardown"
        conflictState.showing = false
        try await waitForConflict { conflictWindow.attachedSheet == nil && !UnsavedEditorRegistry.hasUnsaved }
        notes.error = nil
        print("PASS: native editing gates delayed/failed detail reads, saves full >600-character bodies and preserves a conflicting draft")
    }

    private static func editTaskTitle(_ host: NSView, window: NSWindow, text: String) throws {
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let field = fields(host).first(where: { $0.placeholderString == "Что нужно сделать" }) else { throw AppError.message("Native task title field missing") }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Native task title editor missing") }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.shouldChangeText(in: range, replacementString: text) else { throw AppError.message("Task title rejected native editing") }
        editor.replaceCharacters(in: range, with: text); editor.didChangeText()
    }

    private static func hiddenProjectScope(_ app: AppStore, notes: NotesStore, noteID: String, taskID: String) throws {
        notes.selectedTaskID = taskID; notes.selectedTaskProject = "Пилот"; app.librarySection = "tasks"
        try expect(app.activeTaskProjectID == "Пилот", "Visible task project must scope task commands")
        app.librarySection = "inbox"; notes.selectedNoteID = noteID
        try expect(app.activeTaskProjectID == nil, "A hidden tracker project cannot scope another section")
        app.voice.present()
        try expect(app.voice.flushDraft(), "Could not persist the owned voice context fixture")
        let data = try Data(contentsOf: app.root.appendingPathComponent("voice-draft.json"))
        let draft = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try expect(draft?["projectID"] == nil && draft?["noteID"] as? String == noteID, "Actual voice context must keep the current note and omit the hidden task project")
        app.voice.dismiss(); app.librarySection = "meetings"; notes.selectedTaskProject = "all"
        try expect(app.activeTaskProjectID == nil, "Meeting commands cannot inherit a previously selected task project")
        print("PASS: actual voice draft keeps its visible context instead of a hidden tracker project")
    }
    private static func freshMountNavigation(_ app: AppStore, notes: NotesStore, completedTaskID: String) async throws {
        app.librarySection = "meetings"
        app.openTask(id: completedTaskID)
        try expect(app.librarySection == "tasks" && notes.pendingTaskNavigationID == completedTaskID, "Navigation target must survive until the task workspace mounts")
        let host = NSHostingView(rootView: TasksWorkspaceView(notes: notes).environmentObject(app).environment(\.locale, Locale(identifier: "ru_RU")).frame(width: 1120, height: 820))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 1120, height: 820)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await waitForLayout(host, window) {
            notes.selectedTaskID == completedTaskID && notes.pendingTaskNavigationID == nil
                && nodes(host).contains { $0.identifier == "tasks.row." + completedTaskID && $0.value == "Выбрана" }
        }
        print("PASS: fresh task workspace mount consumes completed-task navigation through the default open filter")
    }
    private static func editTaskSearch(_ host: NSView, window: NSWindow, text: String) throws {
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        guard let field = fields(host).first(where: { $0.placeholderString == "Найти задачу…" }) else { throw AppError.message("Native task search field missing") }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Native task search editor missing") }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.shouldChangeText(in: range, replacementString: text) else { throw AppError.message("Native task search rejected editing") }
        editor.replaceCharacters(in: range, with: text); editor.didChangeText()
    }

    private static func staleVirtualSource(_ app: AppStore, _ notes: NotesStore) throws {
        var meeting = Meeting(title: "План проверки", source: "synthetic.wav"); meeting.status = "ready"
        let directory = app.meetingDirectory(meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try app.write(meeting, directory.appendingPathComponent("meta.json"))
        let item: [String: Any] = ["kind": "action", "text": "Проверить первый сценарий", "owner": "", "due": "", "segmentIDs": [1]]
        let data = try JSONSerialization.data(withJSONObject: ["overview": "План проверки", "items": [item], "cards": [], "provider": "fixture", "model": "synthetic", "generatedAt": 1, "warnings": []])
        var summary = try JSONDecoder().decode(Summary.self, from: data)
        try app.write(summary, directory.appendingPathComponent("summary.json"))
        try app.write(Transcript(duration: 5, segments: [Segment(id: 1, start: 0, end: 5, speaker: "speaker_1", text: "Проверить первый сценарий")], warnings: [], model: "synthetic"), directory.appendingPathComponent("transcript.json"))
        app.reloadLibrary(); notes.loadTasks(); notes.loadTaskWorkspaces()
        let stale = try required(notes.taskWorkspaces.values.first { $0.meetingID == meeting.id && $0.virtual }, notes.error)
        try expect(!stale.sourceFingerprint.isEmpty, "Virtual task must retain the domain source fingerprint")
        notes.captureDrafts["taskthought:\(stale.id)"] = "Не потерять черновик"
        summary.items[0].text = "Теперь проверить другой сценарий"; summary.generatedAt += 1
        try app.write(summary, directory.appendingPathComponent("summary.json"))
        try expect(notes.updateTaskWorkspace(stale, patch: ["owner": "Ошибочная правка"]) == nil && notes.error != nil, "A regenerated summary cannot let revision zero mutate a different virtual task")
        try expect(notes.captureDrafts["taskthought:\(stale.id)"] == "Не потерять черновик", "Changed virtual source must retain the thought draft")
        notes.captureDrafts.removeValue(forKey: "taskthought:\(stale.id)"); notes.error = nil
        notes.reload(); notes.loadTasks(); notes.loadTaskWorkspaces()
        try expect(notes.taskWorkspaces.values.contains { $0.meetingID == meeting.id && $0.virtual && $0.owner != "Ошибочная правка" }, "Failed virtual mutation cannot materialize or replace the new task")
    }

    private static func render(app: AppStore, notes: NotesStore, taskID: String, root: URL, dark: Bool, width: CGFloat, height: CGFloat, name: String) async throws {
        notes.selectedTaskID = taskID
        let host = NSHostingView(rootView: TasksWorkspaceView(notes: notes).environmentObject(app).environment(\.locale, Locale(identifier: "ru_RU")).environment(\.colorScheme, dark ? .dark : .light).frame(width: width, height: height).background(Ink.paper).tint(Ink.accent))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await settle(host, window); try capture(host, at: root.appendingPathComponent(name))
    }
    private static func capture(_ view: NSView, at url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Could not capture the owned task fixture") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Task fixture PNG failed") }
        try png.write(to: url)
    }
    private static func settle(_ host: NSView, _ window: NSWindow) async throws {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
    }
    private static func waitForLayout(_ host: NSView, _ window: NSWindow, condition: () -> Bool) async throws {
        for _ in 0..<120 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let tabs = nodes(host).filter { $0.identifier?.hasPrefix("tasks.tab.") == true }
        for node in tabs { print("TASK TAB AX id=\(node.identifier ?? "nil") value=\(node.value ?? "nil")") }
        throw AppError.message("Native task tab did not switch after AX press")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw AppError.message("Task workflow did not settle")
    }
    private static func fresh(_ notes: NotesStore, _ id: String) -> TaskWorkspace {
        guard let task = notes.loadTaskWorkspace(id) else { preconditionFailure(notes.error ?? "Task fixture task-get failed") }
        return task
    }
    private static func request<T: Decodable>(_ notes: NotesStore, _ command: String, _ arguments: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: RustBridge.shared.get().request(root: notes.root, command: command, arguments: arguments))
    }
    private static func operation() -> String { UUID().uuidString.lowercased() }
    private static func required<T>(_ value: T?, _ message: String?) throws -> T {
        guard let value else { throw AppError.message(message ?? "Required task fixture value is missing") }; return value
    }
    private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw AppError.message(message) } }

    @MainActor private struct AXNode {
        let object: NSObject
        private func get(_ name: String) -> Any? { let selector = NSSelectorFromString(name); return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil }
        var identifier: String? { (object as? any NSAccessibilityProtocol)?.accessibilityIdentifier() ?? get("accessibilityIdentifier") as? String }
        var value: String? { (object as? any NSAccessibilityProtocol)?.accessibilityValue() as? String ?? get("accessibilityValue") as? String }
        var label: String? { (object as? any NSAccessibilityProtocol)?.accessibilityLabel() ?? get("accessibilityLabel") as? String }
        var enabled: Bool {
            if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton { return button.isEnabled }
            if let control = object as? NSControl { return control.isEnabled }
            if let modern = object as? any NSAccessibilityProtocol { return modern.isAccessibilityEnabled() }
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Getter.self)(object, selector)
        }
        var role: String? { (object as? any NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? get("accessibilityRole") as? String }
        var children: [Any] { (object as? any NSAccessibilityProtocol)?.accessibilityChildren() ?? get("accessibilityChildren") as? [Any] ?? [] }
        func press() -> Bool {
            if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton, button.isEnabled {
                button.performClick(nil); return true
            }
            if let button = object as? NSButton, button.isEnabled { button.performClick(nil); return true }
            if let node = object as? any NSAccessibilityProtocol { return node.accessibilityPerformPress() }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }
    private static func nodes(_ root: NSView) -> [AXNode] {
        var result: [AXNode] = []; var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = AXNode(object: object); result.append(node)
            for child in node.children { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0); return result
    }
    private static func press(_ root: NSView, identifier: String) throws {
        guard let node = nodes(root).first(where: { $0.identifier == identifier }), node.press() else { throw AppError.message("Native task action missing: " + identifier) }
    }
}
#endif
