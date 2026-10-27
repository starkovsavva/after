import AppKit
import Combine
import Foundation
import PosleCore

/// One coordinator per library. The app supplies an idle predicate, so large
/// model jobs and recording always take priority. No account is inferred from
/// system settings and no connection is enabled without an explicit settings save.
@MainActor
final class TrackerSyncCoordinator: ObservableObject {
    @Published private(set) var state = TrackerSyncState()
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice: String?
    let root: URL
    private var timer: Timer?
    private var isIdle: () -> Bool = { false }
    private var changed: () -> Void = {}
    private var lastAttempt: [String: Date] = [:]
    private var generation = 0
    private var featureEnabled = false
    #if DEBUG
    private var releasePreview = false
    func seedPreview(_ value: TrackerSyncState) {
        stop(); releasePreview = true; state = value; error = nil; notice = nil
    }
    #endif
    private struct Credentials: Codable {
        var accessToken: String
        var refreshToken: String = ""
        var clientID: String = ""
        var clientSecret: String = ""
    }
    init(root: URL) { self.root = root }
    func start(isIdle: @escaping () -> Bool, onChange: @escaping () -> Void) {
        featureEnabled = true
        self.isIdle = isIdle; changed = onChange
        guard timer == nil else { return }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
    }
    func stop() { featureEnabled = false; timer?.invalidate(); timer = nil; generation += 1 }
    func reload() {
        #if DEBUG
        if releasePreview { return }
        #endif
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "tracker-state")
            state = try JSONDecoder().decode(TrackerSyncState.self, from: data)
        } catch { self.error = error.localizedDescription }
    }
    private func key(_ id: String) -> String { "tracker.connection.\(id)" }
    private func credentials(_ config: TrackerSyncConfiguration) throws -> Credentials {
        let text = try Keychain.readChecked(account: key(config.id))
        guard !text.isEmpty, let data = text.data(using: .utf8) else { throw AppError.message("Добавьте токен подключения в настройках.") }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    private func saveCredentials(_ credentials: Credentials, for id: String) throws {
        let data = try JSONEncoder().encode(credentials)
        try Keychain.save(String(decoding: data, as: UTF8.self), account: key(id))
    }
    /// A refresh token is optional for a manually supplied access token. When
    /// provided, refresh uses the user's own OAuth Desktop client and Keychain.
    private func authenticated(_ config: TrackerSyncConfiguration, generation expected: Int) async throws -> (TrackerSyncConfiguration, Credentials) {
        try checkEnabled(expected)
        var credentials = try credentials(config)
        guard config.provider == "google", (config.expiresAt ?? 0) < Date().timeIntervalSince1970 + 90 else { return (config, credentials) }
        guard !credentials.refreshToken.isEmpty, !credentials.clientID.isEmpty else {
            throw AppError.message("Срок токена Google истёк. Обновите его в настройках или добавьте refresh token своего OAuth-клиента.")
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = ["grant_type": "refresh_token", "client_id": credentials.clientID, "refresh_token": credentials.refreshToken]
        if !credentials.clientSecret.isEmpty { fields["client_secret"] = credentials.clientSecret }
        request.httpBody = fields.sorted(by: { $0.key < $1.key }).map { form($0.key) + "=" + form($0.value) }.joined(separator: "&").data(using: .utf8)
        let session = URLSession(configuration: .ephemeral, delegate: TrackerSyncNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try checkEnabled(expected)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 65_536,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = value["access_token"] as? String, !token.isEmpty,
              let seconds = value["expires_in"] as? Double, seconds > 0 else {
            throw AppError.message("Google не обновил доступ. Проверьте OAuth-клиент и refresh token в настройках подключения.")
        }
        credentials.accessToken = token
        if let next = value["refresh_token"] as? String, !next.isEmpty { credentials.refreshToken = next }
        try saveCredentials(credentials, for: config.id)
        var config = config; config.expiresAt = Date().timeIntervalSince1970 + seconds
        let data2 = try RustBridge.shared.get().request(root: root, command: "tracker-configure", arguments: ["configuration": object(config), "expectedRevision": config.revision])
        state = try JSONDecoder().decode(TrackerSyncState.self, from: data2)
        return (state.configurations.first(where: { $0.id == config.id }) ?? config, credentials)
    }
    private func checkEnabled(_ expected: Int) throws {
        guard featureEnabled, expected == generation else { throw CancellationError() }
    }
    private func form(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    func save(_ draft: TrackerSyncConfiguration, token: String, refreshToken: String, clientID: String, clientSecret: String) async -> Bool {
        guard featureEnabled, !busy else { return false }; busy = true; defer { busy = false }
        do {
            var config = draft
            if config.id.isEmpty { config.id = UUID().uuidString.lowercased() }
            let previous = try? credentials(config)
            let secrets = Credentials(accessToken: token.isEmpty ? previous?.accessToken ?? "" : token,
                refreshToken: refreshToken.isEmpty ? previous?.refreshToken ?? "" : refreshToken,
                clientID: clientID.isEmpty ? previous?.clientID ?? "" : clientID,
                clientSecret: clientSecret.isEmpty ? previous?.clientSecret ?? "" : clientSecret)
            guard !secrets.accessToken.isEmpty || (!secrets.refreshToken.isEmpty && !secrets.clientID.isEmpty) else {
                throw AppError.message("Добавьте токен доступа или refresh token своего OAuth-клиента.")
            }
            // Validate/save metadata first. If Keychain fails, do not leave an
            // enabled connector pointing at absent credentials.
            let active = config.enabled; config.enabled = false
            let data = try RustBridge.shared.get().request(root: root, command: "tracker-configure", arguments: ["configuration": object(config), "expectedRevision": config.revision])
            state = try JSONDecoder().decode(TrackerSyncState.self, from: data)
            try saveCredentials(secrets, for: config.id)
            guard var saved = state.configurations.first(where: { $0.id == config.id }) else { throw AppError.message("Подключение не сохранилось.") }
            saved.enabled = active
            let final = try RustBridge.shared.get().request(root: root, command: "tracker-configure", arguments: ["configuration": object(saved), "expectedRevision": saved.revision])
            state = try JSONDecoder().decode(TrackerSyncState.self, from: final)
            error = nil; notice = "Подключение сохранено"; return true
        } catch { reload(); self.error = error.localizedDescription; return false }
    }
    func scopes(_ config: TrackerSyncConfiguration) async -> [TrackerSyncScope] {
        guard featureEnabled, !busy else { return [] }; let currentGeneration = generation; busy = true; defer { busy = false }
        do {
            let (config, credential) = try await authenticated(config, generation: currentGeneration)
            try checkEnabled(currentGeneration)
            let root = root
            let data = try await Task.detached(priority: .utility) {
                try RustBridge.shared.get().request(root: root, command: "tracker-scopes", arguments: ["connectionID": config.id, "token": credential.accessToken])
            }.value
            struct Response: Decodable { var scopes: [TrackerSyncScope] }
            try checkEnabled(currentGeneration)
            error = nil; return try JSONDecoder().decode(Response.self, from: data).scopes
        } catch is CancellationError { return [] }
        catch {
            guard featureEnabled, currentGeneration == generation else { return [] }
            self.error = error.localizedDescription; return []
        }
    }
    func synchronize(_ config: TrackerSyncConfiguration, manual: Bool = true) async {
        guard featureEnabled, !busy else { return }; busy = true; lastAttempt[config.id] = Date(); defer { busy = false }
        let currentGeneration = generation
        do {
            let (config, credential) = try await authenticated(config, generation: currentGeneration)
            try checkEnabled(currentGeneration)
            let root = root
            let data = try await Task.detached(priority: .utility) {
                try RustBridge.shared.get().request(root: root, command: "tracker-sync", arguments: ["connectionID": config.id, "token": credential.accessToken, "force": manual])
            }.value
            guard currentGeneration == generation else { return }
            state = try JSONDecoder().decode(TrackerSyncState.self, from: data); error = nil
            notice = "Задачи синхронизированы"; changed()
        } catch is CancellationError {}
        catch {
            guard featureEnabled, currentGeneration == generation else { return }
            reload(); self.error = error.localizedDescription; changed()
        }
    }
    func disconnect(_ config: TrackerSyncConfiguration) {
        guard !busy else { return }
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "tracker-disconnect", arguments: ["connectionID": config.id, "expectedRevision": config.revision])
            state = try JSONDecoder().decode(TrackerSyncState.self, from: data)
            try Keychain.save("", account: key(config.id)); error = nil; notice = "Подключение отключено. Локальные задачи сохранены."
        } catch { self.error = error.localizedDescription }
    }
    func resolve(_ conflict: TrackerSyncConflict, resolution: String) async {
        guard featureEnabled, !busy, let config = state.configurations.first(where: { $0.id == conflict.connection }) else { return }
        let currentGeneration = generation
        busy = true; defer { busy = false }
        do {
            let (config, credential) = try await authenticated(config, generation: currentGeneration)
            try checkEnabled(currentGeneration)
            let root = root
            let data = try await Task.detached(priority: .utility) {
                try RustBridge.shared.get().request(root: root, command: "tracker-resolve", arguments: ["connectionID": config.id, "conflictID": conflict.id, "fingerprint": conflict.fingerprint, "resolution": resolution, "token": credential.accessToken])
            }.value
            try checkEnabled(currentGeneration)
            state = try JSONDecoder().decode(TrackerSyncState.self, from: data); error = nil; changed()
        } catch is CancellationError {}
        catch {
            guard featureEnabled, currentGeneration == generation else { return }
            reload(); self.error = error.localizedDescription
        }
    }
    func export(taskID: String, connection: TrackerSyncConfiguration, scope: String) {
        guard featureEnabled, !busy else { return }
        do {
            let data = try RustBridge.shared.get().request(root: root, command: "tracker-export", arguments: ["connectionID": connection.id, "taskID": taskID, "scope": scope])
            state = try JSONDecoder().decode(TrackerSyncState.self, from: data); error = nil; notice = "Задача добавлена в очередь отправки"
        } catch { self.error = error.localizedDescription }
    }
    private func tick() async {
        guard !busy, isIdle() else { return }
        reload()
        let time = Date().timeIntervalSince1970
        guard let config = state.configurations.first(where: {
            $0.enabled && !$0.paused && !$0.requiresAuth && !$0.scopes.isEmpty && ($0.retryAt ?? 0) <= time &&
            time - (lastAttempt[$0.id]?.timeIntervalSince1970 ?? $0.lastSync ?? 0) >= 300
        }) else { return }
        await synchronize(config, manual: false)
    }
}
private final class TrackerSyncNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
