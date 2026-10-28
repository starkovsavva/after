import PosleCore
import SwiftUI

enum TaskAttachmentKind: String, Identifiable {
    case note, meeting, repository, link
    var id: String { rawValue }
    var title: String {
        switch self { case .note: return L("Прикрепить заметку"); case .meeting: return L("Фрагмент встречи"); case .repository: return L("Прикрепить репозиторий"); case .link: return L("Прикрепить ссылку") }
    }
}

struct TaskAttachmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let task: TaskWorkspace
    let kind: TaskAttachmentKind
    @State private var query = ""
    @State private var selectedNoteID: String?
    @State private var meetingID = ""
    @State private var transcript: Transcript?
    @State private var selectedSegments: Set<Int> = []
    @State private var title = ""
    @State private var url = ""
    private var availableNotes: [CapturedNote] {
        notes.notes.filter { $0.kind != "task" && (query.isEmpty || ($0.displayTitle + " " + $0.text).localizedCaseInsensitiveContains(query)) }
    }
    private var segments: [Segment] {
        (transcript?.segments ?? []).filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppPageHeader(title: kind.title, modal: true)
            switch kind {
            case .note: notePicker
            case .meeting: meetingPicker
            case .repository, .link: linkForm
            }
            if let error = notes.error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if kind == .repository {
                    Button(L("Выбрать папку…")) { if notes.chooseTaskFolder(task, repository: true) { dismiss() } }
                }
                Spacer()
                Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Прикрепить"), action: attach).buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .disabled(!canAttach || notes.taskWorkspaceBusy).keyboardShortcut(.defaultAction).accessibilityIdentifier("tasks.attach-confirm")
            }
        }.padding(24).frame(width: 580).frame(minHeight: 360, idealHeight: kind == .note || kind == .meeting ? 620 : 380).appControlDefaults()
            .onAppear { if kind == .meeting, let id = task.meetingID { meetingID = id; loadTranscript() } }
    }
    private var notePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L("Найти заметку"), text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("tasks.attach-note-search")
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(availableNotes) { note in
                        Button { selectedNoteID = note.id } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selectedNoteID == note.id ? "checkmark.circle.fill" : "circle").foregroundStyle(selectedNoteID == note.id ? Ink.accent : .secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(note.displayTitle).font(AppTypography.controlStrong).lineLimit(2)
                                    Text(note.text).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(10).contentShape(Rectangle()).background(selectedNoteID == note.id ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
                        }.buttonStyle(.plain).accessibilityIdentifier("tasks.attach-note." + note.id)
                    }
                    if availableNotes.isEmpty { Text(L("Заметки не найдены")).foregroundStyle(.secondary).padding(20) }
                }
            }
            Text(L("Сохранится связь с заметкой. Её можно будет открыть и изменить.")).font(AppTypography.caption).foregroundStyle(.secondary)
        }
    }
    private var meetingPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("Встреча"), selection: $meetingID) {
                Text(L("Выберите встречу")).tag("")
                ForEach(app.noteMeetings) { Text($0.title).tag($0.id) }
            }.onChange(of: meetingID) { _, _ in selectedSegments = []; query = ""; loadTranscript() }
            TextField(L("Найти реплику"), text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(segments.prefix(200)) { segment in
                        Toggle(isOn: Binding(get: { selectedSegments.contains(segment.id) }, set: { enabled in
                            if enabled { selectedSegments.insert(segment.id) } else { selectedSegments.remove(segment.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(segment.text).font(AppTypography.control).lineLimit(4)
                                Text(timecode(segment.start)).font(AppTypography.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 7)
                        }.toggleStyle(.checkbox).accessibilityIdentifier("tasks.attach-segment.\(segment.id)")
                    }
                    if !meetingID.isEmpty && transcript == nil { Text(L("У этой встречи пока нет транскрипта")).foregroundStyle(.secondary).padding(.vertical, 20) }
                    else if segments.isEmpty && transcript != nil { Text(L("Реплики не найдены")).foregroundStyle(.secondary).padding(.vertical, 20) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(LF("Выбрано реплик: {0}", arguments: [String(describing: (selectedSegments.count))])).font(AppTypography.caption).foregroundStyle(.secondary)
        }
    }
    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(L("Название"), text: $title).textFieldStyle(.roundedBorder)
            TextField(kind == .repository ? "https://github.com/…" : "https://…", text: $url).textFieldStyle(.roundedBorder)
            Text(kind == .repository ? L("Сохранится адрес репозитория или ссылка на выбранную папку. Поиск по содержимому папки можно включить отдельно в меню материала.") : L("Ссылка появится среди материалов задачи."))
                .font(AppTypography.control).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
    private var canAttach: Bool {
        switch kind {
        case .note: return selectedNoteID != nil
        case .meeting: return !meetingID.isEmpty && !selectedSegments.isEmpty
        case .repository, .link: return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && TaskWorkspaceURL.external(url.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
    }
    private func attach() {
        let material: TaskMaterial
        switch kind {
        case .note:
            guard let note = availableNotes.first(where: { $0.id == selectedNoteID }) else { return }
            material = TaskMaterial(kind: "note", title: note.displayTitle, noteID: note.id)
        case .meeting:
            let name = app.noteMeetings.first { $0.id == meetingID }?.title ?? L("Фрагмент встречи")
            material = TaskMaterial(kind: "meeting", title: name, meetingID: meetingID, segmentIDs: selectedSegments.sorted())
        case .repository, .link:
            material = TaskMaterial(kind: kind.rawValue, title: title.trimmingCharacters(in: .whitespacesAndNewlines), url: url.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if notes.linkTaskMaterial(material, to: task) != nil { dismiss() }
    }
    private func loadTranscript() {
        guard !meetingID.isEmpty else { transcript = nil; return }
        transcript = app.read(app.meetingDirectory(meetingID).appendingPathComponent("transcript.json"))
    }
    private func timecode(_ seconds: Double) -> String {
        let value = max(0, Int(seconds)); return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
