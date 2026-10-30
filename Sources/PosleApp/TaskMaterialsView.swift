import AppKit
import PosleCore
import SwiftUI

struct TaskMaterialsView: View {
    @ObservedObject private var theme = ThemeController.shared
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let task: TaskWorkspace
    @State private var attachment: TaskAttachmentKind?
    @State private var editingNote: CapturedNote?
    @State private var indexing: [String: Bool] = [:]
    @State private var cloudIndexing: [String: Bool] = [:]
    private var materials: [TaskMaterial] { task.materials.filter { !$0.isWorkspace } }
    private var workspaces: [TaskMaterial] { task.materials.filter(\.isWorkspace) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("Мысли и заметки")).font(AppTypography.heading)
                Spacer()
                Menu {
                    Button(L("Заметку…")) { attachment = .note }
                    Button(L("Фрагмент встречи…")) { attachment = .meeting }
                    Button(L("Файл…")) { notes.chooseTaskFile(task) }
                    Divider()
                    Button(L("Папку…")) { notes.chooseTaskFolder(task, repository: false) }
                    Button(L("Репозиторий…")) { attachment = .repository }
                    Button(L("Ссылку…")) { attachment = .link }
                } label: { Label(L("Прикрепить"), systemImage: "paperclip") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(notes.attachmentBusy).accessibilityIdentifier("tasks.attach")
            }
            if notes.attachmentBusy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("Добавляем файл…")).font(AppTypography.caption).foregroundStyle(.secondary) }
                    .accessibilityIdentifier("tasks.file-import-progress")
            }
            if materials.isEmpty {
                Text(L("Добавьте мысль или прикрепите материал к задаче.")).font(AppTypography.control).foregroundStyle(.secondary)
            }
            ForEach(materials) { material in materialRow(material) }
            if let meetingID = task.meetingID, !materials.contains(where: { $0.meetingID == meetingID }) { source(meetingID) }
            if !workspaces.isEmpty {
                Text(L("Код и папки")).font(AppTypography.heading).padding(.top, 8)
                ForEach(workspaces) { material in workspaceRow(material) }
            }
            if let legacy = notes.legacyTask(for: task) { TaskSubtasksView(notes: notes, task: legacy) }
        }
        .onAppear(perform: loadIndexing)
        .onChange(of: task.id) { _, _ in loadIndexing() }
        .sheet(item: $attachment) { kind in TaskAttachmentSheet(notes: notes, task: task, kind: kind).environmentObject(app) }
        .sheet(item: $editingNote, onDismiss: { notes.reload(); notes.loadTaskWorkspaces() }) { NoteEditorView(notes: notes, note: $0).environmentObject(app) }
    }
    private func materialRow(_ material: TaskMaterial) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(material.title, systemImage: material.symbol).font(AppTypography.controlStrong)
            if let text = material.displayText, !text.isEmpty, text != material.title {
                Text(text).font(AppTypography.body).foregroundStyle(.primary).lineSpacing(4).lineLimit(5).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if material.available == false { Text(L("Материал недоступен")).foregroundStyle(Ink.warning) }
                else if let date = material.createdAt { Text(Date(timeIntervalSince1970: date).formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(UILocale()))) }
                Text(material.shared && task.agentAccess.enabled ? L("Доступна агентам") : L("Только в «After»"))
                Spacer(minLength: 0)
                Button(L("Открыть")) { open(material) }.buttonStyle(.borderless).disabled(material.available == false)
                detach(material)
            }.font(AppTypography.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
            .accessibilityElement(children: .contain).accessibilityIdentifier("tasks.material." + (material.id ?? ""))
    }
    private func workspaceRow(_ material: TaskMaterial) -> some View {
        HStack(spacing: 12) {
            Button { open(material) } label: {
                HStack(spacing: 10) {
                    Image(systemName: material.symbol).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(material.title).font(AppTypography.controlStrong)
                        Text(material.path ?? material.url ?? "").font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let id = material.id, indexing[id] == true {
                            Text(cloudIndexing[id] == true ? L("В базе знаний · разрешено облако") : L("В базе знаний · только на Mac")).font(AppTypography.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(material.available == false)
            if material.path != nil, let id = material.id {
                Menu {
                    Toggle(L("Индексировать содержимое"), isOn: Binding(get: { indexing[id] == true }, set: { setIndexing(material, enabled: $0, cloud: cloudIndexing[id] == true) }))
                    Toggle(L("Разрешить отправку ИИ в облаке"), isOn: Binding(get: { cloudIndexing[id] == true }, set: { setIndexing(material, enabled: indexing[id] == true, cloud: $0) })).disabled(indexing[id] != true)
                    Divider()
                    Text(L("Учитываются gitignore и .posleignore. Скрытые файлы, ключи и .env пропускаются."))
                } label: { Image(systemName: indexing[id] == true ? "doc.text.magnifyingglass" : "ellipsis.circle").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().help(L("Индексация папки")).accessibilityLabel(L("Индексация ") + material.title).accessibilityIdentifier("tasks.code-index." + id)
            }
            detach(material)
        }.padding(.vertical, 9)
    }
    private func loadIndexing() {
        struct Grant: Decodable { var taskID: String; var materialID: String; var allowCloud: Bool }
        struct Envelope: Decodable { var grants: [Grant] }
        do {
            let data = try RustBridge.shared.get().request(root: app.root, command: "code-index-grants")
            let grants = try JSONDecoder().decode(Envelope.self, from: data).grants.filter { $0.taskID == task.id }
            indexing = Dictionary(uniqueKeysWithValues: grants.map { ($0.materialID, true) })
            cloudIndexing = Dictionary(uniqueKeysWithValues: grants.map { ($0.materialID, $0.allowCloud) })
        } catch { notes.error = error.localizedDescription }
    }
    private func setIndexing(_ material: TaskMaterial, enabled: Bool, cloud: Bool) {
        guard let id = material.id else { return }
        do {
            _ = try RustBridge.shared.get().request(root: app.root, command: "code-index-grant", arguments: ["taskID": task.id, "materialID": id, "enabled": enabled, "allowCloud": cloud])
            indexing[id] = enabled; cloudIndexing[id] = cloud
            SemanticIndexController.shared.connect(app); SemanticIndexController.shared.requestRefresh()
        } catch { notes.error = error.localizedDescription }
    }
    private func detach(_ material: TaskMaterial) -> some View {
        Button { notes.unlinkTaskMaterial(material, from: task) } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
            .buttonStyle(.plain).help(L("Открепить от задачи")).accessibilityLabel(L("Открепить ") + material.title)
    }
    private func source(_ meetingID: String) -> some View {
        Button {
            let segment = notes.legacyTask(for: task)?.taskOrigin?.segmentIDs.first ?? notes.legacyTask(for: task)?.segmentIDs.first
            app.openMeeting(meetingID, tab: segment == nil ? "summary" : "transcript", segmentID: segment)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.noteMeetings.first { $0.id == meetingID }?.title ?? L("Встреча")).font(AppTypography.controlStrong)
                    Text(L("Источник задачи")).font(AppTypography.caption).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "chevron.right").font(AppTypography.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("tasks.source")
    }
    private func open(_ material: TaskMaterial) {
        if let noteID = material.noteID, let note = notes.notes.first(where: { $0.id == noteID }) {
            if material.kind == "file", let attachment = note.attachments.first(where: { $0.id == material.attachmentID }) { notes.openAttachment(attachment, note: note) }
            else { editingNote = note }
            return
        }
        if let meetingID = material.meetingID { app.openMeeting(meetingID, tab: "transcript", segmentID: material.segmentIDs.first); return }
        if let path = material.path, path.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: path)); return }
        if let url = material.url.flatMap(TaskWorkspaceURL.external) { NSWorkspace.shared.open(url); return }
        notes.error = L("Материал недоступен. Возможно, исходный файл или заметка были удалены.")
    }
}

/// Kept outside the materials scroll view so capture remains available even
/// when a task has a long history of linked notes and workspace references.
struct TaskThoughtComposer: View {
    @ObservedObject private var theme = ThemeController.shared
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let task: TaskWorkspace
    private var thought: Binding<String> { Binding(get: { notes.taskThought(for: task) }, set: { notes.setTaskThought($0, task: task) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Добавить мысль к задаче…"), text: thought, axis: .vertical).lineLimit(1...6).textFieldStyle(.plain)
                    .font(AppTypography.body).accessibilityIdentifier("tasks.append-text")
                Button { app.voice.present(taskID: task.id, title: task.title) } label: { Image(systemName: "mic").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).help(L("Надиктовать мысль")).accessibilityLabel(L("Надиктовать мысль"))
                Button { notes.saveTaskThought(task) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 21)).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).disabled(thought.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notes.taskWorkspaceBusy)
                    .accessibilityLabel(L("Сохранить мысль")).accessibilityIdentifier("tasks.thought-save")
            }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
        }
    }
}
