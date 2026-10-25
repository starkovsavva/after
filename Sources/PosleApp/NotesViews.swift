import AppKit
import PosleCore
import SwiftUI
import UniformTypeIdentifiers

// Imported card decks share library storage with meetings but are not valid
// destinations for meeting notes. Keep this independent of the sidebar filter.
extension AppStore {
    var noteMeetings: [Meeting] { meetings.filter { $0.libraryKind != "cards" } }
}

private func noteKindTitle(_ kind: String) -> String {
    ["note": "Заметка", "important": "Важно", "question": "Вопрос", "task": "Задача"][kind] ?? "Заметка"
}
private func noteKindIcon(_ kind: String) -> String {
    ["note": "text.alignleft", "important": "bookmark", "question": "questionmark.bubble", "task": "checkmark.circle"][kind] ?? "text.alignleft"
}

struct NotesWorkspaceView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let meeting: Meeting
    private var text: Binding<String> { Binding(get: { notes.captureDrafts[meeting.id] ?? "" }, set: { notes.captureDrafts[meeting.id] = $0 }) }
    private var kind: Binding<String> { Binding(get: { notes.captureKinds[meeting.id] ?? "note" }, set: { notes.captureKinds[meeting.id] = $0 }) }
    @State private var editing: CapturedNote?
    @State private var showingContext = false
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    contextLine
                    NoteComposer(text: text, kind: kind, placeholder: "Новая заметка…") {
                        let time = app.settings.notesAutoTimestamp ? (app.isRecording && app.captureMeetingID == meeting.id
                            ? Date().timeIntervalSince(app.recordingDate ?? Date()) : (app.transcript == nil ? nil : app.playbackTime)) : nil
                        if let saved = notes.capture(text: text.wrappedValue, kind: kind.wrappedValue, meetingID: meeting.id, timestamp: time) {
                            text.wrappedValue = ""; notes.highlightedNoteID = saved.id
                        }
                    }.appLayoutAnchor("notes.composer")
                    if notes.notes(for: meeting.id).isEmpty && notes.error == nil {
                        NotesEmpty(title: "Заметок пока нет", text: "", icon: "pencil.and.outline")
                    }
                    ForEach(notes.notes(for: meeting.id)) { note in
                        NoteRow(note: note, notes: notes, meetingTitle: nil) { editing = note }
                            .id(note.id).padding(2)
                            .background(notes.highlightedNoteID == note.id ? Ink.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.appContentLayout()
            }
            .onAppear { if let id = notes.highlightedNoteID { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: notes.highlightedNoteID) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
        }
        .overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
        .onAppear { notes.reload() }
        .sheet(item: $editing) { note in NoteEditorView(notes: notes, note: note).environmentObject(app).appControlDefaults() }
        .sheet(isPresented: $showingContext) { MeetingContextEditor(notes: notes, meeting: meeting).environmentObject(app) }
    }
    private var contextLine: some View {
        let context = notes.context(for: meeting.id)
        return HStack(spacing: 14) {
            if !context.project.isEmpty {
                Button { openContext(context.project, mode: "project") } label: {
                    HStack(spacing: 7) { Image(systemName: "folder"); Text(context.project).lineLimit(1).truncationMode(.middle) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(Ink.accent).help("Встречи проекта «\(context.project)»")
            }
            if !context.person.isEmpty {
                Button { openContext(context.person, mode: "person") } label: {
                    HStack(spacing: 7) { Image(systemName: "person"); Text(context.person).lineLimit(1).truncationMode(.middle) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(Ink.accent).help("Встречи с \(context.person)")
            }
            if context.project.isEmpty && context.person.isEmpty {
                Button("Добавить проект или человека") { showingContext = true }.buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
            Button { showingContext = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24) }
                .buttonStyle(.plain).help("Проект, человек и шаблон").accessibilityLabel("Изменить проект, человека и шаблон встречи")
        }.font(AppTypography.control).frame(height: 24)
    }
    private func openContext(_ label: String, mode: String) {
        notes.contextMode = mode; notes.contextSelection = label; app.librarySection = "contexts"
    }
}

struct NotesInboxView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    private var text: Binding<String> { Binding(get: { notes.captureDrafts["inbox"] ?? "" }, set: { notes.captureDrafts["inbox"] = $0 }) }
    private var kind: Binding<String> { Binding(get: { notes.captureKinds["inbox"] ?? "note" }, set: { notes.captureKinds["inbox"] = $0 }) }
    @State private var query = ""
    @State private var editing: CapturedNote?
    private var inbox: [CapturedNote] {
        notes.inbox(meetingIDs: Set(app.noteMeetings.map(\.id))).filter { query.isEmpty || ($0.text + " " + $0.sourceURL + " " + $0.attachments.map(\.extractedText).joined(separator: " ")).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Text("Входящие").font(AppTypography.sectionTitle).accessibilityAddTraits(.isHeader)
                        if notes.error == nil { Text("\(inbox.count)").font(AppTypography.caption).foregroundStyle(.secondary) }
                        Spacer()
                        TextField("Поиск в заметках", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                            .accessibilityLabel("Поиск во входящих заметках")
                    }
                    NoteComposer(text: text, kind: kind, placeholder: "Новая заметка…") {
                        if notes.capture(text: text.wrappedValue, kind: kind.wrappedValue) != nil { text.wrappedValue = "" }
                    }
                    if inbox.isEmpty && notes.error == nil { NotesEmpty(title: query.isEmpty ? "Входящие пусты" : "Заметки не найдены", text: "", icon: "tray") }
                    ForEach(inbox) { note in
                        NoteRow(note: note, notes: notes, meetingTitle: nil, meetingUnavailable: note.meetingID != nil) { editing = note }
                            .id(note.id).padding(2).background(notes.highlightedNoteID == note.id ? Ink.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.appContentLayout()
            }.onAppear { notes.reload(); if notes.highlightedNoteID != nil { query = "" }; Task { await Task.yield(); if let id = notes.highlightedNoteID { proxy.scrollTo(id, anchor: .center) } } }
                .onChange(of: notes.highlightedNoteID) { _, id in query = ""; Task { await Task.yield(); if let id { proxy.scrollTo(id, anchor: .center) } } }
                .sheet(item: $editing) { note in NoteEditorView(notes: notes, note: note).environmentObject(app).appControlDefaults() }
        }.overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
    }
}

private struct NoteComposer: View {
    @Binding var text: String
    @Binding var kind: String
    let placeholder: String
    let save: () -> Void
    @State private var expanded = false
    @FocusState private var focused: Bool
    private var editorHeight: CGFloat {
        if expanded { return 132 }
        return min(112, max(68, CGFloat(text.components(separatedBy: .newlines).count) * 20 + 12))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty { Text(placeholder).font(AppTypography.body).foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                TextEditor(text: $text).font(AppTypography.body).scrollContentBackground(.hidden).frame(height: editorHeight)
                    .focused($focused).accessibilityLabel(placeholder)
            }
            HStack(spacing: 10) {
                Picker("Тип заметки", selection: $kind) {
                    ForEach(["note", "important", "question", "task"], id: \.self) { value in Label(noteKindTitle(value), systemImage: noteKindIcon(value)).tag(value) }
                }.labelsHidden().frame(width: 130).accessibilityLabel("Тип заметки")
                Button { expanded.toggle(); focused = true } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(expanded ? "Уменьшить поле заметки" : "Увеличить поле заметки")
                    .accessibilityLabel(expanded ? "Уменьшить поле заметки" : "Увеличить поле заметки")
                Spacer()
                Button("Сохранить", action: save).buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command]).help("Сохранить · ⌘↩")
            }
        }.padding(12).background(Ink.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Ink.accent.opacity(0.7) : Ink.line))
    }
}

private struct NoteRow: View {
    @EnvironmentObject private var app: AppStore
    let note: CapturedNote
    @ObservedObject var notes: NotesStore
    let meetingTitle: String?
    var meetingUnavailable = false
    let edit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                if note.kind == "task" {
                    Button { var value = note; value.completed.toggle(); _ = notes.save(value) } label: {
                        Image(systemName: note.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(note.completed ? Ink.green : .secondary).frame(width: 24, height: 24)
                    }.buttonStyle(.plain).accessibilityLabel(note.completed ? "Вернуть задачу в работу" : "Завершить задачу")
                } else {
                    Image(systemName: noteKindIcon(note.kind)).foregroundStyle(note.kind == "important" ? Ink.accent : .secondary)
                        .frame(width: 24, height: 24).help(noteKindTitle(note.kind)).accessibilityLabel(noteKindTitle(note.kind))
                }
                Button(action: edit) {
                    Text(note.text.isEmpty ? "Отмеченный момент" : note.text).font(AppTypography.body).lineSpacing(4).lineLimit(4)
                        .strikethrough(note.kind == "task" && note.completed).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.top, 3).accessibilityHint("Открыть заметку")
                Menu {
                    Button("Редактировать", action: edit)
                    Button("Копировать текст") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.text, forType: .string) }
                    if note.kind != "task" { Button("Сделать задачей") { var value = note; value.kind = "task"; _ = notes.save(value) } }
                    if note.meetingID != nil { Button("Во входящие") { var value = note; value.meetingID = nil; value.timestamp = nil; _ = notes.save(value) } }
                    Button("Удалить заметку", role: .destructive) { notes.delete(note) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).frame(width: 26).accessibilityLabel("Действия с заметкой")
            }
            HStack(spacing: 10) {
                if let timestamp = note.timestamp, note.meetingID != nil, !meetingUnavailable {
                    Button(Exporter.timestamp(timestamp)) { open() }.monospacedDigit().buttonStyle(.borderless).help("Открыть момент без воспроизведения")
                }
                if !note.owner.isEmpty || !note.due.isEmpty { Text([note.owner, note.due].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1) }
                if meetingUnavailable { Button("Встреча недоступна") { edit() }.buttonStyle(.borderless).help("Прикрепить заметку к другой встрече") }
                else if let meetingTitle { Button(meetingTitle) { open() }.buttonStyle(.borderless).lineLimit(1) }
                if !note.attachments.isEmpty { Label("\(note.attachments.count)", systemImage: "paperclip") }
                if note.expansion != nil { Image(systemName: "sparkles").foregroundStyle(Ink.accent).help("Есть дополнение по записи").accessibilityLabel("Есть дополнение по записи") }
                Spacer(minLength: 0)
                Text(Date(timeIntervalSince1970: note.createdAt).formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU")))).lineLimit(1)
            }.font(AppTypography.caption).foregroundStyle(.secondary).padding(.leading, 33)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.paper, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Ink.line))
    }
    private func open() { if let id = note.meetingID { app.openMeeting(id, tab: note.timestamp == nil ? "notes" : "transcript", timestamp: note.timestamp); notes.highlightedNoteID = note.id } }
}

struct NoteEditorView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    @Environment(\.dismiss) private var dismiss
    @State private var session: NoteEditingSession
    @State private var dropping = false
    @State private var showDelete = false
    @State private var dismissConfirmation = false
    @State private var showingSource = false
    init(notes: NotesStore, note: CapturedNote) { self.notes = notes; _session = State(initialValue: NoteEditingSession(note: note)) }
    private var persisted: CapturedNote? { notes.workspace.notes.first { $0.id == session.baseline.id } }
    private var current: CapturedNote { persisted ?? session.baseline }
    private var dirty: Bool { session.hasUnsavedChanges }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Заметка").font(AppTypography.modalTitle)
                Spacer()
                Button("Закрыть") { if dirty { dismissConfirmation = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { save() }.buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.return, modifiers: [.command])
            }.padding(22)
            Divider()
            if session.conflicted {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Заметка изменилась в другом окне. Ваши правки остались здесь.", systemImage: "exclamationmark.circle").font(AppTypography.control).foregroundStyle(Ink.warning)
                            Text("Можно сохранить свой текст и поля новой заметкой. Вложения останутся в исходной.").font(AppTypography.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Сохранить как новую заметку") { saveAsNew() }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                                if let persisted { Button("Открыть сохранённую версию") { session.didPersist(persisted); notes.error = nil } }
                            }
                        }.padding(14).background(Ink.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Picker("Тип", selection: $session.draft.kind) { ForEach(["note", "important", "question", "task"], id: \.self) { Text(noteKindTitle($0)).tag($0) } }.frame(width: 190)
                        Spacer()
                        if let time = session.draft.timestamp { Text(Exporter.timestamp(time)).font(AppTypography.control).monospacedDigit().foregroundStyle(Ink.accent) }
                    }
                    TextEditor(text: $session.draft.text).font(AppTypography.body).scrollContentBackground(.hidden).frame(minHeight: 100, maxHeight: 160)
                        .padding(10).background(Ink.field, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Текст заметки")
                    Picker("Встреча", selection: Binding(get: { session.draft.meetingID ?? "" }, set: { value in
                        if session.draft.meetingID != (value.isEmpty ? nil : value) { session.draft.timestamp = nil }; session.draft.meetingID = value.isEmpty ? nil : value
                    })) {
                        Text("Входящие · без встречи").tag("")
                        if let id = session.draft.meetingID, !app.noteMeetings.contains(where: { $0.id == id }) { Text("Встреча недоступна").tag(id) }
                        ForEach(app.noteMeetings) { Text($0.title).tag($0.id) }
                    }
                    if showingSource || !session.draft.sourceURL.isEmpty { TextField("Ссылка", text: $session.draft.sourceURL).textFieldStyle(.roundedBorder).accessibilityLabel("Ссылка на источник") }
                    if session.draft.kind == "task" {
                        HStack { TextField("Кто делает", text: $session.draft.owner); TextField("Срок, например до пятницы", text: $session.draft.due) }.textFieldStyle(.roundedBorder)
                    }
                    Divider()
                    HStack {
                        Button { persistBeforeAttachment { notes.chooseAttachments(for: $0) } } label: { Label("Файл", systemImage: "paperclip") }.accessibilityLabel("Добавить файлы")
                        Button { persistBeforeAttachment { notes.paste(into: $0) } } label: { Label("Вставить", systemImage: "doc.on.clipboard") }
                        if !showingSource && session.draft.sourceURL.isEmpty { Button { showingSource = true } label: { Label("Ссылка", systemImage: "link") } }
                        Spacer()
                        if notes.attachmentBusy { ProgressView().controlSize(.small) }
                    }
                    ForEach(current.attachments, id: \.id) { attachment in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Button { notes.openAttachment(attachment, note: current) } label: { Label(attachment.name, systemImage: "doc") }.buttonStyle(.borderless).lineLimit(1)
                                Spacer()
                                if attachment.contentType.hasPrefix("image") || ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(URL(fileURLWithPath: attachment.name).pathExtension.lowercased()) {
                                    Button("Распознать текст") { notes.recognize(attachment, note: current) }.disabled(notes.attachmentBusy)
                                }
                                Button { notes.removeAttachment(attachment, from: current) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Удалить вложение \(attachment.name)")
                            }
                            if !attachment.extractedText.isEmpty { Text(attachment.extractedText).font(AppTypography.control).textSelection(.enabled).lineSpacing(4) }
                        }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Divider()
                    HStack(alignment: .top) {
                        Button { persistBeforeAttachment { note in Task { await app.expandCapturedNote(note); notes.reload() } } } label: { Label("Дополнить по записи", systemImage: "sparkles") }
                            .disabled(app.busy || current.meetingID == nil || current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help(current.meetingID == nil ? "Сначала прикрепите заметку к встрече" : "Дополнить заметку подтверждёнными деталями. Исходный текст сохранится.")
                        Spacer()
                        Image(systemName: app.settings.mode == "cloud" ? "cloud" : "laptopcomputer").foregroundStyle(.secondary)
                            .help(app.settings.mode == "cloud" ? "Облачный ИИ" : "ИИ на этом Mac")
                    }
                    if app.settings.mode == "cloud" {
                        Label("OpenAI получит вашу пометку и выбранные фрагменты транскрипта. Аудио и файлы вложений остаются на Mac.", systemImage: "cloud").font(AppTypography.control).foregroundStyle(.secondary)
                    }
                    if let expansion = current.expansion { NoteExpansionView(expansion: expansion, note: current) }
                }.padding(24)
            }
        }.frame(width: 700, height: 650).background(Ink.paper)
            .overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
            .interactiveDismissDisabled(dirty)
            .confirmationDialog("Сохранить изменения в заметке?", isPresented: $dismissConfirmation) {
                Button("Сохранить") { save() }
                Button("Не сохранять", role: .destructive) { dismiss() }
                Button("Продолжить редактирование", role: .cancel) {}
            }
            .onDrop(of: [.fileURL, .url, .plainText, .image], isTargeted: $dropping) { providers in
                let value = session.draft
                guard let saved = notes.save(value) else { refreshConflict(); return false }
                session.didPersist(saved); return notes.receiveDrop(providers, noteID: saved.id)
            }
            .overlay { if dropping { RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.accent, style: StrokeStyle(lineWidth: 2, dash: [7])).padding(5).allowsHitTesting(false) } }
            .onChange(of: persisted) { _, value in session.receive(value) }
    }
    private func save() {
        if let saved = notes.save(session.draft) { session.didPersist(saved); dismiss() }
        else { refreshConflict() }
    }
    private func persistBeforeAttachment(_ action: (CapturedNote) -> Void) {
        if let saved = notes.save(session.draft) { session.didPersist(saved); action(saved) }
        else { refreshConflict() }
    }
    private func refreshConflict() { notes.reload(); session.receive(persisted) }
    private func saveAsNew() {
        let preserveMeeting = session.draft.meetingID.map { id in app.noteMeetings.contains { $0.id == id } } ?? true
        if let saved = notes.save(session.asNewNote(preserveMeeting: preserveMeeting)) {
            notes.notice = "Ваш текст сохранён новой заметкой. Вложения остались в исходной."
            session.didPersist(saved); dismiss()
        }
    }
}

struct NotesTemplatesView: View {
    @ObservedObject var notes: NotesStore
    @State private var editing: NoteTemplate?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Шаблоны заметок").font(AppTypography.heading); Spacer(); Button("Создать шаблон") { editing = NoteTemplate(name: "Новый шаблон", body: "", focus: "") } }
            ForEach(notes.templates) { template in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(template.name).font(AppTypography.bodyStrong); Text(template.focus).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer(); Button("Изменить") { editing = template }
                }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            }
        }.overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(8).frame(maxWidth: 440) }
            .sheet(item: $editing) { template in TemplateEditor(notes: notes, template: template) }
    }
}

private struct TemplateEditor: View {
    @ObservedObject var notes: NotesStore
    @Environment(\.dismiss) private var dismiss
    @State var template: NoteTemplate
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Шаблон заметки").font(AppTypography.modalTitle); Spacer(); Button("Отмена") { dismiss() }; Button("Сохранить") { if notes.saveTemplate(template) { dismiss() } }.buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            TextField("Название", text: $template.name).textFieldStyle(.roundedBorder)
            Text("Структура заметки").font(AppTypography.control).foregroundStyle(.secondary)
            TextEditor(text: $template.body).font(AppTypography.body).frame(height: 180).padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 8))
            Text("Что выписать из встречи").font(AppTypography.control).foregroundStyle(.secondary)
            TextEditor(text: $template.focus).font(AppTypography.body).frame(height: 90).padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 8))
            HStack { Button("Удалить шаблон", role: .destructive) { if notes.deleteTemplate(template) { dismiss() } }; Spacer() }
        }.padding(24).frame(width: 620)
            .overlay(alignment: .topTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
    }
}

private struct MeetingContextEditor: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @State private var context: MeetingContext
    @State private var selectedTemplate = ""
    @State private var insertTemplate = false
    init(notes: NotesStore, meeting: Meeting) {
        self.notes = notes; self.meeting = meeting
        let value = notes.context(for: meeting.id); _context = State(initialValue: value); _selectedTemplate = State(initialValue: value.templateID ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Контекст встречи").font(AppTypography.modalTitle)
            TextField("Проект", text: $context.project).textFieldStyle(.roundedBorder)
            TextField("Человек", text: $context.person).textFieldStyle(.roundedBorder)
            Picker("Шаблон", selection: $selectedTemplate) {
                Text("Без шаблона").tag(""); ForEach(notes.templates) { Text($0.name).tag($0.id) }
            }
            if !selectedTemplate.isEmpty { Toggle("Создать заметку по шаблону", isOn: $insertTemplate) }
            HStack { Spacer(); Button("Отмена") { dismiss() }; Button("Сохранить") {
                context.templateID = selectedTemplate.isEmpty ? nil : selectedTemplate
                context.project = context.project.trimmingCharacters(in: .whitespacesAndNewlines); context.person = context.person.trimmingCharacters(in: .whitespacesAndNewlines)
                guard notes.saveContext(context) else { return }
                if let template = notes.templates.first(where: { $0.id == selectedTemplate }) {
                    if insertTemplate { _ = notes.capture(text: template.body, meetingID: meeting.id) }
                    if app.selection == meeting.id && !template.focus.isEmpty { app.updateMeeting(meeting.id) { $0.focus = template.focus } }
                }
                if notes.error == nil { dismiss() }
            }.buttonStyle(.borderedProminent).tint(Ink.actionFill) }
        }.padding(24).frame(width: 570)
            .overlay(alignment: .topTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
            .onAppear { if context.revision == 0 && selectedTemplate.isEmpty { selectedTemplate = app.settings.defaultTemplateID } }
    }
}

private struct NotesMessage: View {
    @ObservedObject var notes: NotesStore
    @State private var details = false
    private var text: String? { notes.error ?? notes.notice }
    var body: some View {
        Group {
            if let text {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: notes.error != nil ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(notes.error != nil ? Ink.warning : Ink.green).padding(.top, 4)
                    Text(text).font(AppTypography.control).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    if notes.error != nil {
                        Button { details = true } label: { Image(systemName: "info.circle").frame(width: 24, height: 24) }
                            .buttonStyle(.plain).help("Полный текст ошибки").accessibilityLabel("Полный текст ошибки")
                            .popover(isPresented: $details) { Text(text).font(AppTypography.body).textSelection(.enabled).padding(20).frame(width: 420) }
                    }
                    Button { notes.error = nil; notes.notice = nil } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).accessibilityLabel("Закрыть сообщение")
                }.padding(12).background(Ink.paper, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(notes.error != nil ? Ink.warning.opacity(0.5) : Ink.line))
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
            }
        }.task(id: notes.notice) {
            guard let shown = notes.notice else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            if notes.notice == shown { notes.notice = nil }
        }
    }
}
private struct NotesEmpty: View {
    let title: String
    let text: String
    let icon: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 25)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(AppTypography.heading)
            if !text.isEmpty { Text(text).font(AppTypography.control).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440) }
        }.padding(.vertical, 28).frame(maxWidth: .infinity)
    }
}

private struct NoteExpansionView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    let expansion: NoteExpansion
    let note: CapturedNote
    @State private var valid = false
    @State private var checking = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Дополнение ИИ", systemImage: "sparkles").font(AppTypography.bodyStrong).foregroundStyle(Ink.accent)
            if checking { ProgressView().controlSize(.small) }
            else if !valid {
                Text("Исходная запись или заметка изменилась. Разверните заметку заново, чтобы получить актуальные ссылки.").font(AppTypography.control).foregroundStyle(Ink.warning)
            } else {
                ForEach(Array(expansion.statements.enumerated()), id: \.offset) { _, statement in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(statement.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140))], alignment: .leading, spacing: 8) {
                            ForEach(statement.segmentIDs, id: \.self) { id in
                                Button {
                                    Task { await validate(); if valid, let meetingID = note.meetingID { dismiss(); app.openMeeting(meetingID, tab: "transcript", segmentID: id) } }
                                } label: {
                                    Label(sourceTitle(id), systemImage: "quote.bubble")
                                }.buttonStyle(.borderless).font(AppTypography.control)
                            }
                        }
                    }
                }
                if !expansion.openQuestions.isEmpty {
                    Text("ИИ предлагает уточнить").font(AppTypography.bodyStrong)
                    ForEach(expansion.openQuestions, id: \.self) { Text("• " + $0).font(AppTypography.body).lineSpacing(4) }
                }
                ForEach(expansion.warnings, id: \.self) { Label($0, systemImage: "info.circle").font(AppTypography.control).foregroundStyle(.secondary) }
            }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(Ink.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .task(id: expansion.sourceFingerprint) { await validate() }
    }
    private func sourceTitle(_ id: Int) -> String {
        guard let meetingID = note.meetingID,
              let transcript: Transcript = app.read(app.meetingDirectory(meetingID).appendingPathComponent("transcript.json")),
              let segment = transcript.segments.first(where: { $0.id == id }) else { return "Источник \(id + 1)" }
        return Exporter.timestamp(segment.start)
    }
    private func validate() async {
        checking = true
        defer { checking = false }
        do {
            struct Result: Decodable { var valid: Bool }
            let root = app.root; let noteID = note.id
            let data = try await Task.detached { try RustBridge.shared.get().request(root: root, command: "note-expansion-validate", arguments: ["noteID": noteID]) }.value
            valid = try JSONDecoder().decode(Result.self, from: data).valid
        } catch { valid = false }
    }
}

/// A source-backed preparation view: explicit project/person matching, no generated history.
struct NotesContextsView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    @State private var selected = ""
    @State private var mode = "project"
    @State private var query = ""
    private var allLabels: [String] {
        var unique: [String: String] = [:]
        let meetingIDs = Set(app.noteMeetings.map(\.id))
        for context in notes.workspace.contexts where meetingIDs.contains(context.meetingID) {
            let label = (mode == "project" ? context.project : context.person).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            if !label.isEmpty && unique[key] == nil { unique[key] = label }
        }
        return unique.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var labels: [String] { allLabels.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    private var related: [Meeting] {
        let ids = Set(notes.workspace.contexts.filter {
            let label = (mode == "project" ? $0.project : $0.person).trimmingCharacters(in: .whitespacesAndNewlines)
            return label.compare(selected, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }.map(\.meetingID))
        return app.noteMeetings.filter { ids.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Text("Проекты и люди").font(AppTypography.sectionTitle).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Picker("Группировать", selection: $mode) { Text("Проекты").tag("project"); Text("Люди").tag("person") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200).accessibilityLabel("Проекты или люди")
                }
                HStack(spacing: 12) {
                    Picker(mode == "project" ? "Проект" : "Человек", selection: $selected) {
                        if labels.isEmpty { Text(notes.error != nil ? "Недоступно" : mode == "project" ? "Нет проектов" : "Нет людей").tag("") }
                        ForEach(labels, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(mode == "project" ? "Выбрать проект" : "Выбрать человека")
                    if !selected.isEmpty { Text("Встреч: \(related.count)").font(AppTypography.caption).foregroundStyle(.secondary) }
                    if allLabels.count > 7 || !query.isEmpty {
                        TextField("Фильтр", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                            .accessibilityLabel(mode == "project" ? "Найти проект" : "Найти человека")
                    }
                }
                if selected.isEmpty && notes.error == nil {
                    NotesEmpty(title: query.isEmpty ? (mode == "project" ? "Проектов пока нет" : "Людей пока нет") : "Ничего не найдено",
                               text: query.isEmpty ? "Добавьте проект или человека в параметрах заметок встречи." : "", icon: "rectangle.3.group")
                } else {
                    ForEach(related) { meeting in brief(meeting) }
                }
            }.appContentLayout()
        }.onAppear { notes.reload(); if let target = notes.contextSelection { mode = notes.contextMode; selected = target; notes.contextSelection = nil } else if selected.isEmpty { selected = labels.first ?? "" } }
            .onChange(of: mode) { _, _ in if !labels.contains(selected) { selected = labels.first ?? "" } }
            .onChange(of: query) { _, _ in if !labels.contains(selected) { selected = labels.first ?? "" } }
            .overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
    }
    @ViewBuilder private func brief(_ meeting: Meeting) -> some View {
        let summary: Summary? = app.read(app.meetingDirectory(meeting.id).appendingPathComponent("summary.json"))
        let actions = summary?.items.filter { ["decision", "question"].contains($0.kind) || ($0.kind == "action" && !meeting.completedTasks.contains($0.id)) } ?? []
        let own = notes.notes(for: meeting.id).filter { $0.kind != "task" || !$0.completed }
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                Button { app.openMeeting(meeting.id) } label: { Text(meeting.title).font(AppTypography.heading).multilineTextAlignment(.leading) }.buttonStyle(.borderless)
                Spacer(); Text(Date(timeIntervalSince1970: meeting.createdAt).formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU")))).font(AppTypography.control).foregroundStyle(.secondary)
            }
            if let overview = summary?.overview, !overview.isEmpty { Text(overview).font(AppTypography.body).lineSpacing(4).textSelection(.enabled) }
            ForEach(actions.prefix(12)) { item in
                Button { app.openMeeting(meeting.id, tab: item.segmentIDs.isEmpty ? "summary" : "transcript", segmentID: item.segmentIDs.first) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: item.kind == "question" ? "questionmark.bubble" : item.kind == "action" ? "list.bullet.rectangle" : "checkmark.seal").foregroundStyle(Ink.accent)
                        VStack(alignment: .leading, spacing: 4) { Text(item.text).font(AppTypography.body).foregroundStyle(.primary).multilineTextAlignment(.leading); if !item.owner.isEmpty || !item.due.isEmpty { Text([item.owner, item.due].filter { !$0.isEmpty }.joined(separator: " · ")).font(AppTypography.caption).foregroundStyle(.secondary) } }
                        Spacer(); Image(systemName: "arrow.up.forward").font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            if actions.count > 12 { Button("Все договорённости и вопросы") { app.openMeeting(meeting.id) }.buttonStyle(.borderless).font(AppTypography.control) }
            if !own.isEmpty {
                Divider()
                DisclosureGroup("Мои заметки · \(own.count)") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(own) { note in
                            Button { app.openMeeting(meeting.id, tab: "notes"); notes.highlightedNoteID = note.id } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "pencil")
                                    Text(note.text).lineLimit(3).multilineTextAlignment(.leading)
                                    Spacer()
                                }.font(AppTypography.control)
                            }.buttonStyle(.borderless)
                        }
                    }.padding(.top, 8)
                }.font(AppTypography.controlStrong)
            }
            if summary == nil && own.isEmpty { Text("Конспект ещё не создан. Откройте встречу, чтобы добавить заметки.").font(AppTypography.control).foregroundStyle(.secondary) }
        }.padding(16).background(Ink.soft, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct NotesTasksView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    @State private var filter = "open"
    @State private var query = ""
    @State private var editing: CapturedNote?
    @State private var newText = ""
    private var filtered: [LibraryTask] {
        notes.tasks.filter { task in
            (filter == "all" || (filter == "open" ? !task.completed : task.completed)) &&
            (query.isEmpty || [task.text, task.owner, task.due, task.title].joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Мои задачи").font(AppTypography.sectionTitle).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { notes.reload(); notes.loadTasks(); app.reloadLibrary() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).accessibilityLabel("Обновить задачи").help("Обновить задачи")
                }
                HStack(spacing: 10) {
                    TextField("Новая задача…", text: $newText).textFieldStyle(.roundedBorder).onSubmit(addTask)
                    Button("Добавить", action: addTask).buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(spacing: 16) {
                    Picker("Статус задач", selection: $filter) { Text("В работе").tag("open"); Text("Завершённые").tag("done"); Text("Все").tag("all") }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).accessibilityLabel("Статус задач")
                    Spacer(minLength: 0)
                    TextField("Поиск в задачах", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                if filtered.isEmpty && notes.error == nil {
                    NotesEmpty(title: !query.isEmpty ? "Задачи не найдены" : filter == "done" ? "Нет завершённых задач" : filter == "open" ? "Нет открытых задач" : "Задач пока нет", text: "", icon: "checklist")
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { task in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                notes.complete(task, completed: !task.completed); app.reloadLibrary()
                                if app.selection == task.meetingID { app.refreshResults(task.meetingID ?? "") }
                            } label: { Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 18)).foregroundStyle(task.completed ? Ink.green : .secondary).frame(width: 26, height: 26) }
                                .buttonStyle(.plain).accessibilityLabel(task.completed ? "Вернуть задачу в работу" : "Завершить задачу")
                            VStack(alignment: .leading, spacing: 7) {
                                Text(task.text).font(AppTypography.body).lineSpacing(4).strikethrough(task.completed).textSelection(.enabled)
                                HStack(spacing: 10) {
                                    if !task.owner.isEmpty || !task.due.isEmpty { Text([task.owner, task.due].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1) }
                                    if let meetingID = task.meetingID, app.noteMeetings.contains(where: { $0.id == meetingID }) {
                                        Button { app.openMeeting(meetingID, tab: task.noteID == nil ? "summary" : "notes"); notes.highlightedNoteID = task.noteID } label: { Text(task.title).lineLimit(1) }.buttonStyle(.borderless).help(task.title)
                                        if let source = task.segmentIDs.first {
                                            Button { app.openMeeting(meetingID, tab: "transcript", segmentID: source) } label: { Image(systemName: "quote.bubble").frame(width: 24, height: 24) }
                                                .buttonStyle(.plain).help("Исходная реплика").accessibilityLabel("Открыть исходную реплику задачи")
                                        }
                                    } else {
                                        Button { app.librarySection = "inbox"; notes.highlightedNoteID = task.noteID } label: { Label(task.meetingID == nil ? "Входящие" : "Встреча недоступна", systemImage: "tray") }.buttonStyle(.borderless)
                                    }
                                }.font(AppTypography.caption).foregroundStyle(.secondary)
                            }.padding(.top, 3).frame(maxWidth: .infinity, alignment: .leading)
                            if let id = task.noteID, let note = notes.workspace.notes.first(where: { $0.id == id }) {
                                Button { editing = note } label: { Image(systemName: "pencil").frame(width: 24, height: 24) }
                                    .buttonStyle(.plain).help("Изменить задачу").accessibilityLabel("Изменить задачу")
                            } else {
                                Menu { Button("Создать свою задачу по этой") {
                                    var note = CapturedNote(text: task.text, kind: "task", meetingID: task.meetingID, timestamp: task.timestamp)
                                    note.owner = task.owner; note.due = task.due
                                    if let saved = notes.save(note) { editing = saved; notes.loadTasks() }
                                } } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                                    .menuStyle(.borderlessButton).frame(width: 26).accessibilityLabel("Действия с задачей")
                            }
                        }.padding(.vertical, 12)
                        Divider()
                    }
                }
            }.appContentLayout()
        }.onAppear { notes.reload(); notes.loadTasks() }
            .onChange(of: notes.workspace.notes) { _, _ in notes.loadTasks() }
            .onChange(of: app.busy) { _, busy in if !busy { notes.reload(); notes.loadTasks() } }
            .overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
            .sheet(item: $editing, onDismiss: { notes.loadTasks() }) { note in NoteEditorView(notes: notes, note: note).environmentObject(app) }
    }
    private func addTask() { if notes.capture(text: newText, kind: "task") != nil { newText = ""; notes.loadTasks() } }
}
