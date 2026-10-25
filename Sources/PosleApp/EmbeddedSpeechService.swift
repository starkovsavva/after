import Darwin
import Foundation

/// Local ASR executes on the persistent Rust/Python thread inside this app's
/// own PID. The main actor receives only progress and the final result.
final class EmbeddedSpeechService: @unchecked Sendable {
    private typealias Callback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    private typealias Run = @convention(c) (UnsafePointer<CChar>?, Callback?, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    private typealias SetCancelled = @convention(c) (Int32) -> Void
    private typealias Release = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private struct API {
        let handle: UnsafeMutableRawPointer
        let run: Run
        let setCancelled: SetCancelled
        let release: Release
    }
    private let lock = NSLock()
    private var api: API?
    private var cancelled = false
    private var running = false

    /// Call once before dispatching a new job; cancellation is cooperative.
    func resetCancellation() {
        lock.lock(); cancelled = false; let api = api; lock.unlock()
        api?.setCancelled(0)
    }

    func cancel() {
        lock.lock(); cancelled = true; let api = api; lock.unlock()
        api?.setCancelled(1)
    }

    @discardableResult
    func run(root: URL, interpreter: URL, backend: URL, command: String, meeting: URL?,
             speakers: Int = 0, diarization: Bool = true,
             event: @escaping @Sendable (WorkerEvent) -> Void) async throws -> WorkerEvent? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.lock.lock()
                if self.running {
                    self.lock.unlock(); continuation.resume(throwing: AppError.message("Распознавание уже выполняется.")); return
                }
                self.running = true
                self.lock.unlock()
                defer { self.lock.lock(); self.running = false; self.lock.unlock() }
                do {
                    let api = try self.loadAPI()
                    self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
                    if cancelled { throw CancellationError() }
                    var input: [String: Any] = ["root": root.path, "interpreter": interpreter.path, "backend": backend.path,
                                               "command": command, "speakers": speakers, "diarization": diarization]
                    if let meeting { input["meeting"] = meeting.path }
                    let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                    let context = EmbeddedSpeechCallback(event)
                    let retained = Unmanaged.passRetained(context)
                    defer { retained.release() }
                    let callback: Callback = { line, pointer in
                        guard let line, let pointer else { return }
                        let context = Unmanaged<EmbeddedSpeechCallback>.fromOpaque(pointer).takeUnretainedValue()
                        guard let event = try? JSONDecoder().decode(WorkerEvent.self, from: Data(String(cString: line).utf8)) else { return }
                        context.event(event)
                    }
                    let response: Data = try String(decoding: data, as: UTF8.self).withCString { input in
                        guard let output = api.run(input, callback, retained.toOpaque()) else {
                            throw AppError.message("Встроенное распознавание вернуло пустой ответ.")
                        }
                        defer { api.release(output) }
                        return Data(String(cString: output).utf8)
                    }
                    guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
                        throw AppError.message("Некорректный ответ встроенного распознавания.")
                    }
                    guard envelope["ok"] as? Bool == true else {
                        if envelope["cancelled"] as? Bool == true { throw CancellationError() }
                        throw AppError.message(envelope["error"] as? String ?? "Не удалось завершить распознавание.")
                    }
                    let value: WorkerEvent?
                    if let result = envelope["value"] as? [String: Any] {
                        value = try JSONDecoder().decode(WorkerEvent.self, from: JSONSerialization.data(withJSONObject: result))
                    } else { value = nil }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func loadAPI() throws -> API {
        lock.lock(); defer { lock.unlock() }
        if let api { return api }
        let path = ProcessInfo.processInfo.environment["POSLE_RUST_LIBRARY"] ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libposle_core.dylib").path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw AppError.message("Не удалось загрузить Rust-ядро распознавания.")
        }
        guard let run = dlsym(handle, "posle_speech_run"), let cancel = dlsym(handle, "posle_speech_set_cancelled"),
              let release = dlsym(handle, "posle_free_string") else {
            dlclose(handle)
            throw AppError.message("Версия ядра распознавания не соответствует приложению.")
        }
        let loaded = API(handle: handle, run: unsafeBitCast(run, to: Run.self),
                         setCancelled: unsafeBitCast(cancel, to: SetCancelled.self), release: unsafeBitCast(release, to: Release.self))
        loaded.setCancelled(cancelled ? 1 : 0)
        api = loaded
        return loaded
    }
}

private final class EmbeddedSpeechCallback: @unchecked Sendable {
    let event: @Sendable (WorkerEvent) -> Void
    init(_ event: @escaping @Sendable (WorkerEvent) -> Void) { self.event = event }
}
