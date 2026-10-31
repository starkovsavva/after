import AfterPlatform
import AfterLocalization
import Darwin
import Foundation

/// Only regular, private files directly inside this meeting may be opened or
/// exported. Open each component without following links; copy through the same
/// descriptor so replacement of a path cannot redirect an export.
package enum MeetingMediaAccess {
    package static func fileURL(root: URL, meetingID: String, name: String) -> URL? {
        guard let descriptor = try? openFile(root: root, meetingID: meetingID, name: name) else { return nil }
        close(descriptor)
        return root.appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent(meetingID, isDirectory: true).appendingPathComponent(name)
    }

    package static func directoryURL(root: URL, meetingID: String) -> URL? {
        guard !meetingID.isEmpty, meetingID != ".", meetingID != "..", !meetingID.contains("/"), !meetingID.contains("\\"), !meetingID.contains("\0") else { return nil }
        let library = root.resolvingSymlinksInPath().appendingPathComponent("meetings", isDirectory: true)
        let directory = library.appendingPathComponent(meetingID, isDirectory: true)
        for candidate in [library, directory] {
            guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        }
        return directory
    }

    package static func copy(root: URL, meetingID: String, name: String, to destination: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard destination.isFileURL, parent.path != rootPath, !parent.path.hasPrefix(rootPath + "/") else {
            throw AppError.message(L("Сохраните копию вне папки данных After."))
        }
        let descriptor = try openFile(root: root, meetingID: meetingID, name: name)
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        let temporary = parent.appendingPathComponent(".after-export-" + UUID().uuidString)
        let outputDescriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard outputDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty { try output.write(contentsOf: bytes) }
        try output.synchronize(); try output.close()
        // Atomic rename replaces a destination link itself; it never follows it.
        let result = temporary.path.withCString { from in destination.path.withCString { to in rename(from, to) } }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func openFile(root: URL, meetingID: String, name: String) throws -> Int32 {
        func validComponent(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
        }
        guard validComponent(meetingID), validComponent(name) else { throw unavailable }
        let canonical = root.resolvingSymlinksInPath()
        var directory = canonical.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard directory >= 0 else { throw unavailable }
        defer { close(directory) }
        for component in ["meetings", meetingID] {
            let next = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw unavailable }
            close(directory); directory = next
        }
        let descriptor = name.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw unavailable }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1, information.st_size > 0 else { close(descriptor); throw unavailable }
        return descriptor
    }
    private static var unavailable: Error { AppError.message(L("Медиафайл недоступен. Проверьте файлы встречи.")) }
}
