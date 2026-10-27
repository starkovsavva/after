import AppKit
import Foundation
import PosleCore

extension NotesStore {
    @discardableResult func materializeTask(_ task: LibraryTask) -> CapturedNote? {
        performTaskOperation(task, command: "task-materialize", arguments: [:])
    }
    @discardableResult func updateTask(_ task: LibraryTask, patch: [String: Any], expectedRevision: Int? = nil) -> CapturedNote? {
        var arguments: [String: Any] = ["patch": patch]
        if let revision = expectedRevision ?? task.noteRevision { arguments["expectedRevision"] = revision }
        return performTaskOperation(task, command: "task-update", arguments: arguments)
    }
    @discardableResult func appendTask(_ task: LibraryTask, text: String) -> CapturedNote? {
        var arguments: [String: Any] = ["text": text]
        if let revision = task.noteRevision { arguments["expectedRevision"] = revision }
        return performTaskOperation(task, command: "task-append", arguments: arguments)
    }
    /// A voice command can materialize a summary task while its inline draft
    /// is hidden. Reconcile by stable provenance instead of a summary position.
    func reconcileTaskDrafts() {
        for task in tasks {
            guard let originalID = task.taskOrigin?.summaryTaskID, originalID != task.id else { continue }
            for prefix in ["taskappend", "tasksubtask", "taskmeta", "taskthought"] {
                let original = "\(prefix):\(originalID)"
                let canonical = "\(prefix):\(task.id)"
                if let text = captureDrafts[original], captureDrafts[canonical] == nil || captureDrafts[canonical] == "" {
                    captureDrafts[canonical] = text
                    captureDrafts.removeValue(forKey: original)
                }
            }
            if selectedTaskID == originalID { selectedTaskID = task.id }
        }
    }
    /// Editing a generated task explicitly accepts it into the tracker. Bind
    /// the first character to a UUID before a regenerated summary can remove it.
    func setTaskDraft(_ text: String, task: LibraryTask, prefix: String) {
        let original = "\(prefix):\(task.id)"
        guard task.noteID == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            captureDrafts[original] = text
            return
        }
        guard let note = materializeTask(task) else {
            captureDrafts[original] = text
            return
        }
        captureDrafts["\(prefix):manual:\(note.id)"] = text
    }
    private func performTaskOperation(_ task: LibraryTask, command: String, arguments: [String: Any]) -> CapturedNote? {
        do {
            var input = arguments; input["taskID"] = task.id
            if task.noteID == nil, let meetingID = task.meetingID {
                input["expectedSource"] = ["text": task.text, "segmentIDs": task.segmentIDs, "meetingID": meetingID]
            }
            let data = try RustBridge.shared.get().request(root: root, command: command, arguments: input)
            let saved = try JSONDecoder().decode(CapturedNote.self, from: data)
            let canonicalID = "manual:\(saved.id)"
            reload(); loadTasks(); loadTaskWorkspaces(); selectedTaskID = canonicalID; error = nil
            return saved
        } catch { self.error = error.localizedDescription; return nil }
    }
}


extension NotesStore {
    func loadTaskWorkspaces() {
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "task-list", arguments: ["includeDetails": false])
            let response = try JSONDecoder().decode(TaskWorkspacesResponse.self, from: data)
            taskWorkspaces = Dictionary(uniqueKeysWithValues: response.tasks.map { ($0.id, $0) })
            loadSelectedTaskWorkspace()
        } catch { self.error = error.localizedDescription }
    }

    /// One detailed read for the selected task. List rows never expand note or
    /// transcript bodies and never fetch every task's historical snapshots.
    func loadSelectedTaskWorkspace() {
        guard let selected = selectedTaskID else { return }
        let canonical = tasks.first { $0.id == selected || $0.noteID == selected || $0.taskOrigin?.summaryTaskID == selected }?.id ?? selected
        _ = loadTaskWorkspace(canonical)
    }
    @discardableResult func loadTaskWorkspace(_ taskID: String) -> TaskWorkspace? {
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "task-get", arguments: ["taskID": taskID])
            let task = try JSONDecoder().decode(TaskWorkspace.self, from: data)
            taskWorkspaces[task.id] = task
            return task
        } catch { self.error = error.localizedDescription; return nil }
    }

    func taskWorkspace(for task: LibraryTask) -> TaskWorkspace {
        if let value = taskWorkspaces[task.id] { return value }
        let title = task.taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return TaskWorkspace(id: task.id, title: title.isEmpty ? task.text.split(separator: "\n").first.map(String.init) ?? "Новая задача" : title,
            text: task.text, status: task.completed ? .done : .todo, completed: task.completed,
            owner: task.owner, due: task.due, revision: task.noteRevision ?? 0,
            virtual: task.noteID == nil, meetingID: task.meetingID)
    }

    /// Metadata list responses contain an excerpt. Search the canonical body
    /// already loaded by notes-tasks, without reading each detailed workspace.
    func taskMatchesQuery(_ task: TaskWorkspace, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let body = tasks.first { $0.id == task.id || $0.taskOrigin?.summaryTaskID == task.id }?.text ?? task.text
        return [task.title, body, task.owner, task.project, task.due].joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    func legacyTask(for task: TaskWorkspace) -> LibraryTask? {
        tasks.first { $0.id == task.id || $0.taskOrigin?.summaryTaskID == task.id }
    }

    @discardableResult
    func createWorkspaceTask(title: String, text: String = "", project: String = "",
                             source: TaskWorkspaceSource = .local, externalURL: String = "",
                             due: String = "", owner: String = "") -> TaskWorkspace? {
        taskWorkspaceRequest("task-create", arguments: ["title": title, "text": text, "project": project,
            "source": source.rawValue, "externalURL": externalURL, "due": due, "owner": owner,
            "operationID": UUID().uuidString.lowercased()])
    }

    @discardableResult
    func updateTaskWorkspace(_ task: TaskWorkspace, patch: [String: Any]) -> TaskWorkspace? {
        mutateTaskWorkspace(task, command: "task-details-update", arguments: ["patch": patch])
    }

    @discardableResult
    func linkTaskMaterial(_ material: TaskMaterial, to task: TaskWorkspace) -> TaskWorkspace? {
        do {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(material))
            return mutateTaskWorkspace(task, command: "task-material-link", arguments: ["material": object])
        } catch { self.error = error.localizedDescription; return nil }
    }

    @discardableResult
    func shareTaskMaterial(_ material: TaskMaterial, task: TaskWorkspace, shared: Bool) -> TaskWorkspace? {
        guard let id = material.id else { return nil }
        return mutateTaskWorkspace(task, command: "task-material-link", arguments: ["material": ["id": id, "shared": shared]])
    }

    func unlinkTaskMaterial(_ material: TaskMaterial, from task: TaskWorkspace) {
        guard let id = material.id else { return }
        _ = mutateTaskWorkspace(task, command: "task-material-unlink", arguments: ["materialID": id])
    }

    private func mutateTaskWorkspace(_ task: TaskWorkspace, command: String, arguments: [String: Any]) -> TaskWorkspace? {
        var input = arguments
        input["taskID"] = task.id; input["expectedRevision"] = task.revision
        if task.virtual { input["expectedSourceFingerprint"] = task.sourceFingerprint }
        input["operationID"] = UUID().uuidString.lowercased()
        return taskWorkspaceRequest(command, arguments: input)
    }

    private func taskWorkspaceRequest(_ command: String, arguments: [String: Any]) -> TaskWorkspace? {
        guard !taskWorkspaceBusy else { return nil }
        taskWorkspaceBusy = true
        defer { taskWorkspaceBusy = false }
        do {
            let data = try RustBridge.shared.get().request(root: root, command: command, arguments: arguments)
            let saved = try JSONDecoder().decode(TaskWorkspace.self, from: data)
            reload(); loadTasks(); loadTaskWorkspaces()
            taskWorkspaces[saved.id] = saved
            selectedTaskID = saved.id; error = nil
            return saved
        } catch { self.error = error.localizedDescription; return nil }
    }

    func taskThought(for task: TaskWorkspace) -> String { captureDrafts["taskthought:\(task.id)"] ?? "" }
    func setTaskThought(_ text: String, task: TaskWorkspace) {
        if let legacy = legacyTask(for: task) { setTaskDraft(text, task: legacy, prefix: "taskthought") }
        else { captureDrafts["taskthought:\(task.id)"] = text }
    }
    func saveTaskThought(_ task: TaskWorkspace) {
        let key = "taskthought:\(task.id)"
        let text = (captureDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let title = String(text.split(separator: "\n").first.map(String.init)?.prefix(100) ?? "Мысль к задаче")
        if linkTaskMaterial(TaskMaterial(kind: "note", title: title, text: text, shared: task.agentAccess.enabled), to: task) != nil {
            captureDrafts.removeValue(forKey: key)
        }
    }

    @discardableResult func chooseTaskFolder(_ task: TaskWorkspace, repository: Bool) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = repository ? "Выберите папку репозитория. Сохранится только ссылка." : "Выберите папку. Файлы не копируются и не читаются."
        panel.prompt = "Прикрепить"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return linkTaskMaterial(TaskMaterial(kind: repository ? "repository" : "folder",
            title: url.lastPathComponent, path: url.path), to: task) != nil
    }

    func chooseTaskFile(_ task: TaskWorkspace) {
        guard !attachmentBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "Прикрепить выбранный файл к задаче"; panel.prompt = "Прикрепить"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachTaskFile(url, to: task)
    }

    /// Import only the file explicitly selected by the user; Rust owns the copy
    /// and its limits. Linking uses the real attachment identity, never a fake path.
    func attachTaskFile(_ url: URL, to task: TaskWorkspace) {
        guard !attachmentBusy else { error = "Дождитесь добавления текущего файла."; return }
        var holder = CapturedNote(); holder.title = url.lastPathComponent
        guard let saved = save(holder) else { return }
        attachmentBusy = true
        Task {
            defer { attachmentBusy = false }
            do {
                let root = self.root; let noteID = saved.id; let revision = saved.revision
                let data = try await Task.detached(priority: .userInitiated) {
                    try RustBridge.shared.get().request(root: root, command: "note-attach", arguments: ["noteID": noteID, "revision": revision, "path": url.path])
                }.value
                let imported = try JSONDecoder().decode(CapturedNote.self, from: data)
                reload()
                guard let attachment = imported.attachments.last else { throw AppError.message("Файл не был добавлен к заметке.") }
                _ = linkTaskMaterial(TaskMaterial(kind: "file", title: attachment.name, noteID: imported.id, attachmentID: attachment.id), to: task)
            } catch {
                let message = error.localizedDescription
                // Only remove our untouched, empty import holder. A successful
                // import that later conflicts remains recoverable in Notes.
                if let empty = workspace.notes.first(where: { $0.id == saved.id }),
                   empty.revision == saved.revision, empty.attachments.isEmpty, empty.text.isEmpty {
                    delete(empty)
                }
                self.error = message
            }
        }
    }
}

extension NotesStore {
    func taskContext(_ task: TaskWorkspace) -> TaskContextSnapshot? {
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "task-context", arguments: ["taskID": task.id, "agentOnly": false, "sharedOnly": true])
            return try JSONDecoder().decode(TaskContextSnapshot.self, from: data)
        } catch { self.error = error.localizedDescription; return nil }
    }
}
