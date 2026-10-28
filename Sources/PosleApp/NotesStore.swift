import AppKit
import Combine
import Foundation
import PosleCore
import UniformTypeIdentifiers
import Vision

/// Native capture state; all durable edits pass through the Rust revision checks.
@MainActor
final class NotesStore: ObservableObject {
    let root: URL
    let refreshState = NotesRefreshState()
    private var sortedNotes: [CapturedNote] = []
    private var contextsByMeeting: [String: MeetingContext] = [:]
    @Published var workspace = NotesWorkspace(notes: [], templates: [], contexts: []) {
        didSet {
            refreshState.revision &+= 1
            sortedNotes = workspace.notes.filter { $0.trashedAt == nil }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.updatedAt > $1.updatedAt }
            contextsByMeeting = Dictionary(workspace.contexts.map { ($0.meetingID, $0) }, uniquingKeysWith: { _, newer in newer })
        }
    }
    @Published var error: String?
    @Published var notice: String?
    @Published var attachmentBusy = false
    @Published var tasks: [LibraryTask] = [] { didSet { refreshState.revision &+= 1 } }
    @Published var selectedTaskID: String?
    @Published var selectedTaskProject = "all"
    @Published var taskNavigationRequest = UUID()
    var pendingTaskNavigationID: String?
    @Published var taskWorkspaces: [String: TaskWorkspace] = [:] { didSet { refreshState.revision &+= 1 } }
    @Published var taskWorkspaceBusy = false
    @Published var newLibraryNoteRequest = UUID()
    @Published var selectedNoteID: String?
    @Published var highlightedNoteID: String?
    @Published var hotkeyNotice: String?
    @Published var captureDrafts: [String: String] = [:] { didSet { scheduleDraftPersistence() } }
    @Published var captureKinds: [String: String] = [:] { didSet { scheduleDraftPersistence() } }
    @Published var editingNewTask = false
    /// Drafts keep their original destination across navigation and restarts.
    /// Hidden drafts remain part of the update gate until saved or discarded.
    var firstPendingCaptureDraftKey: String? {
        captureDrafts.keys.sorted().first { key in
            !(captureDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var hasUnsavedCaptureDrafts: Bool { firstPendingCaptureDraftKey != nil }
    @Published var contextSelection: String?
    var contextMode = "project"
    private struct Drafts: Codable { var texts: [String: String]; var kinds: [String: String] }
    private var draftSaveTask: Task<Void, Never>?
    private var restoringDrafts = false
    init(root: URL) {
        self.root = root; reload()
        restoringDrafts = true
        if let bridge = try? RustBridge.shared.get(),
           let data = try? bridge.read(root: root, url: root.appendingPathComponent("capture-drafts.json")),
           let drafts = try? JSONDecoder().decode(Drafts.self, from: data) {
            captureDrafts = drafts.texts; captureKinds = drafts.kinds
        }
        restoringDrafts = false
    }
    private func scheduleDraftPersistence() {
        guard !restoringDrafts else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            _ = self?.flushCaptureDrafts()
        }
    }
    @discardableResult func flushCaptureDrafts() -> Bool {
        draftSaveTask?.cancel(); draftSaveTask = nil
        do {
            try RustBridge.shared.get().write(root: root, url: root.appendingPathComponent("capture-drafts.json"),
                value: Drafts(texts: captureDrafts, kinds: captureKinds))
            return true
        } catch {
            self.error = "Не удалось сохранить черновик. Ваш текст остался в редакторе."; return false
        }
    }
    var notes: [CapturedNote] { sortedNotes }
    var templates: [NoteTemplate] { workspace.templates }
    func notes(for meetingID: String?) -> [CapturedNote] { notes.filter { $0.meetingID == meetingID } }
    func inbox(meetingIDs: Set<String>) -> [CapturedNote] {
        notes.filter { note in note.meetingID.map { !meetingIDs.contains($0) } ?? true }
    }
    func context(for meetingID: String) -> MeetingContext {
        contextsByMeeting[meetingID] ?? MeetingContext(meetingID: meetingID)
    }
    func reload() {
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "notes-list")
            workspace = try JSONDecoder().decode(NotesWorkspace.self, from: data)
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func save(_ note: CapturedNote) -> CapturedNote? {
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "note-save", arguments: ["note": try object(note)])
            let saved = try JSONDecoder().decode(CapturedNote.self, from: data)
            accept(saved); return saved
        } catch { self.error = error.localizedDescription; return nil }
    }
    @discardableResult func capture(text: String, kind: String = "note", meetingID: String? = nil, timestamp: Double? = nil, sourceURL: String = "", folderID: String? = nil) -> CapturedNote? {
        var note = CapturedNote(text: text)
        note.kind = kind; note.meetingID = meetingID; note.timestamp = timestamp; note.sourceURL = sourceURL; note.folderID = folderID
        guard let saved = save(note) else { return nil }
        notice = kind == "important" ? "Момент отмечен" : "Заметка сохранена"
        return saved
    }
    func delete(_ note: CapturedNote) {
        do {
            _ = try RustBridge.shared.get().request(root: root, command: "note-trash", arguments: ["id": note.id, "revision": note.revision])
            error = nil; reload()
            if selectedNoteID == note.id { selectedNoteID = nil }
        } catch { self.error = error.localizedDescription }
    }
    func restore(_ note: CapturedNote) {
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "note-restore", arguments: ["id": note.id, "revision": note.revision])
            accept(try JSONDecoder().decode(CapturedNote.self, from: data))
        } catch { self.error = error.localizedDescription }
    }
    func purge(_ note: CapturedNote) {
        do {
            _ = try RustBridge.shared.get().request(root: root, command: "note-delete", arguments: ["id": note.id, "revision": note.revision])
            error = nil
            workspace.notes.removeAll { $0.id == note.id }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func saveContext(_ context: MeetingContext) -> Bool {
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "context-save", arguments: ["context": try object(context)])
            let saved = try JSONDecoder().decode(MeetingContext.self, from: data)
            workspace.contexts.removeAll { $0.meetingID == saved.meetingID }; workspace.contexts.append(saved)
            error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func saveTemplate(_ template: NoteTemplate) -> Bool {
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "template-save", arguments: ["template": try object(template)])
            let saved = try JSONDecoder().decode(NoteTemplate.self, from: data)
            workspace.templates.removeAll { $0.id == saved.id }; workspace.templates.append(saved)
            error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func deleteTemplate(_ template: NoteTemplate) -> Bool {
        do {
            _ = try RustBridge.shared.get().request(root: root, command: "template-delete", arguments: ["id": template.id, "revision": template.revision])
            workspace.templates.removeAll { $0.id == template.id }
            error = nil; reload() // Rust also clears template references and advances context revisions.
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func chooseAttachments(for note: CapturedNote) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "Добавить файлы к заметке"
        if panel.runModal() == .OK { attach(panel.urls, to: note.id) }
    }
    func attach(_ urls: [URL], to noteID: String) {
        guard !attachmentBusy else { error = "Дождитесь добавления текущего файла."; return }
        attachmentBusy = true
        Task {
            defer { attachmentBusy = false }
            for url in urls.prefix(20) {
                guard let note = workspace.notes.first(where: { $0.id == noteID }) else { break }
                do {
                    let root = self.root; let revision = note.revision
                    let data = try await Task.detached(priority: .userInitiated) { try RustBridge.shared.get().request(root: root, command: "note-attach", arguments: ["noteID": noteID, "revision": revision, "path": url.path]) }.value
                    accept(try JSONDecoder().decode(CapturedNote.self, from: data))
                } catch { self.error = error.localizedDescription; break }
            }
        }
    }
    func removeAttachment(_ attachment: NoteAttachment, from note: CapturedNote) {
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "attachment-remove", arguments: ["noteID": note.id, "attachmentID": attachment.id, "revision": note.revision])
            accept(try JSONDecoder().decode(CapturedNote.self, from: data))
        } catch { self.error = error.localizedDescription }
    }
    func openAttachment(_ attachment: NoteAttachment, note: CapturedNote) {
        do { NSWorkspace.shared.open(try attachmentURL(attachment, note: note)) }
        catch { self.error = error.localizedDescription }
    }
    func recognize(_ attachment: NoteAttachment, note: CapturedNote) {
        guard !attachmentBusy else { return }
        do {
            let url = try attachmentURL(attachment, note: note)
            attachmentBusy = true
            Task {
                defer { attachmentBusy = false }
                do {
                    let text = try await Task.detached(priority: .userInitiated) {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
                        request.recognitionLanguages = ["ru-RU", "en-US"]
                        try VNImageRequestHandler(url: url).perform([request])
                        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    }.value
                    guard let current = workspace.notes.first(where: { $0.id == note.id }) else { return }
                    let data = try RustBridge.shared.get().request(root: root, command: "attachment-text", arguments: ["noteID": current.id, "attachmentID": attachment.id, "revision": current.revision, "text": text])
                    accept(try JSONDecoder().decode(CapturedNote.self, from: data))
                    notice = text.isEmpty ? "Текст на изображении не найден" : "Текст распознан на Mac"
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    /// Paste reads only the content the user explicitly asked to add.
    func paste(into note: CapturedNote, board: NSPasteboard = .general) {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            attach(urls, to: note.id); return
        }
        if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("posle-paste-\(UUID().uuidString).png")
            do {
                try png.write(to: temporary, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                guard !attachmentBusy else { try? FileManager.default.removeItem(at: temporary); return }
                let data = try RustBridge.shared.get().request(root: root, command: "note-attach", arguments: ["noteID": note.id, "revision": note.revision, "path": temporary.path])
                accept(try JSONDecoder().decode(CapturedNote.self, from: data)); try? FileManager.default.removeItem(at: temporary)
            } catch { try? FileManager.default.removeItem(at: temporary); self.error = error.localizedDescription }
            return
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            var updated = note; updated.text += (updated.text.isEmpty ? "" : "\n") + text; _ = save(updated)
        }
    }
    func receiveDrop(_ providers: [NSItemProvider], noteID: String) -> Bool {
        let accepted = providers.contains { $0.canLoadObject(ofClass: URL.self) || $0.canLoadObject(ofClass: String.self) || $0.canLoadObject(ofClass: NSImage.self) }
        guard accepted, !attachmentBusy else { return false }
        attachmentBusy = true
        Task {
            defer { attachmentBusy = false }
            for provider in providers.prefix(20) {
                var fileURL: URL?
                var temporary: URL?
                var appendedText: String?
                if provider.canLoadObject(ofClass: URL.self) {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { value, _ in continuation.resume(returning: value) }
                    }
                    if let url { if url.isFileURL { fileURL = url } else { appendedText = url.absoluteString } }
                } else if provider.canLoadObject(ofClass: NSImage.self) {
                    let image: NSImage? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: NSImage.self) { value, _ in continuation.resume(returning: value as? NSImage) }
                    }
                    if let data = image?.tiffRepresentation, data.count <= 25 * 1024 * 1024,
                       let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("posle-drop-\(UUID().uuidString).png")
                        do { try png.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); fileURL = url; temporary = url }
                        catch { self.error = error.localizedDescription }
                    }
                } else if provider.canLoadObject(ofClass: String.self) {
                    appendedText = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: String.self) { value, _ in continuation.resume(returning: value) }
                    }
                }
                defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
                guard let current = workspace.notes.first(where: { $0.id == noteID }) else { break }
                if let fileURL {
                    do {
                        let data = try RustBridge.shared.get().request(root: root, command: "note-attach", arguments: ["noteID": noteID, "revision": current.revision, "path": fileURL.path])
                        accept(try JSONDecoder().decode(CapturedNote.self, from: data))
                    } catch { self.error = error.localizedDescription }
                } else if let appendedText {
                    var updated = current; updated.text += (updated.text.isEmpty ? "" : "\n") + appendedText; _ = save(updated)
                }
            }
        }
        return true
    }
    func loadTasks() {
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "notes-tasks")
            tasks = try JSONDecoder().decode(LibraryTasksResponse.self, from: data).tasks
            reconcileTaskDrafts()
        } catch { self.error = error.localizedDescription }
    }
    func complete(_ task: LibraryTask, completed: Bool) {
        if let noteID = task.noteID, var note = workspace.notes.first(where: { $0.id == noteID }) {
            note.completed = completed
            if save(note) != nil { loadTasks() }
        } else if let meetingID = task.meetingID, let index = task.itemIndex {
            do {
                _ = try RustBridge.shared.get().request(root: root, command: "notes-task-complete", arguments: ["meetingID": meetingID, "itemIndex": index, "text": task.text, "expectedSegmentIDs": task.segmentIDs, "completed": completed])
                loadTasks()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func attachmentURL(_ attachment: NoteAttachment, note: CapturedNote) throws -> URL {
        struct Response: Decodable { var path: String }
        let data = try RustBridge.shared.get().request(root: root, command: "attachment-path", arguments: ["noteID": note.id, "attachmentID": attachment.id])
        return URL(fileURLWithPath: try JSONDecoder().decode(Response.self, from: data).path)
    }
    private func accept(_ note: CapturedNote) {
        error = nil
        workspace.notes.removeAll { $0.id == note.id }; workspace.notes.append(note)
    }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
}
