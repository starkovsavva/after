import AfterPlatform
import AfterLocalization
import AfterCore
import SwiftUI

struct TaskCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var notes: NotesStore
    let task: TaskWorkspace?
    let initialFolderID: String?
    let completion: (TaskWorkspace) -> Void
    private let draftKey: String
    private let detailLoader: (String) async throws -> TaskWorkspace
    @State private var initialValues: [String]
    @State private var editingTask: TaskWorkspace?
    @State private var loading: Bool
    @State private var loadInFlight = false
    @State private var loadError: String?
    @State private var editorID = UUID()
    @State private var confirmingDiscard = false
    @State private var title: String
    @State private var text: String
    @State private var project: String
    @State private var source: TaskWorkspaceSource
    @State private var externalURL: String
    @State private var owner: String
    @State private var due: String
    init(notes: NotesStore, task: TaskWorkspace? = nil, initialProject: String = "", initialSource: TaskWorkspaceSource = .local, initialFolderID: String? = nil, detailLoader: ((String) async throws -> TaskWorkspace)? = nil, completion: @escaping (TaskWorkspace) -> Void) {
        self.notes = notes; self.task = task; self.initialFolderID = initialFolderID; self.completion = completion
        let key = initialFolderID.map { "newtask:folder:" + $0 } ?? "newtask"
        self.draftKey = key
        self.detailLoader = detailLoader ?? { try await notes.taskWorkspaceForEditing($0) }
        // List rows deliberately contain excerpts. An existing task must never
        // seed an editable body or revision until its authoritative read finishes.
        let newTitle = task == nil ? notes.captureDrafts[key] ?? "" : ""
        _initialValues = State(initialValue: [newTitle, "", initialProject, initialSource.rawValue, "", "", ""])
        _loading = State(initialValue: task != nil)
        _title = State(initialValue: newTitle)
        _text = State(initialValue: "")
        _project = State(initialValue: initialProject)
        _source = State(initialValue: initialSource)
        _externalURL = State(initialValue: "")
        _owner = State(initialValue: "")
        _due = State(initialValue: "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppPageHeader(title: task == nil ? L("Новая задача") : L("Изменить задачу"), modal: true)
            if task == nil, let folder = notes.folder(initialFolderID) {
                Label(folder.name, systemImage: "folder").font(AppTypography.caption).foregroundStyle(.secondary)
            }
            if loading {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L("Загружаю задачу…")).font(AppTypography.control).foregroundStyle(.secondary) }
                    .accessibilityIdentifier("tasks.form.loading")
            }
            if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError).font(AppTypography.control).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true)
                    Button(L("Повторить")) { Task { await loadForEditing() } }.accessibilityIdentifier("tasks.form.retry")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(L("Название")) { TextField(L("Что нужно сделать"), text: $title).accessibilityIdentifier("tasks.form.title") }
                    field(L("Описание")) { TextField(L("Детали задачи"), text: $text, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("tasks.form.description") }
                    HStack(alignment: .top, spacing: 16) {
                        field(L("Проект")) { TextField(L("Не указан"), text: $project) }
                        field(L("Ответственный")) { TextField(L("Не указан"), text: $owner) }
                    }
                    field(L("Срок")) {
                        HStack {
                            TextField(L("ГГГГ-ММ-ДД или без срока"), text: $due).accessibilityIdentifier("tasks.due-date")
                            Menu {
                                Button(L("Сегодня")) { due = TaskDueDate.storage(Date()) }.accessibilityIdentifier("tasks.due-today")
                                Button(L("Завтра")) { if let date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) { due = TaskDueDate.storage(date) } }.accessibilityIdentifier("tasks.due-tomorrow")
                                Button(L("Без срока")) { due = "" }.accessibilityIdentifier("tasks.due-none")
                            } label: { Image(systemName: "calendar") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("Выбрать срок"))
                        }
                    }
                    field(L("Источник")) {
                        Picker(L("Источник"), selection: $source) { ForEach(TaskWorkspaceSource.allCases) { Text(L($0.title)).tag($0) } }.labelsHidden()
                    }
                    if source != .local {
                        field(L("Ссылка на оригинал")) { TextField("https://…", text: $externalURL).accessibilityIdentifier("tasks.form.external-url") }
                        Text(L("Статус и материалы хранятся в «After». Оригинал по ссылке обновляется отдельно.")).font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                }.textFieldStyle(.roundedBorder).disabled(!ready || loading || notes.taskWorkspaceBusy)
            }
            if let error = notes.error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L("Отмена")) { if dirty { confirmingDiscard = true } else { close() } }.keyboardShortcut(.cancelAction).accessibilityIdentifier("tasks.form.cancel")
                Button(task == nil ? L("Создать") : L("Сохранить"), action: save)
                    .buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.defaultAction)
                    .disabled(!ready || loading || !valid || notes.taskWorkspaceBusy).accessibilityIdentifier("tasks.form.save")
            }
        }.padding(24).frame(width: 540).frame(minHeight: 540, idealHeight: 650).appControlDefaults()
            .onChange(of: title) { _, value in if task == nil { notes.captureDrafts[draftKey] = value } }
            .interactiveDismissDisabled(dirty)
            .onAppear { registerDraft() }
            .task(id: task?.id) { await loadForEditing() }
            .onChange(of: dirty) { _, _ in registerDraft() }
            .onDisappear { UnsavedEditorRegistry.remove(id: editorID) }
            .confirmationDialog(L("Отменить изменения задачи?"), isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button(L("Продолжить редактирование"), role: .cancel) {}
                Button(L("Отменить изменения"), role: .destructive) { close() }.accessibilityIdentifier("tasks.form.discard")
            }
    }
    private var ready: Bool { task == nil || editingTask?.id == task?.id }
    private var dirty: Bool { ready && [title, text, project, source.rawValue, externalURL, owner, due] != initialValues }
    private func loadForEditing() async {
        guard let taskID = task?.id, editingTask == nil, !loadInFlight else { return }
        loadInFlight = true; loading = true; loadError = nil
        defer { loadInFlight = false; loading = false }
        do {
            let loaded = try await detailLoader(taskID)
            try Task.checkCancellation()
            guard loaded.id == taskID else { throw AppError.message(L("Не удалось загрузить выбранную задачу. Повторите попытку.")) }
            title = loaded.title; text = loaded.text; project = loaded.project; source = loaded.source
            externalURL = loaded.externalURL; owner = loaded.owner; due = loaded.due
            initialValues = [title, text, project, source.rawValue, externalURL, owner, due]
            editingTask = loaded
            registerDraft()
        } catch is CancellationError {
            // Closing the sheet must not publish an error or a late draft.
        } catch { loadError = error.localizedDescription }
    }
    private func registerDraft() {
        UnsavedEditorRegistry.set(id: editorID, title: task == nil ? L("Новая задача") : L("Правка задачи"), dirty: dirty)
    }
    private func close() { UnsavedEditorRegistry.remove(id: editorID); dismiss() }
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (source == .local || TaskWorkspaceURL.external(externalURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(AppTypography.controlStrong); content() }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func save() {
        guard ready, !loading, valid, !notes.taskWorkspaceBusy else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = source == .local ? "" : externalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved: TaskWorkspace?
        if let task = editingTask {
            saved = notes.updateTaskWorkspace(task, patch: ["title": title, "text": text, "project": project,
                "source": source.rawValue, "externalURL": url, "owner": owner, "due": due])
        } else {
            saved = notes.createWorkspaceTask(title: title, text: text, project: project, source: source,
                externalURL: url, due: due, owner: owner, folderID: initialFolderID)
        }
        if let saved { if task == nil { notes.captureDrafts.removeValue(forKey: draftKey) }; completion(saved); close() }
    }
}
