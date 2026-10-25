import Darwin
import Foundation

/// Stable JSON C ABI. UI models remain Swift values; persistence is owned by Rust.
final class RustBridge: @unchecked Sendable {
    private typealias Invoke = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias Release = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private let handle: UnsafeMutableRawPointer
    private let invoke: Invoke
    private let release: Release
    static let shared: Result<RustBridge, Error> = Result { try RustBridge() }

    private init() throws {
        let library: URL
        if let path = ProcessInfo.processInfo.environment["POSLE_RUST_LIBRARY"] { library = URL(fileURLWithPath: path) }
        else { library = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libposle_core.dylib") }
        guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
            throw AppError.message("Не удалось загрузить Rust-ядро. Откройте собранное После.app целиком.")
        }
        guard let request = dlsym(handle, "posle_request"), let free = dlsym(handle, "posle_free_string") else {
            dlclose(handle)
            throw AppError.message("Версия Rust-ядра не соответствует приложению.")
        }
        self.handle = handle
        invoke = unsafeBitCast(request, to: Invoke.self)
        release = unsafeBitCast(free, to: Release.self)
    }

    func request(root: URL, command: String, arguments: [String: Any] = [:]) throws -> Data {
        var input = arguments; input["root"] = root.path; input["command"] = command
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let string = String(decoding: data, as: UTF8.self)
        let response: Data = try string.withCString { pointer in
            guard let output = invoke(pointer) else { throw AppError.message("Rust-ядро вернуло пустой ответ") }
            defer { release(output) }
            return Data(String(cString: output).utf8)
        }
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw AppError.message("Некорректный ответ Rust-ядра")
        }
        guard envelope["ok"] as? Bool == true else {
            throw AppError.message(envelope["error"] as? String ?? "Ошибка ядра библиотеки")
        }
        return try JSONSerialization.data(withJSONObject: envelope["value"] ?? NSNull(), options: [.fragmentsAllowed])
    }
    func read(root: URL, url: URL) throws -> Data {
        try request(root: root, command: "read", arguments: ["path": relative(root: root, url: url)])
    }
    func write<T: Encodable>(root: URL, url: URL, value: T) throws {
        let encoded = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        _ = try request(root: root, command: "write", arguments: ["path": relative(root: root, url: url), "value": object])
    }
    private func relative(root: URL, url: URL) throws -> String {
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { throw AppError.message("Файл находится вне библиотеки встреч") }
        return String(path.dropFirst(prefix.count))
    }
}
