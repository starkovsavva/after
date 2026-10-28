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
    private var generation = UUID()
    struct Result: Decodable { var complete: Bool?; var indexed: Int?; var total: Int?; var warnings: [String]? }
    func connect(_ app: AppStore) {
        guard app.availableFeatures.semanticSearch, !app.isPreview else { return }
        if self.app === app && connectedRoot == app.root { requestRefresh(); return }
        // A previous blocking FFI call must drain before a different library can
        // start a provider request. Its result no longer owns this controller.
        generation = UUID(); schedule?.cancel(); schedule = nil; work?.cancel()
        self.app = app; connectedRoot = app.root
        indexed = 0; total = 0; message = ""; failed = false
        subscriptions.removeAll()
        app.notes.objectWillChange.debounce(for: .seconds(2), scheduler: RunLoop.main).sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .posleJobsChanged).sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in self?.requestRefresh() }.store(in: &subscriptions)
        requestRefresh()
    }
    func requestRefresh() {
        guard let app, app.availableFeatures.semanticSearch, !app.isTerminating else { return }
        wantsRefresh = true
        guard work == nil else { return }
        schedule?.cancel()
        let current = generation, root = app.root
        schedule = Task { [weak self, weak app] in
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            guard !Task.isCancelled, let self, let app, self.isCurrent(app, root: root, generation: current) else { return }
            self.start()
        }
    }
    func stop() {
        generation = UUID(); schedule?.cancel(); schedule = nil; work?.cancel(); wantsRefresh = false
        subscriptions.removeAll(); connectedRoot = nil; app = nil
    }
    private func isCurrent(_ app: AppStore, root: URL, generation: UUID) -> Bool {
        self.generation == generation && self.app === app && connectedRoot == root
            && app.root == root && app.availableFeatures.semanticSearch && !app.isTerminating
    }
    private func start() {
        guard work == nil, let app, app.availableFeatures.semanticSearch, !app.isTerminating else { return }
        let root = app.root, current = generation
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.running = false; self.work = nil
                // stop→connect may occur while blocking FFI is draining. Resume
                // the new owner's requested work after the old call has ended.
                if self.wantsRefresh { self.requestRefresh() }
            }
            do {
                guard self.isCurrent(app, root: root, generation: current) else { throw CancellationError() }
                try Task.checkCancellation()
                struct Settings: Decodable { var config: SemanticSearchConfiguration; var fingerprint: String }
                let settingsData = try await Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "semantic-config") }.value
                guard self.isCurrent(app, root: root, generation: current) else { throw CancellationError() }
                try Task.checkCancellation()
                let snapshot = try JSONDecoder().decode(Settings.self, from: settingsData)
                let config = snapshot.config
                let fingerprint = snapshot.fingerprint
                guard config.enabled else { self.message = ""; self.wantsRefresh = false; return }
                let key = try config.keyAccount.map { try Keychain.readChecked(account: $0) } ?? ""
                self.running = true; self.failed = false
                repeat {
                    guard self.isCurrent(app, root: root, generation: current) else { throw CancellationError() }
                    try Task.checkCancellation()
                    self.wantsRefresh = false
                    while app.isRecording || app.startingRecording || app.stoppingRecording || app.busy || app.jobs.activeCount > 0 || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                        guard self.isCurrent(app, root: root, generation: current) else { throw CancellationError() }
                        self.message = L("Продолжим после записи и обработки")
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    try Task.checkCancellation()
                    guard self.isCurrent(app, root: root, generation: current) else { throw CancellationError() }
                    self.message = L("Обновляем смысловой индекс…")
                    let data = try await Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "semantic-refresh", arguments: ["maxDocuments": 8, "apiKey": key, "configFingerprint": fingerprint]) }.value
                    guard self.isCurrent(app, root: root, generation: current) else { throw CancellationError() }
                    try Task.checkCancellation()
                    let result = try JSONDecoder().decode(Result.self, from: data)
                    self.indexed = result.indexed ?? 0; self.total = result.total ?? 0
                    if let warning = result.warnings?.first { self.message = warning }
                    else { self.message = result.complete == true ? LF("Индекс обновлён: {0} фрагментов", arguments: [String(describing: (self.indexed))]) : LF("{0} из {1} фрагментов", arguments: [String(describing: (self.indexed)), String(describing: (self.total))]) }
                    if result.complete != true { self.wantsRefresh = true }
                    if self.wantsRefresh { try await Task.sleep(nanoseconds: 250_000_000) }
                } while self.wantsRefresh && !Task.isCancelled
            } catch is CancellationError {
                if self.isCurrent(app, root: root, generation: current) { self.message = L("Обновление индекса приостановлено") }
            } catch {
                if self.isCurrent(app, root: root, generation: current) { self.failed = true; self.message = error.localizedDescription }
            }
        }
    }
}

struct SemanticSearchSettings: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject private var index = SemanticIndexController.shared
    @State private var editorID = UUID()
    @State private var mounted = false
    @State private var lifecycleID = UUID()
    @State private var config = SemanticSearchConfiguration()
    @State private var savedConfig = SemanticSearchConfiguration()
    @State private var draftKeys: [String: String] = [:]
    @State private var savedKeys: [String: String] = [:]
    @State private var loadedAccounts: Set<String> = []
    @State private var loadedKeyAccount: String?
    private var key: String { config.keyAccount.flatMap { draftKeys[$0] } ?? "" }
    private var keyBinding: Binding<String> {
        Binding(get: { key }, set: { value in
            if let account = config.keyAccount { draftKeys[account] = value; registerDrafts() }
        })
    }
    private var endpointBinding: Binding<String> {
        Binding(get: { config.endpoint }, set: { value in
            config.endpoint = value; config.modelRevision = ""; loadKey(); registerDrafts()
        })
    }
    private var modelBinding: Binding<String> {
        Binding(get: { config.model }, set: { value in config.model = value; config.modelRevision = ""; registerDrafts() })
    }
    private var enabledBinding: Binding<Bool> {
        Binding(get: { config.enabled }, set: { enabled in
            config.enabled = enabled
            if !enabled && savedConfig.enabled { saveDisabled() }
            registerDrafts()
        })
    }
    private var hasUnsaved: Bool {
        config != savedConfig || draftKeys.contains { account, value in value != (savedKeys[account] ?? "") }
    }
    private func registerDrafts() {
        guard mounted else { return }
        SettingsDraftRegistry.set(id: editorID, title: L("Настройки смыслового поиска"), dirty: hasUnsaved, busy: busy)
    }
    private func cancelChanges() {
        config = savedConfig; draftKeys = savedKeys; loadKey()
        message = ""; failed = false; registerDrafts()
    }
    @State private var availableModels: [String] = []
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("Смысловой поиск")).font(AppTypography.sectionTitle)
            Toggle(L("Находить по смыслу"), isOn: enabledBinding).accessibilityIdentifier("semantic.enabled")
            Text(L("Помогает вспомнить карточку или заметку другими словами, в том числе на другом языке. Тексты индексируются небольшими пакетами; запись и распознавание имеют приоритет."))
                .font(AppTypography.control).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Picker(L("Модель поиска"), selection: Binding(get: { config.provider }, set: { provider in
                    config.provider = provider; config.endpoint = provider == "ollama" ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234/v1"; config.modelRevision = ""; loadKey()
                })) { Text("Ollama").tag("ollama"); Text(L("LM Studio / совместимый API")).tag("openai") }
                LabeledContent(L("Адрес")) { TextField("http://127.0.0.1:11434", text: endpointBinding).textFieldStyle(.roundedBorder).accessibilityIdentifier("semantic.endpoint") }
                LabeledContent(L("Модель")) { TextField("qwen3-embedding:0.6b", text: modelBinding).textFieldStyle(.roundedBorder).accessibilityIdentifier("semantic.model") }
                HStack {
                    Button(L("Найти установленные модели")) { discover() }.disabled(busy).accessibilityIdentifier("semantic.discover")
                    if !availableModels.isEmpty {
                        Menu(L("Выбрать модель")) { ForEach(availableModels, id: \.self) { name in Button(name) { config.model = name; config.modelRevision = "" } } }
                    }
                }
                if !config.isLocal {
                    Toggle(L("Разрешить отправку текстов провайдеру поиска"), isOn: $config.allowCloud).accessibilityIdentifier("semantic.cloud-consent")
                    Text(L("Это отдельное разрешение для embeddings. Календарь не сохраняется в индекс; для папок разрешение задаётся у каждого материала.")).font(AppTypography.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(L("Дополнительно")) {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent(L("Размерность")) { TextField("1024", value: $config.dimensions, format: .number).frame(width: 100).textFieldStyle(.roundedBorder) }
                        LabeledContent(L("Версия модели")) { TextField(L("Определяется при проверке"), text: $config.modelRevision).textFieldStyle(.roundedBorder) }
                        Text(L("Для Ollama проверяется digest модели. Если заменили модель в LM Studio под тем же ID, проверьте подключение и измените версию перед перестройкой.")).font(AppTypography.caption).foregroundStyle(.secondary)
                        LabeledContent(L("Префикс запроса")) { TextField(L("Зависит от модели"), text: $config.queryPrefix).textFieldStyle(.roundedBorder) }
                        LabeledContent(L("Префикс документа")) { TextField(L("Зависит от модели"), text: $config.documentPrefix).textFieldStyle(.roundedBorder) }
                        LabeledContent(L("Ключ, если нужен")) { SecureField(L("Хранится в Связке ключей"), text: keyBinding).textFieldStyle(.roundedBorder).disabled(config.keyAccount == nil).accessibilityIdentifier("semantic.key") }
                    }.padding(.top, 8)
                }
                HStack(spacing: 10) {
                    Button(L("Проверить и сохранить")) { checkAndSave() }.disabled(busy).accessibilityIdentifier("semantic.check")
                    if hasUnsaved {
                        Button(L("Отменить изменения")) { cancelChanges() }.disabled(busy).accessibilityIdentifier("semantic.cancel")
                    }
                    if config.provider == "ollama", config.isLocal, config.model == "qwen3-embedding:0.6b" {
                        Button(L("Скачать модель · 639 МБ")) { download() }.disabled(busy).accessibilityIdentifier("semantic.download")
                    }
                }
            }
            if busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("Подключаемся к модели…")).font(AppTypography.caption).foregroundStyle(.secondary) } }
            if !message.isEmpty { Text(message).font(AppTypography.caption).foregroundStyle(failed ? Ink.warning : .secondary).textSelection(.enabled).accessibilityIdentifier("semantic.connection-status") }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(index.message.isEmpty ? L("Индекс ещё не обновлён") : index.message).font(AppTypography.control).foregroundStyle(index.failed ? Ink.warning : .secondary).accessibilityIdentifier("semantic.index-status")
                    if index.running, index.total > 0 { ProgressView(value: Double(index.indexed), total: Double(max(index.total, 1))).frame(maxWidth: 300) }
                }
                Spacer()
                if index.running { Button(L("Приостановить")) { index.stop() } }
                else { Button(L("Обновить индекс")) { index.requestRefresh() }.disabled(!config.enabled || busy).accessibilityIdentifier("semantic.refresh") }
            }
            Text(L("Папки подключаются отдельно в материалах задачи. Файлы .env, ключи, скрытые файлы и исключения gitignore не индексируются; свои исключения добавьте в .posleignore."))
                .font(AppTypography.caption).foregroundStyle(.secondary)
        }
        .onAppear { mounted = true; lifecycleID = UUID(); index.connect(app); load(); registerDrafts() }
        .onChange(of: config) { _, _ in registerDrafts() }
        .onChange(of: draftKeys) { _, _ in registerDrafts() }
        .onChange(of: savedKeys) { _, _ in registerDrafts() }
        .onChange(of: busy) { _, _ in registerDrafts() }
        .onDisappear { mounted = false; lifecycleID = UUID(); SettingsDraftRegistry.remove(id: editorID) }
    }
    private func load() {
        do {
            struct Envelope: Decodable { var config: SemanticSearchConfiguration }
            let saved = try JSONDecoder().decode(Envelope.self, from: RustBridge.shared.get().request(root: app.root, command: "semantic-config")).config
            savedConfig = saved; config = saved; loadKey(); registerDrafts()
        } catch { failed = true; message = error.localizedDescription }
    }
    private func loadKey() {
        let next = config.keyAccount
        loadedKeyAccount = next
        guard let next, !loadedAccounts.contains(next) else { return }
        let value = app.isPreview ? "" : Keychain.read(account: next)
        draftKeys[next] = value; savedKeys[next] = value; loadedAccounts.insert(next)
        registerDrafts()
    }
    private func saveDisabled() {
        index.stop()
        do {
            struct Envelope: Decodable { var config: SemanticSearchConfiguration }
            var saved = try JSONDecoder().decode(Envelope.self, from: RustBridge.shared.get().request(root: app.root, command: "semantic-config")).config
            saved.enabled = false
            _ = try RustBridge.shared.get().request(root: app.root, command: "semantic-config", arguments: ["config": saved.arguments])
            savedConfig = saved; registerDrafts()
        } catch { failed = true; message = error.localizedDescription }
    }
    private func checkAndSave() {
        guard !busy else { return }; busy = true; registerDrafts(); failed = false; message = ""
        let root = app.root, draft = config, draftKey = key, generation = lifecycleID
        Task { @MainActor in
            defer { if mounted && lifecycleID == generation { busy = false; registerDrafts() } }
            guard mounted && lifecycleID == generation else { return }
            do {
                if !draft.enabled {
                    if let account = draft.keyAccount, draftKey != (savedKeys[account] ?? ""), !app.isPreview { try Keychain.save(draftKey, account: account) }
                    _ = try RustBridge.shared.get().request(root: root, command: "semantic-config", arguments: ["config": draft.arguments])
                    savedConfig = draft
                    if let account = draft.keyAccount { savedKeys[account] = draftKey }
                    registerDrafts(); message = L("Настройки сохранены"); return
                }
                let result = try await Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "semantic-check", arguments: ["config": draft.arguments, "apiKey": draftKey]) }.value
                guard mounted && lifecycleID == generation else { return }
                struct Checked: Decodable { var config: SemanticSearchConfiguration }
                let confirmed = try JSONDecoder().decode(Checked.self, from: result).config
                guard draft == config, draftKey == key, loadedKeyAccount == draft.keyAccount, config.enabled else { message = L("Настройки изменились. Повторите проверку."); return }
                if let account = confirmed.keyAccount, draftKey != (savedKeys[account] ?? ""), !app.isPreview { try Keychain.save(draftKey, account: account) }
                _ = try RustBridge.shared.get().request(root: root, command: "semantic-config", arguments: ["config": confirmed.arguments]); savedConfig = confirmed; config = confirmed
                if let account = confirmed.keyAccount { savedKeys[account] = draftKey }
                registerDrafts(); message = L("Модель подключена"); index.requestRefresh()
            } catch { if mounted && lifecycleID == generation { failed = true; message = error.localizedDescription } }
        }
    }
    private func discover() {
        guard !busy else { return }; busy = true; registerDrafts(); failed = false
        let root = app.root, draft = config, draftKey = key, generation = lifecycleID
        Task { @MainActor in
            defer { if mounted && lifecycleID == generation { busy = false; registerDrafts() } }
            guard mounted && lifecycleID == generation else { return }
            do {
                let data = try await Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "semantic-models", arguments: ["config": draft.arguments, "apiKey": draftKey]) }.value
                guard mounted && lifecycleID == generation else { return }
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                availableModels = ((result?["models"] as? [[String: Any]]) ?? []).compactMap { ($0["name"] ?? $0["id"]) as? String }.sorted()
                message = availableModels.isEmpty ? L("Установленные модели не найдены") : L("Выберите embedding-модель из списка")
            } catch { if mounted && lifecycleID == generation { failed = true; message = error.localizedDescription } }
        }
    }
    private func download() {
        guard !busy else { return }; busy = true; registerDrafts(); failed = false; message = L("Скачиваем модель в Ollama…")
        let root = app.root, draft = config, draftKey = key, generation = lifecycleID
        Task { @MainActor in
            defer { if mounted && lifecycleID == generation { busy = false; registerDrafts() } }
            guard mounted && lifecycleID == generation else { return }
            do {
                _ = try await Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "semantic-pull", arguments: ["config": draft.arguments, "apiKey": draftKey]) }.value
                guard mounted && lifecycleID == generation else { return }
                message = L("Модель скачана. Включите поиск и проверьте подключение.")
            } catch { if mounted && lifecycleID == generation { failed = true; message = error.localizedDescription } }
        }
    }
}
