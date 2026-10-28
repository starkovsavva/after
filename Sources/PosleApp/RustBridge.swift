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
        let handle = try NativeLibraryIntegrity.openCoreLibrary()
        guard let request = dlsym(handle, "posle_request"), let free = dlsym(handle, "posle_free_string") else {
            dlclose(handle)
            throw AppError.message(L("Версия Rust-ядра не соответствует приложению."))
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
            guard let output = invoke(pointer) else { throw AppError.message(L("Rust-ядро вернуло пустой ответ")) }
            defer { release(output) }
            return Data(String(cString: output).utf8)
        }
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw AppError.message(L("Некорректный ответ Rust-ядра"))
        }
        guard envelope["ok"] as? Bool == true else {
            throw AppError.message(envelope["error"] as? String ?? L("Ошибка ядра библиотеки"))
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
        // Foundation shortens an existing /private/tmp root to /tmp while a new
        // child retains /private/tmp. Compare equivalent root spellings only.
        // Preserve the child's lexical path so Rust can reject symlinks itself;
        // resolving it here could redirect a write to another meeting.
        var rootPaths = [root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
        if let canonical = root.path.withCString({ realpath($0, nil) }) {
            rootPaths.append(String(cString: canonical)); free(canonical)
        }
        let path = url.path
        for rootPath in rootPaths {
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        throw AppError.message(L("Файл находится вне библиотеки встреч"))
    }
}
