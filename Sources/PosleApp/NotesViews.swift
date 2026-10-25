import AppKit
import PosleCore
import SwiftUI
import UniformTypeIdentifiers

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
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        AppPageHeader(title: "Мои заметки", subtitle: "Мысли во время разговора и детали, к которым хочется вернуться.", compact: true)
                        Spacer()
                        Button { showingContext = true } label: { Label("Контекст и шаблон", systemImage: "rectangle.3.group") }
                            .buttonStyle(.bordered)
                    }
                    contextLine
                    NoteComposer(text: text, kind: kind, placeholder: "Запишите мысль, вопрос или договорённость…") {
                        let time = app.settings.notesAutoTimestamp ? (app.isRecording && app.captureMeetingID == meeting.id
                            ? Date().timeIntervalSince(app.recordingDate ?? Date()) : (app.transcript == nil ? nil : app.playbackTime)) : nil
                        if let saved = notes.capture(text: text.wrappedValue, kind: kind.wrappedValue, meetingID: meeting.id, timestamp: time) {
                            text.wrappedValue = ""; notes.highlightedNoteID = saved.id
                        }
                    }
                    .appLayoutAnchor("notes.composer")
                    NotesMessage(notes: notes)
                    if notes.notes(for: meeting.id).isEmpty {
                        NotesEmpty(title: "Здесь будут ваши пометки", text: "Отметьте важный момент во время записи сочетанием ⌃⌥B. Добавить мысль из любого приложения — ⌃⌥N.", icon: "pencil.and.outline")
                    }
                    ForEach(notes.notes(for: meeting.id)) { note in
                        NoteRow(note: note, notes: notes, meetingTitle: nil) { editing = note }
                            .id(note.id)
                            .padding(3)
                            .background(notes.highlightedNoteID == note.id ? Ink.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 11))
                    }
                }.appContentLayout()
            }
            .onAppear { if let id = notes.highlightedNoteID { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: notes.highlightedNoteID) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
        }
        .onAppear { notes.reload() }
        .sheet(item: $editing) { note in NoteEditorView(notes: notes, note: note).environmentObject(app).appControlDefaults() }
        .sheet(isPresented: $showingContext) { MeetingContextEditor(notes: notes, meeting: meeting).environmentObject(app) }
    }
    @ViewBuilder private var contextLine: some View {
        let context = notes.context(for: meeting.id)
        if !context.project.isEmpty || !context.person.isEmpty {
            HStack(spacing: 15) {
                if !context.project.isEmpty { Label(context.project, systemImage: "folder") }
                if !context.person.isEmpty { Label(context.person, systemImage: "person") }
                Spacer()
                Button("На чём остановились") { notes.contextMode = context.project.isEmpty ? "person" : "project"; notes.contextSelection = context.project.isEmpty ? context.person : context.project; app.librarySection = "contexts" }.buttonStyle(.borderless)
            }.font(AppTypography.control).foregroundStyle(.secondary)
        }
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
        notes.inbox(meetingIDs: Set(app.meetings.map(\.id))).filter { query.isEmpty || ($0.text + " " + $0.sourceURL + " " + $0.attachments.map(\.extractedText).joined(separator: " ")).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    AppPageHeader(title: "Входящие", subtitle: "Поймайте мысль сейчас. Привязать к встрече можно позже.")
                    Spacer()
                    Text("⌃⌥N").font(AppTypography.control).foregroundStyle(.secondary).padding(8).background(Ink.soft, in: RoundedRectangle(cornerRadius: 6))
                }
                NoteComposer(text: text, kind: kind, placeholder: "Что хочется сохранить?") {
                    if notes.capture(text: text.wrappedValue, kind: kind.wrappedValue) != nil { text.wrappedValue = "" }
                }
                NotesMessage(notes: notes)
                HStack { Text("Неразобранные · \(inbox.count)").font(AppTypography.bodyStrong); Spacer(); TextField("Найти во входящих", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 250) }
                if inbox.isEmpty { NotesEmpty(title: query.isEmpty ? "Все мысли на своих местах" : "Ничего не найдено", text: query.isEmpty ? "Добавьте заметку здесь или вызовите маленькое окно из строки меню." : "Попробуйте другое слово.", icon: "tray") }
                ForEach(inbox) { note in NoteRow(note: note, notes: notes, meetingTitle: nil, meetingUnavailable: note.meetingID != nil) { editing = note }.id(note.id).padding(3).background(notes.highlightedNoteID == note.id ? Ink.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 11)) }
            }.appContentLayout()
        }.onAppear { notes.reload(); if notes.highlightedNoteID != nil { query = "" }; Task { await Task.yield(); if let id = notes.highlightedNoteID { proxy.scrollTo(id, anchor: .center) } } }
            .onChange(of: notes.highlightedNoteID) { _, id in query = ""; Task { await Task.yield(); if let id { proxy.scrollTo(id, anchor: .center) } } }
            .sheet(item: $editing) { note in NoteEditorView(notes: notes, note: note).environmentObject(app).appControlDefaults() }
        }
    }
}

private struct NoteComposer: View {
    @Binding var text: String
    @Binding var kind: String
    let placeholder: String
    let save: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty { Text(placeholder).font(AppTypography.body).foregroundStyle(.tertiary).padding(.top, 9).padding(.leading, 5).allowsHitTesting(false) }
                TextEditor(text: $text).font(AppTypography.body).scrollContentBackground(.hidden).frame(minHeight: 85, maxHeight: 150)
                    .accessibilityLabel(placeholder)
            }
            HStack {
                Picker("Тип заметки", selection: $kind) {
                    ForEach(["note", "important", "question", "task"], id: \.self) { value in Label(noteKindTitle(value), systemImage: noteKindIcon(value)).tag(value) }
                }.labelsHidden().frame(width: 145)
                Spacer()
                Button("Сохранить", action: save).buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }.padding(15).background(Ink.soft, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if note.kind == "task" {
                    Button { var value = note; value.completed.toggle(); _ = notes.save(value) } label: {
                        Image(systemName: note.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(note.completed ? Ink.green : .secondary)
                    }.buttonStyle(.plain).accessibilityLabel(note.completed ? "Вернуть задачу в работу" : "Завершить задачу")
                } else { Image(systemName: noteKindIcon(note.kind)).foregroundStyle(note.kind == "important" ? Ink.accent : .secondary) }
                Text(noteKindTitle(note.kind)).font(AppTypography.captionStrong).foregroundStyle(.secondary)
                if let timestamp = note.timestamp, note.meetingID != nil, !meetingUnavailable {
                    Button(Exporter.timestamp(timestamp)) { open() }.font(AppTypography.control).monospacedDigit().buttonStyle(.borderless).help("Открыть момент без воспроизведения")
                }
                Spacer()
                Text(Date(timeIntervalSince1970: note.createdAt).formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU")))).font(AppTypography.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Редактировать", action: edit)
                    if note.kind != "task" { Button("Сделать задачей") { var value = note; value.kind = "task"; _ = notes.save(value) } }
                    if note.meetingID != nil { Button("Во входящие") { var value = note; value.meetingID = nil; value.timestamp = nil; _ = notes.save(value) } }
                    Button("Удалить заметку", role: .destructive) { notes.delete(note) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20).accessibilityLabel("Действия с заметкой")
            }
            Button(action: edit) {
                Text(note.text.isEmpty ? "Отмеченный момент" : note.text).font(AppTypography.body).lineSpacing(5)
                    .strikethrough(note.kind == "task" && note.completed).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !note.owner.isEmpty || !note.due.isEmpty {
                Text([note.owner, note.due].filter { !$0.isEmpty }.joined(separator: " · ")).font(AppTypography.control).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if meetingUnavailable { Label("Встреча недоступна · можно привязать к другой", systemImage: "tray").font(AppTypography.control).foregroundStyle(.secondary) }
                else if let meetingTitle { Button(meetingTitle) { open() }.buttonStyle(.borderless).font(AppTypography.control) }
                if !note.attachments.isEmpty { Label("\(note.attachments.count)", systemImage: "paperclip").font(AppTypography.control).foregroundStyle(.secondary) }
                if note.expansion != nil { Label("Дополнено по записи", systemImage: "sparkles").font(AppTypography.control).foregroundStyle(Ink.accent) }
            }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.paper, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
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
    init(notes: NotesStore, note: CapturedNote) { self.notes = notes; _session = State(initialValue: NoteEditingSession(note: note)) }
    private var persisted: CapturedNote? { notes.workspace.notes.first { $0.id == session.baseline.id } }
    private var current: CapturedNote { persisted ?? session.baseline }
    private var dirty: Bool { session.hasUnsavedChanges }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Своя заметка").font(AppTypography.modalTitle)
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
                VStack(alignment: .leading, spacing: 19) {
                    HStack {
                        Picker("Тип", selection: $session.draft.kind) { ForEach(["note", "important", "question", "task"], id: \.self) { Text(noteKindTitle($0)).tag($0) } }.frame(width: 190)
                        Spacer()
                        if let time = session.draft.timestamp { Text(Exporter.timestamp(time)).font(AppTypography.control).monospacedDigit().foregroundStyle(Ink.accent) }
                    }
                    TextEditor(text: $session.draft.text).font(AppTypography.body).scrollContentBackground(.hidden).frame(minHeight: 150)
                        .padding(10).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Текст заметки")
                    Picker("Встреча", selection: Binding(get: { session.draft.meetingID ?? "" }, set: { value in
                        if session.draft.meetingID != (value.isEmpty ? nil : value) { session.draft.timestamp = nil }; session.draft.meetingID = value.isEmpty ? nil : value
                    })) {
                        Text("Входящие · без встречи").tag("")
                        if let id = session.draft.meetingID, !app.meetings.contains(where: { $0.id == id }) { Text("Встреча недоступна").tag(id) }
                        ForEach(app.meetings) { Text($0.title).tag($0.id) }
                    }
                    TextField("Ссылка на источник (необязательно)", text: $session.draft.sourceURL).textFieldStyle(.roundedBorder)
                    if session.draft.kind == "task" {
                        HStack { TextField("Кто делает", text: $session.draft.owner); TextField("Срок, например до пятницы", text: $session.draft.due) }.textFieldStyle(.roundedBorder)
                    }
                    Divider()
                    HStack {
                        Text("Материалы").font(AppTypography.bodyStrong); Spacer()
                        if notes.attachmentBusy { ProgressView().controlSize(.small) }
                        Button { persistBeforeAttachment { notes.paste(into: $0) } } label: { Label("Вставить", systemImage: "doc.on.clipboard") }
                        Button { persistBeforeAttachment { notes.chooseAttachments(for: $0) } } label: { Image(systemName: "paperclip") }.accessibilityLabel("Добавить файлы")
                    }
                    if current.attachments.isEmpty { Text("Перетащите сюда скриншот, файл, ссылку или выделенный текст.").font(AppTypography.control).foregroundStyle(.secondary) }
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
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Дополнить по записи").font(AppTypography.heading)
                            Text("Ваш текст останется как есть. ИИ добавит отдельный результат с исходными репликами.")
                                .font(AppTypography.control).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(app.settings.mode == "cloud" ? "Развернуть в облаке" : "Развернуть на Mac") { persistBeforeAttachment { note in Task { await app.expandCapturedNote(note); notes.reload() } } }
                            .disabled(app.busy || current.meetingID == nil || current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if app.settings.mode == "cloud" {
                        Label("OpenAI получит вашу пометку и выбранные фрагменты транскрипта. Аудио и файлы вложений остаются на Mac.", systemImage: "cloud").font(AppTypography.control).foregroundStyle(.secondary)
                    }
                    if let expansion = current.expansion { NoteExpansionView(expansion: expansion, note: current) }
                    NotesMessage(notes: notes)
                }.padding(24)
            }
        }.frame(width: 700, height: 700).background(Ink.paper)
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
        let preserveMeeting = session.draft.meetingID.map { id in app.meetings.contains { $0.id == id } } ?? true
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
            Text("Структура помогает подготовиться к разговору. Поле «Что выписать» направляет конспект.").font(AppTypography.control).foregroundStyle(.secondary)
            ForEach(notes.templates) { template in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(template.name).font(AppTypography.bodyStrong); Text(template.focus).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer(); Button("Изменить") { editing = template }
                }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            }
            NotesMessage(notes: notes)
        }.sheet(item: $editing) { template in TemplateEditor(notes: notes, template: template) }
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
            TextEditor(text: $template.body).font(AppTypography.body).frame(height: 180).padding(8).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            Text("Что выписать из встречи").font(AppTypography.control).foregroundStyle(.secondary)
            TextEditor(text: $template.focus).font(AppTypography.body).frame(height: 90).padding(8).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            HStack { Button("Удалить шаблон", role: .destructive) { if notes.deleteTemplate(template) { dismiss() } }; Spacer() }
            NotesMessage(notes: notes)
        }.padding(24).frame(width: 620)
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
            Text("Свяжите разговоры по проекту или человеку, чтобы быстро вспомнить договорённости.").font(AppTypography.control).foregroundStyle(.secondary)
            TextField("Проект, например Новый поставщик", text: $context.project).textFieldStyle(.roundedBorder)
            TextField("С кем, например Анна · закупки", text: $context.person).textFieldStyle(.roundedBorder)
            Picker("Шаблон", selection: $selectedTemplate) {
                Text("Без шаблона").tag(""); ForEach(notes.templates) { Text($0.name).tag($0.id) }
            }
            if !selectedTemplate.isEmpty { Toggle("Добавить структуру отдельной заметкой", isOn: $insertTemplate) }
            NotesMessage(notes: notes)
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
            .onAppear { if context.revision == 0 && selectedTemplate.isEmpty { selectedTemplate = app.settings.defaultTemplateID } }
    }
}

private struct NotesMessage: View {
    @ObservedObject var notes: NotesStore
    @State private var details = false
    private var text: String { notes.error ?? notes.notice ?? "Заметки сохраняются на этом Mac" }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notes.error != nil ? "exclamationmark.circle" : notes.notice != nil ? "checkmark.circle" : "lock")
            Text(text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if notes.error != nil {
                Button("Подробнее") { details = true }.buttonStyle(.borderless)
                    .popover(isPresented: $details) { Text(text).font(AppTypography.body).textSelection(.enabled).padding(20).frame(width: 420) }
            }
            if notes.error != nil || notes.notice != nil {
                Button { notes.error = nil; notes.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Закрыть сообщение")
            }
        }.font(AppTypography.caption).foregroundStyle(notes.error != nil ? Ink.warning : notes.notice != nil ? Ink.green : Color.secondary)
            .frame(height: 32).help(text)
    }
}
private struct NotesEmpty: View {
    let title: String
    let text: String
    let icon: String
    var body: some View {
        VStack(spacing: 12) { Image(systemName: icon).font(.system(size: 29)).foregroundStyle(Ink.accent); Text(title).font(AppTypography.emptyTitle); Text(text).font(AppTypography.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440).lineSpacing(4) }
            .padding(.vertical, 42).frame(maxWidth: .infinity)
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
    private var labels: [String] {
        var unique: [String: String] = [:]
        for context in notes.workspace.contexts {
            let label = (mode == "project" ? context.project : context.person).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            if !label.isEmpty && unique[key] == nil { unique[key] = label }
        }
        return unique.values.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var related: [Meeting] {
        let ids = Set(notes.workspace.contexts.filter {
            let label = (mode == "project" ? $0.project : $0.person).trimmingCharacters(in: .whitespacesAndNewlines)
            return label.compare(selected, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }.map(\.meetingID))
        return app.meetings.filter { ids.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 17) {
                Text("Проекты и люди").font(AppTypography.sectionTitle)
                Picker("Группировать", selection: $mode) { Text("Проекты").tag("project"); Text("Люди").tag("person") }.pickerStyle(.segmented).tint(Ink.actionFill)
                TextField("Найти", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(labels, id: \.self) { value in Button { selected = value } label: {
                            HStack { Image(systemName: mode == "project" ? "folder" : "person"); Text(value).lineLimit(2); Spacer() }.font(AppTypography.body).padding(12).background(selected == value ? Ink.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain) }
                    }
                }
            }.padding(24).frame(width: 248)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if selected.isEmpty {
                        NotesEmpty(title: "Вспомните прошлый разговор", text: "Укажите проект или человека в разделе «Мои заметки → Контекст и шаблон». Здесь соберутся связанные встречи, решения и открытые вопросы.", icon: "rectangle.3.group")
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(selected).font(AppTypography.pageTitle)
                            Text("На чём остановились · \(related.count) встреч").font(AppTypography.body).foregroundStyle(.secondary)
                            Text("Сводка из сохранённых конспектов и собственных заметок. Каждая запись ведёт к встрече.").font(AppTypography.control).foregroundStyle(.secondary)
                        }
                        ForEach(related) { meeting in brief(meeting) }
                    }
                }.frame(maxWidth: 760).padding(AppLayout.contentInset).frame(maxWidth: .infinity)
            }
        }.onAppear { notes.reload(); if let target = notes.contextSelection { mode = notes.contextMode; selected = target; notes.contextSelection = nil } else if selected.isEmpty { selected = labels.first ?? "" } }
            .onChange(of: mode) { _, _ in if !labels.contains(selected) { selected = labels.first ?? "" } }
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
                        Image(systemName: item.kind == "question" ? "questionmark.bubble" : item.kind == "action" ? "circle" : "checkmark.seal").foregroundStyle(Ink.accent)
                        VStack(alignment: .leading, spacing: 4) { Text(item.text).font(AppTypography.body).foregroundStyle(.primary).multilineTextAlignment(.leading); if !item.owner.isEmpty || !item.due.isEmpty { Text([item.owner, item.due].filter { !$0.isEmpty }.joined(separator: " · ")).font(AppTypography.caption).foregroundStyle(.secondary) } }
                        Spacer(); Image(systemName: "arrow.up.forward").font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            if actions.count > 12 { Button("Все договорённости и вопросы") { app.openMeeting(meeting.id) }.buttonStyle(.borderless).font(AppTypography.control) }
            ForEach(own.prefix(5)) { note in
                Button { app.openMeeting(meeting.id, tab: "notes"); notes.highlightedNoteID = note.id } label: { HStack(alignment: .top) { Image(systemName: "pencil"); Text(note.text).lineLimit(3).multilineTextAlignment(.leading); Spacer() }.font(AppTypography.control) }.buttonStyle(.borderless)
            }
            if summary == nil && own.isEmpty { Text("Конспект ещё не создан. Откройте встречу, чтобы добавить заметки.").font(AppTypography.control).foregroundStyle(.secondary) }
        }.padding(21).background(Ink.soft, in: RoundedRectangle(cornerRadius: 12))
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
            VStack(alignment: .leading, spacing: 25) {
                HStack(alignment: .top) {
                    AppPageHeader(title: "Мои задачи", subtitle: "Свои задачи и договорённости из всех встреч.")
                    Spacer(); Button { notes.reload(); notes.loadTasks(); app.reloadLibrary() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Обновить задачи")
                }
                HStack(spacing: 12) {
                    TextField("Добавить свою задачу…", text: $newText).textFieldStyle(.roundedBorder).onSubmit(addTask)
                    Button("Добавить", action: addTask).buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Picker("Статус задач", selection: $filter) { Text("В работе").tag("open"); Text("Завершённые").tag("done"); Text("Все").tag("all") }.pickerStyle(.segmented).tint(Ink.actionFill).frame(maxWidth: 350)
                    Spacer(); TextField("Текст, человек, встреча", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                }
                NotesMessage(notes: notes)
                if filtered.isEmpty { NotesEmpty(title: filter == "open" ? "Ничего не забыто" : "Задач пока нет", text: "Добавьте свою задачу или создайте конспект встречи. Договорённости с источниками появятся здесь.", icon: "checklist") }
                ForEach(filtered) { task in
                    HStack(alignment: .top, spacing: 14) {
                        Button {
                            notes.complete(task, completed: !task.completed); app.reloadLibrary()
                            if app.selection == task.meetingID { app.refreshResults(task.meetingID ?? "") }
                        } label: { Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).foregroundStyle(task.completed ? Ink.green : .secondary) }.buttonStyle(.plain).accessibilityLabel(task.completed ? "Вернуть задачу в работу" : "Завершить задачу")
                        VStack(alignment: .leading, spacing: 10) {
                            Text(task.text).font(AppTypography.body).lineSpacing(5).strikethrough(task.completed).textSelection(.enabled)
                            if !task.owner.isEmpty || !task.due.isEmpty { Text([task.owner, task.due].filter { !$0.isEmpty }.joined(separator: " · ")).font(AppTypography.control).foregroundStyle(.secondary) }
                            HStack {
                                if let meetingID = task.meetingID, app.meetings.contains(where: { $0.id == meetingID }) {
                                    Button { app.openMeeting(meetingID, tab: task.noteID == nil ? "summary" : "notes"); notes.highlightedNoteID = task.noteID } label: { Label(task.title, systemImage: "arrow.up.forward") }.buttonStyle(.borderless).font(AppTypography.control).lineLimit(1)
                                    if let source = task.segmentIDs.first { Button("Источник") { app.openMeeting(meetingID, tab: "transcript", segmentID: source) }.buttonStyle(.borderless).font(AppTypography.control) }
                                } else {
                                    Button { app.librarySection = "inbox"; notes.highlightedNoteID = task.noteID } label: { Label(task.meetingID == nil ? "Входящие" : "Встреча недоступна · заметка во входящих", systemImage: "tray") }.buttonStyle(.borderless).font(AppTypography.control)
                                }
                                Spacer()
                                if let id = task.noteID, let note = notes.workspace.notes.first(where: { $0.id == id }) {
                                    Button("Изменить") { editing = note }.font(AppTypography.control)
                                } else {
                                    Menu { Button("Создать свою задачу по этой") {
                                        var note = CapturedNote(text: task.text, kind: "task", meetingID: task.meetingID, timestamp: task.timestamp)
                                        note.owner = task.owner; note.due = task.due
                                        if let saved = notes.save(note) { editing = saved; notes.loadTasks() }
                                    } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20).accessibilityLabel("Действия с задачей")
                                }
                            }
                        }
                    }.padding(18).background(Ink.soft, in: RoundedRectangle(cornerRadius: 10))
                }
            }.appContentLayout()
        }.onAppear { notes.reload(); notes.loadTasks() }
            .onChange(of: notes.workspace.notes) { _, _ in notes.loadTasks() }
            .onChange(of: app.busy) { _, busy in if !busy { notes.reload(); notes.loadTasks() } }
            .sheet(item: $editing, onDismiss: { notes.loadTasks() }) { note in NoteEditorView(notes: notes, note: note).environmentObject(app) }
    }
    private func addTask() { if notes.capture(text: newText, kind: "task") != nil { newText = ""; notes.loadTasks() } }
}
