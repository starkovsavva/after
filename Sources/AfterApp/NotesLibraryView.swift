import AfterPlatform
import AfterLocalization
import AppKit
import Combine
import AfterCore
import SwiftUI
import UniformTypeIdentifiers

/// A failed disk/CAS save keeps the full rich draft available when the library
/// is reopened. The registry lives only for this app session; successful saves
/// still pass through Rust's revision checks.
@MainActor
private final class LibraryNoteDocument: ObservableObject {
    private static var documents: [String: LibraryNoteDocument] = [:]
    static func shared(notes: NotesStore) -> LibraryNoteDocument {
        let key = notes.root.standardizedFileURL.path
        if let document = documents[key] { return document }
        let document = LibraryNoteDocument(notes: notes)
        documents[key] = document
        return document
    }
    static func flushAll() -> Bool {
        var succeeded = true
        for document in documents.values { if !document.flush() { succeeded = false } }
        return succeeded
    }
    @Published var session: NoteEditingSession?
    @Published var saveError = ""
    let notes: NotesStore
    private var pending: Task<Void, Never>?
    private init(notes: NotesStore) { self.notes = notes }
    var selectedID: String? { session?.draft.id }
    var draft: CapturedNote? { session?.draft }
    var dirty: Bool { session?.hasUnsavedChanges == true }
    /// Native List owns focus and arrow keys; its selection still goes through
    /// the same save/conflict gate as clicking a note elsewhere in the app.
    var nativeSelection: Binding<String?> {
        Binding(get: { self.selectedID }, set: { id in
            if let id, let note = self.notes.workspace.notes.first(where: { $0.id == id }) {
                _ = self.select(note)
            } else if id == nil { _ = self.clear() }
        })
    }
    func edit(_ change: (inout CapturedNote) -> Void) {
        guard var value = session, value.draft.trashedAt == nil else { return }
        change(&value.draft); session = value
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = self?.flush()
        }
    }
    @discardableResult func flush() -> Bool {
        pending?.cancel(); pending = nil
        guard var value = session, value.hasUnsavedChanges else { return true }
        guard !value.conflicted else { saveError = L("Заметка изменилась в другом окне. Ваши правки сохранены в редакторе."); return false }
        guard let saved = notes.save(value.draft) else {
            notes.reload()
            value.receive(notes.workspace.notes.first { $0.id == value.baseline.id })
            session = value
            saveError = value.conflicted ? L("Заметка изменилась в другом окне. Ваши правки сохранены в редакторе.") : (notes.error ?? L("Не удалось сохранить заметку."))
            return false
        }
        value.didPersist(saved); session = value; saveError = ""
        return true
    }
    @discardableResult func select(_ note: CapturedNote) -> Bool {
        if note.id == selectedID { receive(note); return true }
        guard flush() else { return false }
        session = NoteEditingSession(note: note); saveError = ""
        notes.selectedNoteID = note.id
        return true
    }
    func receive(_ note: CapturedNote?) {
        guard var value = session else { return }
        value.receive(note); session = value
        if value.conflicted { saveError = L("Заметка изменилась в другом окне. Ваши правки сохранены в редакторе.") }
    }
    @discardableResult func clear() -> Bool {
        guard flush() else { return false }
        session = nil; saveError = ""; notes.selectedNoteID = nil
        return true
    }
    func reloadPersisted() {
        guard let id = selectedID else { return }
        notes.reload()
        if let note = notes.workspace.notes.first(where: { $0.id == id }) {
            session = NoteEditingSession(note: note); saveError = ""; notes.error = nil
        }
    }
    @discardableResult func moveToFolder(_ name: String, expectedID: String) -> Bool {
        guard selectedID == expectedID, draft?.trashedAt == nil else { return false }
        let destination: LibraryFolder?
        if name.isEmpty { destination = nil }
        else if let existing = notes.folders.first(where: { $0.name == name }) { destination = existing }
        else {
            guard let created = notes.saveFolder(LibraryFolder(name: name)) else { return false }
            destination = created
        }
        edit { $0.folder = destination?.name ?? ""; $0.folderID = destination?.id }
        return flush()
    }
    @discardableResult func saveCopy() -> CapturedNote? {
        guard let session, let saved = notes.save(session.asNewNote()) else { return nil }
        self.session = NoteEditingSession(note: saved); saveError = ""; notes.selectedNoteID = saved.id
        notes.notice = L("Копия сохранена. Вложения остались в исходной заметке.")
        return saved
    }
}

struct NotesLibraryView: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var notes: NotesStore
    @StateObject private var document: LibraryNoteDocument
    @StateObject private var commands = RichNoteCommands()
    @State private var filter = "all"
    @State private var folder = ""
    @State private var query = ""
    @State private var newFolder = ""
    @State private var tagsInput = ""
    @State private var showFolder = false
    @State private var folderNoteID: String?
    @State private var advanced: CapturedNote?
    @State private var linkingNote: CapturedNote?
    @State private var deleting: CapturedNote?
    @State private var confirmReload = false
    init(notes: NotesStore) {
        self.notes = notes
        _document = StateObject(wrappedValue: LibraryNoteDocument.shared(notes: notes))
    }
    private var persisted: CapturedNote? { notes.workspace.notes.first { $0.id == document.selectedID } }
    private var folders: [LibraryFolder] { notes.folders }
    private var visibleNotes: [CapturedNote] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.workspace.notes.filter { note in
            if filter == "trash" { guard note.trashedAt != nil else { return false } }
            else { guard note.trashedAt == nil else { return false } }
            if filter == "inbox", let meetingID = note.meetingID,
               app.allNoteMeetings.contains(where: { $0.id == meetingID }) { return false }
            if filter == "pinned" && !note.pinned { return false }
            if let selected = app.folderSelection, noteFolderID(note) != selected { return false }
            if !folder.isEmpty && noteFolderID(note) != folder { return false }
            if search.isEmpty { return true }
            let content = [note.title, note.text, note.tags.map { "#" + $0 }.joined(separator: " "), note.folder,
                           note.attachments.map { $0.name + " " + $0.extractedText }.joined(separator: " ")].joined(separator: "\n")
            return content.localizedCaseInsensitiveContains(search)
        }.sorted { left, right in
            if filter != "trash" && left.pinned != right.pinned { return left.pinned }
            return (left.trashedAt ?? left.updatedAt) > (right.trashedAt ?? right.updatedAt)
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            noteList.frame(width: 236)
            Divider()
            if let draft = document.draft { editor(draft) }
            else {
                VStack(spacing: 14) {
                    Image(systemName: "note.text").font(.system(size: 30)).foregroundStyle(Ink.accent).accessibilityHidden(true)
                    Text(filter == "trash" ? L("Корзина пуста") : L("Выберите заметку")).font(AppTypography.heading)
                    if filter != "trash" { Button(L("Новая заметка")) { createNote() }.buttonStyle(.borderedProminent).tint(Ink.actionFill) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Ink.paper)
            .onAppear {
                Task { await notes.refresh() }
                if let id = notes.selectedNoteID, let note = notes.workspace.notes.first(where: { $0.id == id }) { select(note, reveal: true) }
                else if document.draft == nil, let note = visibleNotes.first { select(note) }
                tagsInput = document.draft?.tags.map { "#" + $0 }.joined(separator: " ") ?? ""
            }
            .onDisappear { _ = document.flush() }
            .onChange(of: notes.newLibraryNoteRequest) { _, _ in createNote() }
            .onChange(of: persisted) { _, note in document.receive(note) }
            .onChange(of: notes.selectedNoteID) { _, id in
                guard let id, id != document.selectedID, let note = notes.workspace.notes.first(where: { $0.id == id }) else { return }
                select(note, reveal: true)
            }
            .onChange(of: filter) { _, _ in
                guard document.flush() else { return }
                folder = ""; selectVisibleNote()
            }
            .onChange(of: app.folderSelection) { _, _ in
                guard document.flush() else { return }
                folder = ""; selectVisibleNote()
            }
            .onChange(of: folder) { _, _ in
                guard document.flush() else { return }
                selectVisibleNote()
            }
            .onChange(of: document.selectedID) { _, _ in
                tagsInput = document.draft?.tags.map { "#" + $0 }.joined(separator: " ") ?? ""
            }
            .sheet(item: $advanced, onDismiss: { notes.reload(); document.receive(persisted) }) { note in
                NoteEditorView(notes: notes, note: note).environmentObject(app)
            }
            .sheet(item: $linkingNote, onDismiss: { notes.reload(); document.receive(persisted) }) { note in
                KnowledgeLinksSheet(notes: notes, source: note).environmentObject(app)
            }
            .alert(L("Новая папка"), isPresented: $showFolder) {
                TextField(L("Название папки"), text: $newFolder)
                Button(folderNoteID == nil ? L("Создать") : L("Создать и переместить")) {
                    let name = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    if let noteID = folderNoteID {
                        if document.moveToFolder(name, expectedID: noteID) { app.folderSelection = document.draft?.folderID; folder = "" }
                    } else if let created = notes.saveFolder(LibraryFolder(name: name)) {
                        app.folderSelection = created.id; folder = ""; selectVisibleNote()
                    }
                    newFolder = ""; folderNoteID = nil
                }.disabled(newFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L("Отмена"), role: .cancel) { newFolder = ""; folderNoteID = nil }
            }
            .confirmationDialog(L("Удалить заметку навсегда?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button(L("Удалить навсегда"), role: .destructive) {
                    guard let note = deleting else { return }
                    notes.purge(note)
                    if !notes.workspace.notes.contains(where: { $0.id == note.id }) { _ = document.clear(); if let first = visibleNotes.first { select(first) } }
                    deleting = nil
                }
                Button(L("Отмена"), role: .cancel) { deleting = nil }
            } message: { Text(L("Вложения этой заметки тоже будут удалены.")) }
            .confirmationDialog(L("Открыть сохранённую версию?"), isPresented: $confirmReload, titleVisibility: .visible) {
                Button(L("Открыть сохранённую версию"), role: .destructive) { document.reloadPersisted() }
                Button(L("Продолжить редактирование"), role: .cancel) {}
            } message: { Text(L("Несохранённые правки в этом редакторе будут заменены.")) }
    }
    private var noteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppListHeader(title: notes.folder(app.folderSelection)?.name ?? L("Заметки")) {
                Menu {
                    Button(L("Новая заметка")) { createNote() }
                    Button(L("Новая папка…")) { folderNoteID = nil; showFolder = true }
                } label: { Image(systemName: "square.and.pencil").frame(width: 26, height: 26) }.menuStyle(.borderlessButton).frame(width: 30).help(L("Создать заметку или папку"))
            }
            VStack(spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Поиск заметок"), text: $query).textFieldStyle(.plain).accessibilityLabel(L("Поиск по заголовкам, тексту, тегам и вложениям"))
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Очистить поиск заметок")) }
                }.padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 7))
                Picker(L("Показать"), selection: $filter) {
                    Text(L("Все заметки")).tag("all"); Text(L("Без встречи")).tag("inbox")
                    Text(L("Закреплённые")).tag("pinned"); Text(L("Корзина")).tag("trash")
                }.labelsHidden()
                if !folders.isEmpty && filter != "trash" && app.folderSelection == nil {
                    Picker(L("Папка"), selection: $folder) {
                        Text(L("Все папки")).tag("")
                        ForEach(folders) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                }
            }.padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            List(selection: document.nativeSelection) {
                ForEach(visibleNotes) { note in
                    row(note).tag(note.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            if note.trashedAt == nil {
                                Button(note.pinned ? L("Открепить") : L("Закрепить")) { if select(note) { document.edit { $0.pinned.toggle() }; _ = document.flush() } }
                                Button(L("Переместить в корзину"), role: .destructive) { trash(note) }
                            } else {
                                Button(L("Восстановить")) { restore(note) }
                                Button(L("Удалить навсегда"), role: .destructive) { deleting = note }
                            }
                        }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .overlay(alignment: .top) {
                    if visibleNotes.isEmpty {
                        Text(query.isEmpty ? (filter == "trash" ? L("Корзина пуста") : L("Нет заметок")) : L("Ничего не найдено"))
                            .font(AppTypography.control).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 28)
                            .allowsHitTesting(false)
                    }
                }
            Divider()
            Text(LF("Всего: {0}", arguments: [String(describing: (visibleNotes.count))])).font(AppTypography.caption).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 32)
        }.background(Ink.soft)
    }
    private func row(_ note: CapturedNote) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if note.pinned { Image(systemName: "pin.fill").font(AppTypography.caption).foregroundStyle(Ink.accent) }
                Text(note.displayTitle).font(AppTypography.controlStrong).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(Date(timeIntervalSince1970: note.updatedAt), style: .date).font(AppTypography.caption).foregroundStyle(.secondary)
                if !note.attachments.isEmpty { Image(systemName: "paperclip").font(AppTypography.caption).foregroundStyle(.secondary) }
                if note.meetingID != nil { Image(systemName: "waveform").font(AppTypography.caption).foregroundStyle(.secondary) }
            }
            let snippet = note.text.split(separator: "\n").dropFirst(note.title.isEmpty ? 1 : 0).joined(separator: " ")
            if !snippet.isEmpty { Text(snippet).font(AppTypography.control).foregroundStyle(.secondary).lineLimit(2) }
            let folderName = notes.folder(noteFolderID(note))?.name ?? note.folder
            if !folderName.isEmpty || !note.tags.isEmpty {
                Text(([folderName].filter { !$0.isEmpty } + note.tags.map { "#" + $0 }).joined(separator: " · ")).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
            .contentShape(Rectangle())
    }
    private func editor(_ draft: CapturedNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if draft.trashedAt != nil {
                    Label(L("В корзине"), systemImage: "trash").font(AppTypography.control).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Восстановить")) { restore(draft) }.buttonStyle(.bordered)
                    Button { deleting = persisted ?? draft } label: { Image(systemName: "trash.slash") }.help(L("Удалить навсегда"))
                } else {
                    Button { document.edit { $0.pinned.toggle() }; _ = document.flush() } label: { Image(systemName: draft.pinned ? "pin.fill" : "pin") }.help(draft.pinned ? L("Открепить") : L("Закрепить"))
                    Button {
                        guard document.flush(), let note = persisted else { return }
                        advanced = note
                    } label: { Image(systemName: "paperclip") }.help(L("Вложения, источник и свойства заметки"))
                    if draft.kind == "note" && app.effectiveSettings(for: draft.folderID == nil ? draft.meetingID : nil,
                                                                    folderID: draft.folderID).features.knowledgeBase {
                        Button {
                            guard document.flush(), let note = persisted else { return }
                            linkingNote = note
                        } label: { Image(systemName: "link") }
                            .help(L("Связи заметки"))
                            .accessibilityLabel(L("Связи заметки"))
                            .accessibilityIdentifier("knowledge.links.open")
                    }
                    Spacer()
                    Text(!document.saveError.isEmpty ? L("Не сохранено") : document.dirty ? L("Сохраняю…") : L("Сохранено")).font(AppTypography.caption).foregroundStyle(.secondary)
                    Menu {
                        Button(L("RTF с форматированием…")) { export(draft, format: "rtf") }
                        Button(L("Текст…")) { export(draft, format: "txt") }
                        Button("Markdown…") { export(draft, format: "md") }
                    } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).frame(width: 28).help(L("Экспорт заметки"))
                    Button { trash(draft) } label: { Image(systemName: "trash") }.help(L("Переместить в корзину"))
                }
            }.buttonStyle(.borderless).frame(height: 40).padding(.horizontal, 20)
            Divider()
            if !document.saveError.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(document.saveError, systemImage: "exclamationmark.circle").font(AppTypography.caption).foregroundStyle(Ink.warning).textSelection(.enabled)
                    HStack {
                        if document.session?.conflicted != true { Button(L("Повторить")) { _ = document.flush() } }
                        Button(L("Сохранить копию")) { if let saved = document.saveCopy() { filter = "all"; folder = ""; query = ""; select(saved) } }
                        if persisted != nil { Button(L("Открыть сохранённую версию…")) { confirmReload = true } }
                    }.font(AppTypography.caption)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Ink.warning.opacity(0.06))
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField(L("Новая заметка"), text: binding(\.title)).font(AppTypography.pageTitle).textFieldStyle(.plain).disabled(draft.trashedAt != nil)
                    .accessibilityLabel(L("Заголовок заметки"))
                HStack(spacing: 10) {
                    Text(Date(timeIntervalSince1970: draft.updatedAt), style: .date).font(AppTypography.caption).foregroundStyle(.secondary)
                    if let meetingID = draft.meetingID {
                        if let meeting = app.allNoteMeetings.first(where: { $0.id == meetingID }) {
                            Button { if document.flush() { app.openMeeting(meetingID, tab: "notes") } } label: { Label(meeting.title, systemImage: "waveform").lineLimit(1) }.buttonStyle(.link).font(AppTypography.caption)
                        } else {
                            Label(L("Встреча недоступна"), systemImage: "waveform").font(AppTypography.caption).foregroundStyle(.secondary)
                                .help(L("Связь с встречей сохранена. После восстановления из Корзины она снова откроется."))
                        }
                    }
                    Spacer(minLength: 0)
                }
                if draft.trashedAt == nil { RichNoteToolbar(commands: commands) }
                RichNoteEditor(text: binding(\.text), rtf: binding(\.contentRTF), commands: commands, editable: draft.trashedAt == nil, onAttachmentPaste: { board in
                    guard document.flush(), let note = persisted else { return }
                    notes.paste(into: note, board: board)
                })
                    .id(draft.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                if !draft.attachments.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "paperclip").foregroundStyle(.secondary)
                        ForEach(Array(draft.attachments.prefix(2))) { attachment in
                            Button(attachment.name) { if let note = persisted { notes.openAttachment(attachment, note: note) } }.lineLimit(1).buttonStyle(.link)
                        }
                        if draft.attachments.count > 2 { Text("+\(draft.attachments.count - 2)").foregroundStyle(.secondary) }
                    }.font(AppTypography.caption)
                }
                if draft.trashedAt == nil {
                    Divider()
                    HStack(spacing: 10) {
                        Menu {
                            Button(draft.meetingID == nil ? L("Без папки") : L("Как у встречи")) { moveNote(to: nil) }
                            ForEach(folders) { folder in Button(folder.name) { moveNote(to: folder) } }
                            Divider()
                            Button(L("Новая папка…")) { folderNoteID = draft.id; showFolder = true }
                        } label: { Label(notes.folder(noteFolderID(draft))?.name ?? (draft.folder.isEmpty ? L("Папка") : draft.folder), systemImage: "folder").lineLimit(1) }.menuStyle(.borderlessButton).frame(maxWidth: 170)
                        TextField(L("#теги через пробел"), text: Binding(get: { tagsInput }, set: { value in
                            tagsInput = value
                            let tags = value.split { $0.isWhitespace || $0 == "," }.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }.filter { !$0.isEmpty }
                            document.edit { $0.tags = Array(NSOrderedSet(array: tags)) as? [String] ?? tags }
                        })).textFieldStyle(.plain).font(AppTypography.caption).accessibilityLabel(L("Теги заметки"))
                    }.frame(height: 30)
                }
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.paper)
    }
    private func binding(_ key: WritableKeyPath<CapturedNote, String>) -> Binding<String> {
        Binding(get: { document.draft?[keyPath: key] ?? "" }, set: { value in document.edit { $0[keyPath: key] = value } })
    }
    @discardableResult private func select(_ note: CapturedNote, reveal: Bool = false) -> Bool {
        guard document.select(note) else { notes.selectedNoteID = document.selectedID; return false }
        if reveal { filter = note.trashedAt == nil ? "all" : "trash"; folder = ""; query = "" }
        return true
    }
    private func selectVisibleNote() {
        if let id = notes.selectedNoteID, let requested = visibleNotes.first(where: { $0.id == id }) {
            _ = select(requested); return
        }
        if let id = document.selectedID, visibleNotes.contains(where: { $0.id == id }) { return }
        if let first = visibleNotes.first { select(first) } else { _ = document.clear() }
    }
    private func createNote(in targetFolder: String? = nil) {
        guard document.flush() else { return }
        let destinationID = targetFolder ?? (folder.isEmpty ? app.folderSelection : folder)
        let destination = notes.folder(destinationID)
        var note = CapturedNote(); note.folderID = destination?.id; note.folder = destination?.name ?? ""
        guard let saved = notes.save(note) else { return }
        filter = "all"; query = ""; folder = app.folderSelection == nil ? (destination?.id ?? "") : ""
        _ = document.select(saved)
    }
    private func noteFolderID(_ note: CapturedNote) -> String? {
        note.folderID ?? note.meetingID.flatMap { notes.context(for: $0).folderID }
    }
    private func moveNote(to destination: LibraryFolder?) {
        guard document.flush() else { return }
        document.edit { $0.folderID = destination?.id; $0.folder = destination?.name ?? "" }
        guard document.flush() else { return }
        if app.folderSelection != nil { app.folderSelection = destination?.id }
        folder = ""
    }
    private func trash(_ note: CapturedNote) {
        guard document.flush() else { return }
        let latest = notes.workspace.notes.first { $0.id == note.id } ?? note
        notes.delete(latest)
        guard notes.workspace.notes.first(where: { $0.id == note.id })?.trashedAt != nil else { return }
        if document.selectedID == note.id { _ = document.clear(); if let first = visibleNotes.first { select(first) } }
    }
    private func restore(_ note: CapturedNote) {
        notes.restore(notes.workspace.notes.first { $0.id == note.id } ?? note)
        guard let restored = notes.workspace.notes.first(where: { $0.id == note.id }), restored.trashedAt == nil else { return }
        _ = document.clear(); filter = "all"; folder = ""; query = ""; select(restored)
    }
    private func export(_ note: CapturedNote, format: String) {
        guard document.flush() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == "rtf" ? .rtf : format == "txt" ? .plainText : UTType(filenameExtension: "md") ?? .plainText]
        let name = note.displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = String(name.prefix(100)) + "." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if format == "rtf" {
                let body: NSAttributedString
                if let rtf = Data(base64Encoded: note.contentRTF), let styled = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil), styled.string == note.text { body = styled }
                else { body = NSAttributedString(string: note.text, attributes: [.font: NSFont.systemFont(ofSize: 14)]) }
                let content = NSMutableAttributedString(string: note.displayTitle + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold)])
                content.append(body)
                data = try content.data(from: NSRange(location: 0, length: content.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            } else {
                let prefix = format == "md" ? "# " : ""
                data = Data((prefix + note.displayTitle + "\n\n" + note.text + (note.tags.isEmpty ? "" : "\n\n" + note.tags.map { "#" + $0 }.joined(separator: " "))).utf8)
            }
            try data.write(to: url, options: .atomic)
        } catch { document.saveError = error.localizedDescription }
    }
}

/// The app delegate flushes debounced edits before macOS closes any windows.
@MainActor
enum NoteDraftPersistence {
    static func flushAll() -> Bool { LibraryNoteDocument.flushAll() }
    #if DEBUG
    static func verifyImmediatePersistence(notes: NotesStore) throws {
        guard let note = notes.capture(text: "Черновик перед выходом") else { throw AppError.message(notes.error ?? "Cannot create a note") }
        let document = LibraryNoteDocument.shared(notes: notes)
        guard document.select(note) else { throw AppError.message("Cannot select a note") }
        document.edit { $0.text = "Последние символы до Command-Q"; $0.title = "Проверка выхода" }
        guard flushAll(), let persisted = notes.notes.first(where: { $0.id == note.id }), persisted.text == "Последние символы до Command-Q" else { throw AppError.message("Immediate quit did not flush the debounce") }
        let noteCount = notes.notes.count
        document.edit { $0.text = "Текст, набранный перед созданием папки" }
        guard document.moveToFolder("Новая папка из редактора", expectedID: note.id),
              document.selectedID == note.id, notes.notes.count == noteCount,
              let moved = notes.notes.first(where: { $0.id == note.id }),
              moved.folder == "Новая папка из редактора", moved.text == "Текст, набранный перед созданием папки" else {
            throw AppError.message("Creating a folder from the editor did not move the same note and preserve pending typing")
        }
        guard !document.moveToFolder("Не та заметка", expectedID: UUID().uuidString),
              document.draft?.folder == moved.folder else { throw AppError.message("A stale folder action moved a different note") }
        guard let other = notes.capture(text: "Заметка для перехода стрелками") else { throw AppError.message("Cannot create native selection fixture") }
        let nativeSelection = document.nativeSelection
        document.edit { $0.text = "Правка перед переходом стрелкой" }
        nativeSelection.wrappedValue = other.id
        guard document.selectedID == other.id, notes.selectedNoteID == other.id,
              let beforeConflict = notes.notes.first(where: { $0.id == note.id }),
              beforeConflict.text == "Правка перед переходом стрелкой" else {
            throw AppError.message("Native List selection did not flush the current note before switching documents")
        }
        nativeSelection.wrappedValue = note.id
        document.edit { $0.text = "Моя несохранённая правка" }
        var foreign = beforeConflict; foreign.text = "Правка другого окна"
        guard notes.save(foreign) != nil else { throw AppError.message(notes.error ?? "Cannot create concurrent edit") }
        nativeSelection.wrappedValue = other.id
        guard document.selectedID == note.id, notes.selectedNoteID == note.id,
              document.draft?.text == "Моя несохранённая правка", !document.saveError.isEmpty else {
            throw AppError.message("Native List selection switched documents despite a conflicting unsaved draft")
        }
        nativeSelection.wrappedValue = nil
        guard document.selectedID == note.id else { throw AppError.message("Native List deselection discarded a conflicting draft") }
        guard !flushAll(), document.draft?.text == "Моя несохранённая правка", notes.notes.first(where: { $0.id == note.id })?.text == "Правка другого окна" else { throw AppError.message("A failed quit save lost concurrent edits") }
        guard let copy = document.saveCopy(), copy.id != note.id, copy.text == "Моя несохранённая правка", flushAll() else { throw AppError.message("The failed quit draft cannot be recovered as a copy") }
        _ = document.clear()
    }
    #endif
}
