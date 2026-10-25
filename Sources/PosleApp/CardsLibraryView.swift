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
    private var matching: [LibraryCard] {
        entries.filter { (deck.isEmpty || $0.meeting.id == deck) && (query.isEmpty || ($0.card.front + " " + $0.card.back + " " + $0.card.context).localizedCaseInsensitiveContains(query)) }
    }
    private var visible: [LibraryCard] { mode == "study" ? matching.filter { $0.review?.isDue ?? true } : matching }
    private var current: LibraryCard? { visible.first { $0.id == picked } ?? visible.first }
    private var decks: [Meeting] { app.meetings.filter { meeting in entries.contains { $0.meeting.id == meeting.id } } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                AppPageHeader(title: "Карточки", subtitle: "Повторяйте фразы и понятия прямо в После.")
                Spacer()
                Button("Импорт…") { chooseImport() }.buttonStyle(.bordered).disabled(app.busy)
                Button("Экспорт…") { exportCards() }.buttonStyle(.bordered).disabled(matching.isEmpty)
            }.padding(.horizontal, AppLayout.contentInset).padding(.top, AppLayout.contentInset).padding(.bottom, 24)
            HStack(spacing: 12) {
                Picker("Режим", selection: $mode) { Text("Повторение").tag("study"); Text("Все карточки").tag("all") }.pickerStyle(.segmented).tint(Ink.actionFill).labelsHidden().frame(width: 245)
                Picker("Колода", selection: $deck) {
                    Text("Все встречи и колоды").tag("")
                    ForEach(decks) { Text($0.title).tag($0.id) }
                }.labelsHidden().frame(maxWidth: 240)
                TextField("Найти карточку", text: $query).textFieldStyle(.roundedBorder)
            }.padding(.horizontal, AppLayout.contentInset).padding(.bottom, 16)
            Divider()
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("К повторению: \(matching.filter { $0.review?.isDue ?? true }.count) · Всего: \(matching.count)").font(AppTypography.control).foregroundStyle(.secondary)
                            Spacer(); if loading { ProgressView().controlSize(.small) }
                        }
                        if let entry = current {
                            if mode == "all" {
                                Picker("Карточка", selection: Binding(get: { current?.id ?? "" }, set: { picked = $0; flipped = false })) {
                                    ForEach(visible) { Text($0.card.front).tag($0.id) }
                                }.labelsHidden()
                            }
                            study(entry)
                        } else {
                            VStack(spacing: 15) {
                                Image(systemName: entries.isEmpty ? "rectangle.on.rectangle.angled" : "checkmark.seal").font(.system(size: 38, weight: .light)).foregroundStyle(Ink.accent)
                                Text(entries.isEmpty ? "Здесь будут ваши карточки" : mode == "study" ? "Повторение завершено" : "Карточки не найдены")
                                    .font(AppTypography.emptyTitle)
                                Text(entries.isEmpty ? "Создайте конспект встречи или импортируйте TSV/CSV с вопросами и ответами." : mode == "study" ? "Следующий показ рассчитан по вашим ответам. Можно открыть все карточки." : "Попробуйте другой запрос или выберите другую колоду.")
                                    .font(AppTypography.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                                if entries.isEmpty { Button("Импортировать карточки") { chooseImport() }.buttonStyle(.borderedProminent).tint(Ink.actionFill) }
                                else if mode == "study" { Button("Все карточки") { mode = "all" }.buttonStyle(.bordered) }
                            }.frame(maxWidth: .infinity, minHeight: 330)
                        }
                    }.appContentLayout()
                }
            }
            if let entry = current {
                VStack(spacing: 7) {
                    HStack(spacing: 9) {
                        rating(entry, value: 1, title: "Снова", color: .red)
                        rating(entry, value: 2, title: "Трудно", color: .orange)
                        rating(entry, value: 3, title: "Хорошо", color: Ink.green)
                        rating(entry, value: 4, title: "Легко", color: Ink.accent)
                    }.disabled(!flipped)
                    Text(!flipped ? "Сначала покажите ответ, затем оцените его." : entry.review.map {
                        "Повторений: \($0.count) · Следующий показ: \(formattedDue($0.due))"
                    } ?? "Оцените, насколько легко удалось вспомнить ответ.")
                        .font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.horizontal, AppLayout.contentInset).frame(height: 82).background(Ink.paper)
                    .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
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
    private func study(_ entry: LibraryCard) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label(entry.card.kind == "phrase" ? "Фраза" : "Понятие", systemImage: "rectangle.on.rectangle.angled").foregroundStyle(Ink.accent)
                Spacer()
                Button(entry.meeting.title) { app.openMeeting(entry.meeting.id, tab: "cards") }.buttonStyle(.link).lineLimit(1)
            }.font(AppTypography.control)
            Text(entry.card.front).font(AppTypography.cardFront).textSelection(.enabled)
            if flipped {
                Divider()
                Text(entry.card.back).font(AppTypography.cardAnswer).lineSpacing(7).textSelection(.enabled)
                if !entry.card.context.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(entry.card.segmentIDs.isEmpty ? "Контекст карточки" : "Контекст из встречи").font(AppTypography.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let segment = entry.card.segmentIDs.first {
                                Button("Открыть источник") { app.openMeeting(entry.meeting.id, tab: "transcript", segmentID: segment) }.buttonStyle(.link)
                            }
                        }
                        Text(entry.card.context).font(AppTypography.body).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(16).background(Ink.soft, in: RoundedRectangle(cornerRadius: 10))
                }
                Button(entry.example == nil ? "Придумать пример" : "Придумать другой пример") { makeExample(entry) }
                    .buttonStyle(.bordered).disabled(app.busy || app.isRecording)
                if let example = entry.example {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Пример от ИИ", systemImage: "sparkles").font(AppTypography.caption).foregroundStyle(Ink.accent)
                        Text(example.example).font(AppTypography.bodyStrong).textSelection(.enabled)
                        Text(example.translation).font(AppTypography.body).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(example.explanation).font(AppTypography.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Ink.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                if app.settings.mode == "cloud" {
                    Text("Для примера OpenAI получит эту карточку с контекстом. Запрос оплачивается через API.").font(AppTypography.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Вспомните перевод или объяснение своими словами.").font(AppTypography.body).foregroundStyle(.secondary)
                Button("Показать ответ") { flipped = true }.buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.space, modifiers: [])
            }
        }.padding(28).frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
            .background(Ink.paper, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.line))
    }
    private func rating(_ entry: LibraryCard, value: Int, title: String, color: Color) -> some View {
        Button { rate(entry, value: value) } label: {
            HStack(spacing: 7) {
                Text(String(value)).font(AppTypography.control).monospacedDigit().foregroundStyle(.secondary)
                Text(title).font(AppTypography.controlStrong).foregroundStyle(.primary)
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.25)))
        }.buttonStyle(.plain).disabled(!flipped || app.busy || app.isRecording)
            .keyboardShortcut(KeyEquivalent(Character(String(value))), modifiers: [])
            .accessibilityLabel("\(title): \(ratingDescription(value))")
            .accessibilityHint("Запланировать следующее повторение. Клавиша \(value).")
            .help("\(ratingDescription(value)) · \(value)")
    }
    private func ratingDescription(_ value: Int) -> String {
        switch value {
        case 1: return "Не удалось вспомнить ответ"
        case 2: return "Вспомнил с трудом"
        case 3: return "Вспомнил правильно"
        default: return "Вспомнил без усилий"
        }
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
    private func formattedDue(_ value: String) -> String {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU")))
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
        guard !app.busy && !app.isRecording else { return }
        app.beginJob(id: entry.meeting.id); app.progressText = "Придумываю пример…"
        Task {
            defer { app.endJob() }
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
