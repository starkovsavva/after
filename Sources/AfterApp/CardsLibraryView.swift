import AfterPlatformMacOS
import AfterLocalization
import AppKit
import Combine
import AfterCore
import SwiftUI
import UniformTypeIdentifiers

struct CardsLibraryView: View { var body: some View { CardsWorkspaceView() } }

struct CardsWorkspaceView: View {
    @EnvironmentObject private var app: AppStore
    @StateObject private var workspace = CardsWorkspace()
    var meetingID: String? = nil
    var embedded = false
    @State private var query = ""
    @State private var mode = "study"
    @State private var deck = ""
    @State private var picked: String?
    @State private var flipped = false
    @State private var editor: CardEditorRequest?
    @State private var deleting: LibraryCardEntry?
    @State private var showingMeetings = false
    @State private var importURL: URL?
    @State private var showingImport = false
    private var scopedEntries: [LibraryCardEntry] {
        guard meetingID == nil, let folderID = app.folderSelection else { return workspace.entries }
        return workspace.entries.filter { app.folderID(for: $0.meeting.id) == folderID }
    }
    private var matching: [LibraryCardEntry] {
        scopedEntries.filter { entry in
            (deck.isEmpty || entry.meeting.id == deck) &&
            (query.isEmpty || (entry.card.front + " " + entry.card.back + " " + entry.card.context + " " + entry.meeting.title).localizedCaseInsensitiveContains(query))
        }
    }
    private var visible: [LibraryCardEntry] { mode == "study" ? matching.filter(\.isDue) : matching }
    private var current: LibraryCardEntry? { visible.first { $0.id == picked } ?? visible.first }
    private var scopeMeeting: Meeting? { app.meetings.first { $0.id == meetingID } }
    private var decks: [Meeting] { app.meetings.filter { meeting in scopedEntries.contains { $0.meeting.id == meeting.id } } }
    private var hasContent: Bool { !scopedEntries.isEmpty }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 0) {
                header
                Divider()
                if let error = workspace.error { problem(error) }
                if !workspace.errors.isEmpty { problem(L("Не удалось загрузить часть карточек. ") + workspace.errors.joined(separator: "\n")) }
                if workspace.loading && !hasContent { ProgressView(L("Загружаю карточки…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if mode == "all" && !visible.isEmpty { browser }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let entry = current { cardDetail(entry, showingAnswer: flipped) }
                            else { empty }
                        }.appContentLayout()
                    }
                }
                if mode == "study", let entry = current {
                    StudyReviewBar(flipped: $flipped, enabled: !workspace.saving && !entry.suspended, review: entry.review, rate: { value in
                        Task { await workspace.rate(root: app.root, entry: entry, rating: value, meetingID: meetingID); flipped = false; picked = nil; app.refreshResults(entry.meeting.id) }
                    }, intervals: workspace.options)
                }
            }
            .task(id: current.map { $0.id + $0.fingerprint + $0.reviewFingerprint }) { await workspace.preview(root: app.root, entry: current) }
            .onChange(of: current?.id) { _, _ in flipped = previewAnswer }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .posleJobsChanged)) { _ in Task { await reload() } }
        .onChange(of: app.folderSelection) { _, _ in
            if !decks.contains(where: { $0.id == deck }) { deck = "" }
            picked = nil; flipped = false
        }
        .onChange(of: mode) { _, _ in flipped = previewAnswer; picked = nil }
        .onChange(of: deck) { _, _ in flipped = false; picked = nil; app.assistantCardMeetingID = meetingID ?? (deck.isEmpty ? nil : deck) }
        .onChange(of: query) { _, _ in flipped = false; picked = nil }
        .onChange(of: app.navigationTarget?.id) { _, _ in revealTarget() }
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--preview-all") { mode = "all" }; revealTarget(); app.assistantCardMeetingID = meetingID ?? (deck.isEmpty ? nil : deck) }
        .onDisappear { app.assistantCardMeetingID = nil }
        .sheet(item: $editor) { request in
            CardEditorView(request: request) { result in
                app.reloadLibrary(); if !embedded { deck = result.meeting.id }; mode = "all"; picked = result.meeting.id + ":" + result.card.id
                Task { await reload() }
            }.environmentObject(app)
        }
        .sheet(isPresented: $showingImport) {
            if let url = importURL {
                CardImportView(url: url) { meeting in
                    app.reloadLibrary(); if !embedded { deck = meeting.id }; mode = "all"; showingImport = false; Task { await reload() }
                }.environmentObject(app)
            }
        }
        .sheet(isPresented: $showingMeetings) { meetingPicker }
        .alert(L("Переместить карточку в Корзину?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("Отмена"), role: .cancel) { deleting = nil }
            Button(L("В Корзину"), role: .destructive) {
                if let entry = deleting { Task { await workspace.mutate(root: app.root, entry: entry, delete: true, meetingID: meetingID); app.refreshResults(entry.meeting.id) } }; deleting = nil
            }
        } message: { Text(L("Карточку можно будет восстановить в течение 30 дней.")) }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if !embedded { Text(L("Карточки")).font(AppTypography.pageTitle).accessibilityAddTraits(.isHeader) }
                if hasContent {
                    AppTabBar(label: L("Режим"), selection: $mode,
                              tabs: [AppTab(L("Повторение"), value: "study"), AppTab(L("Все карточки"), value: "all")],
                              identifier: "cards.mode")
                }
                Spacer(minLength: 8)
                if workspace.canUndo && (app.folderSelection == nil || workspace.lastReviewMeetingID.flatMap { app.folderID(for: $0) } == app.folderSelection) {
                    Button { Task { await workspace.undo(root: app.root, meetingID: meetingID); flipped = false } } label: { Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help(L("Отменить последнюю оценку")).accessibilityLabel(L("Отменить последнюю оценку")).disabled(workspace.saving)
                }
                if hasContent {
                    Button { editor = CardEditorRequest(meeting: scopeMeeting) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help(L("Новая карточка")).accessibilityLabel(L("Новая карточка"))
                }
                Menu {
                    if !embedded { Button(L("Импортировать TSV или CSV…")) { chooseImport() } }
                    Button(L("Экспортировать TSV…")) { exportCards() }.disabled(matching.isEmpty)
                    if !embedded { Button(L("Взять из встречи…")) { showingMeetings = true } }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).frame(width: 28).accessibilityLabel(L("Действия с карточками"))
            }
            if hasContent {
                HStack(spacing: 12) {
                    if !embedded && decks.count > 1 {
                        Picker(L("Колода"), selection: $deck) { Text(L("Все колоды")).tag(""); ForEach(decks) { Text($0.title).tag($0.id) } }.labelsHidden().frame(maxWidth: 210, alignment: .leading)
                    }
                    TextField(L("Найти карточку"), text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 120, maxWidth: 320)
                    Spacer()
                    Text(mode == "study" ? LF("{0} к повторению", arguments: [String(describing: (visible.count))]) : LF("Всего: {0}", arguments: [String(describing: (matching.count))])).font(AppTypography.caption).foregroundStyle(.secondary)
                    if workspace.loading || workspace.saving { ProgressView().controlSize(.small) }
                }
            }
        }.padding(.horizontal, AppLayout.contentInset).padding(.vertical, embedded ? 12 : 20)
    }
    private var browser: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { current?.id }, set: { picked = $0; flipped = false })) {
                ForEach(visible) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.card.front).font(AppTypography.bodyStrong).lineLimit(2)
                            if entry.suspended { Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityLabel(L("Не повторяется")) }
                        }
                        Text(entry.card.back).font(AppTypography.control).foregroundStyle(.secondary).lineLimit(2)
                        if !embedded { Text(entry.meeting.title).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.padding(.vertical, 6).tag(entry.id)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(Ink.paper).frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
            Divider()
            ScrollView {
                if let entry = current { cardDetail(entry, showingAnswer: true).appContentLayout() }
            }.frame(maxWidth: .infinity)
        }
    }
    private func cardDetail(_ entry: LibraryCardEntry, showingAnswer: Bool) -> some View {
        StudyCardContent(card: entry.card, flipped: showingAnswer, example: entry.example,
            makingExample: app.jobs.contains(objectID: entry.meeting.id, kinds: ["example"]), sourceMeetingID: entry.meeting.id,
            meetingTitle: embedded ? nil : entry.meeting.title, openMeeting: {
                if entry.meeting.libraryKind == "cards" { deck = entry.meeting.id; mode = "all" }
                else { app.openMeeting(entry.meeting.id, tab: "cards") }
            }, originIsDeck: entry.meeting.libraryKind == "cards", exampleIsStale: entry.exampleIsStale, sourceStale: entry.sourceStale, showSourceHint: mode == "study",
            actions: cardActions(entry)) { app.enqueueExample(entry.card, meetingID: entry.meeting.id) }
    }
    private func cardActions(_ entry: LibraryCardEntry) -> CardActionsView {
        CardActionsView(paused: entry.suspended, disabled: workspace.saving,
            edit: { editor = CardEditorRequest(entry: entry) },
            togglePause: { Task { await workspace.mutate(root: app.root, entry: entry, delete: false, meetingID: meetingID); app.refreshResults(entry.meeting.id) } },
            delete: { deleting = entry })
    }
    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            if workspace.error != nil || !workspace.errors.isEmpty {
                Text(hasContent ? L("Нет доступных карточек") : L("Не удалось загрузить карточки")).font(AppTypography.heading)
                Button(L("Повторить загрузку")) { Task { await reload() } }.buttonStyle(.bordered)
            } else if !hasContent {
                Text(L("Карточек пока нет")).font(AppTypography.heading)
                if embedded, scopeMeeting?.libraryKind != "cards" {
                    Text(scopeMeeting.map { app.generatesCards(for: $0) } == true
                         ? L("Создайте карточку вручную или обновите конспект: генерация для этой встречи включена.")
                         : L("Создайте карточку вручную. Для генерации откройте меню встречи → «Автосоздание карточек»."))
                        .font(AppTypography.body).foregroundStyle(.secondary)
                } else {
                    Text(L("Сохраняйте фразы и понятия из встреч и повторяйте их здесь.")).font(AppTypography.body).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button(L("Создать карточку")) { editor = CardEditorRequest(meeting: scopeMeeting) }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    Button(embedded ? L("Открыть конспект") : L("Взять из встречи…")) {
                        if embedded { app.tab = "summary" } else { showingMeetings = true }
                    }.buttonStyle(.bordered)
                }
                if !embedded {
                    Button(L("Импортировать…")) { chooseImport() }.buttonStyle(.plain).font(AppTypography.control).foregroundStyle(.secondary)
                }
            } else if !query.isEmpty {
                Text(L("Ничего не найдено")).font(AppTypography.heading)
                Button(L("Очистить поиск")) { query = "" }.buttonStyle(.bordered)
            } else if mode == "study" {
                Text(L("На сегодня всё")).font(AppTypography.heading)
                Text(matching.allSatisfy(\.suspended) ? L("Эти карточки исключены из повторения.") : L("Можно посмотреть все карточки или вернуться позже.")).font(AppTypography.body).foregroundStyle(.secondary)
                Button(L("Все карточки")) { mode = "all" }.buttonStyle(.bordered)
            } else {
                Text(L("В этой колоде нет карточек")).font(AppTypography.heading)
                Button(L("Все колоды")) { deck = "" }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading).padding(.vertical, 30)
    }
    private var meetingPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L("Карточки из встречи")).font(AppTypography.modalTitle); Spacer(); Button(L("Готово")) { showingMeetings = false }.keyboardShortcut(.cancelAction) }
            Text(L("Выберите встречу. Создание карточек включается в контексте её конспекта.")).font(AppTypography.body).foregroundStyle(.secondary)
            List(app.filteredMeetings) { meeting in
                Button {
                    showingMeetings = false; app.openMeeting(meeting.id, tab: "summary")
                } label: {
                    HStack { Text(meeting.title).font(AppTypography.body); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.frame(height: 260)
            if app.filteredMeetings.isEmpty {
                Button(L("Открыть встречи")) { showingMeetings = false; app.librarySection = "meetings" }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
            }
        }.padding(24).frame(width: 540).appControlDefaults()
    }
    private func problem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Ink.warning)
            Text(text).font(AppTypography.control).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer()
            Button(L("Повторить")) { Task { await reload() } }.buttonStyle(.bordered).disabled(workspace.loading)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Ink.warning.opacity(0.07))
    }
    private func reload() async { await workspace.reload(root: app.root, meetingID: meetingID); revealTarget() }
    private func revealTarget() {
        guard let target = app.navigationTarget, target.kind == "card", let cardID = target.cardID,
              workspace.entries.contains(where: { $0.meeting.id == target.meetingID && $0.card.id == cardID }) else { return }
        mode = "all"; picked = target.meetingID + ":" + cardID
    }
    private var previewAnswer: Bool { ProcessInfo.processInfo.arguments.contains("--preview") && ProcessInfo.processInfo.arguments.contains("--preview-answer") }
    private func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.tabSeparatedText, .commaSeparatedText, .plainText]; panel.canChooseDirectories = false
        panel.message = L("TSV или CSV: вопрос, ответ и необязательный контекст. Текстовый экспорт Anki поддерживается.")
        if panel.runModal() == .OK, let url = panel.url { importURL = url; showingImport = true }
    }
    private func exportCards() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.tabSeparatedText]; panel.nameFieldStringValue = L("After — карточки.tsv")
        if panel.runModal() == .OK, let url = panel.url {
            do { try Exporter.anki(cards: matching.map(\.card), title: L("After")).write(to: url, atomically: true, encoding: .utf8) }
            catch { workspace.error = error.localizedDescription }
        }
    }
}

private struct CardImportPreview: Decodable { var cards: [Flashcard]; var warnings: [String]; var total: Int; var skipped: Int; var sourceFingerprint: String }
private struct CardImportResult: Decodable { var meeting: Meeting; var count: Int; var skipped: Int; var warnings: [String] }
private struct CardImportView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let imported: (Meeting) -> Void
    @State private var separator = "auto"
    @State private var title = ""
    @State private var preview: CardImportPreview?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Импорт карточек")).font(AppTypography.modalTitle)
            if let folder = app.notes.folder(app.folderSelection) {
                Label(folder.name, systemImage: "folder").font(AppTypography.caption).foregroundStyle(.secondary)
            }
            Text(url.lastPathComponent).font(AppTypography.control).foregroundStyle(.secondary)
            TextField(L("Название колоды"), text: $title).textFieldStyle(.roundedBorder)
            Picker(L("Разделитель"), selection: $separator) { Text(L("Автоматически")).tag("auto"); Text(L("Табуляция")).tag("tab"); Text(L("Запятая")).tag("comma"); Text(L("Точка с запятой")).tag("semicolon") }
            Text(L("Первые два столбца — вопрос и ответ. Столбец Context или «Контекст» добавляется отдельно. Карточки начнут повторяться как новые.")).font(AppTypography.control).foregroundStyle(.secondary)
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).textSelection(.enabled) }
            if let preview {
                Text(LF("Карточек: {0} · Пропущено: {1}", arguments: [String(describing: (preview.total)), String(describing: (preview.skipped))])).font(AppTypography.control).fontWeight(.medium)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(preview.cards.prefix(6))) { card in
                            VStack(alignment: .leading, spacing: 7) { Text(card.front).fontWeight(.medium); Text(card.back).foregroundStyle(.secondary) }.font(AppTypography.body).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                        }
                        ForEach(preview.warnings, id: \.self) { Text($0).font(AppTypography.caption).foregroundStyle(Ink.warning) }
                    }
                }.frame(minHeight: 160, maxHeight: 310)
            }
            HStack {
                Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? L("Импортирую…") : L("Импортировать")) { save() }.buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(loading || saving || preview?.cards.isEmpty != false || app.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 650).task(id: separator) { await loadPreview() }
            .onAppear { title = url.deletingPathExtension().lastPathComponent }
    }
    private func loadPreview() async {
        loading = true; preview = nil; error = nil
        let root = app.root, path = url.path, selected = separator
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                let data = try RustBridge.shared.get().request(root: root, command: "cards-import-preview", arguments: ["path": path, "separator": selected])
                return try JSONDecoder().decode(CardImportPreview.self, from: data)
            }.value
            guard !Task.isCancelled && separator == selected else { return }
            preview = value; loading = false
        } catch { guard !Task.isCancelled && separator == selected else { return }; self.error = error.localizedDescription; loading = false }
    }
    private func save() {
        saving = true; error = nil
        let root = app.root, path = url.path, selected = separator, name = title, fingerprint = preview?.sourceFingerprint ?? ""
        let folderID = app.folderSelection
        Task {
            defer { saving = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    var arguments: [String: Any] = ["path": path, "separator": selected, "title": name, "expectedFingerprint": fingerprint]
                    if let folderID { arguments["folderID"] = folderID }
                    let data = try RustBridge.shared.get().request(root: root, command: "cards-import", arguments: arguments)
                    return try JSONDecoder().decode(CardImportResult.self, from: data)
                }.value
                app.notice = LF("Импортировано карточек: {0}", arguments: [String(describing: (result.count))]); imported(result.meeting)
            } catch { self.error = error.localizedDescription }
        }
    }
}
