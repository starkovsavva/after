import AppKit
import Darwin
import CryptoKit
import Foundation
import PosleCore
import Security

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

struct InstalledLocalModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var provider: String
    var endpoint: String
}

struct InstalledASRModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var format: String
    var source: String
    var compatible: Bool
    var reason: String
}

struct InstalledGGUFModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var source: String
    var sizeBytes: Int64
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

struct WorkerEvent: Decodable {
    var event: String
    var message: String?
    var fraction: Double?
    var models: [String]?
    var model: String?
    var ggufModels: [InstalledGGUFModel]?
    var installedModels: [InstalledLocalModel]?
    var asrModels: [InstalledASRModel]?
    var notes: [String]?
    var voicePlan: VoicePlan?

    init(event: String, message: String? = nil) {
        self.event = event; self.message = message
    }

    private enum CodingKeys: String, CodingKey { case event, message, fraction, models, model, ggufModels, asrModels, notes, voicePlan }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        event = try values.decode(String.self, forKey: .event)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        fraction = try values.decodeIfPresent(Double.self, forKey: .fraction)
        models = try? values.decode([String].self, forKey: .models)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        ggufModels = try values.decodeIfPresent([InstalledGGUFModel].self, forKey: .ggufModels)
        installedModels = try? values.decode([InstalledLocalModel].self, forKey: .models)
        asrModels = try values.decodeIfPresent([InstalledASRModel].self, forKey: .asrModels)
        notes = try values.decodeIfPresent([String].self, forKey: .notes)
        voicePlan = try values.decodeIfPresent(VoicePlan.self, forKey: .voicePlan)
    }
}

private final class WorkerEventResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: WorkerEvent?
    func record(_ event: WorkerEvent) {
        guard event.event == "done" else { return }
        lock.lock(); result = event; lock.unlock()
    }
    var value: WorkerEvent? { lock.lock(); defer { lock.unlock() }; return result }
}

/// Drain both pipes concurrently. A subprocess never runs on the main thread.
final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func resetCancellation() { lock.lock(); cancelled = false; lock.unlock() }

    func cancel() {
        lock.lock(); cancelled = true; let current = process; lock.unlock()
        if current?.isRunning == true { current?.terminate() }
    }

    @discardableResult
    func run(_ executable: URL, arguments: [String], environment: [String: String] = [:], input: Data? = nil,
             event: @escaping @Sendable (WorkerEvent) -> Void) async throws -> WorkerEvent? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WorkerEvent?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let completion = WorkerEventResult()
                let process = Process()
                let output = Pipe(), errors = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                let inputPipe = input.map { _ in Pipe() }
                if let inputPipe { _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
                process.standardInput = inputPipe ?? FileHandle.nullDevice as Any
                process.standardOutput = output; process.standardError = errors
                process.environment = ProcessEnvironment.withoutSecrets(ProcessInfo.processInfo.environment).merging(environment) { _, new in new }
                self.lock.lock(); self.process = process; self.lock.unlock()
                defer { self.lock.lock(); self.process = nil; self.lock.unlock() }
                do { try process.run() }
                catch { continuation.resume(throwing: error); return }
                self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
                if cancelled, process.isRunning { process.terminate() }
                // Read stderr even when noisy downloads/ffmpeg fill the OS pipe buffer.
                let group = DispatchGroup()
                if let input, let inputPipe {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { try? inputPipe.fileHandleForWriting.close(); group.leave() }
                        try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                    }
                }
                let diagnostic = LockedTail()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    while true {
                        let data = errors.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        diagnostic.append(data)
                    }
                    group.leave()
                }
                var pending = Data()
                var lastError: String?
                func deliver(_ data: Data) {
                    if let decoded = try? JSONDecoder().decode(WorkerEvent.self, from: data) {
                        if decoded.event == "error" { lastError = decoded.message }
                        completion.record(decoded)
                        event(decoded)
                    } else if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                        event(WorkerEvent(event: "progress", message: String(line.suffix(240))))
                    }
                }
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    while let newline = pending.firstIndex(of: 10) {
                        deliver(pending.subdata(in: 0..<newline))
                        pending.removeSubrange(0...newline)
                    }
                }
                if !pending.isEmpty { deliver(pending) }
                process.waitUntilExit()
                group.wait()
                if process.terminationStatus == 0 { continuation.resume(returning: completion.value) }
                else {
                    let fallback = process.terminationReason == .uncaughtSignal
                        ? "Обработка остановлена. Исходная запись сохранена."
                        : "Не удалось завершить обработку. \(diagnostic.text)"
                    continuation.resume(throwing: AppError.message(lastError ?? fallback))
                }
            }
        }
    }
}

private final class LockedTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(value)
        if data.count > 2000 { data = data.suffix(2000) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? "Откройте настройки и проверьте установку моделей."
    }
}

enum ProcessEnvironment {
    static func withoutSecrets(_ values: [String: String]) -> [String: String] {
        values.filter { key, _ in
            let name = key.uppercased()
            return !["API_KEY", "ACCESS_KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "COOKIE"].contains { name.contains($0) }
        }
    }
}

enum Keychain {
    private static let service = "app.posle.meetings"
    static func account(for settings: AppSettings) -> String {
        switch settings.cloudProvider {
        case "openai": return "openai" // Preserve the key from releases before provider selection.
        case "openrouter": return "cloud.openrouter"
        case "polza": return "cloud.polza"
        default: return scopedAccount(prefix: "cloud.custom", endpoint: settings.cloudEndpoint)
        }
    }
    static func speechAccount(for settings: AppSettings) -> String {
        switch settings.speechCloudProvider {
        case "openai": return "speech.openai"
        default: return scopedAccount(prefix: "speech.custom", endpoint: settings.speechCloudEndpoint)
        }
    }
    private static func scopedAccount(prefix: String, endpoint: String) -> String {
        let raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: raw)
        let scheme = components?.scheme?.lowercased(), host = components?.host?.lowercased()
        components?.scheme = scheme; components?.host = host
        if (components?.scheme == "https" && components?.port == 443) || (components?.scheme == "http" && components?.port == 80) { components?.port = nil }
        if var path = components?.percentEncodedPath {
            while path.hasSuffix("/") { path.removeLast() }
            components?.percentEncodedPath = path
        }
        let normalized = components?.string ?? raw
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return prefix + "." + digest
    }
    static func read(account: String = "openai") -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ key: String, account: String = "openai") throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppError.message("Связка ключей не разрешила удалить ключ: \(status)")
            }
            return
        }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        let status = update == errSecItemNotFound
            ? SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) : update
        guard status == errSecSuccess else { throw AppError.message("Связка ключей не сохранила ключ: \(status)") }
    }
}

/// Give the private, app-owned model runtime real executable identities. Keeping
/// compatibility symlinks in the same directory preserves Ollama's library and
/// llama-server discovery without changing argv or touching external providers.
enum ManagedModelRuntime {
    static let serverName = "После ИИ"
    static let modelName = "После Модель"

    static func brandedExecutable(root: URL) throws -> URL {
        let manager = FileManager.default
        let runtime = root.appendingPathComponent("runtime")
        let base = runtime.appendingPathComponent("ollama")
        try ownedDirectory(runtime)
        try ownedDirectory(base)
        let lockURL = base.appendingPathComponent(".posle-identity.lock")
        let descriptor = lockURL.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw failure() }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == getuid(), flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw failure() }
        defer { flock(descriptor, LOCK_UN) }
        let bin = base.appendingPathComponent("bin")
        if manager.fileExists(atPath: bin.path) { try ownedDirectory(bin) }
        let candidates = [bin, base]
        guard let directory = candidates.first(where: {
            exists($0.appendingPathComponent("ollama")) || exists($0.appendingPathComponent(serverName))
        }) else {
            throw AppError.message("В настройках нажмите «Подготовить локальный ИИ» или выберите установленную Ollama / LM Studio.")
        }
        let server = try brand(directory: directory, original: "ollama", display: serverName)
        let modelDirectories = [directory, base.appendingPathComponent("lib/ollama")]
        if let models = modelDirectories.first(where: {
            exists($0.appendingPathComponent("llama-server")) || exists($0.appendingPathComponent(modelName))
        }) {
            if models != directory {
                try ownedDirectory(base.appendingPathComponent("lib"))
                try ownedDirectory(models)
            }
            _ = try brand(directory: models, original: "llama-server", display: modelName)
        }
        return server
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func ownedDirectory(_ url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeDirectory,
              (values[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw failure() }
    }

    private static func ownedExecutable(_ url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              (values[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              FileManager.default.isExecutableFile(atPath: url.path) else { throw failure() }
    }

    private static func brand(directory: URL, original: String, display: String) throws -> URL {
        try ownedDirectory(directory)
        let manager = FileManager.default
        let source = directory.appendingPathComponent(original)
        let destination = directory.appendingPathComponent(display)
        if exists(destination) { try ownedExecutable(destination) }
        if let values = try? manager.attributesOfItem(atPath: source.path) {
            if values[.type] as? FileAttributeType == .typeSymbolicLink {
                guard try manager.destinationOfSymbolicLink(atPath: source.path) == display else { throw failure() }
                try ownedExecutable(destination)
                return destination
            }
            try ownedExecutable(source)
            // rename is atomic, keeps the verified Mach-O bytes/signature and
            // replaces a previous branded version only after a runtime update.
            let result = source.path.withCString { from in
                destination.path.withCString { to in Darwin.rename(from, to) }
            }
            guard result == 0 else { throw failure() }
        } else {
            // Recover if an earlier launch stopped between rename and symlink.
            try ownedExecutable(destination)
        }
        try manager.createSymbolicLink(atPath: source.path, withDestinationPath: display)
        return destination
    }

    private static func failure() -> AppError {
        .message("Не удалось подготовить процессы локального ИИ. Повторите подготовку в настройках.")
    }
}

@MainActor
final class LocalModelService {
    private var process: Process?
    private var port = 11436
    private var externalURL: String?
    var baseURL: String { externalURL ?? "http://127.0.0.1:\(port)" }
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        return URLSession(configuration: configuration)
    }()

    static func validatedEndpoint(_ value: String) throws -> String {
        guard let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              ["", "/"].contains(components.path) else {
            throw AppError.message("Укажите локальный адрес сервера без /v1, например http://127.0.0.1:1234. Номер порта должен быть от 1 до 65535.")
        }
        var clean = components
        clean.path = ""
        guard let endpoint = clean.string else { throw AppError.message("Проверьте адрес локального сервера.") }
        return endpoint
    }

    func ensure(root: URL, settings: AppSettings, cancelled: @MainActor () -> Bool = { false }) async throws {
        guard !cancelled() else { throw AppError.message("Обработка остановлена. Запись сохранена.") }
        if settings.localProvider != "managed" {
            guard ["ollama", "lmstudio"].contains(settings.localProvider) else {
                throw AppError.message("Выберите После, Ollama или LM Studio в настройках.")
            }
            stop()
            externalURL = try Self.validatedEndpoint(settings.resolvedLocalEndpoint)
            // Rust checks connection, HTTP errors and the actual selected model.
            // This service owns only the managed process; external servers are untouched.
            guard !cancelled() else { throw AppError.message("Обработка остановлена. Запись сохранена.") }
            return
        }
        externalURL = nil
        if process?.isRunning == true, await healthy() { return }
        if process != nil { stop() }
        // The managed service owns its port and model cache. External servers are selected explicitly.
        var available = false
        for candidate in 11436...11456 {
            guard !cancelled() else { throw AppError.message("Обработка остановлена. Запись сохранена.") }
            port = candidate
            if !(await healthy()) { available = true; break }
        }
        guard available else { throw AppError.message("Порты локального ИИ заняты. Перезапустите После.") }
        let binary = try ManagedModelRuntime.brandedExecutable(root: root)
        let p = Process(); p.executableURL = binary; p.arguments = ["serve"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.environment = ProcessEnvironment.withoutSecrets(ProcessInfo.processInfo.environment).merging([
            "OLLAMA_HOST": "127.0.0.1:\(port)", "OLLAMA_MODELS": root.appendingPathComponent("cache/ollama-models").path,
            "OLLAMA_NO_CLOUD": "1", "OLLAMA_CONTEXT_LENGTH": "16384", "OLLAMA_NUM_PARALLEL": "1",
            "OLLAMA_MAX_LOADED_MODELS": "1", "OLLAMA_KEEP_ALIVE": "0"
        ]) { _, new in new }
        try p.run(); process = p
        for _ in 0..<40 {
            guard !cancelled() else { throw AppError.message("Обработка остановлена. Запись сохранена.") }
            if await healthy() { return }
            if !p.isRunning { throw AppError.message("Локальный ИИ не запустился. Повторите подготовку в настройках.") }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AppError.message("Локальный ИИ долго запускается. Повторите через несколько секунд.")
    }
    private func healthy() async -> Bool {
        let path = "/api/tags"
        guard let url = URL(string: baseURL + path) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    func stop() {
        if process?.isRunning == true { process?.terminate() }
        process = nil; externalURL = nil
    }
}
