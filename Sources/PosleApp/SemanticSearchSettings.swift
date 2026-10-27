import AppKit
import Combine
import CryptoKit
import PosleCore
import SwiftUI

struct SemanticSearchConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var provider = "ollama"
    var endpoint = "http://127.0.0.1:11434"
    var model = "qwen3-embedding:0.6b"
    var modelRevision = ""
    var dimensions = 1024
    var queryPrefix = "Instruct: Given a search query, retrieve relevant passages from personal notes, tasks, meetings and code.\nQuery: "
    var documentPrefix = ""
    var allowCloud = false
    var arguments: [String: Any] { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:] }
    var keyAccount: String? {
        guard var parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else { return nil }
        parts.host = host; parts.scheme = parts.scheme?.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        let hash = SHA256.hash(data: Data((parts.string ?? endpoint).utf8)).map { String(format: "%02x", $0) }.joined()
        return "semantic." + hash
    }
    var isLocal: Bool { URLComponents(string: endpoint)?.host.map { ["127.0.0.1", "localhost", "::1"].contains($0.lowercased()) } ?? false }
}

/// One low-priority batch at a time. SQLite checkpoints survive quit/restart;
/// canonical sources are reconciled before each batch, never copied into jobs.
@MainActor
final class SemanticIndexController: ObservableObject {
    static let shared = SemanticIndexController()
    @Published private(set) var running = false
    @Published private(set) var indexed = 0
    @Published private(set) var total = 0
    @Published private(set) var message = ""
    @Published private(set) var failed = false
    private weak var app: AppStore?
    private var subscriptions: Set<AnyCancellable> = []
    private var work: Task<Void, Never>?
    private var schedule: Task<Void, Never>?
    private var wantsRefresh = false
    private var connectedRoot: URL?
    struct Result: Decodable { var complete: Bool?; var indexed: Int?; var total: Int?; var warnings: [String]? }
    func connect(_ app: AppStore) {
        guard !app.isPreview, connectedRoot != app.root else { return }
        self.app = app; connectedRoot = app.root
        subscriptions.removeAll()
        app.notes.objectWillChange.debounce(for: .seconds(2), scheduler: RunLoop.main).sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .posleJobsChanged).sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
        requestRefresh()
    }
    func requestRefresh() {
        wantsRefresh = true
        guard work == nil else { return }
        schedule?.cancel()
        schedule = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            self.start()
        }
    }
    func stop() { schedule?.cancel(); work?.cancel(); wantsRefresh = false }
    private func start() {
        guard work == nil, let app, !app.isTerminating else { return }
        let root = app.root
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.running = false; self.work = nil }
            do {
                struct Settings: Decodable { var config: SemanticSearchConfiguration; var fingerprint: String }
                let settingsData = try await Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "semantic-config") }.value
                let snapshot = try JSONDecoder().decode(Settings.self, from: settingsData)
                let config = snapshot.config
                let fingerprint = snapshot.fingerprint
                guard config.enabled else { self.message = ""; self.wantsRefresh = false; return }
                let key = try config.keyAccount.map { try Keychain.readChecked(account: $0) } ?? ""
                self.running = true; self.failed = false
                repeat {
                    if app.isTerminating { throw CancellationError() }
                    try Task.checkCancellation()
                    self.wantsRefresh = false
                    while app.isRecording || app.startingRecording || app.stoppingRecording || app.busy || app.jobs.activeCount > 0 || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                        if app.isTerminating { throw CancellationError() }
                        self.message = "Продолжим после записи и обработки"
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    try Task.checkCancellation()
                    self.message = "Обновляем смысловой индекс…"
                    let data = try await Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "semantic-refresh", arguments: ["maxDocuments": 8, "apiKey": key, "configFingerprint": fingerprint]) }.value
                    let result = try JSONDecoder().decode(Result.self, from: data)
                    self.indexed = result.indexed ?? 0; self.total = result.total ?? 0
                    if let warning = result.warnings?.first { self.message = warning }
                    else { self.message = result.complete == true ? "Индекс обновлён: \(self.indexed) фрагментов" : "\(self.indexed) из \(self.total) фрагментов" }
                    if result.complete != true { self.wantsRefresh = true }
                    if self.wantsRefresh { try await Task.sleep(nanoseconds: 250_000_000) }
                } while self.wantsRefresh && !Task.isCancelled
            } catch is CancellationError { self.message = "Обновление индекса приостановлено" }
            catch { self.failed = true; self.message = error.localizedDescription }
        }
    }
}

struct SemanticSearchSettings: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject private var index = SemanticIndexController.shared
    @State private var config = SemanticSearchConfiguration()
    @State private var key = ""
    @State private var loadedKeyAccount: String?
    @State private var availableModels: [String] = []
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Смысловой поиск").font(AppTypography.sectionTitle)
            Toggle("Находить по смыслу", isOn: $config.enabled).accessibilityIdentifier("semantic.enabled")
            Text("Помогает вспомнить карточку или заметку другими словами, в том числе на другом языке. Тексты индексируются небольшими пакетами; запись и распознавание имеют приоритет.")
                .font(AppTypography.control).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Picker("Модель поиска", selection: Binding(get: { config.provider }, set: { provider in
                    config.provider = provider; config.endpoint = provider == "ollama" ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234/v1"; config.modelRevision = ""; loadKey()
                })) { Text("Ollama").tag("ollama"); Text("LM Studio / совместимый API").tag("openai") }
                LabeledContent("Адрес") { TextField("http://127.0.0.1:11434", text: $config.endpoint).textFieldStyle(.roundedBorder).accessibilityIdentifier("semantic.endpoint") }
                LabeledContent("Модель") { TextField("qwen3-embedding:0.6b", text: $config.model).textFieldStyle(.roundedBorder).accessibilityIdentifier("semantic.model") }
                HStack {
                    Button("Найти установленные модели") { discover() }.disabled(busy).accessibilityIdentifier("semantic.discover")
                    if !availableModels.isEmpty {
                        Menu("Выбрать модель") { ForEach(availableModels, id: \.self) { name in Button(name) { config.model = name; config.modelRevision = "" } } }
                    }
                }
                if !config.isLocal {
                    Toggle("Разрешить отправку текстов провайдеру поиска", isOn: $config.allowCloud).accessibilityIdentifier("semantic.cloud-consent")
                    Text("Это отдельное разрешение для embeddings. Календарь не сохраняется в индекс; для папок разрешение задаётся у каждого материала.").font(AppTypography.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Дополнительно") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Размерность") { TextField("1024", value: $config.dimensions, format: .number).frame(width: 100).textFieldStyle(.roundedBorder) }
                        LabeledContent("Версия модели") { TextField("Определяется при проверке", text: $config.modelRevision).textFieldStyle(.roundedBorder) }
                        Text("Для Ollama проверяется digest модели. Если заменили модель в LM Studio под тем же ID, проверьте подключение и измените версию перед перестройкой.").font(AppTypography.caption).foregroundStyle(.secondary)
                        LabeledContent("Префикс запроса") { TextField("Зависит от модели", text: $config.queryPrefix).textFieldStyle(.roundedBorder) }
                        LabeledContent("Префикс документа") { TextField("Зависит от модели", text: $config.documentPrefix).textFieldStyle(.roundedBorder) }
                        LabeledContent("Ключ, если нужен") { SecureField("Хранится в Связке ключей", text: $key).textFieldStyle(.roundedBorder).disabled(config.keyAccount == nil) }
                    }.padding(.top, 8)
                }
                HStack(spacing: 10) {
                    Button("Проверить и сохранить") { checkAndSave() }.disabled(busy).accessibilityIdentifier("semantic.check")
                    if config.provider == "ollama", config.isLocal, config.model == "qwen3-embedding:0.6b" {
                        Button("Скачать модель · 639 МБ") { download() }.disabled(busy).accessibilityIdentifier("semantic.download")
                    }
                }
            }
            if busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Подключаемся к модели…").font(AppTypography.caption).foregroundStyle(.secondary) } }
            if !message.isEmpty { Text(message).font(AppTypography.caption).foregroundStyle(failed ? Ink.warning : .secondary).textSelection(.enabled).accessibilityIdentifier("semantic.connection-status") }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(index.message.isEmpty ? "Индекс ещё не обновлён" : index.message).font(AppTypography.control).foregroundStyle(index.failed ? Ink.warning : .secondary).accessibilityIdentifier("semantic.index-status")
                    if index.running, index.total > 0 { ProgressView(value: Double(index.indexed), total: Double(max(index.total, 1))).frame(maxWidth: 300) }
                }
                Spacer()
                if index.running { Button("Приостановить") { index.stop() } }
                else { Button("Обновить индекс") { index.requestRefresh() }.disabled(!config.enabled || busy).accessibilityIdentifier("semantic.refresh") }
            }
            Text("Папки подключаются отдельно в материалах задачи. Файлы .env, ключи, скрытые файлы и исключения gitignore не индексируются; свои исключения добавьте в .posleignore.")
                .font(AppTypography.caption).foregroundStyle(.secondary)
        }
        .onAppear { index.connect(app); load() }
        .onChange(of: config.endpoint) { _, _ in config.modelRevision = ""; loadKey() }
        .onChange(of: config.model) { _, _ in config.modelRevision = "" }
        .onChange(of: config.enabled) { _, enabled in if !enabled { saveDisabled() } }
    }
    private func load() {
        do {
            struct Envelope: Decodable { var config: SemanticSearchConfiguration }
            config = try JSONDecoder().decode(Envelope.self, from: RustBridge.shared.get().request(root: app.root, command: "semantic-config")).config
            loadKey()
        } catch { failed = true; message = error.localizedDescription }
    }
    private func loadKey() {
        let next = config.keyAccount
        guard next != loadedKeyAccount else { return }
        loadedKeyAccount = next; key = next.map { Keychain.read(account: $0) } ?? ""
    }
    private func saveDisabled() {
        index.stop()
        do {
            struct Envelope: Decodable { var config: SemanticSearchConfiguration }
            var saved = try JSONDecoder().decode(Envelope.self, from: RustBridge.shared.get().request(root: app.root, command: "semantic-config")).config
            saved.enabled = false
            _ = try RustBridge.shared.get().request(root: app.root, command: "semantic-config", arguments: ["config": saved.arguments])
        } catch { failed = true; message = error.localizedDescription }
    }
    private func checkAndSave() {
        guard !busy else { return }; busy = true; failed = false; message = ""
        let root = app.root, draft = config, draftKey = key
        Task { @MainActor in
            defer { busy = false }
            do {
                if !draft.enabled {
                    _ = try RustBridge.shared.get().request(root: root, command: "semantic-config", arguments: ["config": draft.arguments]); message = "Настройки сохранены"; return
                }
                let result = try await Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "semantic-check", arguments: ["config": draft.arguments, "apiKey": draftKey]) }.value
                struct Checked: Decodable { var config: SemanticSearchConfiguration }
                let confirmed = try JSONDecoder().decode(Checked.self, from: result).config
                guard draft == config, draftKey == key, loadedKeyAccount == draft.keyAccount, config.enabled else { message = "Настройки изменились. Повторите проверку."; return }
                if let account = confirmed.keyAccount { try Keychain.save(draftKey, account: account) }
                _ = try RustBridge.shared.get().request(root: root, command: "semantic-config", arguments: ["config": confirmed.arguments]); config = confirmed
                message = "Модель подключена"; index.requestRefresh()
            } catch { failed = true; message = error.localizedDescription }
        }
    }
    private func discover() {
        guard !busy else { return }; busy = true; failed = false
        let root = app.root, draft = config, draftKey = key
        Task { @MainActor in
            defer { busy = false }
            do {
                let data = try await Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "semantic-models", arguments: ["config": draft.arguments, "apiKey": draftKey]) }.value
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                availableModels = ((result?["models"] as? [[String: Any]]) ?? []).compactMap { ($0["name"] ?? $0["id"]) as? String }.sorted()
                message = availableModels.isEmpty ? "Установленные модели не найдены" : "Выберите embedding-модель из списка"
            } catch { failed = true; message = error.localizedDescription }
        }
    }
    private func download() {
        guard !busy else { return }; busy = true; failed = false; message = "Скачиваем модель в Ollama…"
        let root = app.root, draft = config, draftKey = key
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "semantic-pull", arguments: ["config": draft.arguments, "apiKey": draftKey]) }.value
                message = "Модель скачана. Включите поиск и проверьте подключение."
            } catch { failed = true; message = error.localizedDescription }
        }
    }
}
