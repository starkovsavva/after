import PosleCore
import SwiftUI

struct TaskCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var notes: NotesStore
    let task: TaskWorkspace?
    let completion: (TaskWorkspace) -> Void
    private let initialValues: [String]
    @State private var editorID = UUID()
    @State private var confirmingDiscard = false
    @State private var title: String
    @State private var text: String
    @State private var project: String
    @State private var source: TaskWorkspaceSource
    @State private var externalURL: String
    @State private var owner: String
    @State private var due: String
    init(notes: NotesStore, task: TaskWorkspace? = nil, initialProject: String = "", initialSource: TaskWorkspaceSource = .local, completion: @escaping (TaskWorkspace) -> Void) {
        self.notes = notes; self.task = task; self.completion = completion
        initialValues = [task?.title ?? notes.captureDrafts["newtask"] ?? "", task?.text ?? "",
            task?.project ?? initialProject, (task?.source ?? initialSource).rawValue,
            task?.externalURL ?? "", task?.owner ?? "", task?.due ?? ""]
        _title = State(initialValue: task?.title ?? notes.captureDrafts["newtask"] ?? "")
        _text = State(initialValue: task?.text ?? "")
        _project = State(initialValue: task?.project ?? initialProject)
        _source = State(initialValue: task?.source ?? initialSource)
        _externalURL = State(initialValue: task?.externalURL ?? "")
        _owner = State(initialValue: task?.owner ?? "")
        _due = State(initialValue: task?.due ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppPageHeader(title: task == nil ? "Новая задача" : "Изменить задачу", modal: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Название") { TextField("Что нужно сделать", text: $title).accessibilityIdentifier("tasks.form.title") }
                    field("Описание") { TextField("Детали задачи", text: $text, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("tasks.form.description") }
                    HStack(alignment: .top, spacing: 16) {
                        field("Проект") { TextField("Не указан", text: $project) }
                        field("Ответственный") { TextField("Не указан", text: $owner) }
                    }
                    field("Срок") {
                        HStack {
                            TextField("ГГГГ-ММ-ДД или без срока", text: $due).accessibilityIdentifier("tasks.due-date")
                            Menu {
                                Button("Сегодня") { due = TaskDueDate.storage(Date()) }.accessibilityIdentifier("tasks.due-today")
                                Button("Завтра") { if let date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) { due = TaskDueDate.storage(date) } }.accessibilityIdentifier("tasks.due-tomorrow")
                                Button("Без срока") { due = "" }.accessibilityIdentifier("tasks.due-none")
                            } label: { Image(systemName: "calendar") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Выбрать срок")
                        }
                    }
                    field("Источник") {
                        Picker("Источник", selection: $source) { ForEach(TaskWorkspaceSource.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                    }
                    if source != .local {
                        field("Ссылка на оригинал") { TextField("https://…", text: $externalURL).accessibilityIdentifier("tasks.form.external-url") }
                        Text("Статус и материалы хранятся в «После». Оригинал по ссылке обновляется отдельно.").font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                }.textFieldStyle(.roundedBorder)
            }
            if let error = notes.error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Отмена") { if dirty { confirmingDiscard = true } else { close() } }.keyboardShortcut(.cancelAction).accessibilityIdentifier("tasks.form.cancel")
                Button(task == nil ? "Создать" : "Сохранить", action: save)
                    .buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.defaultAction)
                    .disabled(!valid || notes.taskWorkspaceBusy).accessibilityIdentifier("tasks.form.save")
            }
        }.padding(24).frame(width: 540).frame(minHeight: 540, idealHeight: 650).appControlDefaults()
            .onChange(of: title) { _, value in if task == nil { notes.captureDrafts["newtask"] = value } }
            .interactiveDismissDisabled(dirty)
            .onAppear { registerDraft() }
            .onChange(of: dirty) { _, _ in registerDraft() }
            .onDisappear { UnsavedEditorRegistry.remove(id: editorID) }
            .confirmationDialog("Отменить изменения задачи?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Продолжить редактирование", role: .cancel) {}
                Button("Отменить изменения", role: .destructive) { close() }.accessibilityIdentifier("tasks.form.discard")
            }
    }
    private var dirty: Bool { [title, text, project, source.rawValue, externalURL, owner, due] != initialValues }
    private func registerDraft() {
        UnsavedEditorRegistry.set(id: editorID, title: task == nil ? "Новая задача" : "Правка задачи", dirty: dirty)
    }
    private func close() { UnsavedEditorRegistry.remove(id: editorID); dismiss() }
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (source == .local || TaskWorkspaceURL.external(externalURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(AppTypography.controlStrong); content() }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func save() {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = source == .local ? "" : externalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved: TaskWorkspace?
        if let task {
            saved = notes.updateTaskWorkspace(task, patch: ["title": title, "text": text, "project": project,
                "source": source.rawValue, "externalURL": url, "owner": owner, "due": due])
        } else {
            saved = notes.createWorkspaceTask(title: title, text: text, project: project, source: source,
                externalURL: url, due: due, owner: owner)
        }
        if let saved { if task == nil { notes.captureDrafts.removeValue(forKey: "newtask") }; completion(saved); close() }
    }
}
