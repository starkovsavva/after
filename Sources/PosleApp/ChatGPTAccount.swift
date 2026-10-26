import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import Security

struct ChatGPTProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let email: String?
    let planEnabled: Bool
}
struct ChatGPTModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let supportedReasoning: [String]?
    var reasoningChoices: [String] {
        supportedReasoning ?? (id == "gpt-6-luna" ? ["none", "low", "medium", "high", "xhigh", "max"] : [])
    }
}

/// Only an explicit settings action opens the browser. Production credentials never enter
/// previews, the meeting library, authorization logs, or another application's auth store.
@MainActor
final class ChatGPTAccount: ObservableObject {
    static let shared = ChatGPTAccount()
    @Published private(set) var profile: ChatGPTProfile?
    @Published private(set) var savedProfiles: [ChatGPTProfile] = []
    @Published private(set) var models: [ChatGPTModel] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSigningOut = false
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    private let engine: ChatGPTSessionStore
    private let disabled: Bool
    private var loginTask: Task<ChatGPTSessionStore.Snapshot, Error>?
    private var initialRestoreTask: Task<ChatGPTSessionStore.Snapshot, Error>?
    private var initialRestoreFailure: Error?
    private var initialRestoreRevision: UUID?
    private var revision = UUID()
    private var catalogRevision = UUID()
    private var refreshCount = 0

    convenience init(preview: Bool = false) {
        let arguments = ProcessInfo.processInfo.arguments
        let disabled = preview || arguments.contains("--preview") || arguments.contains("--snapshot") || arguments.contains { $0.hasPrefix("--check-") }
        let engine = ChatGPTSessionStore()
        let restore: Task<ChatGPTSessionStore.Snapshot, Error>? = disabled ? nil : Task { try await engine.snapshot() }
        self.init(engine: engine, disabled: disabled, restore: restore)
    }
    private init(engine: ChatGPTSessionStore, disabled: Bool, restore: Task<ChatGPTSessionStore.Snapshot, Error>?) {
        self.engine = engine; self.disabled = disabled; initialRestoreTask = restore
        initialRestoreRevision = revision
        if restore != nil { Task { [weak self] in try? await self?.restoreInitialSession() } }
    }
    /// Every startup caller awaits the same read. A cancelled job does not cancel
    /// restoration for the UI or other jobs; an explicit sign-in/out supersedes it.
    private func restoreInitialSession() async throws {
        guard revision == initialRestoreRevision else { return }
        guard let pending = initialRestoreTask else {
            if let initialRestoreFailure { throw initialRestoreFailure }
            return
        }
        do {
            let snapshot = try await pending.value
            try Task.checkCancellation()
            guard initialRestoreTask != nil else { return }
            initialRestoreTask = nil
            if revision == initialRestoreRevision { apply(snapshot) }
        } catch is CancellationError { throw CancellationError() }
        catch {
            if initialRestoreTask != nil {
                initialRestoreTask = nil; initialRestoreFailure = error
                if revision == initialRestoreRevision { report(error) }
            }
            throw error
        }
    }
    func signIn(useDifferentAccount: Bool = false) async {
        do { try await restoreInitialSession() } catch is CancellationError { return } catch {}
        await connect(accountID: useDifferentAccount ? nil : profile?.id)
    }
    func signIn(accountID: String) async {
        do { try await restoreInitialSession() } catch is CancellationError { return } catch {}
        await connect(accountID: accountID)
    }
    private func connect(accountID: String?) async {
        guard !disabled, !isConnecting, !isSigningOut else { return }
        let operationID = UUID(); revision = operationID
        isConnecting = true; message = nil; isError = false
        let engine = self.engine
        let operation = Task { try await engine.signIn(accountID: accountID) { NSWorkspace.shared.open($0) } }
        loginTask = operation
        do {
            let snapshot = try await operation.value
            guard revision == operationID else { return }
            apply(snapshot)
            message = profile?.planEnabled == true ? "ChatGPT подключён" : "Вход выполнен. Разреши приложению использовать подписку ChatGPT."
        } catch {
            guard revision == operationID else { return }
            if !(error is CancellationError) { report(error) }
        }
        guard revision == operationID else { return }
        loginTask = nil; isConnecting = false
        if profile?.planEnabled == true { await refreshModels() }
    }
    func cancelSignIn() { revision = UUID(); loginTask?.cancel(); loginTask = nil; isConnecting = false }
    func signOut() async {
        guard !disabled, !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        cancelSignIn(); catalogRevision = UUID(); models = []; isLoadingModels = false
        profile = nil
        do {
            let result = try await engine.signOut()
            apply(result.snapshot)
            message = result.remoteRevoked ? "Выход выполнен" : "Выход выполнен на этом Mac. Отозвать доступ также можно в настройках ChatGPT."
            isError = !result.remoteRevoked
        } catch { report(error) }
    }
    func refreshModels() async {
        guard !disabled else { return }
        do { try await restoreInitialSession() } catch { return }
        guard !isSigningOut, let accountID = profile?.id, profile?.planEnabled == true else { models = []; return }
        let operationID = UUID(); catalogRevision = operationID
        isLoadingModels = true; message = nil; isError = false
        defer { if catalogRevision == operationID { isLoadingModels = false } }
        do {
            let catalog = try await engine.models(expectedAccountID: accountID)
            guard catalogRevision == operationID, profile?.id == accountID else { return }
            models = catalog
            if catalog.isEmpty { message = "Для этого аккаунта пока нет доступных моделей"; isError = false }
        } catch {
            guard catalogRevision == operationID, profile?.id == accountID else { return }
            models = []
            if let snapshot = try? await engine.snapshot() { apply(snapshot) }
            report(error)
        }
    }
    func accessToken(expectedAccountID: String) async throws -> String {
        guard !disabled else { throw ChatGPTSignInError.accountChanged }
        try await restoreInitialSession()
        guard !isSigningOut, profile?.id == expectedAccountID else { throw ChatGPTSignInError.accountChanged }
        refreshCount += 1; isRefreshing = true
        defer { refreshCount -= 1; isRefreshing = refreshCount > 0 }
        do {
            let token = try await engine.accessToken(expectedAccountID: expectedAccountID)
            guard profile?.id == expectedAccountID else { throw ChatGPTSignInError.accountChanged }
            return token
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let snapshot = try? await engine.snapshot() { apply(snapshot) }
            report(error); throw error
        }
    }
    private func apply(_ snapshot: ChatGPTSessionStore.Snapshot) {
        if profile?.id != snapshot.active?.id || snapshot.active?.planEnabled != true { models = [] }
        profile = snapshot.active; savedProfiles = snapshot.profiles
    }
    private func report(_ error: Error) {
        isError = true
        message = (error as? ChatGPTSignInError)?.errorDescription ?? "Не удалось подключиться к ChatGPT. Проверь сеть и попробуй ещё раз."
    }
    #if DEBUG
    static func restoringFixture() throws -> (account: ChatGPTAccount, id: String) {
        let fixture = try ChatGPTSessionStore.startupFixture()
        let restore = Task {
            try await Task.sleep(for: .milliseconds(35))
            return try await fixture.engine.snapshot()
        }
        return (ChatGPTAccount(engine: fixture.engine, disabled: false, restore: restore), fixture.id)
    }
    static func fixture(profile: ChatGPTProfile? = nil, savedProfiles: [ChatGPTProfile] = [], models: [ChatGPTModel] = [], connecting: Bool = false, loading: Bool = false, message: String? = nil, isError: Bool = false) -> ChatGPTAccount {
        let result = ChatGPTAccount(preview: true)
        result.profile = profile; result.savedProfiles = savedProfiles; result.models = models
        result.isConnecting = connecting; result.isLoadingModels = loading; result.message = message; result.isError = isError
        return result
    }
    #endif
}

enum ChatGPTSignInError: LocalizedError, Equatable {
    case callback, identity, registration, accountChanged, permission, signInRequired
    case keychain, network, unavailable, invalidClient, refreshTooEarly, oauthDenied
    var errorDescription: String? {
        switch self {
        case .callback: return "Не удалось подтвердить ответ браузера. Начни вход заново."
        case .identity: return "Не удалось проверить аккаунт ChatGPT. Начни вход заново."
        case .registration: return "ChatGPT не завершил регистрацию приложения. Попробуй войти заново."
        case .accountChanged: return "Выбран другой аккаунт ChatGPT. Запусти задачу заново для нужного аккаунта."
        case .permission: return "Разреши приложению использовать подписку ChatGPT в настройках подключения."
        case .signInRequired: return "Сессия ChatGPT завершилась. Войди заново."
        case .keychain: return "Связка ключей не сохранила сессию. Проверь доступ и войди снова."
        case .network: return "Не удалось подключиться к ChatGPT. Проверь сеть и попробуй ещё раз."
        case .unavailable: return "ChatGPT временно недоступен. Попробуй позже."
        case .invalidClient: return "ChatGPT не принял регистрацию приложения. Переподключи аккаунт."
        case .refreshTooEarly: return "ChatGPT ещё не разрешил обновление сессии. Попробуй немного позже."
        case .oauthDenied: return "Доступ не разрешён. Текущий аккаунт не изменён."
        }
    }
}

/// Pure helpers exercise the same validation in offline native checks.
enum ChatGPTSecurity {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func randomURLSafe(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTSignInError.identity }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeBase64URL(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw ChatGPTSignInError.identity }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { throw ChatGPTSignInError.identity }
        return data
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func accountID(subject: String, clientID: String) -> String {
        base64URL(Data(SHA256.hash(data: Data((issuer + "\u{0}" + subject + "\u{0}" + clientID).utf8))))
    }
    static func constantEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func callback(_ target: String, state: String, issuedClientID: String?) throws -> (code: String, clientID: String) {
        guard target.hasPrefix("/auth/callback?"), let parts = URLComponents(string: "http://127.0.0.1" + target), parts.path == "/auth/callback", parts.fragment == nil,
              let items = parts.queryItems else { throw ChatGPTSignInError.callback }
        var fields: [String: String] = [:]
        for item in items {
            guard fields[item.name] == nil, let value = item.value else { throw ChatGPTSignInError.callback }
            fields[item.name] = value
        }
        guard let returnedState = fields["state"], constantEqual(returnedState, state) else { throw ChatGPTSignInError.callback }
        if let issuer = fields["iss"], issuer != self.issuer { throw ChatGPTSignInError.callback }
        if fields["error"] != nil { throw ChatGPTSignInError.oauthDenied }
        guard let code = fields["code"], !code.isEmpty, code.utf8.count <= 8192 else { throw ChatGPTSignInError.callback }
        let clientID = fields["client_id"] ?? issuedClientID ?? ""
        guard !clientID.isEmpty, clientID != "dynamic_agent_client", clientID.utf8.count < 1024,
              issuedClientID == nil || clientID == issuedClientID else { throw ChatGPTSignInError.registration }
        return (code, clientID)
    }
    struct Identity: Sendable { let subject: String; let name: String?; let email: String? }
    static func verifyIDToken(_ token: String, clientID: String, nonce: String?, expectedSubject: String?, jwks: Data, now: Date = Date()) throws -> Identity {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3, token.utf8.count < 65_536,
              let header = try JSONSerialization.jsonObject(with: decodeBase64URL(segments[0])) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              let keyID = header["kid"] as? String, !keyID.isEmpty,
              let keys = (try JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]] else { throw ChatGPTSignInError.identity }
        let matchingKeys = keys.filter { $0["kid"] as? String == keyID }
        guard matchingKeys.count == 1, let jwk = matchingKeys.first,
              jwk["kty"] as? String == "RSA", (jwk["use"] == nil || jwk["use"] as? String == "sig"),
              (jwk["alg"] == nil || jwk["alg"] as? String == "RS256"),
              let modulus = jwk["n"] as? String, let exponent = jwk["e"] as? String else { throw ChatGPTSignInError.identity }
        let n = try decodeBase64URL(modulus), e = try decodeBase64URL(exponent)
        guard (256...1024).contains(n.count), (1...8).contains(e.count), !e.allSatisfy({ $0 == 0 }) else { throw ChatGPTSignInError.identity }
        let der = derSequence(derInteger(n) + derInteger(e))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((segments[0] + "." + segments[1]).utf8) as CFData,
                                    try decodeBase64URL(segments[2]) as CFData, nil) else { throw ChatGPTSignInError.identity }
        guard let claims = try JSONSerialization.jsonObject(with: decodeBase64URL(segments[1])) as? [String: Any],
              claims["iss"] as? String == issuer, let subject = claims["sub"] as? String, !subject.isEmpty,
              let exp = numericClaim(claims["exp"]), exp > now.timeIntervalSince1970 else { throw ChatGPTSignInError.identity }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID), (audiences.count <= 1 || claims["azp"] as? String == clientID),
              claims["azp"] == nil || claims["azp"] as? String == clientID else { throw ChatGPTSignInError.identity }
        if let nonce { guard let value = claims["nonce"] as? String, constantEqual(value, nonce) else { throw ChatGPTSignInError.identity } }
        if let expectedSubject { guard constantEqual(subject, expectedSubject) else { throw ChatGPTSignInError.accountChanged } }
        if let nbf = numericClaim(claims["nbf"]), nbf > now.timeIntervalSince1970 + 30 { throw ChatGPTSignInError.identity }
        if let iat = numericClaim(claims["iat"]), iat > now.timeIntervalSince1970 + 30 { throw ChatGPTSignInError.identity }
        return Identity(subject: subject, name: claims["name"] as? String, email: claims["email"] as? String)
    }
    private static func numericClaim(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }
    private static func derLength(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count, bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    private static func derInteger(_ value: Data) -> Data {
        var bytes = Data(value.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: bytes.startIndex) }
        return Data([0x02]) + derLength(bytes.count) + bytes
    }
    private static func derSequence(_ value: Data) -> Data { Data([0x30]) + derLength(value.count) + value }
    static func parseModels(_ data: Data) throws -> [ChatGPTModel] {
        guard let rows = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] else { throw ChatGPTSignInError.unavailable }
        var identifiers = Set<String>()
        return rows.compactMap { row in
            guard row["visibility"] as? String == "list", let slug = row["slug"] as? String, !slug.isEmpty,
                  let name = row["display_name"] as? String, !name.isEmpty, identifiers.insert(slug).inserted else { return nil }
            let values = row["supported_reasoning_levels"] as? [[String: Any]]
            let reasoning = values?.compactMap { $0["effort"] as? String }
            return ChatGPTModel(id: slug, name: name, supportedReasoning: reasoning?.isEmpty == false ? reasoning : nil)
        }
    }
}

/// This actor owns all Keychain and URLSession operations. Rotating refresh/access tokens,
/// scopes and expiry are committed in one Keychain write, never separately.
private actor ChatGPTSessionStore {
    struct Snapshot: Sendable { let active: ChatGPTProfile?; let profiles: [ChatGPTProfile] }
    struct SignOutResult: Sendable { let snapshot: Snapshot; let remoteRevoked: Bool }
    private struct Tokens: Codable, Sendable {
        var access: String; var refresh: String; var idToken: String
        var expiresAt: Date; var earliestRefreshAt: Date?; var scopes: [String]
    }
    private struct Registration: Codable, Sendable {
        var id: String; var subject: String; var clientID: String; var displayName: String; var email: String?; var tokens: Tokens?
        var profile: ChatGPTProfile { ChatGPTProfile(id: id, displayName: displayName, email: email, planEnabled: tokens?.scopes.contains("chatgpt.tokens.use.direct") == true) }
    }
    private struct Vault: Codable, Sendable { var registrations: [Registration] = []; var activeID: String? }
    private struct TokenResponse: Decodable, Sendable {
        let access_token: String?; let refresh_token: String?; let id_token: String?; let token_type: String?
        let expires_in: Double?; let scope: String?; let earliest_refresh_at: Double?
    }
    private struct Discovery: Decodable, Sendable { let issuer: String; let jwks_uri: String; let revocation_endpoint: String? }
    private static let vaultAccount = "chatgpt.direct.oauth.v1"
    private var vault: Vault?
    private var generation = UUID()
    private var loginGeneration = UUID()
    private var signingOut = false
    private var refreshTask: Task<Tokens, Error>?
    private var refreshAccountID: String?
    private var activeListener: ChatGPTLoopbackListener?
    #if DEBUG
    private struct TestHooks: Sendable {
        let save: @Sendable (String) throws -> Void
        let request: @Sendable (URLRequest) async throws -> (Data, Int)
    }
    private var testHooks: TestHooks?
    private init(vault: Vault, hooks: TestHooks) { self.vault = vault; testHooks = hooks }
    #endif
    init() {}
    private let redirectDelegate = ChatGPTNoRedirectDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()
    private func load() throws -> Vault {
        if let vault { return vault }
        let raw: String
        do { raw = try Keychain.readChecked(account: Self.vaultAccount) }
        catch { throw ChatGPTSignInError.keychain }
        if raw.isEmpty { let value = Vault(); vault = value; return value }
        guard let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(Vault.self, from: data) else { throw ChatGPTSignInError.keychain }
        vault = value; return value
    }
    private func reload() throws -> Vault {
        #if DEBUG
        if testHooks != nil { return try load() }
        #endif
        vault = nil
        return try load()
    }
    private func credentialGate() async throws -> ChatGPTCredentialGate? {
        #if DEBUG
        if testHooks != nil { return nil }
        #endif
        return try await ChatGPTCredentialGate.acquire()
    }
    private func persist(_ value: Vault) throws {
        do {
            let encoded = try JSONEncoder().encode(value)
            guard let raw = String(data: encoded, encoding: .utf8) else { throw ChatGPTSignInError.keychain }
            #if DEBUG
            if let testHooks { try testHooks.save(raw) }
            else { try Keychain.save(raw, account: Self.vaultAccount) }
            #else
            try Keychain.save(raw, account: Self.vaultAccount)
            #endif
            vault = value
        } catch { throw ChatGPTSignInError.keychain }
    }
    func snapshot() throws -> Snapshot {
        let value = try load()
        return Snapshot(active: value.registrations.first { !signingOut && $0.id == value.activeID && $0.tokens != nil }?.profile, profiles: value.registrations.map(\.profile))
    }
    private func hostID() -> String {
        let defaults = UserDefaults.standard, key = "chatgpt.ext_agent_host_id"
        if let value = defaults.string(forKey: key), value.hasPrefix("urn:uuid:"), UUID(uuidString: String(value.dropFirst(9))) != nil { return value }
        let value = "urn:uuid:" + UUID().uuidString.lowercased(); defaults.set(value, forKey: key); return value
    }
    func signIn(accountID: String?, openBrowser: @MainActor @Sendable (URL) -> Bool) async throws -> Snapshot {
        guard !signingOut else { throw ChatGPTSignInError.accountChanged }
        let value = try load(), registration = accountID.flatMap { id in value.registrations.first { $0.id == id } }
        if accountID != nil && registration == nil { throw ChatGPTSignInError.accountChanged }
        let operationID = UUID(); loginGeneration = operationID
        let state = try ChatGPTSecurity.randomURLSafe(), nonce = try ChatGPTSecurity.randomURLSafe(), verifier = try ChatGPTSecurity.randomURLSafe(byteCount: 64)
        let listener = ChatGPTLoopbackListener(state: state, issuedClientID: registration?.clientID)
        activeListener?.cancel(); activeListener = listener
        defer { listener.cancel(); if loginGeneration == operationID { activeListener = nil } }
        let redirectURI = try await listener.start()
        var authorization = URLComponents(string: ChatGPTSecurity.issuer + "/api/accounts/authorize")!
        var items = [URLQueryItem(name: "client_id", value: registration?.clientID ?? "dynamic_agent_client"),
                     URLQueryItem(name: "ext_agent_host_id", value: hostID()), URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "scope", value: ChatGPTSecurity.scopes),
                     URLQueryItem(name: "resource", value: ChatGPTSecurity.resource), URLQueryItem(name: "state", value: state), URLQueryItem(name: "nonce", value: nonce),
                     URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "code_challenge", value: ChatGPTSecurity.challenge(verifier))]
        if let registration {
            if let token = registration.tokens?.idToken, !token.isEmpty { items.append(URLQueryItem(name: "id_token_hint", value: token)) }
            if let email = registration.email { items.append(URLQueryItem(name: "login_hint", value: email)) }
            if let tokens = registration.tokens, !tokens.scopes.contains("chatgpt.tokens.use.direct") { items.append(URLQueryItem(name: "prompt", value: "consent")) }
        } else { items.append(URLQueryItem(name: "agent_name_hint", value: "После")) }
        authorization.queryItems = items
        guard let url = authorization.url else { throw ChatGPTSignInError.registration }
        try Task.checkCancellation()
        guard await openBrowser(url) else { throw ChatGPTSignInError.unavailable }
        let callback = try await withTaskCancellationHandler(operation: { try await listener.wait() }, onCancel: { listener.cancel() })
        try ensureLogin(operationID)
        let response = try await exchange(["grant_type": "authorization_code", "client_id": callback.clientID, "code": callback.code,
                                          "code_verifier": verifier, "redirect_uri": redirectURI, "resource": ChatGPTSecurity.resource])
        guard let idToken = response.id_token else { throw ChatGPTSignInError.identity }
        let refresh = response.refresh_token ?? "", scope = response.scope ?? ""
        let identity = try ChatGPTSecurity.verifyIDToken(idToken, clientID: callback.clientID, nonce: nonce, expectedSubject: registration?.subject, jwks: try await signingKeys())
        try ensureLogin(operationID)
        let id = ChatGPTSecurity.accountID(subject: identity.subject, clientID: callback.clientID)
        let stored = Registration(id: id, subject: identity.subject, clientID: callback.clientID,
                                  displayName: identity.name?.isEmpty == false ? identity.name! : identity.email ?? "ChatGPT", email: identity.email,
                                  tokens: try tokens(response, old: nil, idToken: idToken, refresh: refresh, scope: scope))
        let gate = try await credentialGate()
        defer { gate?.release() }
        try ensureLogin(operationID)
        var updated = try reload()
        if let index = updated.registrations.firstIndex(where: { $0.id == id }) { updated.registrations[index] = stored }
        else { updated.registrations.append(stored) }
        updated.activeID = id; try persist(updated)
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil; refreshAccountID = nil
        return try snapshot()
    }
    func accessToken(expectedAccountID: String) async throws -> String {
        guard !signingOut else { throw ChatGPTSignInError.accountChanged }
        let value = try load()
        guard value.activeID == expectedAccountID, let record = value.registrations.first(where: { $0.id == expectedAccountID }), let saved = record.tokens else { throw ChatGPTSignInError.accountChanged }
        guard saved.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTSignInError.permission }
        if saved.expiresAt.timeIntervalSinceNow > 90 { return saved.access }
        if let earliest = saved.earliestRefreshAt, earliest > Date() {
            guard saved.expiresAt > Date() else { throw ChatGPTSignInError.refreshTooEarly }; return saved.access
        }
        let operationID = generation, task: Task<Tokens, Error>
        if let existing = refreshTask, refreshAccountID == expectedAccountID { task = existing }
        else { task = Task { try await self.refresh(record, operationID: operationID) }; refreshTask = task; refreshAccountID = expectedAccountID }
        defer { if generation == operationID && refreshAccountID == expectedAccountID { refreshTask = nil; refreshAccountID = nil } }
        let refreshed = try await task.value
        try ensureGeneration(operationID)
        let current = try load()
        guard current.activeID == expectedAccountID, current.registrations.first(where: { $0.id == expectedAccountID })?.tokens?.access == refreshed.access else { throw ChatGPTSignInError.accountChanged }
        guard refreshed.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTSignInError.permission }
        return refreshed.access
    }
    private func refresh(_ selected: Registration, operationID: UUID) async throws -> Tokens {
        let gate = try await credentialGate()
        defer { gate?.release() }
        try ensureGeneration(operationID)
        let latest = try reload()
        guard latest.activeID == selected.id, let record = latest.registrations.first(where: { $0.id == selected.id }), let old = record.tokens else { throw ChatGPTSignInError.accountChanged }
        // Another running copy may already have rotated this session while we waited.
        if old.expiresAt.timeIntervalSinceNow > 90 { return old }
        if let earliest = old.earliestRefreshAt, earliest > Date() { throw ChatGPTSignInError.refreshTooEarly }
        do {
            guard !old.refresh.isEmpty else { throw ChatGPTSignInError.signInRequired }
            let response = try await exchange(["grant_type": "refresh_token", "client_id": record.clientID, "refresh_token": old.refresh, "resource": ChatGPTSecurity.resource], refreshing: true)
            try ensureGeneration(operationID)
            if let idToken = response.id_token { _ = try ChatGPTSecurity.verifyIDToken(idToken, clientID: record.clientID, nonce: nil, expectedSubject: record.subject, jwks: try await signingKeys()) }
            try ensureGeneration(operationID)
            let refresh = response.refresh_token ?? ""
            let replacement = try tokens(response, old: old, idToken: response.id_token ?? old.idToken, refresh: refresh, scope: response.scope)
            var updated = try load()
            guard updated.activeID == record.id, let index = updated.registrations.firstIndex(where: { $0.id == record.id }), updated.registrations[index].tokens?.refresh == old.refresh else { throw ChatGPTSignInError.accountChanged }
            updated.registrations[index].tokens = replacement; try persist(updated); return replacement
        } catch let error as ChatGPTSignInError where error == .signInRequired || error == .identity || error == .keychain {
            try ensureGeneration(operationID)
            // A successful rotation cannot fall back to the old refresh token when
            // verification or persistence fails. Temporary transport failures never
            // reach this path and retain the previous credentials.
            var updated = try load()
            if let index = updated.registrations.firstIndex(where: { $0.id == record.id }) { updated.registrations[index].tokens = nil }
            if updated.activeID == record.id { updated.activeID = nil }
            if error == .keychain { vault = updated }
            else {
                do { try persist(updated) }
                catch { vault = updated; throw ChatGPTSignInError.keychain }
            }
            throw error
        }
    }
    func models(expectedAccountID: String) async throws -> [ChatGPTModel] {
        let token = try await accessToken(expectedAccountID: expectedAccountID), operationID = generation
        var request = URLRequest(url: URL(string: ChatGPTSecurity.resource + "/models")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, status) = try await perform(request)
        try ensureGeneration(operationID)
        guard try load().activeID == expectedAccountID else { throw ChatGPTSignInError.accountChanged }
        guard status == 200 else {
            if status == 401 { throw ChatGPTSignInError.signInRequired }
            if status == 403 { throw ChatGPTSignInError.permission }
            throw status >= 500 ? ChatGPTSignInError.unavailable : ChatGPTSignInError.network
        }
        return try ChatGPTSecurity.parseModels(data)
    }
    func signOut() async throws -> SignOutResult {
        guard !signingOut else { throw ChatGPTSignInError.accountChanged }
        signingOut = true
        defer { signingOut = false }
        generation = UUID(); loginGeneration = UUID(); activeListener?.cancel(); activeListener = nil; refreshTask?.cancel(); refreshTask = nil; refreshAccountID = nil
        let gate = try await credentialGate()
        defer { gate?.release() }
        var value = try reload()
        let selected = value.registrations.first { $0.id == value.activeID }
        var confirmed = selected?.tokens?.refresh.isEmpty != false
        if let record = selected, let tokens = record.tokens, !tokens.refresh.isEmpty {
            do {
                let discovery = try await configuration()
                guard let rawEndpoint = discovery.revocation_endpoint, let endpoint = URL(string: rawEndpoint), Self.isAuthURL(endpoint) else { throw ChatGPTSignInError.identity }
                var request = URLRequest(url: endpoint); request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.form(["token": tokens.refresh, "token_type_hint": "refresh_token", "client_id": record.clientID])
                for attempt in 0..<2 {
                    do { let (_, status) = try await perform(request); if status == 200 { confirmed = true; break }; if status < 500 { break } }
                    catch { if attempt == 1 { break } }
                    try await Task.sleep(for: .milliseconds(350))
                }
            } catch { confirmed = false }
        }
        value = try load()
        if let id = selected?.id, let index = value.registrations.firstIndex(where: { $0.id == id }) { value.registrations[index].tokens = nil }
        value.activeID = nil; try persist(value)
        return SignOutResult(snapshot: try snapshot(), remoteRevoked: confirmed)
    }
    private func ensureLogin(_ value: UUID) throws { try Task.checkCancellation(); guard value == loginGeneration, !signingOut else { throw ChatGPTSignInError.accountChanged } }
    private func ensureGeneration(_ value: UUID) throws { try Task.checkCancellation(); guard value == generation else { throw ChatGPTSignInError.accountChanged } }
    private func tokens(_ response: TokenResponse, old: Tokens?, idToken: String, refresh: String, scope: String?) throws -> Tokens {
        let scopes = scope.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) } ?? old?.scopes ?? []
        let access = response.access_token ?? "", lifetime = response.expires_in ?? 0
        if scopes.contains("chatgpt.tokens.use.direct") {
            guard !access.isEmpty, response.token_type?.lowercased() == "bearer", lifetime.isFinite, lifetime > 0, lifetime <= 86_400 else { throw ChatGPTSignInError.identity }
        }
        return Tokens(access: access, refresh: refresh, idToken: idToken, expiresAt: Date().addingTimeInterval(max(0, min(lifetime, 86_400))),
                      earliestRefreshAt: response.earliest_refresh_at.map(Date.init(timeIntervalSince1970:)), scopes: scopes)
    }
    private func exchange(_ fields: [String: String], refreshing: Bool = false) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: ChatGPTSecurity.issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = Self.form(fields)
        let (data, status) = try await perform(request)
        guard status == 200 else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = (object?["error"] as? String) ?? (object?["error"] as? [String: Any])?["code"] as? String
            let terminal = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
            if refreshing, let code, terminal.contains(code) { throw ChatGPTSignInError.signInRequired }
            if code == "invalid_client" { throw ChatGPTSignInError.invalidClient }
            if code == "token_issued_too_early" { throw ChatGPTSignInError.refreshTooEarly }
            if !refreshing, code == "invalid_grant" { throw ChatGPTSignInError.signInRequired }
            throw status >= 500 || status == 429 ? ChatGPTSignInError.unavailable : ChatGPTSignInError.network
        }
        do { return try JSONDecoder().decode(TokenResponse.self, from: data) } catch { throw ChatGPTSignInError.identity }
    }
    private func configuration() async throws -> Discovery {
        let (data, status) = try await perform(URLRequest(url: URL(string: ChatGPTSecurity.issuer + "/.well-known/openid-configuration")!))
        guard status == 200, let result = try? JSONDecoder().decode(Discovery.self, from: data), result.issuer == ChatGPTSecurity.issuer,
              let jwks = URL(string: result.jwks_uri), Self.isAuthURL(jwks) else { throw ChatGPTSignInError.identity }
        return result
    }
    private func signingKeys() async throws -> Data {
        let discovery = try await configuration()
        guard let url = URL(string: discovery.jwks_uri) else { throw ChatGPTSignInError.identity }
        let (data, status) = try await perform(URLRequest(url: url)); guard status == 200 else { throw ChatGPTSignInError.identity }; return data
    }
    private static func isAuthURL(_ url: URL) -> Bool { url.scheme == "https" && url.host == "auth.openai.com" && url.port == nil && url.user == nil && url.password == nil && url.fragment == nil }
    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            #if DEBUG
            if let testHooks { return try await testHooks.request(request) }
            #endif
            let (stream, response) = try await session.bytes(for: request)
            defer { stream.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw ChatGPTSignInError.network }
            var data = Data()
            for try await byte in stream {
                guard data.count < 2_097_152 else { throw ChatGPTSignInError.network }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, response.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ChatGPTSignInError { throw error }
        catch { throw ChatGPTSignInError.network }
    }
    private static func form(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(values.keys.sorted().map { key in
            (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + (values[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
}
/// Shared by simultaneous app copies, not just concurrent tasks in this actor.
/// The owner-only file contains no token material and closes automatically on process exit.
private final class ChatGPTCredentialGate: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var released = false
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    static func acquire() async throws -> ChatGPTCredentialGate {
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = cache.appendingPathComponent("app.posle.meetings.chatgpt-oauth", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ChatGPTSignInError.keychain }
        let descriptor = open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ChatGPTSignInError.keychain }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else { close(descriptor); throw ChatGPTSignInError.keychain }
        let gate = ChatGPTCredentialGate(descriptor)
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else { throw ChatGPTSignInError.keychain }
                guard ContinuousClock.now < deadline else { throw ChatGPTSignInError.unavailable }
                try await Task.sleep(for: .milliseconds(60))
            }
            try Task.checkCancellation()
            return gate
        } catch { gate.release(); throw error }
    }
    func release() { lock.withLock { if !released { released = true; flock(descriptor, LOCK_UN); close(descriptor) } } }
    deinit { release() }
}

private final class ChatGPTNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// A bounded HTTP listener bound to IPv4 loopback only, with fresh state and an ephemeral port.
private final class ChatGPTLoopbackListener: @unchecked Sendable {
    typealias Callback = (code: String, clientID: String)
    private let queue = DispatchQueue(label: "app.posle.chatgpt.callback")
    private let state: String
    private let issuedClientID: String?
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var continuation: CheckedContinuation<Callback, Error>?
    private var result: Result<Callback, Error>?
    private var port: UInt16?
    private var connections: [UUID: NWConnection] = [:]
    init(state: String, issuedClientID: String?) { self.state = state; self.issuedClientID = issuedClientID }
    func start() async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.result == nil else { continuation.resume(throwing: CancellationError()); return }
                    self.startContinuation = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
                        let listener = try NWListener(using: parameters); self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard let port = listener.port?.rawValue else { self.finish(.failure(ChatGPTSignInError.callback)); return }
                                self.port = port; self.startContinuation?.resume(returning: "http://127.0.0.1:\(port)/auth/callback"); self.startContinuation = nil
                            case .failed: self.finish(.failure(ChatGPTSignInError.callback))
                            case .cancelled: if self.result == nil { self.finish(.failure(CancellationError())) }
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                        let timer = DispatchSource.makeTimerSource(queue: self.queue); timer.schedule(deadline: .now() + 300)
                        timer.setEventHandler { [weak self] in self?.finish(.failure(ChatGPTSignInError.callback)) }
                        self.timer = timer; timer.resume(); listener.start(queue: self.queue)
                    } catch { self.finish(.failure(ChatGPTSignInError.callback)) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    func wait() async throws -> Callback {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { if let result = self.result { continuation.resume(with: result) } else { self.continuation = continuation } }
        }
    }
    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }
    private func finish(_ value: Result<Callback, Error>) {
        guard result == nil else { return }
        result = value; listener?.cancel(); listener = nil; timer?.cancel(); timer = nil
        if let pending = startContinuation {
            switch value { case .failure(let error): pending.resume(throwing: error); case .success: pending.resume(throwing: ChatGPTSignInError.callback) }
            startContinuation = nil
        }
        continuation?.resume(with: value); continuation = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
    }
    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8, case .hostPort(let host, _) = connection.endpoint, host == NWEndpoint.Host("127.0.0.1") else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; connection.start(queue: queue); receive(connection, id: id, buffer: Data())
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in connection?.cancel(); self?.connections.removeValue(forKey: id) }
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak connection] bytes, _, complete, error in
            guard let self, let connection else { return }
            let data = buffer + (bytes ?? Data())
            guard error == nil, data.count <= 16_384 else { connection.cancel(); self.connections.removeValue(forKey: id); return }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { self.handle(data, connection: connection, id: id) }
            else if complete { connection.cancel(); self.connections.removeValue(forKey: id) }
            else { self.receive(connection, id: id, buffer: data) }
        }
    }
    private func handle(_ data: Data, connection: NWConnection, id: UUID) {
        guard let request = String(data: data, encoding: .utf8), let line = request.components(separatedBy: "\r\n").first, let port else { reply(connection, id: id, success: false); return }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        let headers = request.components(separatedBy: "\r\n").dropFirst().prefix(while: { !$0.isEmpty })
        let hosts = headers.filter { $0.lowercased().hasPrefix("host:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1", hosts == ["127.0.0.1:\(port)"], !headers.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) else { reply(connection, id: id, success: false); return }
        do {
            let callback = try ChatGPTSecurity.callback(String(parts[1]), state: state, issuedClientID: issuedClientID)
            reply(connection, id: id, success: true) { [weak self] in self?.finish(.success(callback)) }
        } catch ChatGPTSignInError.oauthDenied { reply(connection, id: id, success: false) { [weak self] in self?.finish(.failure(ChatGPTSignInError.oauthDenied)) } }
        catch { reply(connection, id: id, success: false) }
    }
    private func reply(_ connection: NWConnection, id: UUID, success: Bool, completion: (() -> Void)? = nil) {
        let text = success ? "Ответ получен. Продолжи в приложении После." : "Не удалось подтвердить вход. Вернись в После и попробуй снова."
        let body = Data(("<!doctype html><html lang=\"ru\"><meta charset=\"utf-8\"><meta name=\"referrer\" content=\"no-referrer\"><title>После</title><body><p>" + text + "</p></body></html>").utf8)
        let header = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in connection.cancel(); self?.connections.removeValue(forKey: id); completion?() })
    }
}

#if DEBUG
extension ChatGPTSecurity {
    static func verifySessionLifecycle() async throws { try await ChatGPTSessionStore.verifySessionLifecycle() }
    static func verifyLoopback() async throws {
        let state = "offline-state", clientID = "oaiapp_offline"
        let listener = ChatGPTLoopbackListener(state: state, issuedClientID: clientID)
        defer { listener.cancel() }
        let redirect = try await listener.start()
        guard let url = URL(string: redirect), url.host == "127.0.0.1", url.path == "/auth/callback", url.port != nil else { throw ChatGPTSignInError.callback }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (_, rejected) = try await session.data(from: URL(string: redirect + "?state=wrong&code=offline-code")!)
        guard (rejected as? HTTPURLResponse)?.statusCode == 400 else { throw ChatGPTSignInError.callback }
        let (_, accepted) = try await session.data(from: URL(string: redirect + "?state=offline-state&code=offline-code")!)
        guard (accepted as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTSignInError.callback }
        let callback = try await listener.wait()
        guard callback.code == "offline-code", callback.clientID == clientID else { throw ChatGPTSignInError.callback }
        let cancelled = ChatGPTLoopbackListener(state: state, issuedClientID: clientID)
        _ = try await cancelled.start(); cancelled.cancel()
        do { _ = try await cancelled.wait(); throw ChatGPTSignInError.callback } catch is CancellationError {}
    }
}
private extension ChatGPTSessionStore {
    static func startupFixture() throws -> (engine: ChatGPTSessionStore, id: String) {
        let id = ChatGPTSecurity.accountID(subject: "offline-startup", clientID: "oaiapp_startup")
        let tokens = Tokens(access: "offline-startup-access", refresh: "offline-startup-refresh", idToken: "offline-startup-id",
                            expiresAt: Date().addingTimeInterval(3600), earliestRefreshAt: nil, scopes: ChatGPTSecurity.scopes.components(separatedBy: " "))
        let record = Registration(id: id, subject: "offline-startup", clientID: "oaiapp_startup", displayName: "Offline startup", email: nil, tokens: tokens)
        let body = try JSONSerialization.data(withJSONObject: ["models": [["slug": "offline-model", "display_name": "Offline model", "visibility": "list"]]])
        let hooks = TestHooks(save: { _ in throw ChatGPTSignInError.identity }, request: { request in
            guard request.url?.absoluteString == "https://api.openai.com/v1/models", request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-startup-access" else { throw ChatGPTSignInError.identity }
            return (body, 200)
        })
        return (ChatGPTSessionStore(vault: Vault(registrations: [record], activeID: id), hooks: hooks), id)
    }
    static func verifySessionLifecycle() async throws {
        let id = ChatGPTSecurity.accountID(subject: "offline-subject", clientID: "oaiapp_offline")
        let old = Tokens(access: "offline-old-access", refresh: "offline-old-refresh", idToken: "offline-id-token",
                         expiresAt: Date().addingTimeInterval(20), earliestRefreshAt: nil, scopes: ChatGPTSecurity.scopes.components(separatedBy: " "))
        let record = Registration(id: id, subject: "offline-subject", clientID: "oaiapp_offline", displayName: "Offline check", email: nil, tokens: old)
        let initial = Vault(registrations: [record], activeID: id)
        let writes = ChatGPTFixtureWrites()
        let requests = ChatGPTFixtureRequests(status: 200, body: try JSONSerialization.data(withJSONObject: ["access_token": "offline-new-access", "refresh_token": "offline-new-refresh", "token_type": "Bearer", "expires_in": 3600, "scope": ChatGPTSecurity.scopes]))
        let store = ChatGPTSessionStore(vault: initial, hooks: TestHooks(save: { try writes.save($0) }, request: { try await requests.perform($0) }))
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<24 { group.addTask { try await store.accessToken(expectedAccountID: id) } }
            for try await token in group { guard token == "offline-new-access" else { throw ChatGPTSignInError.identity } }
        }
        guard await requests.count == 1, writes.values.count == 1,
              let saved = writes.values.first?.data(using: .utf8), let committed = try? JSONDecoder().decode(Vault.self, from: saved),
              committed.registrations.first?.tokens?.access == "offline-new-access", committed.registrations.first?.tokens?.refresh == "offline-new-refresh" else { throw ChatGPTSignInError.identity }
        do { _ = try await store.accessToken(expectedAccountID: "another-account"); throw ChatGPTSignInError.identity } catch ChatGPTSignInError.accountChanged {}
        for (status, body, expected) in [(429, "{}", ChatGPTSignInError.unavailable), (400, "{\"error\":\"token_issued_too_early\"}", .refreshTooEarly), (400, "{\"error\":\"temporarily_unavailable\"}", .network)] {
            let temporary = ChatGPTFixtureRequests(status: status, body: Data(body.utf8))
            let store = ChatGPTSessionStore(vault: initial, hooks: TestHooks(save: { _ in throw ChatGPTSignInError.identity }, request: { try await temporary.perform($0) }))
            do { _ = try await store.accessToken(expectedAccountID: id); throw ChatGPTSignInError.identity }
            catch let error as ChatGPTSignInError { guard error == expected else { throw error } }
            guard try await store.snapshot().active?.id == id else { throw ChatGPTSignInError.identity }
        }
        let identityResponse = try JSONDecoder().decode(TokenResponse.self, from: Data("{\"id_token\":\"offline-id-token\",\"scope\":\"openid profile email\"}".utf8))
        let identityTokens = try await store.tokens(identityResponse, old: nil, idToken: "offline-id-token", refresh: "", scope: identityResponse.scope)
        var identityRecord = record; identityRecord.tokens = identityTokens
        let identityOnly = ChatGPTSessionStore(vault: Vault(registrations: [identityRecord], activeID: id), hooks: TestHooks(save: { _ in throw ChatGPTSignInError.identity }, request: { _ in throw ChatGPTSignInError.identity }))
        let identitySnapshot = try await identityOnly.snapshot()
        guard identitySnapshot.active?.id == id, identitySnapshot.active?.planEnabled == false else { throw ChatGPTSignInError.identity }
        do { _ = try await identityOnly.accessToken(expectedAccountID: id); throw ChatGPTSignInError.identity } catch ChatGPTSignInError.permission {}
        let invalid = ChatGPTFixtureRequests(status: 400, body: Data("{\"error\":\"invalid_grant\"}".utf8))
        let invalidWrites = ChatGPTFixtureWrites()
        let terminal = ChatGPTSessionStore(vault: initial, hooks: TestHooks(save: { try invalidWrites.save($0) }, request: { try await invalid.perform($0) }))
        do { _ = try await terminal.accessToken(expectedAccountID: id); throw ChatGPTSignInError.identity } catch ChatGPTSignInError.signInRequired {}
        let snapshot = try await terminal.snapshot()
        guard snapshot.active == nil, snapshot.profiles.count == 1, invalidWrites.values.count == 1 else { throw ChatGPTSignInError.identity }
    }
}
private final class ChatGPTFixtureWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func save(_ value: String) throws { lock.withLock { storage.append(value) } }
}
private actor ChatGPTFixtureRequests {
    private let status: Int
    private let body: Data
    private(set) var count = 0
    init(status: Int, body: Data) { self.status = status; self.body = body }
    func perform(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.absoluteString == "https://auth.openai.com/api/accounts/oauth/token",
              request.httpMethod == "POST", let data = request.httpBody, let form = String(data: data, encoding: .utf8),
              form.contains("client_id=oaiapp_offline"), form.contains("grant_type=refresh_token"), form.contains("refresh_token=offline-old-refresh") else { throw ChatGPTSignInError.identity }
        count += 1
        try await Task.sleep(for: .milliseconds(15))
        return (body, status)
    }
}
#endif
