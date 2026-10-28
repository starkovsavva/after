import PosleCore
import SwiftUI

struct FolderNameTarget: Identifiable {
    let id = UUID()
    let folder: LibraryFolder
    var isNew = false
}

struct MeetingFolderTarget: Identifiable {
    var id: String { meeting.id }
    let meeting: Meeting
}

/// Creation asks for a name; the inherited profile can be customized later.
struct FolderNameSheet: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name: String
    @State private var failure = ""
    @State private var editorID = UUID()
    @State private var finished = false
    let folder: LibraryFolder
    let isNew: Bool
    var onSaved: ((LibraryFolder) -> Void)?

    init(folder: LibraryFolder, isNew: Bool = false, onSaved: ((LibraryFolder) -> Void)? = nil) {
        self.folder = folder; self.isNew = isNew; self.onSaved = onSaved
        _name = State(initialValue: folder.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? L("Новая папка") : L("Переименовать папку")).font(AppTypography.modalTitle)
            TextField(L("Название папки"), text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                .accessibilityIdentifier("folder.quick.name").onSubmit { save() }
            if isNew {
                Text(L("Настройки приложения наследуются. Изменить их можно в настройках папки."))
                    .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if !failure.isEmpty { Text(failure).font(AppTypography.caption).foregroundStyle(Ink.warning).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L("Отмена")) { finish() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("folder.quick.cancel")
                Button(isNew ? L("Создать папку") : L("Сохранить")) { save() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .disabled(app.isTerminating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("folder.quick.save")
            }
        }.padding(24).frame(width: 420).background(Ink.paper).appControlDefaults()
            .onAppear { nameFocused = true }
            .onChange(of: name) { _, value in
                guard !finished else { return }
                UnsavedEditorRegistry.set(id: editorID, title: L("Название папки"), dirty: value != folder.name)
            }
            .interactiveDismissDisabled(name != folder.name)
            .onDisappear { UnsavedEditorRegistry.remove(id: editorID) }
    }
    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isTerminating, !trimmed.isEmpty, !finished else { return }
        if !isNew && trimmed == folder.name { finish(); onSaved?(folder); return }
        var updated = folder; updated.name = trimmed
        guard let saved = app.notes.saveFolder(updated) else { failure = app.notes.error ?? L("Не удалось сохранить папку."); return }
        finish(); onSaved?(saved)
    }
    private func finish() {
        finished = true; UnsavedEditorRegistry.remove(id: editorID); dismiss()
    }
}

/// One explicit destination; a checkmark shows where the meeting is now.
struct MeetingFolderMoveSheet: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @FocusState private var newNameFocused: Bool
    @State private var editorID = UUID()
    @State private var finished = false
    @State private var newName = ""
    @State private var failure = ""
    let meeting: Meeting
    private var locked: Bool { app.captureMeetingID == meeting.id || app.isTerminating }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Переместить встречу")).font(AppTypography.modalTitle)
            Text(meeting.title).font(AppTypography.control).foregroundStyle(Ink.secondaryText).lineLimit(2)
            ScrollView {
                VStack(spacing: 2) {
                    destination(nil, name: L("Без папки"), icon: "tray")
                    ForEach(app.notes.folders) { folder in destination(folder.id, name: folder.name, icon: "folder") }
                }
            }.frame(minHeight: 80, maxHeight: 240)
            if creating {
                HStack {
                    TextField(L("Название папки"), text: $newName).textFieldStyle(.roundedBorder).focused($newNameFocused).onSubmit { createAndMove() }
                        .accessibilityIdentifier("folder.move.newName")
                    Button(L("Создать и переместить")) { createAndMove() }
                        .disabled(locked || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("folder.move.create")
                }
            } else {
                Button { creating = true } label: { Label(L("Новая папка…"), systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless).accessibilityIdentifier("folder.move.new")
            }
            if !failure.isEmpty { Text(failure).font(AppTypography.caption).foregroundStyle(Ink.warning).textSelection(.enabled) }
            HStack { Spacer(); Button(L("Отмена")) { finish() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("folder.move.cancel") }
        }.padding(24).frame(width: 470).background(Ink.paper).appControlDefaults()
            .onChange(of: creating) { _, value in newNameFocused = value }
            .onChange(of: newName) { _, value in
                guard !finished else { return }
                UnsavedEditorRegistry.set(id: editorID, title: L("Название папки"), dirty: !value.isEmpty)
            }
            .interactiveDismissDisabled(!newName.isEmpty)
            .onDisappear { finished = true; UnsavedEditorRegistry.remove(id: editorID) }
    }
    private func finish() {
        finished = true; UnsavedEditorRegistry.remove(id: editorID); dismiss()
    }
    private func destination(_ id: String?, name: String, icon: String) -> some View {
        Button { move(to: id) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
                if app.folderID(for: meeting.id) == id { Image(systemName: "checkmark").foregroundStyle(Ink.accent) }
            }.padding(9).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(locked).accessibilityIdentifier("folder.move.to." + (id ?? "none"))
    }
    private func move(to folderID: String?) {
        guard !locked else { return }
        if app.folderID(for: meeting.id) != folderID {
            guard app.notes.assignMeetingFolder(meeting.id, folderID: folderID) else { failure = app.notes.error ?? L("Не удалось переместить встречу."); return }
        }
        app.folderSelection = folderID
        app.selection = meeting.id; app.librarySection = "meetings"; app.loadSelection(); finish()
    }
    private func createAndMove() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locked, !name.isEmpty else { return }
        guard let folder = app.notes.saveFolder(LibraryFolder(name: name)) else { failure = app.notes.error ?? L("Не удалось создать папку."); return }
        creating = false; newName = ""; move(to: folder.id)
    }
}

/// A folder can be populated from the existing library without importing again.
struct FolderMeetingPicker: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var failure = ""
    let folder: LibraryFolder
    private var candidates: [Meeting] {
        app.meetings.filter {
            $0.libraryKind != "cards" && app.folderID(for: $0.id) != folder.id
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LF("Переместить в «{0}»", arguments: [String(describing: (folder.name))])).font(AppTypography.modalTitle).lineLimit(2)
            TextField(L("Найти встречу"), text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("folder.add.search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates) { meeting in
                        Button {
                            guard app.captureMeetingID != meeting.id, !app.isTerminating else { return }
                            guard app.notes.assignMeetingFolder(meeting.id, folderID: folder.id) else { failure = app.notes.error ?? L("Не удалось переместить встречу."); return }
                            app.librarySection = "meetings"; app.folderSelection = folder.id; app.selection = meeting.id; app.loadSelection(); dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "waveform").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(meeting.title).lineLimit(2)
                                    Text(app.notes.folder(for: meeting.id)?.name ?? L("Без папки")).font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(app.captureMeetingID == meeting.id || app.isTerminating)
                            .accessibilityIdentifier("folder.add.meeting." + meeting.id)
                    }
                    if candidates.isEmpty { Text(query.isEmpty ? L("Нет встреч для перемещения") : L("Встречи не найдены")).foregroundStyle(Ink.secondaryText).padding(9) }
                }
            }.frame(minHeight: 120, maxHeight: 300)
            if !failure.isEmpty { Text(failure).font(AppTypography.caption).foregroundStyle(Ink.warning).textSelection(.enabled) }
            HStack { Spacer(); Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("folder.add.cancel") }
        }.padding(24).frame(width: 470).background(Ink.paper).appControlDefaults()
    }
}
