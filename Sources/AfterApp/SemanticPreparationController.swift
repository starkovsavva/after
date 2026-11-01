import AfterPlatform
import AfterPlatformMacOS
import AfterLocalization
import Combine
import Foundation
import AfterCore

/// Preparation outlives its settings page. The FFI transfer is blocking and
/// cannot be interrupted: cancellation withdraws activation consent and drains
/// that request before a retry is admitted. Only verified files are published
/// by the engine; this controller never treats a partial download as ready.
@MainActor
final class SemanticPreparationController: ObservableObject {
    static let shared = SemanticPreparationController()
    typealias Request = @Sendable (URL, String, SemanticSearchConfiguration, String) throws -> Data
    @Published private(set) var running = false
    @Published private(set) var activationCancelled = false
    @Published private(set) var message = ""
    @Published private(set) var failed = false
    @Published private(set) var revision = UUID()
    private(set) var root: URL?
    private var work: Task<Void, Never>?
    private let request: Request

    init(request: @escaping Request = { root, command, config, key in
        try RustBridge.shared.get().request(root: root, command: command,
                                            arguments: ["config": config.arguments, "apiKey": key])
    }) { self.request = request }

    func isPreparing(_ root: URL) -> Bool { running && self.root == root }
    func cancelActivation() {
        guard running, !activationCancelled else { return }
        activationCancelled = true
        message = L("Включение отменено. Текущая загрузка или проверка завершится в фоне; поиск не будет включён.")
        work?.cancel()
    }
    func start(app: AppStore, draft: SemanticSearchConfiguration, baseline: SemanticSearchConfiguration, key: String) {
        guard work == nil else { return }
        let root = app.root, request = request
        self.root = root; running = true; activationCancelled = false; failed = false
        message = L("Скачиваем модель. Можно закрыть настройки и продолжить работу.")
        work = Task { [self] in
            defer { running = false; work = nil; revision = UUID() }
            do {
                _ = try await modelRequest(app: app, root: root, command: "semantic-pull", config: draft, key: key, request: request)
                try Task.checkCancellation()
                guard !activationCancelled else { throw CancellationError() }
                if draft.provider == "managed" {
                    message = L("Загрузка завершена. Проверяем модель…")
                    var enabled = draft; enabled.enabled = true
                    let checked = try await modelRequest(app: app, root: root, command: "semantic-check", config: enabled, key: "", request: request)
                    try Task.checkCancellation()
                    guard !activationCancelled, app.root == root, app.isFeatureEnabled(.semanticSearch), !app.isTerminating else { throw CancellationError() }
                    struct Envelope: Decodable { var config: SemanticSearchConfiguration }
                    let bridge = try RustBridge.shared.get()
                    let current = try JSONDecoder().decode(Envelope.self, from: bridge.request(root: root, command: "semantic-config")).config
                    guard current == baseline else {
                        message = L("Модель готова. Настройки изменились: включите поиск в настройках, когда будете готовы.")
                        return
                    }
                    let confirmed = try JSONDecoder().decode(Envelope.self, from: checked).config
                    _ = try bridge.request(root: root, command: "semantic-config", arguments: ["config": confirmed.arguments])
                    message = L("Модель After готова. Обновляем смысловой индекс…")
                    SemanticIndexController.shared.connect(app); SemanticIndexController.shared.requestRefresh()
                } else {
                    message = L("Модель скачана. Включите поиск и проверьте подключение.")
                }
            } catch is CancellationError {
                message = L("Включение отменено. Настройки поиска не изменены. Подготовку можно повторить.")
            } catch {
                if activationCancelled { message = L("Включение отменено. Настройки поиска не изменены. Подготовку можно повторить.") }
                else { failed = true; message = error.localizedDescription }
            }
        }
    }
    private func modelRequest(app: AppStore, root: URL, command: String, config: SemanticSearchConfiguration,
                              key: String, request: @escaping Request) async throws -> Data {
        try Task.checkCancellation()
        guard app.root == root, app.isFeatureEnabled(.semanticSearch), !app.isTerminating else { throw CancellationError() }
        if config.isLocal && (app.isRecording || app.startingRecording || app.stoppingRecording) {
            throw AppError.message(L("Дождитесь завершения записи"))
        }
        // Downloads use network and disk, not the inference runtime. Holding
        // this lease during blocking FFI would stall recording finalization,
        // transcription and dictation even after activation was cancelled.
        let lease = command == "semantic-check" && config.isLocal ? try await app.localRuntimeLease.acquire() : nil
        do {
            try Task.checkCancellation()
            guard app.root == root, app.isFeatureEnabled(.semanticSearch), !app.isTerminating else { throw CancellationError() }
            if config.isLocal && (app.isRecording || app.startingRecording || app.stoppingRecording) {
                throw AppError.message(L("Дождитесь завершения записи"))
            }
            let data = try await Task.detached(priority: .utility) { try request(root, command, config, key) }.value
            if let lease { await app.localRuntimeLease.release(lease) }
            return data
        } catch {
            if let lease { await app.localRuntimeLease.release(lease) }
            throw error
        }
    }
}
