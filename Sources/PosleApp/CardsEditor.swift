import PosleCore
import SwiftUI

struct CardEditorRequest: Identifiable {
    let id = UUID()
    var entry: LibraryCardEntry?
    var meeting: Meeting?
}
struct CardEditorView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: CardEditorRequest
    let saved: (CardSaveResult) -> Void
    @State private var front: String
    @State private var back: String
    @State private var kind: String
    @State private var destination: String
    @State private var deckTitle = "Мои карточки"
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDiscard = false
    @State private var editorClosed = false
    init(request: CardEditorRequest, saved: @escaping (CardSaveResult) -> Void) {
        self.request = request; self.saved = saved
        _front = State(initialValue: request.entry?.card.front ?? "")
        _back = State(initialValue: request.entry?.card.back ?? "")
        _kind = State(initialValue: request.entry?.card.kind ?? "phrase")
        _destination = State(initialValue: request.entry?.meeting.id ?? request.meeting?.id ?? "")
    }
    private var dirty: Bool {
        front != (request.entry?.card.front ?? "") || back != (request.entry?.card.back ?? "") ||
        kind != (request.entry?.card.kind ?? "phrase") || destination != (request.entry?.meeting.id ?? request.meeting?.id ?? "") || deckTitle != "Мои карточки"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.entry == nil ? "Новая карточка" : "Изменить карточку").font(AppTypography.modalTitle)
            if request.entry == nil && request.meeting == nil {
                Picker("Сохранить в", selection: $destination) {
                    Text("Новая колода").tag("")
                    ForEach(app.meetings.filter { $0.status == "ready" }) { Text($0.title).tag($0.id) }
                }
                if destination.isEmpty { TextField("Название колоды", text: $deckTitle).textFieldStyle(.roundedBorder) }
            } else {
                Text(request.entry?.meeting.title ?? request.meeting?.title ?? "").font(AppTypography.control).foregroundStyle(.secondary).lineLimit(2)
            }
            Picker("Тип", selection: $kind) { Text("Фраза").tag("phrase"); Text("Понятие").tag("concept") }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 7) {
                Text("Вопрос или фраза").font(AppTypography.controlStrong)
                TextEditor(text: $front).font(AppTypography.body).frame(height: 78)
                    .scrollContentBackground(.hidden).padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.line)).accessibilityLabel("Вопрос карточки").accessibilityIdentifier("cards.edit.front")
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Ответ или перевод").font(AppTypography.controlStrong)
                TextEditor(text: $back).font(AppTypography.body).frame(height: 100)
                    .scrollContentBackground(.hidden).padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.line)).accessibilityLabel("Ответ карточки").accessibilityIdentifier("cards.edit.back")
            }
            if let entry = request.entry, !entry.card.context.isEmpty {
                DisclosureGroup("Контекст встречи") {
                    Text(entry.card.context).font(AppTypography.body).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(AppTypography.control)
            }
            if let error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Отмена") { close() }.keyboardShortcut(.cancelAction).disabled(saving).accessibilityIdentifier("cards.edit.cancel")
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Сохранить") { save() }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .disabled(saving || front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || destination.isEmpty && deckTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("cards.edit.save")
            }
        }.padding(24).frame(width: 540).appControlDefaults().disabled(saving)
            .interactiveDismissDisabled(dirty || saving)
            .onAppear { editorClosed = false; registerDraft() }
            .onChange(of: dirty) { _, _ in registerDraft() }
            .onDisappear { editorClosed = true; UnsavedEditorRegistry.remove(id: request.id) }
            .confirmationDialog("Закрыть без сохранения?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Закрыть без сохранения", role: .destructive) { finish() }.accessibilityIdentifier("cards.edit.discard")
                Button("Продолжить правку", role: .cancel) {}
            }
    }
    private func registerDraft() {
        guard !editorClosed else { return }
        let title = request.entry.map { "Карточка «\($0.card.front.prefix(60))»" } ?? "Новая карточка"
        UnsavedEditorRegistry.set(id: request.id, title: title, dirty: dirty)
    }
    private func finish() {
        editorClosed = true
        UnsavedEditorRegistry.remove(id: request.id)
        dismiss()
    }
    private func close() { if dirty { confirmingDiscard = true } else { finish() } }
    private func save() {
        guard !saving else { return }; saving = true; error = nil
        let root = app.root, text = front, answer = back, type = kind, target = destination, title = deckTitle, entry = request.entry
        Task {
            defer { saving = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    var args: [String: Any] = ["front": text, "back": answer, "kind": type, "newDeckTitle": title]
                    if !target.isEmpty { args["meetingID"] = target }
                    if let entry { args["cardID"] = entry.card.id; args["expectedFingerprint"] = entry.fingerprint }
                    let data = try RustBridge.shared.get().request(root: root, command: "card-save", arguments: args)
                    return try JSONDecoder().decode(CardSaveResult.self, from: data)
                }.value
                finish(); saved(result)
            } catch { self.error = error.localizedDescription }
        }
    }
}
