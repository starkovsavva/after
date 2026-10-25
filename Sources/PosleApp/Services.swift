import AppKit
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

    init(event: String, message: String? = nil) {
        self.event = event; self.message = message
    }

    private enum CodingKeys: String, CodingKey { case event, message, fraction, models, model, ggufModels, asrModels, notes }
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
    func run(_ executable: URL, arguments: [String], environment: [String: String] = [:],
             event: @escaping @Sendable (WorkerEvent) -> Void) async throws -> WorkerEvent? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WorkerEvent?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let completion = WorkerEventResult()
                let process = Process()
                let output = Pipe(), errors = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output; process.standardError = errors
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                self.lock.lock(); self.process = process; self.lock.unlock()
                defer { self.lock.lock(); self.process = nil; self.lock.unlock() }
                do { try process.run() }
                catch { continuation.resume(throwing: error); return }
                self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
                if cancelled, process.isRunning { process.terminate() }
                // Read stderr even when noisy downloads/ffmpeg fill the OS pipe buffer.
                let group = DispatchGroup()
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

enum Keychain {
    private static let service = "app.posle.meetings"
    static func read() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "openai",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "openai"]
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
        let base = root.appendingPathComponent("runtime/ollama")
        let candidates = [base.appendingPathComponent("bin/ollama"), base.appendingPathComponent("ollama")]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw AppError.message("В настройках нажмите «Подготовить локальный ИИ» или выберите установленную Ollama / LM Studio.")
        }
        let p = Process(); p.executableURL = binary; p.arguments = ["serve"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.environment = ProcessInfo.processInfo.environment.merging([
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
