import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AppKit
import Foundation
import AfterCore
import SwiftUI

/// Actual SwiftUI selection and NotesStore → Rust persistence. The fixture owns
/// its disposable root and never opens a real calendar, recording or microphone.
@MainActor
enum TasksNativeChecks {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = env["POSLE_DATA_DIR"] else {
            throw AppError.message("Task checks require --preview and an explicit disposable root")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) &&
                   root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable task root required")
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        let app = AppStore(preview: true)
        let notes = app.notes
        try expect(app.meetings.isEmpty && notes.notes.isEmpty && notes.captureDrafts.isEmpty,
                   "Task checks require an empty fixture")
        let meeting = try makeFixture(app)
        app.reloadLibrary(); notes.loadTasks()
        try expect(notes.tasks.count == 3 && notes.tasks.allSatisfy { $0.noteID == nil },
                   "Initial fixture must contain only summary tasks without note IDs")
        try expect(notes.selectedTaskID == nil, "Initial selection must be nil before the view appears")
        let initialTasks = notes.tasks
        let host = NSHostingView(rootView: TasksWorkspaceView(notes: notes).environmentObject(app)
            .environment(\.locale, Locale(identifier: "ru_RU")).frame(width: 1040, height: 760))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 1040, height: 760)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await waitUntil(host: host, window: window) { notes.selectedTaskID == initialTasks.first?.id }
        try assertSelection(host, taskID: initialTasks[0].id, rowCount: 3)
        try expect(!initialTasks[0].id.isEmpty, "onAppear must select a real task ID")
        let second = initialTasks[1]
        guard let secondRow = accessibilityNodes(host).first(where: { $0.accessibilityIdentifier() == "tasks.row." + second.id }) else {
            throw AppError.message("Second task row is missing from the native accessibility tree")
        }
        try expect(secondRow.accessibilityPerformPress(), "Actual task row must support native press")
        try await waitUntil(host: host, window: window) { notes.selectedTaskID == second.id }
        try assertSelection(host, taskID: second.id, rowCount: 3)
        let detail = accessibilityNodes(host).first { $0.accessibilityIdentifier() == "tasks.detail-title" }
        let detailText = (detail?.accessibilityValue() as? String) ?? detail?.accessibilityLabel() ?? ""
        try expect(detailText.contains(second.text), "Native task detail must follow the pressed row")
        print("PASS: native summary-only tracker selects exactly one first row, then opens the pressed task")

        let oldDraftKeys = ["taskappend", "tasksubtask", "taskmeta"]
        for prefix in oldDraftKeys { notes.captureDrafts["\(prefix):\(second.id)"] = "Черновик \(prefix)" }
        let materialized = try required(notes.materializeTask(second), notes.error ?? "Materialization failed")
        let canonicalID = "manual:\(materialized.id)"
        try expect(materialized.taskOrigin?.sourceText == second.text && materialized.taskOrigin?.segmentIDs == second.segmentIDs,
                   "Canonical task must retain exact summary evidence")
        try expect(notes.tasks.count == 3 && notes.tasks.filter { $0.noteID == materialized.id }.count == 1 &&
                   !notes.tasks.contains { $0.id == second.id }, "Materialization must replace the summary row without duplication")
        try expect(notes.selectedTaskID == canonicalID, "Selection must advance to the canonical ID")
        for prefix in oldDraftKeys {
            try expect(notes.captureDrafts["\(prefix):\(second.id)"] == nil &&
                       notes.captureDrafts["\(prefix):\(canonicalID)"] == "Черновик \(prefix)",
                       "Materialization must retain and migrate \(prefix) draft")
        }
        let repeated = try required(notes.materializeTask(second), notes.error ?? "Repeated materialization failed")
        try expect(repeated.id == materialized.id && notes.tasks.count == 3,
                   "Repeated materialization must return one stable task")
        // The intentionally arbitrary metadata draft above tests identity migration.
        // Remove it before rendering metadata controls, which expect their JSON shape.
        notes.captureDrafts.removeValue(forKey: "taskmeta:\(canonicalID)")
        print("PASS: summary materialization keeps one UUID, exact evidence, selection and all task draft destinations")

        let beforeAppend = try task(notes, noteID: materialized.id)
        let addition = "Сверить условия оплаты с приложением к договору."
        let appended = try required(notes.appendTask(beforeAppend, text: addition), notes.error ?? "Append failed")
        try expect(appended.text == second.text + "\n\n" + addition && appended.history.last?.text == addition &&
                   appended.revision > materialized.revision, "Append must retain original text and record the exact new addition")
        let fresh = try task(notes, noteID: materialized.id)
        let repeatedAppend = try required(notes.appendTask(fresh, text: addition), notes.error ?? "Repeated append failed")
        try expect(repeatedAppend.text == appended.text && repeatedAppend.history.count == appended.history.count,
                   "Repeated exact addition must not duplicate content or history")
        let retainedDraft = notes.captureDrafts["taskappend:\(canonicalID)"]
        try expect(notes.updateTask(beforeAppend, patch: ["owner": "Устаревший редактор"]) == nil && notes.error != nil,
                   "Stale task metadata must fail through Rust CAS")
        try expect(notes.captureDrafts["taskappend:\(canonicalID)"] == retainedDraft &&
                   notes.notes.first(where: { $0.id == materialized.id })?.text == appended.text,
                   "CAS conflict must preserve both persisted content and unsaved draft")
        notes.error = nil
        print("PASS: append keeps exact history, duplicate additions are suppressed and stale edits preserve drafts")

        let current = try task(notes, noteID: materialized.id)
        let metadata = try required(notes.updateTask(current, patch: ["owner": "Анна", "due": "2026-10-30"]),
                                    notes.error ?? "Metadata update failed")
        try expect(metadata.owner == "Анна" && metadata.due == "2026-10-30" &&
                   metadata.history.last?.text.contains("2026-10-30") == true, "Deadline and owner must persist with history")
        try expect(notes.updateTask(try task(notes, noteID: materialized.id), patch: ["owner": "Неверная правка"],
                                    expectedRevision: current.noteRevision) == nil,
                   "Metadata editor's captured revision must protect a newer save")
        try expect(notes.notes.first(where: { $0.id == materialized.id })?.owner == "Анна",
                   "A stale metadata save cannot replace the current owner")
        notes.error = nil
        let subtasks = [TaskSubtask(text: "Проверить реквизиты"), TaskSubtask(text: "Согласовать отсрочку")]
        let withSubtasks = try required(notes.updateTask(try task(notes, noteID: materialized.id), patch: ["subtasks": try object(subtasks)]),
                                        notes.error ?? "Subtask creation failed")
        try expect(withSubtasks.subtasks.map(\.id) == subtasks.map(\.id), "Subtask IDs must round-trip through the domain")
        let staleSubtasks = try task(notes, noteID: materialized.id)
        var completedSubtasks = subtasks; completedSubtasks[0].completed = true
        let toggledSubtask = try required(notes.updateTask(staleSubtasks, patch: ["subtasks": try object(completedSubtasks)]),
                                          notes.error ?? "Subtask completion failed")
        try expect(toggledSubtask.subtasks.first?.completed == true, "Subtask completion must persist")
        try expect(notes.updateTask(staleSubtasks, patch: ["subtasks": try object(subtasks)]) == nil,
                   "Stale subtask state must not undo a later completion")
        notes.error = nil
        let remaining = [completedSubtasks[1]]
        let removedSubtask = try required(notes.updateTask(try task(notes, noteID: materialized.id), patch: ["subtasks": try object(remaining)]),
                                          notes.error ?? "Subtask removal failed")
        try expect(removedSubtask.subtasks == remaining && removedSubtask.text == appended.text &&
                   removedSubtask.owner == metadata.owner, "Removing a subtask must retain task text and metadata")
        print("PASS: deadline, owner and subtask create/complete/remove persist; stale metadata and subtask editors cannot overwrite them")

        app.openMeeting(meeting.id, tab: "summary")
        let sourceItem = try required(app.summary?.items.first { $0.text == second.text }, "Source task missing")
        try expect(!app.taskCompleted(sourceItem), "Canonical task initially remains open in its summary")
        _ = try required(notes.updateTask(try task(notes, noteID: materialized.id), patch: ["completed": true]),
                         notes.error ?? "Task completion failed")
        try expect(app.taskCompleted(sourceItem) && app.selected?.completedTasks.contains(sourceItem.id) == false,
                   "Summary checkbox must use canonical state, independently of legacy metadata")
        app.toggleTask(sourceItem)
        try expect(!app.taskCompleted(sourceItem) && notes.notes.first(where: { $0.id == materialized.id })?.completed == false,
                   "Summary checkbox must reopen the same canonical task")
        app.toggleTask(sourceItem)
        try expect(app.taskCompleted(sourceItem) && notes.tasks.count == 3,
                   "Repeated summary toggles must keep canonical identity and no duplicate row")
        var reordered = try required(app.summary, "Summary missing before regeneration")
        reordered.items.reverse(); reordered.generatedAt += 1
        try app.write(reordered, app.meetingDirectory(meeting.id).appendingPathComponent("summary.json"))
        app.loadSelection(); notes.loadTasks()
        let reorderedItem = try required(app.summary?.items.first { $0.text == second.text }, "Regenerated task missing")
        try expect(notes.tasks.count == 3 && app.taskCompleted(reorderedItem) &&
                   notes.tasks.first(where: { $0.noteID == materialized.id })?.taskOrigin?.segmentIDs == second.segmentIDs,
                   "Regenerating summary order must retain completion, source evidence and one canonical task")
        print("PASS: tracker and summary share canonical completion and source links after summary reordering")

        let externalSource = try required(notes.tasks.first { $0.noteID == nil }, "Unmaterialized task required for external edit")
        notes.selectedTaskID = externalSource.id
        notes.captureDrafts["taskappend:\(externalSource.id)"] = "Уточнение до внешнего редактирования"
        notes.captureDrafts["tasksubtask:\(externalSource.id)"] = "Отдельный черновик исходной задачи"
        let externalData = try RustBridge.shared.get().request(root: root, command: "task-materialize", arguments: [
            "taskID": externalSource.id,
            "expectedSource": ["text": externalSource.text, "segmentIDs": externalSource.segmentIDs, "meetingID": meeting.id]
        ])
        let external = try JSONDecoder().decode(CapturedNote.self, from: externalData)
        let externalID = "manual:\(external.id)"
        // A second destination already has a different pending draft. Source
        // reconciliation must preserve both rather than silently replacing one.
        notes.captureDrafts["tasksubtask:\(externalID)"] = "Другой уже открытый черновик"
        notes.reload(); notes.loadTasks()
        try await waitUntil(host: host, window: window) { notes.selectedTaskID == externalID }
        try expect(notes.captureDrafts["taskappend:\(externalSource.id)"] == nil &&
                   notes.captureDrafts["taskappend:\(externalID)"] == "Уточнение до внешнего редактирования",
                   "External voice/domain canonicalization must migrate the pending task addition")
        try expect(notes.captureDrafts["tasksubtask:\(externalSource.id)"] == "Отдельный черновик исходной задачи" &&
                   notes.captureDrafts["tasksubtask:\(externalID)"] == "Другой уже открытый черновик",
                   "Reconciliation must preserve two independently edited drafts")
        try expect(notes.tasks.count == 3 && notes.tasks.filter { $0.noteID == external.id }.count == 1,
                   "External canonicalization must preserve one selected task row")
        print("PASS: external task canonicalization reconciles selection and drafts without overwriting another pending draft")

        notes.captureDrafts["newtask"] = "Подготовить вопросы к следующей встрече"
        notes.captureDrafts["taskappend:\(canonicalID)"] = "Уточнение, которое ещё не сохранено"
        notes.captureDrafts["tasksubtask:\(canonicalID)"] = "Проверить минимальную партию"
        let draftMetadata = ["owner": "Мария", "due": "2026-11-02", "revision": removedSubtask.revision] as [String: Any]
        notes.captureDrafts["taskmeta:\(canonicalID)"] = String(data: try JSONSerialization.data(withJSONObject: draftMetadata), encoding: .utf8)
        notes.captureKinds["quick:meeting"] = "question"
        try expect(notes.flushCaptureDrafts(), notes.error ?? "Draft persistence failed")
        let reopened = NotesStore(root: root); reopened.loadTasks()
        try expect(reopened.captureDrafts == notes.captureDrafts && reopened.captureKinds == notes.captureKinds && reopened.hasUnsavedCaptureDrafts,
                   "New-task, append, subtask, metadata and capture-kind drafts must reopen intact")
        let persisted = try required(reopened.notes.first { $0.id == materialized.id }, "Canonical task missing on reopen")
        try expect(persisted.text == appended.text && persisted.owner == "Анна" && persisted.due == "2026-10-30" &&
                   persisted.subtasks == remaining && persisted.completed && persisted.history.count >= 6,
                   "Reopen must preserve full task data and history independently of its drafts")
        try expect(reopened.tasks.count == 3, "Reopen must not recreate an original summary task beside its canonical task")
        notes.captureDrafts.removeAll(); notes.captureKinds.removeAll(); _ = notes.flushCaptureDrafts()
        print("PASS: task data, history and every task draft survive reopening without duplicates")
        print("7 native task E2E groups passed")
    }

    private static func makeFixture(_ app: AppStore) throws -> Meeting {
        var meeting = Meeting(title: "Согласование пилота", source: "synthetic.wav")
        meeting.status = "ready"
        let directory = app.meetingDirectory(meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try app.write(meeting, directory.appendingPathComponent("meta.json"))
        let facts: [[String: Any]] = [
            ["kind": "action", "text": "Запросить доступ к стенду", "owner": "", "due": "", "segmentIDs": [1]],
            ["kind": "action", "text": "Проверить договор поставки", "owner": "", "due": "", "segmentIDs": [2]],
            ["kind": "action", "text": "Подготовить список метрик", "owner": "", "due": "", "segmentIDs": [3]]
        ]
        let summary: Summary = try decode(["overview": "Обсудили условия пилота.", "items": facts, "cards": [],
                                           "provider": "fixture", "model": "synthetic", "generatedAt": 1, "warnings": []])
        try app.write(summary, directory.appendingPathComponent("summary.json"))
        let segments = facts.enumerated().map { index, fact in
            ["id": index + 1, "start": Double(index * 10), "end": Double(index * 10 + 5),
             "speaker": "speaker_1", "text": fact["text"] as! String, "overlap": false] as [String: Any]
        }
        let transcript: Transcript = try decode(["duration": 30, "segments": segments, "warnings": [], "model": "synthetic"])
        try app.write(transcript, directory.appendingPathComponent("transcript.json"))
        return meeting
    }
    private static func task(_ notes: NotesStore, noteID: String) throws -> LibraryTask {
        try required(notes.tasks.first { $0.noteID == noteID }, "Canonical task missing")
    }
    private static func assertSelection(_ host: NSView, taskID: String, rowCount: Int) throws {
        let rows = accessibilityNodes(host).filter { $0.accessibilityIdentifier()?.hasPrefix("tasks.row.") == true }
        let uniqueRows = Dictionary(grouping: rows, by: { $0.accessibilityIdentifier() ?? "" })
        if uniqueRows.count != rowCount {
            print("TASK AX diagnostics: hostFrame=\(host.frame), bounds=\(host.bounds), windowVisible=\(host.window?.isVisible ?? false), nodes=\(accessibilityNodes(host).count)")
            for node in accessibilityNodes(host).prefix(150) {
                print("TASK AX: type=\(type(of: node.object)) id=\(node.accessibilityIdentifier() ?? "nil") role=\(node.accessibilityRole()?.rawValue ?? "nil") label=\(node.accessibilityLabel() ?? "nil") value=\(String(describing: node.accessibilityValue())) children=\(node.accessibilityChildren()?.count ?? 0)")
            }
        }
        try expect(uniqueRows.count == rowCount, "All native task rows must expose their identity")
        let selected = uniqueRows.filter { _, nodes in nodes.contains { ($0.accessibilityValue() as? String) == "Выбрана" } }
        try expect(selected.count == 1 && selected.keys.first == "tasks.row." + taskID,
                   "Exactly the actual task must be selected; nil note IDs must never select all rows")
    }
    /// SwiftUI's virtual nodes expose AppKit's public accessibility selectors
    /// without declaring NSAccessibilityProtocol conformance. Native controls
    /// use the typed protocol; virtual nodes use those same public selectors.
    private struct AccessibilityNode {
        let object: NSObject
        private var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
        private func value(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func accessibilityIdentifier() -> String? {
            modern?.accessibilityIdentifier() ?? value("accessibilityIdentifier") as? String
        }
        func accessibilityValue() -> Any? {
            if let modern { return modern.accessibilityValue() }
            return value("accessibilityValue")
        }
        func accessibilityLabel() -> String? {
            modern?.accessibilityLabel() ?? value("accessibilityLabel") as? String
        }
        func accessibilityRole() -> NSAccessibility.Role? {
            if let modern { return modern.accessibilityRole() }
            guard let role = value("accessibilityRole") as? String else { return nil }
            return NSAccessibility.Role(rawValue: role)
        }
        func accessibilityChildren() -> [Any]? {
            if let modern { return modern.accessibilityChildren() }
            return value("accessibilityChildren") as? [Any]
        }
        func accessibilityPerformPress() -> Bool {
            if let modern { return modern.accessibilityPerformPress() }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Press.self)(object, selector)
        }
    }
    private static func accessibilityNodes(_ root: Any) -> [AccessibilityNode] {
        var nodes: [AccessibilityNode] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 80, let object = value as? NSObject else { return }
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = AccessibilityNode(object: object)
            nodes.append(node)
            for child in node.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return nodes
    }
    private static func waitUntil(host: NSView, window: NSWindow, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() {
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Native task view did not settle")
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func decode<T: Decodable>(_ object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw AppError.message(message) }; return value
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AppError.message(message) }
    }
}
#endif
