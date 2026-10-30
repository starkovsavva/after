import AppKit
import PosleCore
import SwiftUI
import UniformTypeIdentifiers

// Imported card decks share library storage with meetings but are not valid
// destinations for meeting notes. Keep this independent of the sidebar filter.
extension AppStore {
    var allNoteMeetings: [Meeting] { meetings.filter { $0.libraryKind != "cards" } }
    var noteMeetings: [Meeting] { allNoteMeetings.filter { folderSelection == nil || folderID(for: $0.id) == folderSelection } }
    /// A note may explicitly override its linked meeting's folder. Match the
    /// worker's precedence when describing where an AI action will run.
    func settingsForNote(_ note: CapturedNote) -> AppSettings {
        effectiveSettings(for: note.folderID == nil ? note.meetingID : nil, folderID: note.folderID)
    }
}

private func noteKindTitle(_ kind: String) -> String {
    ["note": L("Заметка"), "important": L("Важно"), "question": L("Вопрос"), "task": L("Задача")][kind] ?? L("Заметка")
}
private func noteKindIcon(_ kind: String) -> String {
    ["note": "text.alignleft", "important": "bookmark", "question": "questionmark.bubble", "task": "checkmark.circle"][kind] ?? "text.alignleft"
}

struct NotesWorkspaceView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let meeting: Meeting
    private var text: Binding<String> { Binding(get: { notes.captureDrafts[meeting.id] ?? "" }, set: { notes.captureDrafts[meeting.id] = $0 }) }
    private var kind: Binding<String> { Binding(get: {
        let value = notes.captureKinds[meeting.id] ?? "note"
        return value == "task" && !app.isFeatureEnabled(.tasks) ? "note" : value
    }, set: { notes.captureKinds[meeting.id] = $0 }) }
    @State private var editing: CapturedNote?
    @State private var showingContext = false
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    contextLine
                    NoteComposer(text: text, kind: kind, placeholder: L("Новая заметка…"), documentID: "meeting:" + meeting.id) {
                        let time = app.settings.notesAutoTimestamp ? (app.isRecording && app.captureMeetingID == meeting.id
                            ? Date().timeIntervalSince(app.recordingDate ?? Date()) : (app.transcript == nil ? nil : app.playbackTime)) : nil
                        if let saved = notes.capture(text: text.wrappedValue, kind: kind.wrappedValue, meetingID: meeting.id, timestamp: time) {
                            text.wrappedValue = ""; notes.highlightedNoteID = saved.id
                        }
                    }.appLayoutAnchor("notes.composer")
                    if notes.notes(for: meeting.id).isEmpty && notes.error == nil {
                        NotesEmpty(title: L("Заметок пока нет"), text: "", icon: "pencil.and.outline")
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
        .onAppear { Task { await notes.refresh() } }
        .sheet(item: $editing) { note in NoteEditorView(notes: notes, note: note).environmentObject(app).appControlDefaults() }
        .sheet(isPresented: $showingContext) { MeetingContextEditor(notes: notes, meeting: meeting).environmentObject(app) }
    }
    private var contextLine: some View {
        let context = notes.context(for: meeting.id)
        return HStack(spacing: 14) {
            if app.isFeatureEnabled(.tasks), !context.project.isEmpty {
                Button { openContext(context.project, mode: "project") } label: {
                    HStack(spacing: 7) { Image(systemName: "folder"); Text(context.project).lineLimit(1).truncationMode(.middle) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(Ink.accent).help(LF("Встречи проекта «{0}»", arguments: [String(describing: (context.project))]))
            }
            if app.isFeatureEnabled(.tasks), !context.person.isEmpty {
                Button { openContext(context.person, mode: "person") } label: {
                    HStack(spacing: 7) { Image(systemName: "person"); Text(context.person).lineLimit(1).truncationMode(.middle) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(Ink.accent).help(LF("Встречи с {0}", arguments: [String(describing: (context.person))]))
            }
            if app.isFeatureEnabled(.tasks), context.project.isEmpty && context.person.isEmpty {
                Button(L("Добавить проект или человека")) { showingContext = true }.buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
            Button { showingContext = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24) }
                .buttonStyle(.plain).help(app.isFeatureEnabled(.tasks) ? L("Проект, человек и шаблон") : L("Шаблон заметок"))
                .accessibilityLabel(app.isFeatureEnabled(.tasks) ? L("Изменить проект, человека и шаблон встречи") : L("Выбрать шаблон заметок встречи"))
        }.font(AppTypography.control).frame(height: 24)
    }
    private func openContext(_ label: String, mode: String) {
        notes.contextMode = mode; notes.contextSelection = label; app.librarySection = "contexts"
    }
}

struct NotesInboxView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    var draftKey = "inbox"
    private var text: Binding<String> { Binding(get: { notes.captureDrafts[draftKey] ?? "" }, set: { notes.captureDrafts[draftKey] = $0 }) }
    private var kind: Binding<String> { Binding(get: {
        let value = notes.captureKinds[draftKey] ?? "note"
        return value == "task" && !app.isFeatureEnabled(.tasks) ? "note" : value
    }, set: { notes.captureKinds[draftKey] = $0 }) }
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
                        Text(L("Входящие")).font(AppTypography.sectionTitle).accessibilityAddTraits(.isHeader)
                        if notes.error == nil { Text("\(inbox.count)").font(AppTypography.caption).foregroundStyle(.secondary) }
                        Spacer()
                        TextField(L("Поиск в заметках"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                            .accessibilityLabel(L("Поиск во входящих заметках"))
                    }
                    NoteComposer(text: text, kind: kind, placeholder: L("Новая заметка…"), documentID: "capture:" + draftKey) {
                        if notes.capture(text: text.wrappedValue, kind: kind.wrappedValue) != nil {
                            text.wrappedValue = ""
                            if app.showingCaptureDrafts { app.showingCaptureDrafts = false }
                        }
                    }
                    if inbox.isEmpty && notes.error == nil { NotesEmpty(title: query.isEmpty ? L("Входящие пусты") : L("Заметки не найдены"), text: "", icon: "tray") }
                    ForEach(inbox) { note in
                        NoteRow(note: note, notes: notes, meetingTitle: nil, meetingUnavailable: note.meetingID != nil) { editing = note }
                            .id(note.id).padding(2).background(notes.highlightedNoteID == note.id ? Ink.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.appContentLayout()
            }.onAppear { Task { await notes.refresh() }; if notes.highlightedNoteID != nil { query = "" }; Task { await Task.yield(); if let id = notes.highlightedNoteID { proxy.scrollTo(id, anchor: .center) } } }
                .onChange(of: notes.highlightedNoteID) { _, id in query = ""; Task { await Task.yield(); if let id { proxy.scrollTo(id, anchor: .center) } } }
                .sheet(item: $editing) { note in NoteEditorView(notes: notes, note: note).environmentObject(app).appControlDefaults() }
        }.overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
    }
}

private struct NoteComposer: View {
    @EnvironmentObject private var app: AppStore
    @Binding var text: String
    @Binding var kind: String
    let placeholder: String
    let documentID: String
    let save: () -> Void
    @State private var expanded = false
    @State private var focused = false
    private var editorHeight: CGFloat {
        if expanded { return 132 }
        return min(112, max(68, CGFloat(text.components(separatedBy: .newlines).count) * 20 + 12))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlainNoteInput(text: $text, placeholder: placeholder, isFocused: $focused, documentID: documentID)
                .frame(height: editorHeight)
            HStack(spacing: 10) {
                Picker(L("Тип заметки"), selection: $kind) {
                    ForEach(app.isFeatureEnabled(.tasks) ? ["note", "important", "question", "task"] : ["note", "important", "question"], id: \.self) { value in Label(noteKindTitle(value), systemImage: noteKindIcon(value)).tag(value) }
                }.labelsHidden().frame(width: 130).accessibilityLabel(L("Тип заметки"))
                Button { expanded.toggle(); focused = true } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(expanded ? L("Уменьшить поле заметки") : L("Увеличить поле заметки"))
                    .accessibilityLabel(expanded ? L("Уменьшить поле заметки") : L("Увеличить поле заметки"))
                Spacer()
                Button(L("Сохранить"), action: save).buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command]).help(L("Сохранить · ⌘↩"))
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
                if note.kind == "task" && app.isFeatureEnabled(.tasks) {
                    Button { var value = note; value.completed.toggle(); _ = notes.save(value) } label: {
                        Image(systemName: note.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(note.completed ? Ink.green : .secondary).frame(width: 24, height: 24)
                    }.buttonStyle(.plain).accessibilityLabel(note.completed ? L("Вернуть задачу в работу") : L("Завершить задачу"))
                } else {
                    Image(systemName: noteKindIcon(note.kind)).foregroundStyle(note.kind == "important" ? Ink.accent : .secondary)
                        .frame(width: 24, height: 24).help(noteKindTitle(note.kind)).accessibilityLabel(noteKindTitle(note.kind))
                }
                Button(action: edit) {
                    Text(note.text.isEmpty ? L("Отмеченный момент") : note.text).font(AppTypography.body).lineSpacing(4).lineLimit(4)
                        .strikethrough(note.kind == "task" && note.completed).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.top, 3).accessibilityHint(L("Открыть заметку"))
                Menu {
                    Button(L("Редактировать"), action: edit)
                    Button(L("Копировать текст")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.text, forType: .string) }
                    if app.isFeatureEnabled(.tasks), note.kind != "task" { Button(L("Сделать задачей")) { var value = note; value.kind = "task"; _ = notes.save(value) } }
                    if note.meetingID != nil { Button(L("Во входящие")) { var value = note; value.meetingID = nil; value.timestamp = nil; _ = notes.save(value) } }
                    Button(L("Удалить заметку"), role: .destructive) { notes.delete(note) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).frame(width: 26).accessibilityLabel(L("Действия с заметкой"))
            }
            HStack(spacing: 10) {
                if let timestamp = note.timestamp, note.meetingID != nil, !meetingUnavailable {
                    Button(Exporter.timestamp(timestamp)) { open() }.monospacedDigit().buttonStyle(.borderless).help(L("Открыть момент без воспроизведения"))
                }
                if !note.owner.isEmpty || !note.due.isEmpty { Text([note.owner, note.due].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1) }
                if meetingUnavailable { Button(L("Встреча недоступна")) { edit() }.buttonStyle(.borderless).help(L("Прикрепить заметку к другой встрече")) }
                else if let meetingTitle { Button(meetingTitle) { open() }.buttonStyle(.borderless).lineLimit(1) }
                if !note.attachments.isEmpty { Label("\(note.attachments.count)", systemImage: "paperclip") }
                if note.expansion != nil { Image(systemName: "sparkles").foregroundStyle(Ink.accent).help(L("Есть дополнение по записи")).accessibilityLabel(L("Есть дополнение по записи")) }
                Spacer(minLength: 0)
                Text(Date(timeIntervalSince1970: note.createdAt).formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(UILocale()))).lineLimit(1)
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
    @State private var dismissConfirmation = false
    @State private var showingSource = false
    @State private var editorID = UUID()
    @StateObject private var richCommands = RichNoteCommands()
    init(notes: NotesStore, note: CapturedNote) { self.notes = notes; _session = State(initialValue: NoteEditingSession(note: note)) }
    private var persisted: CapturedNote? { notes.workspace.notes.first { $0.id == session.baseline.id } }
    private var current: CapturedNote { persisted ?? session.baseline }
    private var profileSettings: AppSettings { app.settingsForNote(session.draft) }
    private var dirty: Bool { session.hasUnsavedChanges }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Заметка")).font(AppTypography.modalTitle)
                Spacer()
                Button(L("Закрыть")) { if dirty { dismissConfirmation = true } else { dismiss() } }.keyboardShortcut(.cancelAction).accessibilityIdentifier("notes.edit.cancel")
                Button(L("Сохранить")) { save() }.buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.return, modifiers: [.command]).accessibilityIdentifier("notes.edit.save")
            }.padding(22)
            Divider()
            if session.conflicted {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(L("Заметка изменилась в другом окне. Ваши правки остались здесь."), systemImage: "exclamationmark.circle").font(AppTypography.control).foregroundStyle(Ink.warning)
                            Text(L("Можно сохранить свой текст и поля новой заметкой. Вложения останутся в исходной.")).font(AppTypography.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(L("Сохранить как новую заметку")) { saveAsNew() }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                                if let persisted { Button(L("Открыть сохранённую версию")) { session.didPersist(persisted); notes.error = nil } }
                            }
                        }.padding(14).background(Ink.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        if app.isFeatureEnabled(.tasks) || session.draft.kind != "task" {
                            Picker(L("Тип"), selection: $session.draft.kind) {
                                ForEach(app.isFeatureEnabled(.tasks) ? ["note", "important", "question", "task"] : ["note", "important", "question"], id: \.self) { Text(noteKindTitle($0)).tag($0) }
                            }.frame(width: 190)
                        }
                        Spacer()
                        if let time = session.draft.timestamp { Text(Exporter.timestamp(time)).font(AppTypography.control).monospacedDigit().foregroundStyle(Ink.accent) }
                    }
                    RichNoteToolbar(commands: richCommands)
                    RichNoteEditor(text: $session.draft.text, rtf: $session.draft.contentRTF, commands: richCommands, onAttachmentPaste: { board in
                        persistBeforeAttachment { note in notes.paste(into: note, board: board) }
                    }).frame(minHeight: 160, maxHeight: 240)
                        .padding(10).background(Ink.field, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(L("Текст заметки"))
                    Picker(L("Встреча"), selection: Binding(get: { session.draft.meetingID ?? "" }, set: { value in
                        if session.draft.meetingID != (value.isEmpty ? nil : value) { session.draft.timestamp = nil }; session.draft.meetingID = value.isEmpty ? nil : value
                    })) {
                        Text(L("Входящие · без встречи")).tag("")
                        if let id = session.draft.meetingID, !app.noteMeetings.contains(where: { $0.id == id }) {
                            Text(app.allNoteMeetings.first(where: { $0.id == id })?.title ?? L("Встреча недоступна")).tag(id)
                        }
                        ForEach(app.noteMeetings) { Text($0.title).tag($0.id) }
                    }
                    if showingSource || !session.draft.sourceURL.isEmpty { TextField(L("Ссылка"), text: $session.draft.sourceURL).textFieldStyle(.roundedBorder).accessibilityLabel(L("Ссылка на источник")) }
                    if app.isFeatureEnabled(.tasks), session.draft.kind == "task" {
                        HStack { TextField(L("Кто делает"), text: $session.draft.owner); TextField(L("Срок, например до пятницы"), text: $session.draft.due) }.textFieldStyle(.roundedBorder)
                    }
                    Divider()
                    HStack {
                        Button { persistBeforeAttachment { notes.chooseAttachments(for: $0) } } label: { Label(L("Файл"), systemImage: "paperclip") }.accessibilityLabel(L("Добавить файлы"))
                        Button { persistBeforeAttachment { notes.paste(into: $0) } } label: { Label(L("Вставить"), systemImage: "doc.on.clipboard") }
                        if !showingSource && session.draft.sourceURL.isEmpty { Button { showingSource = true } label: { Label(L("Ссылка"), systemImage: "link") } }
                        Spacer()
                        if notes.attachmentBusy { ProgressView().controlSize(.small) }
                    }
                    ForEach(current.attachments, id: \.id) { attachment in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Button { notes.openAttachment(attachment, note: current) } label: { Label(attachment.name, systemImage: "doc") }.buttonStyle(.borderless).lineLimit(1)
                                Spacer()
                                if attachment.contentType.hasPrefix("image") || ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(URL(fileURLWithPath: attachment.name).pathExtension.lowercased()) {
                                    Button(L("Распознать текст")) { notes.recognize(attachment, note: current) }.disabled(notes.attachmentBusy)
                                }
                                Button { notes.removeAttachment(attachment, from: current) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(LF("Удалить вложение {0}", arguments: [String(describing: (attachment.name))]))
                            }
                            if !attachment.extractedText.isEmpty { Text(attachment.extractedText).font(AppTypography.control).textSelection(.enabled).lineSpacing(4) }
                        }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Divider()
                    HStack(alignment: .top) {
                        Button { persistBeforeAttachment { note in Task { await app.expandCapturedNote(note); notes.reload() } } } label: { Label(L("Дополнить по записи"), systemImage: "sparkles") }
                            .disabled(app.busy || current.meetingID == nil || current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help(current.meetingID == nil ? L("Сначала прикрепите заметку к встрече") : L("Дополнить заметку подтверждёнными деталями. Исходный текст сохранится."))
                        Spacer()
                        Image(systemName: profileSettings.mode == "cloud" ? "cloud" : "laptopcomputer").foregroundStyle(.secondary)
                            .help(profileSettings.mode == "cloud" ? profileSettings.cloudProviderTitle : L("ИИ на этом Mac"))
                    }
                    if profileSettings.mode == "cloud" {
                        Label(LF("{0} получит пометку и выбранные фрагменты транскрипта. Аудио и вложения остаются на Mac.", arguments: [L(profileSettings.cloudProviderTitle)]), systemImage: "cloud").font(AppTypography.control).foregroundStyle(.secondary)
                    }
                    if let expansion = current.expansion { NoteExpansionView(expansion: expansion, note: current) }
                }.padding(24)
            }
        }.frame(width: 700, height: 650).background(Ink.paper)
            .overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
            .interactiveDismissDisabled(dirty)
            .onAppear { registerDraft() }
            .onChange(of: dirty) { _, _ in registerDraft() }
            .onDisappear { UnsavedEditorRegistry.remove(id: editorID) }
            .confirmationDialog(L("Сохранить изменения в заметке?"), isPresented: $dismissConfirmation) {
                Button(L("Сохранить")) { save() }
                Button(L("Не сохранять"), role: .destructive) { UnsavedEditorRegistry.remove(id: editorID); dismiss() }.accessibilityIdentifier("notes.edit.discard")
                Button(L("Продолжить редактирование"), role: .cancel) {}
            }
            .onDrop(of: [.fileURL, .url, .plainText, .image], isTargeted: $dropping) { providers in
                let value = session.draft
                guard let saved = notes.save(value) else { refreshConflict(); return false }
                session.didPersist(saved); return notes.receiveDrop(providers, noteID: saved.id)
            }
            .overlay { if dropping { RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.accent, style: StrokeStyle(lineWidth: 2, dash: [7])).padding(5).allowsHitTesting(false) } }
            .onChange(of: persisted) { _, value in session.receive(value) }
    }
    private func registerDraft() {
        UnsavedEditorRegistry.set(id: editorID, title: LF("Заметка «{0}»", arguments: [String(describing: (session.draft.displayTitle.prefix(60)))]), dirty: dirty)
    }
    private func save() {
        if let saved = notes.save(session.draft) { session.didPersist(saved); UnsavedEditorRegistry.remove(id: editorID); dismiss() }
        else { refreshConflict() }
    }
    private func persistBeforeAttachment(_ action: (CapturedNote) -> Void) {
        if let saved = notes.save(session.draft) { session.didPersist(saved); action(saved) }
        else { refreshConflict() }
    }
    private func refreshConflict() { notes.reload(); session.receive(persisted) }
    private func saveAsNew() {
        let preserveMeeting = session.draft.meetingID.map { id in app.allNoteMeetings.contains { $0.id == id } } ?? true
        if let saved = notes.save(session.asNewNote(preserveMeeting: preserveMeeting)) {
            notes.notice = L("Ваш текст сохранён новой заметкой. Вложения остались в исходной.")
            session.didPersist(saved); UnsavedEditorRegistry.remove(id: editorID); dismiss()
        }
    }
}

struct NotesTemplatesView: View {
    @ObservedObject var notes: NotesStore
    @State private var editing: NoteTemplate?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L("Шаблоны заметок")).font(AppTypography.heading); Spacer(); Button(L("Создать шаблон")) { editing = NoteTemplate(name: L("Новый шаблон"), body: "", focus: "") } }
            ForEach(notes.templates) { template in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(template.name).font(AppTypography.bodyStrong); Text(template.focus).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer(); Button(L("Изменить")) { editing = template }
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
    @State private var editorID = UUID()
    private let baseline: NoteTemplate
    init(notes: NotesStore, template: NoteTemplate) {
        self.notes = notes; baseline = template; _template = State(initialValue: template)
    }
    private var dirty: Bool { template != baseline }
    private func close() { UnsavedEditorRegistry.remove(id: editorID); dismiss() }
    private func registerDraft() {
        UnsavedEditorRegistry.set(id: editorID, title: LF("Шаблон «{0}»", arguments: [String(describing: (template.name.prefix(60)))]), dirty: dirty)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L("Шаблон заметки")).font(AppTypography.modalTitle); Spacer(); Button(L("Отмена")) { close() }.accessibilityIdentifier("notes.template.cancel"); Button(L("Сохранить")) { if notes.saveTemplate(template) { close() } }.accessibilityIdentifier("notes.template.save").buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            TextField(L("Название"), text: $template.name).textFieldStyle(.roundedBorder)
            Text(L("Структура заметки")).font(AppTypography.control).foregroundStyle(.secondary)
            TextEditor(text: $template.body).font(AppTypography.body).frame(height: 180).padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 8))
            Text(L("Что выписать из встречи")).font(AppTypography.control).foregroundStyle(.secondary)
            TextEditor(text: $template.focus).font(AppTypography.body).frame(height: 90).padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 8))
            HStack { Button(L("Удалить шаблон"), role: .destructive) { if notes.deleteTemplate(template) { close() } }; Spacer() }
        }.padding(24).frame(width: 620)
            .interactiveDismissDisabled(dirty)
            .onAppear { registerDraft() }
            .onChange(of: dirty) { _, _ in registerDraft() }
            .onDisappear { UnsavedEditorRegistry.remove(id: editorID) }
            .overlay(alignment: .topTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
    }
}

private struct MeetingContextEditor: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @State private var context: MeetingContext
    @State private var baseline: MeetingContext
    @State private var selectedTemplate = ""
    @State private var insertTemplate = false
    @State private var editorID = UUID()
    @State private var baselineTemplate = ""
    @State private var finished = false
    @State private var templateFailureDetail: String?
    @State private var showingTemplateFailure = false
    private var dirty: Bool { context.project != baseline.project || context.person != baseline.person || selectedTemplate != baselineTemplate || insertTemplate }
    private var updatedContext: MeetingContext {
        var updated = context
        updated.templateID = selectedTemplate.isEmpty ? nil : selectedTemplate
        updated.project = updated.project.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.person = updated.person.trimmingCharacters(in: .whitespacesAndNewlines)
        return updated
    }
    private var metadataChanged: Bool {
        let updated = updatedContext
        // A new meeting can display the app's default without a stored row.
        // Explicitly choosing None must persist an override of that default.
        return updated.project != baseline.project || updated.person != baseline.person || updated.templateID != baseline.templateID
            || (baseline.revision == 0 && selectedTemplate != baselineTemplate)
    }
    private func close() { finished = true; UnsavedEditorRegistry.remove(id: editorID); dismiss() }
    private func registerDraft() {
        guard !finished else { return }
        UnsavedEditorRegistry.set(id: editorID, title: LF("Контекст встречи «{0}»", arguments: [String(describing: (meeting.title.prefix(60)))]), dirty: dirty)
    }
    init(notes: NotesStore, meeting: Meeting) {
        self.notes = notes; self.meeting = meeting
        let value = notes.context(for: meeting.id)
        _context = State(initialValue: value); _baseline = State(initialValue: value)
        _selectedTemplate = State(initialValue: value.templateID ?? "")
        _baselineTemplate = State(initialValue: value.templateID ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(app.isFeatureEnabled(.tasks) ? L("Контекст встречи") : L("Шаблон заметок")).font(AppTypography.modalTitle)
            Text(meeting.title).font(AppTypography.control).foregroundStyle(Ink.secondaryText).lineLimit(2)
            if app.isFeatureEnabled(.tasks) {
                TextField(L("Проект"), text: $context.project).textFieldStyle(.roundedBorder).accessibilityIdentifier("notes.context.project")
                TextField(L("Человек"), text: $context.person).textFieldStyle(.roundedBorder).accessibilityIdentifier("notes.context.person")
                Text(L("Встреча появится в «Проекты и люди». Папка и её настройки сохранятся."))
                    .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
            }
            Picker(L("Шаблон"), selection: $selectedTemplate) {
                Text(L("Без шаблона")).tag(""); ForEach(notes.templates) { Text($0.name).tag($0.id) }
            }.accessibilityIdentifier("notes.context.template")
            if !selectedTemplate.isEmpty { Toggle(L("Создать заметку по шаблону"), isOn: $insertTemplate).accessibilityIdentifier("notes.context.insertTemplate") }
            if let detail = templateFailureDetail {
                HStack(alignment: .top, spacing: 10) {
                    Label((metadataChanged ? "" : L("Параметры сохранены. ")) + L("Не удалось создать заметку по шаблону. Повторите сохранение."), systemImage: "exclamationmark.triangle")
                        .font(AppTypography.caption).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("notes.context.templateFailure")
                    Spacer(minLength: 0)
                    Button { showingTemplateFailure = true } label: { Image(systemName: "info.circle").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help(L("Подробности ошибки")).accessibilityLabel(L("Подробности ошибки создания заметки"))
                        .popover(isPresented: $showingTemplateFailure) { Text(detail).font(AppTypography.control).textSelection(.enabled).padding(20).frame(width: 420) }
                }
            }
            HStack {
                Spacer()
                Button(L("Отмена")) { close() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("notes.context.cancel")
                Button(L("Сохранить"), action: save).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("notes.context.save").buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .disabled(app.isTerminating)
            }
        }.padding(24).frame(width: 570)
            .overlay(alignment: .topTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
            .interactiveDismissDisabled(dirty)
            .onAppear {
                if context.revision == 0 && selectedTemplate.isEmpty {
                    selectedTemplate = app.settings.defaultTemplateID; baselineTemplate = selectedTemplate
                }
                registerDraft()
            }
            .onChange(of: selectedTemplate) { _, value in
                if value.isEmpty { insertTemplate = false; templateFailureDetail = nil }
            }
            .onChange(of: dirty) { _, _ in registerDraft() }
            .onDisappear { finished = true; UnsavedEditorRegistry.remove(id: editorID) }
    }
    private func save() {
        guard !finished, !app.isTerminating else { return }
        if selectedTemplate.isEmpty { insertTemplate = false; templateFailureDetail = nil }
        guard dirty else { close(); return }
        templateFailureDetail = nil
        guard metadataChanged || insertTemplate else { close(); return }
        if metadataChanged {
            guard notes.saveContext(updatedContext) else { return }
            // Context and note writes are separate transactions. Once this
            // stage commits, retain its new revision before attempting the note.
            // Retrying the note must not rewrite unchanged meeting metadata.
            context = notes.context(for: meeting.id); baseline = context; baselineTemplate = selectedTemplate
        }
        if insertTemplate {
            guard let template = notes.templates.first(where: { $0.id == selectedTemplate }) else {
                notes.error = L("Шаблон больше недоступен. Выберите другой шаблон и повторите сохранение."); return
            }
            guard notes.capture(text: template.body, meetingID: meeting.id) != nil else {
                templateFailureDetail = notes.error ?? L("Не удалось сохранить заметку.")
                notes.error = nil; registerDraft(); return
            }
            // A later retry or a second queued default action must not insert
            // another copy of the note that already committed successfully.
            insertTemplate = false
        }
        if let template = notes.templates.first(where: { $0.id == selectedTemplate }), app.selection == meeting.id, !template.focus.isEmpty {
            app.updateMeeting(meeting.id) { $0.focus = template.focus }
        }
        close()
    }
}

struct NotesMessage: View {
    @ObservedObject var notes: NotesStore
    @State private var details = false
    private var text: String? { notes.error ?? notes.notice }
    var body: some View {
        Group {
            if let text {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: notes.error != nil ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(notes.error != nil ? Ink.warning : Ink.green).padding(.top, 4)
                    Text(L(text)).font(AppTypography.control).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    if notes.error != nil {
                        Button { details = true } label: { Image(systemName: "info.circle").frame(width: 24, height: 24) }
                            .buttonStyle(.plain).help(L("Полный текст ошибки")).accessibilityLabel(L("Полный текст ошибки"))
                            .popover(isPresented: $details) { Text(L(text)).font(AppTypography.body).textSelection(.enabled).padding(20).frame(width: 420) }
                    }
                    Button { notes.error = nil; notes.notice = nil } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).accessibilityLabel(L("Закрыть сообщение"))
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
            if !text.isEmpty { Text(L(text)).font(AppTypography.control).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440) }
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
            Label(L("Дополнение ИИ"), systemImage: "sparkles").font(AppTypography.bodyStrong).foregroundStyle(Ink.accent)
            if checking { ProgressView().controlSize(.small) }
            else if !valid {
                Text(L("Исходная запись или заметка изменилась. Разверните заметку заново, чтобы получить актуальные ссылки.")).font(AppTypography.control).foregroundStyle(Ink.warning)
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
                    Text(L("ИИ предлагает уточнить")).font(AppTypography.bodyStrong)
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
              let segment = transcript.segments.first(where: { $0.id == id }) else { return LF("Источник {0}", arguments: [String(describing: (id + 1))]) }
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
    @State private var assigning = false
    @State private var editingContext: Meeting?
    @StateObject private var briefs = ContextBriefStore()
    private var index: ContextLibraryIndex { ContextLibraryIndex(meetings: app.noteMeetings, contexts: notes.workspace.contexts, mode: mode) }
    private var allLabels: [String] { index.labels }
    private var labels: [String] { allLabels.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    private var related: [Meeting] { index.meetings(for: selected) }
    private var briefRequest: ContextBriefRequest {
        ContextBriefRequest(folderID: app.folderSelection, mode: mode, label: selected, meetings: related)
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                AppWorkspaceHeader(title: L("Проекты и люди")) {
                    AppTabBar(label: L("Проекты или люди"), selection: $mode,
                              tabs: [AppTab(L("Проекты"), value: "project"), AppTab(L("Люди"), value: "person")],
                              identifier: "contexts.mode")
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("Встречи по общему проекту или человеку.")).font(AppTypography.control).foregroundStyle(Ink.secondaryText)
                        if let folder = app.notes.folder(app.folderSelection) {
                            Label(LF("В папке «{0}»", arguments: [String(describing: (folder.name))]), systemImage: "folder").font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                    if !allLabels.isEmpty {
                        Button { assigning = true } label: { Label(L("Связать встречу…"), systemImage: "plus") }
                            .accessibilityIdentifier("contexts.add").disabled(app.noteMeetings.isEmpty || app.isTerminating)
                    }
                }
                if !allLabels.isEmpty {
                    HStack(spacing: 12) {
                        Picker(mode == "project" ? L("Проект") : L("Человек"), selection: $selected) {
                            if labels.isEmpty { Text(L("Ничего не найдено")).tag("") }
                            ForEach(labels, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(mode == "project" ? L("Выбрать проект") : L("Выбрать человека"))
                            .accessibilityIdentifier("contexts.selection")
                        if !selected.isEmpty { Text(LF("Встреч: {0}", arguments: [String(describing: (related.count))])).font(AppTypography.caption).foregroundStyle(.secondary) }
                        if allLabels.count > 7 || !query.isEmpty {
                            TextField(L("Фильтр"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                                .accessibilityLabel(mode == "project" ? L("Найти проект") : L("Найти человека"))
                        }
                    }
                }
                if selected.isEmpty && notes.error == nil {
                    VStack(spacing: 0) {
                        NotesEmpty(title: query.isEmpty ? (mode == "project" ? L("Проектов пока нет") : L("Людей пока нет")) : L("Ничего не найдено"),
                                   text: query.isEmpty ? (app.noteMeetings.isEmpty ? LF("Сначала добавьте встречу{0}.", arguments: [String(describing: (app.folderSelection == nil ? "" : L(" в эту папку")))]) : L("Свяжите встречу с проектом или человеком, чтобы собрать её заметки и договорённости здесь.")) : "", icon: mode == "project" ? "rectangle.3.group" : "person.2")
                        if query.isEmpty {
                            if app.noteMeetings.isEmpty {
                                Button(L("Открыть встречи")) { app.librarySection = "meetings" }
                                    .accessibilityIdentifier("contexts.openMeetings")
                            } else {
                                Button(L("Связать встречу…")) { assigning = true }
                                    .buttonStyle(.borderedProminent).tint(Ink.actionFill).accessibilityIdentifier("contexts.add")
                            }
                            Text(L("Папки задают настройки. Проекты и люди собирают связанные встречи."))
                                .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).multilineTextAlignment(.center).frame(maxWidth: 440).padding(.top, 16)
                        }
                    }.frame(maxWidth: .infinity)
                } else {
                    ForEach(related) { meeting in brief(meeting) }
                }
            }.appContentLayout()
        }.onAppear {
            Task { await notes.refresh() }
            if let target = notes.contextSelection { mode = notes.contextMode; selected = target; notes.contextSelection = nil }
            normalizeSelection()
        }
            .onChange(of: mode) { _, _ in query = ""; normalizeSelection() }
            .onChange(of: query) { _, _ in normalizeSelection() }
            .onChange(of: allLabels) { _, _ in normalizeSelection() }
            .onChange(of: app.folderSelection) { _, _ in query = ""; normalizeSelection() }
            .task(id: briefRequest) { await briefs.load(root: app.root, request: briefRequest) }
            .onDisappear { briefs.cancel() }
            .sheet(isPresented: $assigning) {
                ContextAssignmentSheet(notes: notes, mode: mode, suggestedLabel: selected) { savedLabel in
                    query = ""; selected = savedLabel
                }.environmentObject(app)
            }
            .sheet(item: $editingContext) { meeting in MeetingContextEditor(notes: notes, meeting: meeting).environmentObject(app).appControlDefaults() }
            .overlay(alignment: .bottomTrailing) { NotesMessage(notes: notes).padding(12).frame(maxWidth: 440) }
    }
    private func normalizeSelection() {
        if !labels.contains(selected) { selected = labels.first ?? "" }
    }
    @ViewBuilder private func brief(_ meeting: Meeting) -> some View {
        let summary = briefs.summaries[meeting.id]
        let actions = summary?.items.filter { ["decision", "question"].contains($0.kind) || ($0.kind == "action" && !meeting.completedTasks.contains($0.id)) } ?? []
        let own = notes.notes(for: meeting.id).filter { $0.kind != "task" || !$0.completed }
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                Button { app.openMeeting(meeting.id) } label: { Text(meeting.title).font(AppTypography.heading).multilineTextAlignment(.leading) }.buttonStyle(.borderless)
                Spacer(); Text(Date(timeIntervalSince1970: meeting.createdAt).formatted(.dateTime.day().month(.abbreviated).locale(UILocale()))).font(AppTypography.control).foregroundStyle(.secondary)
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
            if actions.count > 12 { Button(L("Все договорённости и вопросы")) { app.openMeeting(meeting.id) }.buttonStyle(.borderless).font(AppTypography.control) }
            if !own.isEmpty {
                Divider()
                DisclosureGroup(LF("Мои заметки · {0}", arguments: [String(describing: (own.count))])) {
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
            if summary == nil && own.isEmpty {
                if briefs.loading { ProgressView().controlSize(.small).accessibilityLabel(L("Загрузка конспекта")) }
                else { Text(L("Конспект ещё не создан. Откройте встречу, чтобы добавить заметки.")).font(AppTypography.control).foregroundStyle(.secondary) }
            }
            HStack { Spacer(); Button(L("Изменить связь…")) { editingContext = meeting }.buttonStyle(.borderless).font(AppTypography.control).accessibilityIdentifier("contexts.edit." + meeting.id) }
        }.padding(16).background(Ink.soft, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct NotesTasksView: View {
    @ObservedObject var notes: NotesStore
    var body: some View { TasksWorkspaceView(notes: notes) }
}

#if DEBUG
/// Test-only entry points keep the production editors file-private.
@MainActor
enum NotesEditorCheckViews {
    static func template(notes: NotesStore, template: NoteTemplate) -> some View { TemplateEditor(notes: notes, template: template) }
    static func context(notes: NotesStore, meeting: Meeting) -> some View { MeetingContextEditor(notes: notes, meeting: meeting) }
}
#endif
