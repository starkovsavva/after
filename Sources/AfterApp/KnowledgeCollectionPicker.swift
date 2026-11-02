import AfterCore
import AfterLocalization
import AfterPlatform
import Foundation
import SwiftUI

/// A view draft, not a second collection store. Rust still validates membership,
/// capacity, names and revisions atomically when the user submits it.
@MainActor
final class KnowledgeCollectionPickerDraft: ObservableObject {
    @Published var query = ""
    @Published var folder: String? // nil: all available; empty: without a folder
    @Published private(set) var selected: [String: Int] = [:]
    @Published private(set) var saving = false
    @Published private(set) var error: String?

    func select(_ note: CapturedNote, checked: Bool, capacity: Int) {
        guard !saving else { return }
        if checked {
            guard selected[note.id] != nil || selected.count < capacity else { return }
            selected[note.id] = note.revision
        } else { selected.removeValue(forKey: note.id) }
        error = nil
    }
    func clear() {
        guard !saving else { return }
        selected.removeAll(); error = nil
    }
    static func nameError(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return L("Введите название подборки.") }
        if trimmed.utf8.count > 500 { return L("Сократите название подборки.") }
        if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return L("В названии подборки не должно быть переносов строк или управляющих символов.")
        }
        return nil
    }
    func save(notes: [CapturedNote], name: String?, capacity: Int,
              permitted: (CapturedNote) -> Bool,
              onAdd: ([CapturedNote]) async throws -> Void) async -> Bool {
        guard !saving else { return false }
        error = Self.nameError(name)
        guard error == nil else { return false }
        guard !selected.isEmpty, selected.count <= capacity else {
            error = L("Проверьте количество выбранных заметок."); return false
        }
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let picked = selected.keys.sorted().compactMap { id -> CapturedNote? in
            guard let note = byID[id], permitted(note), note.revision == selected[id] else { return nil }
            return note
        }
        guard picked.count == selected.count else {
            error = L("Заметки изменились или стали недоступны. Выберите их заново."); return false
        }
        saving = true
        defer { saving = false }
        do { try await onAdd(picked); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

struct KnowledgeCollectionPicker: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<String>
    let capacity: Int
    var title: String
    var name: Binding<String>?
    let onAdd: ([CapturedNote]) async throws -> Void
    @StateObject private var draft = KnowledgeCollectionPickerDraft()
    // Keep the opening scope even if the parent changes while this sheet is up.
    @State private var initialFolderID: String?
    @State private var reading: CapturedNote?

    init(excluded: Set<String>, capacity: Int, scopeFolderID: String?,
         title: String = L("Добавить заметки"), name: Binding<String>? = nil,
         onAdd: @escaping ([CapturedNote]) async throws -> Void) {
        self.excluded = excluded; self.capacity = capacity; self.title = title
        self.name = name; self.onAdd = onAdd
        _initialFolderID = State(initialValue: scopeFolderID)
    }
    private func folderID(_ note: CapturedNote) -> String? {
        note.folderID ?? note.meetingID.flatMap { app.folderID(for: $0) }
    }
    private func folderName(_ note: CapturedNote) -> String {
        guard let id = folderID(note) else { return L("Без папки") }
        return app.notes.workspace.folders.first { $0.id == id }?.name ?? L("Папка")
    }
    private func permitted(_ note: CapturedNote) -> Bool {
        guard note.kind == "note", note.trashedAt == nil, !excluded.contains(note.id) else { return false }
        let folder = folderID(note)
        guard initialFolderID == nil || folder == initialFolderID,
              app.folderSelection == nil || folder == app.folderSelection else { return false }
        return app.effectiveSettings(for: note.folderID == nil ? note.meetingID : nil,
                                     folderID: note.folderID).features.knowledgeBase
    }
    private var eligible: [CapturedNote] {
        app.notes.workspace.notes.filter(permitted).sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }
    private var candidates: [CapturedNote] {
        let value = draft.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return eligible.filter { note in
            (draft.folder == nil || (folderID(note) ?? "") == draft.folder) &&
            (value.isEmpty || note.displayTitle.localizedCaseInsensitiveContains(value) ||
             note.text.localizedCaseInsensitiveContains(value))
        }
    }
    private var folders: [String] { Set(eligible.map { folderID($0) ?? "" }).sorted { lhs, rhs in
        let left = eligible.first { (folderID($0) ?? "") == lhs }.map(folderName) ?? ""
        let right = eligible.first { (folderID($0) ?? "") == rhs }.map(folderName) ?? ""
        return left.localizedStandardCompare(right) == .orderedAscending
    } }
    private var compact: Bool { eligible.count <= 1 }
    private var cardMinimumHeight: CGFloat { max(188, CGFloat(ThemeRuntime.shared.palette.textSize) * 7 + 80) }
    private var browserHeight: CGFloat { eligible.count <= 2 ? cardMinimumHeight + 8 : max(352, cardMinimumHeight * 1.6) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppPageHeader(title: title, modal: true)
            if let name {
                TextField(L("Название подборки"), text: name).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("knowledge.collection.pick.name")
                    .disabled(draft.saving)
                if let error = KnowledgeCollectionPickerDraft.nameError(name.wrappedValue),
                   !name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                if folders.count > 1 { folderList }
                VStack(alignment: .leading, spacing: 12) {
                    TextField(L("Найти по названию или тексту"), text: $draft.query)
                        .afterSearchField().disabled(draft.saving)
                        .accessibilityIdentifier("knowledge.collection.pick.search")
                    ScrollView {
                        if candidates.isEmpty { emptyState }
                        else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: compact ? 1 : 2), spacing: 12) {
                                ForEach(candidates) { note in card(note) }
                            }.padding(2)
                        }
                    }.frame(height: browserHeight)
                }
            }
            // The footer is outside every scroll area and remains available at
            // the native sheet's smallest size, including errors and busy state.
            Divider()
            if let error = draft.error {
                Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("knowledge.collection.pick.error")
            }
            footer
        }.padding(24).frame(width: compact ? 620 : 860).background(Ink.paper)
            .appControlDefaults().interactiveDismissDisabled(draft.saving)
            .sheet(item: $reading) { source in readingSheet(source) }
    }
    private var folderList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                folderButton(L("Все папки"), id: nil)
                ForEach(folders, id: \.self) { id in
                    folderButton(eligible.first { (folderID($0) ?? "") == id }.map(folderName) ?? L("Без папки"), id: id)
                }
            }.padding(2)
        }.frame(width: 148, height: browserHeight + 38)
    }
    private func folderButton(_ title: String, id: String?) -> some View {
        Button { draft.folder = id } label: {
            HStack(spacing: 8) {
                Image(systemName: id == nil ? "tray.full" : "folder")
                Text(title).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }.font(AppTypography.control).padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(draft.folder == id ? Ink.accent.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(draft.saving)
            .accessibilityValue(draft.folder == id ? L("Выбрано") : "")
            .accessibilityIdentifier("knowledge.collection.pick.folder." + (id ?? "all"))
    }
    private func card(_ note: CapturedNote) -> some View {
        let checked = draft.selected[note.id] != nil
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { checked }, set: { draft.select(note, checked: $0, capacity: capacity) })) {
                Text(note.displayTitle).font(AppTypography.bodyStrong).lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.checkbox)
                .disabled(draft.saving || (!checked && draft.selected.count >= capacity))
                .accessibilityIdentifier("knowledge.collection.pick.\(note.id)")
            Text(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Пустая заметка") : note.text)
                .font(AppTypography.body).foregroundStyle(.secondary).lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(folderName(note)).lineLimit(1)
                    Text(Date(timeIntervalSince1970: note.updatedAt).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(UILocale())))
                        .lineLimit(1)
                }.font(AppTypography.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(L("Читать")) { reading = note }.buttonStyle(AfterSoftButtonStyle())
                    .disabled(draft.saving).accessibilityLabel(LF("Прочитать: {0}", arguments: [note.displayTitle]))
                    .accessibilityIdentifier("knowledge.collection.pick.read.\(note.id)")
            }
        }.padding(14).frame(maxWidth: .infinity).frame(minHeight: cardMinimumHeight)
            .background(checked ? Ink.accent.opacity(0.08) : Ink.field, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(checked ? Ink.accent : Ink.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 2, y: 1)
    }
    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(L(eligible.isEmpty ? "Нет доступных заметок" : "Заметки не найдены"))
                .font(AppTypography.controlStrong)
            Text(L(eligible.isEmpty ? "В подборку можно добавить обычные заметки из этой области библиотеки." :
                   "Попробуйте другой запрос или выберите другую папку."))
                .font(AppTypography.control).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !draft.query.isEmpty || draft.folder != nil {
                Button(L("Сбросить фильтры")) { draft.query = ""; draft.folder = nil }
                    .buttonStyle(AfterSoftButtonStyle()).disabled(draft.saving)
            }
        }.padding(24).frame(maxWidth: .infinity).frame(minHeight: 172)
            .accessibilityIdentifier("knowledge.collection.pick.empty")
    }
    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(LF("Выбрано: {0} из {1}", arguments: [String(draft.selected.count), String(capacity)]))
                    .font(AppTypography.controlStrong).accessibilityIdentifier("knowledge.collection.pick.count")
                Text(L(draft.selected.isEmpty ? "Отметьте заметки для подборки." : "Содержимое заметок не изменится."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                if !draft.selected.isEmpty {
                    Button(L("Снять весь выбор")) { draft.clear() }.buttonStyle(.link)
                        .font(AppTypography.caption).disabled(draft.saving)
                        .accessibilityIdentifier("knowledge.collection.pick.clear")
                }
            }
            Spacer(minLength: 0)
            if draft.saving { ProgressView().controlSize(.small).accessibilityLabel(L("Сохранение…")) }
            Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
                .buttonStyle(AfterSoftButtonStyle()).disabled(draft.saving)
                .accessibilityIdentifier("knowledge.collection.pick.cancel")
            Button(L(draft.saving ? "Сохранение…" : name == nil ? "Добавить" : "Создать подборку")) {
                Task {
                    if await draft.save(notes: app.notes.workspace.notes, name: name?.wrappedValue,
                                        capacity: capacity, permitted: permitted, onAdd: onAdd) { dismiss() }
                }
            }.buttonStyle(AfterSoftButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                .disabled(draft.saving || draft.selected.isEmpty || KnowledgeCollectionPickerDraft.nameError(name?.wrappedValue) != nil)
                .accessibilityIdentifier("knowledge.collection.pick.confirm")
        }
    }
    private func readingSheet(_ source: CapturedNote) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let note = app.notes.workspace.notes.first(where: { $0.id == source.id && $0.revision == source.revision && permitted($0) }) {
                Text(folderName(note) + " · " + KnowledgeMaterialPresentation.date(note.updatedAt))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(note.displayTitle).font(AppTypography.modalTitle).textSelection(.enabled)
                        Text(note.text.isEmpty ? L("Пустая заметка") : note.text)
                            .font(AppTypography.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("knowledge.collection.pick.full-text")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 380)
            } else {
                Text(L("Заметки изменились или стали недоступны. Выберите их заново."))
                    .font(AppTypography.body).padding(.vertical, 24)
            }
            HStack { Spacer(); Button(L("Закрыть")) { reading = nil }.buttonStyle(AfterSoftButtonStyle())
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("knowledge.collection.pick.read.close") }
        }.padding(24).frame(width: 680).background(Ink.paper)
    }
}
