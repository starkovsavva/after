import AfterLocalization
import AfterCore
import SwiftUI

struct KnowledgeRebuildSheet: View {
    @ObservedObject private var app: AppStore
    @StateObject private var controller: KnowledgeRebuildController
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "proposal"
    @State private var noteQuery = ""
    @State private var discardConfirmation = false
    @State private var restartConfirmation = false

    init(store: AppStore, controller: KnowledgeRebuildController? = nil) {
        app = store
        _controller = StateObject(wrappedValue: controller ?? KnowledgeRebuildController(root: store.root) { ids, folder, instruction, event in
            try await store.generateKnowledgeRebuild(noteIDs: ids, folderID: folder, instruction: instruction, event: event)
        })
    }
    private var candidates: [CapturedNote] {
        app.notes.workspace.notes.filter { note in
            let folder = note.folderID ?? note.meetingID.flatMap { app.folderID(for: $0) }
            return note.kind == "note" && note.trashedAt == nil &&
                (app.folderSelection == nil || folder == app.folderSelection) &&
                app.effectiveSettings(for: note.folderID == nil ? note.meetingID : nil, folderID: note.folderID).features.knowledgeBase
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }
    private var visibleCandidates: [CapturedNote] {
        let query = noteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
    }
    private var selectedBytes: Int {
        candidates.filter { controller.selectedNoteIDs.contains($0.id) }.reduce(0) { $0 + $1.title.utf8.count + $1.text.utf8.count }
    }
    private var unavailableSelection: Bool {
        !controller.selectedNoteIDs.isSubset(of: Set(candidates.map(\.id))) ||
            (controller.phase == .review && controller.selectionFolderID != app.folderSelection)
    }
    private var workBlocked: Bool { app.isRecording || app.startingRecording || app.stoppingRecording || app.busy }
    private var instructionValid: Bool {
        let text = controller.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.utf8.count <= 4_000
    }
    private var canGenerate: Bool {
        !controller.busy && !workBlocked && !unavailableSelection &&
            (1...30).contains(controller.selectedNoteIDs.count) && selectedBytes <= 60_000 && instructionValid
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppPageHeader(title: L("Переорганизовать базу знаний"), modal: true)
            AppTabBar(label: L("Переорганизация"), selection: $tab, tabs: [
                AppTab(controller.phase == .select ? L("Поручение") : controller.phase == .review ? L("Проверка") : L("Результат"), value: "proposal"),
                AppTab(L("История применений"), value: "history")
            ], identifier: "knowledge.rebuild.tab")
            if controller.busy || !controller.status.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    if controller.busy { ProgressView().controlSize(.small) }
                    Text(controller.status).font(AppTypography.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("knowledge.rebuild.status")
            }
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.circle").font(AppTypography.caption)
                    .foregroundStyle(Ink.warning).textSelection(.enabled)
                    .accessibilityIdentifier("knowledge.rebuild.error")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == "history" { history }
                    else if controller.phase == .select { selection }
                    else if controller.phase == .review { review }
                    else {
                        Text(controller.receipt?.undone == true ? L("Применение отменено.") : L("Изменения применены. Их можно отменить в истории."))
                            .font(AppTypography.heading).accessibilityIdentifier("knowledge.rebuild.finished")
                        Button(L("Открыть историю применений")) { tab = "history" }.buttonStyle(.bordered)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
            if tab == "proposal" && controller.phase == .select { providerDisclosure }
            Divider()
            footer
        }.padding(24).frame(minWidth: 680, idealWidth: 800, maxWidth: 920, minHeight: 560, idealHeight: 660)
            .appControlDefaults()
            .interactiveDismissDisabled(controller.mutating || controller.reviewChanged)
            .confirmationDialog(L("Закрыть без применения изменений?"), isPresented: $discardConfirmation) {
                Button(L("Закрыть без применения"), role: .destructive) { controller.cancel(); dismiss() }
                Button(L("Продолжить проверку"), role: .cancel) {}
            }
            .confirmationDialog(L("Начать новое поручение? Правки текущего предложения не сохранятся."), isPresented: $restartConfirmation) {
                Button(L("Начать заново"), role: .destructive) { controller.startOver() }
                Button(L("Продолжить проверку"), role: .cancel) {}
            }
            .task { await controller.loadHistory() }
            .onChange(of: tab) { _, value in if value == "history" { Task { await controller.loadHistory() } } }
            .onChange(of: candidates.map(\.id)) { _, ids in
                if controller.phase == .select && !controller.busy { controller.selectedNoteIDs.formIntersection(Set(ids)) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .knowledgeRebuildChanged)) { notification in
                if let changedRoot = notification.object as? URL,
                   changedRoot.standardizedFileURL.resolvingSymlinksInPath() == app.root.standardizedFileURL.resolvingSymlinksInPath() { app.notes.reload() }
            }
            .onDisappear { controller.cancel() }
    }
    private var selection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Выберите заметки и опишите результат. Сначала появится предложение; без вашего применения библиотека не изменится."))
                .font(AppTypography.control).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(LF("Выбрано заметок: {0} из 30", arguments: [String(controller.selectedNoteIDs.count)]))
                    .font(AppTypography.controlStrong).accessibilityIdentifier("knowledge.rebuild.selection-count")
                Spacer()
                Button(L("Снять выбор")) { controller.selectedNoteIDs.removeAll() }
                    .buttonStyle(.borderless).disabled(controller.busy || controller.selectedNoteIDs.isEmpty)
            }
            TextField(L("Поиск заметок"), text: $noteQuery).textFieldStyle(.roundedBorder)
            if candidates.isEmpty {
                Text(L("В этой области нет доступных заметок. Сначала сохраните заметку или выберите другую папку."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleCandidates) { note in
                            Toggle(isOn: Binding(get: { controller.selectedNoteIDs.contains(note.id) }, set: { value in
                                if value { if controller.selectedNoteIDs.count < 30 { controller.selectedNoteIDs.insert(note.id) } }
                                else { controller.selectedNoteIDs.remove(note.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(note.displayTitle).font(AppTypography.control).lineLimit(2)
                                    Text(KnowledgeMaterialPresentation.metadata(note)).font(AppTypography.caption).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                                .disabled(controller.busy || (!controller.selectedNoteIDs.contains(note.id) && controller.selectedNoteIDs.count >= 30))
                                .accessibilityIdentifier("knowledge.rebuild.select." + note.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 170).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            }
            if selectedBytes > 60_000 {
                Text(L("Выберите меньше заметок: тексты слишком длинные для одного поручения."))
                    .font(AppTypography.caption).foregroundStyle(Ink.warning)
            }
            HStack {
                Text(L("Что изменить?")).font(AppTypography.controlStrong)
                Spacer()
                Menu(L("Примеры поручений")) {
                    Button(L("Собрать подборки по проектам")) { controller.instruction = L("Собери заметки в подборки по проектам. Не меняй исходные тексты.") }
                    Button(L("Разделить длинные заметки")) { controller.instruction = L("Раздели длинные заметки по темам. Создай новые заметки со ссылками на источники, сохрани исходники.") }
                    Button(L("Объединить повторяющиеся мысли")) { controller.instruction = L("Объедини повторяющиеся мысли в новые заметки. Сохрани исходники и укажи источники каждой новой заметки.") }
                }.menuStyle(.borderlessButton).fixedSize().disabled(controller.busy)
            }
            TextEditor(text: $controller.instruction).font(AppTypography.control).frame(minHeight: 85, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
                .disabled(controller.busy).accessibilityLabel(L("Поручение"))
                .accessibilityIdentifier("knowledge.rebuild.instruction")
            if controller.instruction.utf8.count > 4_000 {
                Text(L("Поручение слишком длинное. Сократите текст.")) .font(AppTypography.caption).foregroundStyle(Ink.warning)
            }
        }
    }
    // Keep consent next to the action, outside the scrollable note/form area.
    private var providerDisclosure: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(controller.busy ? controller.providerDescription : app.knowledgeRebuildProviderDescription)
                .font(AppTypography.controlStrong)
            if !controller.busy {
                Text(app.effectiveSettings(folderID: app.folderSelection).mode == "local"
                    ? L("После нажатия «Предложить изменения» выбранные тексты и поручение будут обработаны локально.")
                    : L("После нажатия «Предложить изменения» названия и тексты только выбранных заметок и поручение будут отправлены этому облачному провайдеру."))
                    .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if workBlocked {
                    Text(L("Дождитесь завершения записи или текущей обработки, чтобы предложить изменения."))
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                }
            }
        }.accessibilityIdentifier("knowledge.rebuild.provider-disclosure")
    }
    @ViewBuilder private var review: some View {
        if let proposal = controller.proposal, let preview = controller.preview {
            Text(proposal.title).font(AppTypography.heading)
            Text(proposal.summary).font(AppTypography.control).textSelection(.enabled)
            Text(L("Новые заметки сохранят ссылки на источники. Исходники останутся; изменятся только заметки из раздела «Изменения исходников»."))
                .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if unavailableSelection {
                Text(L("Выбранные заметки или область стали недоступны. Вернитесь к выбору и подготовьте новое предложение."))
                    .font(AppTypography.caption).foregroundStyle(Ink.warning)
            }
            if !proposal.edits.isEmpty {
                Text(L("Изменения исходников")).font(AppTypography.heading)
                ForEach(proposal.edits) { edit in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Spacer()
                            Button(L("Не менять эту заметку")) { controller.removeEdit(edit.noteID) }
                                .buttonStyle(.borderless).font(AppTypography.caption)
                                .accessibilityIdentifier("knowledge.rebuild.remove.edit." + edit.noteID)
                        }
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("До")).font(AppTypography.controlStrong)
                                if let before = preview.beforeEdits.first(where: { $0.noteID == edit.noteID }) {
                                    Text(before.title).font(AppTypography.controlStrong)
                                    ScrollView { Text(before.text).font(AppTypography.control).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                        .frame(height: 150)
                                }
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("После")).font(AppTypography.controlStrong)
                                TextField(L("Название"), text: editBinding(edit.noteID, \.title)).textFieldStyle(.roundedBorder)
                                TextEditor(text: editBinding(edit.noteID, \.text)).font(AppTypography.control).frame(height: 150)
                                    .accessibilityIdentifier("knowledge.rebuild.edit.text." + edit.noteID)
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        if let original = controller.sourceNotes[edit.noteID], !original.contentRTF.isEmpty, original.text != edit.text {
                            Text(L("При изменении текста форматирование этой заметки будет сброшено."))
                                .font(AppTypography.caption).foregroundStyle(.secondary)
                        }
                    }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8)).disabled(controller.busy)
                }
            }
            if !proposal.newNotes.isEmpty {
                Text(L("Новые заметки")).font(AppTypography.heading)
                ForEach(proposal.newNotes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField(L("Название"), text: newNoteBinding(note.key, \.title)).textFieldStyle(.roundedBorder)
                            Button(L("Убрать новую заметку")) { controller.removeNewNote(note.key) }
                                .buttonStyle(.borderless).font(AppTypography.caption)
                                .accessibilityIdentifier("knowledge.rebuild.remove.new." + note.key)
                        }
                        TextEditor(text: newNoteBinding(note.key, \.text)).font(AppTypography.control).frame(height: 130)
                            .accessibilityIdentifier("knowledge.rebuild.new.text." + note.key)
                        Text(LF("Источники: {0}", arguments: [note.sourceNoteIDs.map { sourceTitle($0) }.joined(separator: ", ")]))
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                        DisclosureGroup(L("Идентификаторы источников")) {
                            Text(note.sourceNoteIDs.joined(separator: "\n")).font(AppTypography.caption).textSelection(.enabled)
                        }.font(AppTypography.caption).foregroundStyle(.secondary)
                    }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8)).disabled(controller.busy)
                }
            }
            if !proposal.collections.isEmpty {
                Text(L("Подборки")).font(AppTypography.heading)
                ForEach(proposal.collections) { collection in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            TextField(L("Название подборки"), text: collectionBinding(collection.key)).textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("knowledge.rebuild.collection.name." + collection.key)
                            Button { controller.removeCollection(collection.key) } label: { Image(systemName:"xmark") }
                                .buttonStyle(.borderless).help(L("Убрать подборку из предложения"))
                                .accessibilityLabel(L("Убрать подборку из предложения"))
                                .accessibilityIdentifier("knowledge.rebuild.remove.collection." + collection.key)
                        }
                        ForEach(Array(collection.members.enumerated()), id: \.offset) { _, member in
                            Label(referenceTitle(member), systemImage: "note.text").font(AppTypography.caption)
                        }
                    }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8)).disabled(controller.busy)
                }
            }
            if !proposal.links.isEmpty {
                DisclosureGroup(LF("Связи между заметками: {0}", arguments: [String(proposal.links.count)])) {
                    ForEach(Array(proposal.links.enumerated()), id: \.offset) { index, link in
                        HStack {
                            Text(referenceTitle(link.from) + " → " + referenceTitle(link.to)).font(AppTypography.caption)
                            Spacer()
                            Button { controller.removeLink(index) } label: { Image(systemName:"xmark") }
                                .buttonStyle(.borderless).help(L("Убрать связь из предложения"))
                                .accessibilityLabel(L("Убрать связь из предложения"))
                                .accessibilityIdentifier("knowledge.rebuild.remove.link.\(index)")
                        }
                    }
                }.font(AppTypography.controlStrong).disabled(controller.busy)
            }
            if controller.reviewChanged {
                Text(L("Вы отредактировали предложение. Проверьте его ещё раз перед применением."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
            if !proposal.hasChanges { Text(L("Изменения не предложены. Уточните поручение и попробуйте ещё раз.")).font(AppTypography.control) }
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Отмена доступна, пока затронутые заметки, подборки и связи не изменились после применения."))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            if controller.historyLoading { ProgressView().controlSize(.small) }
            if let error = controller.historyError { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
            if controller.history.isEmpty && !controller.historyLoading { Text(L("Применений пока нет.")).foregroundStyle(.secondary) }
            ForEach(controller.history) { operation in
                VStack(alignment: .leading, spacing: 7) {
                    Text(operation.title).font(AppTypography.controlStrong)
                    Text(operation.summary).font(AppTypography.caption)
                    Text(KnowledgeMaterialPresentation.date(operation.appliedAt)).font(AppTypography.caption).foregroundStyle(.secondary)
                    if operation.undoneAt != nil { Text(L("Применение отменено.")).font(AppTypography.caption).foregroundStyle(.secondary) }
                    else {
                        Button(L("Отменить применение")) { controller.undo(operation) }.buttonStyle(.bordered)
                            .disabled(controller.busy || !operation.canUndo || workBlocked)
                            .accessibilityIdentifier("knowledge.rebuild.undo." + operation.operationID)
                        if !operation.canUndo {
                            Text(L("Отмена недоступна: затронутые материалы изменились или больше недоступны."))
                                .font(AppTypography.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private var footer: some View {
        HStack {
            Button(L("Закрыть")) {
                if controller.reviewChanged { discardConfirmation = true }
                else { controller.cancel(); dismiss() }
            }.keyboardShortcut(.cancelAction).disabled(controller.mutating)
            Spacer()
            if tab == "proposal" {
                if controller.phase == .select {
                    Button(L("Предложить изменения")) {
                        controller.generate(notes: candidates, folderID: app.folderSelection, provider: app.knowledgeRebuildProviderDescription)
                    }.buttonStyle(.borderedProminent).disabled(!canGenerate)
                        .accessibilityIdentifier("knowledge.rebuild.generate")
                } else {
                    Button(L("Новое поручение")) {
                        if controller.reviewChanged { restartConfirmation = true } else { controller.startOver() }
                    }.disabled(controller.busy)
                        .accessibilityIdentifier("knowledge.rebuild.restart")
                    if controller.phase == .review {
                        Button(controller.reviewChanged ? L("Проверить изменения") : L("Применить изменения")) {
                            if controller.reviewChanged { controller.validateEdits() } else { controller.apply() }
                        }.buttonStyle(.borderedProminent)
                            .disabled(controller.busy || workBlocked || unavailableSelection || controller.proposal?.hasChanges != true)
                            .accessibilityIdentifier(controller.reviewChanged ? "knowledge.rebuild.validate" : "knowledge.rebuild.apply")
                    }
                }
            }
        }
    }
    private func sourceTitle(_ id: String) -> String { controller.sourceNotes[id]?.displayTitle ?? id }
    private func referenceTitle(_ reference: KnowledgeRebuildReference) -> String {
        if let id = reference.noteID { return sourceTitle(id) }
        if let key = reference.draftKey, let note = controller.proposal?.newNotes.first(where: { $0.key == key }) {
            return LF("Новая заметка: {0}", arguments: [note.title])
        }
        return L("Недоступная заметка")
    }
    private func editBinding(_ id: String, _ path: WritableKeyPath<KnowledgeRebuildEdit, String>) -> Binding<String> {
        Binding(get: { controller.proposal?.edits.first { $0.noteID == id }?[keyPath: path] ?? "" }, set: { text in
            guard var proposal = controller.proposal, let index = proposal.edits.firstIndex(where: { $0.noteID == id }) else { return }
            proposal.edits[index][keyPath: path] = text; controller.proposal = proposal
        })
    }
    private func newNoteBinding(_ key: String, _ path: WritableKeyPath<KnowledgeRebuildNewNote, String>) -> Binding<String> {
        Binding(get: { controller.proposal?.newNotes.first { $0.key == key }?[keyPath: path] ?? "" }, set: { text in
            guard var proposal = controller.proposal, let index = proposal.newNotes.firstIndex(where: { $0.key == key }) else { return }
            proposal.newNotes[index][keyPath: path] = text; controller.proposal = proposal
        })
    }
    private func collectionBinding(_ key: String) -> Binding<String> {
        Binding(get: { controller.proposal?.collections.first { $0.key == key }?.name ?? "" }, set: { name in
            guard var proposal = controller.proposal, let index = proposal.collections.firstIndex(where: { $0.key == key }) else { return }
            proposal.collections[index].name = name; controller.proposal = proposal
        })
    }
}
