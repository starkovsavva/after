import AppKit
import PosleCore
import SwiftUI
import UniformTypeIdentifiers

private struct LibraryCard: Identifiable {
    let meeting: Meeting
    let card: Flashcard
    let review: ReviewState?
    let example: CardExample?
    var id: String { meeting.id + ":" + card.id }
}

/// One native review queue across the library. Scheduling remains in Rust FSRS.
struct CardsLibraryView: View {
    @EnvironmentObject private var app: AppStore
    @State private var entries: [LibraryCard] = []
    @State private var query = ""
    @State private var mode = "study"
    @State private var deck = ""
    @State private var picked: String?
    @State private var flipped = false
    @State private var loading = false
    @State private var generation = UUID()
    @State private var importURL: URL?
    @State private var showingImport = false
    @State private var exampleCardID: String?
    private var matching: [LibraryCard] {
        entries.filter { (deck.isEmpty || $0.meeting.id == deck) && (query.isEmpty || ($0.card.front + " " + $0.card.back + " " + $0.card.context).localizedCaseInsensitiveContains(query)) }
    }
    private var dueCount: Int { matching.filter { $0.review?.isDue ?? true }.count }
    private var visible: [LibraryCard] { mode == "study" ? matching.filter { $0.review?.isDue ?? true } : matching }
    private var current: LibraryCard? { visible.first { $0.id == picked } ?? visible.first }
    private var decks: [Meeting] { app.meetings.filter { meeting in entries.contains { $0.meeting.id == meeting.id } } }
    var body: some View {
        // Keep due-driven content and its controls in the same clock update.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Text("Карточки").font(AppTypography.pageTitle).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Импорт…") { chooseImport() }.buttonStyle(.bordered).disabled(app.busy)
                    Button("Экспорт…") { exportCards() }.buttonStyle(.bordered).disabled(matching.isEmpty)
                        .help("Сохранить карточки как TSV, совместимый с Anki")
                }
                HStack(spacing: 12) {
                    Picker("Режим", selection: $mode) { Text("Повторение").tag("study"); Text("Все карточки").tag("all") }
                        .pickerStyle(.segmented).tint(Ink.actionFill).labelsHidden().frame(width: 225)
                    Picker("Колода", selection: $deck) {
                        Text("Все колоды").tag("")
                        ForEach(decks) { Text($0.title).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 210)
                    TextField("Найти карточку", text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 140)
                }
            }.padding(.vertical, 20).frame(maxWidth: AppLayout.readableWidth, alignment: .leading)
                .padding(.horizontal, AppLayout.contentInset).frame(maxWidth: .infinity)
            Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(mode == "study" ? "\(dueCount) к повторению" : "Всего: \(matching.count)")
                                .font(AppTypography.caption).foregroundStyle(.secondary)
                            Spacer()
                            ProgressView().controlSize(.small).opacity(loading ? 1 : 0).frame(width: 16, height: 16)
                                .accessibilityHidden(!loading)
                        }
                        if let entry = current {
                            if mode == "all" {
                                Picker("Карточка", selection: Binding(get: { current?.id ?? "" }, set: { picked = $0; flipped = false })) {
                                    ForEach(visible) { Text($0.card.front).tag($0.id) }
                                }.labelsHidden()
                            }
                            StudyCardContent(card: entry.card, flipped: flipped, example: entry.example,
                                             makingExample: exampleCardID == entry.id,
                                             sourceMeetingID: entry.meeting.id, meetingTitle: entry.meeting.title,
                                             openMeeting: {
                                                 if entry.meeting.libraryKind == "cards" { deck = entry.meeting.id; mode = "all" }
                                                 else { app.openMeeting(entry.meeting.id, tab: "cards") }
                                             }, originIsDeck: entry.meeting.libraryKind == "cards") {
                                makeExample(entry)
                            }
                        } else { empty }
                    }.appContentLayout()
                }
            if let entry = current {
                StudyReviewBar(flipped: $flipped, enabled: !app.busy && !app.isRecording,
                               review: entry.review) { value in rate(entry, value: value) }
            }
        }.task { await reload() }
            .onChange(of: app.busy) { _, busy in if !busy { Task { await reload() } } }
            .onChange(of: mode) { _, _ in flipped = false; picked = nil }
            .onChange(of: deck) { _, _ in flipped = false; picked = nil }
            .onChange(of: query) { _, _ in flipped = false; picked = nil }
            .onChange(of: current?.id) { _, _ in
                flipped = ProcessInfo.processInfo.arguments.contains("--preview") && ProcessInfo.processInfo.arguments.contains("--preview-answer")
            }
            .sheet(isPresented: $showingImport) {
                if let url = importURL {
                    CardImportView(url: url) { meeting in
                        app.reloadLibrary(); deck = meeting.id; mode = "all"; showingImport = false
                        Task { await reload() }
                    }.environmentObject(app)
                }
            }
        }
    }
    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loading ? "Загружаю карточки…" : entries.isEmpty ? "Карточек пока нет" : !query.isEmpty ? "Ничего не найдено" : mode == "study" ? "На сегодня всё" : "В этой колоде нет карточек")
                .font(AppTypography.heading)
            if !loading {
                if entries.isEmpty {
                    Button("Импортировать карточки") { chooseImport() }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                } else if mode == "study" && query.isEmpty {
                    Button("Все карточки") { mode = "all" }.buttonStyle(.bordered)
                } else if !query.isEmpty {
                    Button("Очистить поиск") { query = "" }.buttonStyle(.bordered)
                }
            }
        }.frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading).padding(.vertical, 16)
    }
    private func reload() async {
        let token = UUID(); generation = token; loading = true
        let meetings = app.meetings, root = app.root
        let loaded = await Task.detached(priority: .userInitiated) {
            var result: [LibraryCard] = []
            guard let bridge = try? RustBridge.shared.get() else { return result }
            for meeting in meetings {
                let directory = root.appendingPathComponent("meetings/\(meeting.id)")
                guard let data = try? bridge.read(root: root, url: directory.appendingPathComponent("summary.json")), let summary = try? JSONDecoder().decode(Summary.self, from: data) else { continue }
                let reviews = (try? bridge.read(root: root, url: directory.appendingPathComponent("review-state.json"))).flatMap { try? JSONDecoder().decode([String: ReviewState].self, from: $0) } ?? [:]
                let examples = (try? bridge.read(root: root, url: directory.appendingPathComponent("examples.json"))).flatMap { try? JSONDecoder().decode([String: CardExample].self, from: $0) } ?? [:]
                result += summary.cards.map { LibraryCard(meeting: meeting, card: $0, review: reviews[$0.id], example: examples[$0.id]) }
            }
            return result
        }.value
        guard generation == token else { return }
        entries = loaded; loading = false
    }
    private func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.tabSeparatedText, .commaSeparatedText, .plainText]; panel.canChooseDirectories = false
        panel.message = "TSV или CSV: вопрос, ответ и необязательный контекст. Текстовый экспорт Anki поддерживается."
        if panel.runModal() == .OK, let url = panel.url { importURL = url; showingImport = true }
    }
    private func exportCards() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.tabSeparatedText]; panel.nameFieldStringValue = "После — карточки.tsv"
        if panel.runModal() == .OK, let url = panel.url {
            do { try Exporter.anki(cards: matching.map(\.card), title: "После").write(to: url, atomically: true, encoding: .utf8) }
            catch { app.error = error.localizedDescription }
        }
    }
    private func rate(_ entry: LibraryCard, value: Int) {
        guard flipped, current?.id == entry.id, !app.busy && !app.isRecording else { return }
        app.beginJob(id: entry.meeting.id); app.progressText = "Сохраняю повторение…"
        Task {
            defer { app.endJob() }
            do { try await app.worker("review", id: entry.meeting.id, extra: ["--card", entry.card.id, "--rating", String(value)]); app.refreshResults(entry.meeting.id); flipped = false; picked = nil }
            catch { app.error = error.localizedDescription }
        }
    }
    private func makeExample(_ entry: LibraryCard) {
        guard exampleCardID == nil, !app.busy && !app.isRecording else { return }
        exampleCardID = entry.id
        app.beginJob(id: entry.meeting.id); app.progressText = "Придумываю пример…"
        Task {
            defer { exampleCardID = nil; app.endJob() }
            do { try await app.worker("example", id: entry.meeting.id, extra: ["--card", entry.card.id]); app.refreshResults(entry.meeting.id) }
            catch { app.error = error.localizedDescription }
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
            Text("Импорт карточек").font(AppTypography.modalTitle)
            Text(url.lastPathComponent).font(AppTypography.control).foregroundStyle(.secondary)
            TextField("Название колоды", text: $title).textFieldStyle(.roundedBorder)
            Picker("Разделитель", selection: $separator) { Text("Автоматически").tag("auto"); Text("Табуляция").tag("tab"); Text("Запятая").tag("comma"); Text("Точка с запятой").tag("semicolon") }
            Text("Первые два столбца — вопрос и ответ. Столбец Context или «Контекст» добавляется отдельно. Карточки начнут повторяться как новые.").font(AppTypography.control).foregroundStyle(.secondary)
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).textSelection(.enabled) }
            if let preview {
                Text("Карточек: \(preview.total) · Пропущено: \(preview.skipped)").font(AppTypography.control).fontWeight(.medium)
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
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? "Импортирую…" : "Импортировать") { save() }.buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(loading || saving || preview?.cards.isEmpty != false || app.busy).keyboardShortcut(.defaultAction)
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
        Task {
            defer { saving = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let data = try RustBridge.shared.get().request(root: root, command: "cards-import", arguments: ["path": path, "separator": selected, "title": name, "expectedFingerprint": fingerprint])
                    return try JSONDecoder().decode(CardImportResult.self, from: data)
                }.value
                app.notice = "Импортировано карточек: \(result.count)"; imported(result.meeting)
            } catch { self.error = error.localizedDescription }
        }
    }
}
