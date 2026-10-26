import CryptoKit
import Darwin
import Foundation
import MachO

/// The expected digest is part of the signed executable's __TEXT segment. A
/// replaceable bundle resource or Info.plist must never establish this trust.
enum NativeLibraryIntegrity {
    enum Failure: LocalizedError {
        case invalidDigest, unsafeLocation, modifiedLibrary, unavailable
        var errorDescription: String? {
            switch self {
            case .invalidDigest: return "В приложении отсутствует проверка Rust-ядра. Переустановите «После»."
            case .unsafeLocation: return "Rust-ядро находится в небезопасном месте. Переустановите «После»."
            case .modifiedLibrary: return "Rust-ядро изменено или повреждено. Переустановите «После»."
            case .unavailable: return "Не удалось загрузить проверенное Rust-ядро. Переустановите «После»."
            }
        }
    }

    static func openCoreLibrary() throws -> UnsafeMutableRawPointer {
        #if DEBUG
        // Isolated native diagnostics use a freshly built, explicitly supplied
        // library. This branch does not exist in distributed release binaries.
        if let path = ProcessInfo.processInfo.environment["POSLE_RUST_LIBRARY"] {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw Failure.unavailable }
            return handle
        }
        #endif
        let expected = try embeddedDigest()
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let canonicalBundle = try canonicalPath(bundle.path)
        let directory = open(bundle.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unsafeLocation }
        defer { close(directory) }
        try validate(directory, directory: true)
        let contents = try openDirectory("Contents", relativeTo: directory)
        defer { close(contents) }
        let frameworks = try openDirectory("Frameworks", relativeTo: contents)
        defer { close(frameworks) }
        let descriptor = openat(frameworks, "libposle_core.dylib", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeLocation }
        defer { close(descriptor) }
        let before = try validate(descriptor, directory: false)
        let path = canonicalBundle + "/Contents/Frameworks/libposle_core.dylib"
        guard try canonicalPath(path) == path else { throw Failure.unsafeLocation }
        var pathInfo = stat()
        guard lstat(path, &pathInfo) == 0, sameFile(before, pathInfo), pathInfo.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeLocation }
        let digest = try sha256(descriptor)
        guard digest == expected else { throw Failure.modifiedLibrary }
        let after = try validate(descriptor, directory: false)
        guard unchanged(before, after), lstat(path, &pathInfo) == 0,
              sameFile(after, pathInfo), pathInfo.st_mode & S_IFMT == S_IFREG,
              try canonicalPath(path) == path else { throw Failure.modifiedLibrary }
        // Hashing consumes this descriptor. dyld's /dev/fd loader must receive
        // the verified file from its beginning, independent of OS fd semantics.
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw Failure.unavailable }
        // Keep the verified inode open through dlopen, so replacing its pathname
        // cannot select another file. This is a tamper-at-rest check, not full
        // protection from a same-UID process concurrently rewriting this inode.
        guard let handle = dlopen("/dev/fd/\(descriptor)", RTLD_NOW | RTLD_LOCAL) else { throw Failure.unavailable }
        return handle
    }

    private static func embeddedDigest() throws -> String {
        // Inserted diagnostic libraries may precede the executable in dyld's
        // image list. Identify the main image through dyld's executable path,
        // never through replaceable CFBundleExecutable metadata or index zero.
        var length: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &length)
        guard length > 0, length < 1024 * 1024 else { throw Failure.invalidDigest }
        var executablePath = [CChar](repeating: 0, count: Int(length))
        guard _NSGetExecutablePath(&executablePath, &length) == 0,
              let executable = try? canonicalPath(String(cString: executablePath)) else { throw Failure.invalidDigest }
        let index = (0..<_dyld_image_count()).first { index in
            guard let imageName = _dyld_get_image_name(index), let path = try? canonicalPath(String(cString: imageName)) else { return false }
            return path == executable
        }
        guard let index, let header = _dyld_get_image_header(index), header.pointee.magic == MH_MAGIC_64 else { throw Failure.invalidDigest }
        var size: UInt = 0
        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(header64, "__TEXT", "__posle_core", &size), size == 64 else { throw Failure.invalidDigest }
        let data = UnsafeBufferPointer(start: bytes, count: 64)
        guard data.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidDigest }
        return String(decoding: data, as: UTF8.self)
    }
    private static func canonicalPath(_ path: String) throws -> String {
        guard let pointer = realpath(path, nil) else { throw Failure.unsafeLocation }
        defer { free(pointer) }; return String(cString: pointer)
    }
    private static func openDirectory(_ name: String, relativeTo parent: Int32) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeLocation }
        do { try validate(descriptor, directory: true); return descriptor }
        catch { close(descriptor); throw error }
    }
    @discardableResult private static func validate(_ descriptor: Int32, directory: Bool) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              value.st_uid == geteuid() || value.st_uid == 0,
              value.st_mode & 0o022 == 0,
              directory || (value.st_size > 0 && value.st_size <= 512 * 1024 * 1024) else { throw Failure.unsafeLocation }
        return value
    }
    private static func sameFile(_ left: stat, _ right: stat) -> Bool { left.st_dev == right.st_dev && left.st_ino == right.st_ino }
    private static func unchanged(_ left: stat, _ right: stat) -> Bool {
        sameFile(left, right) && left.st_size == right.st_size && left.st_mode == right.st_mode && left.st_uid == right.st_uid
        && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
        && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }
    private static func sha256(_ descriptor: Int32) throws -> String {
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw Failure.modifiedLibrary }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
