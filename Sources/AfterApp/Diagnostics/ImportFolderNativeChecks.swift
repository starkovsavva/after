import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import Foundation
import AfterCore

/// Exercises the real asynchronous Rust import while navigation changes.
@MainActor
enum ImportFolderNativeChecks {
    static func run(store: AppStore) async throws {
        let root = store.root.standardizedFileURL.resolvingSymlinksInPath()
        guard store.isPreview, ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("posle-native-check-") else { throw AppError.message("Import checks require a disposable preview library") }
        guard let english = store.notes.saveFolder(LibraryFolder(name: "Импорт — английский")),
              let work = store.notes.saveFolder(LibraryFolder(name: "Импорт — работа")) else { throw AppError.message(store.notes.error ?? "Cannot create import folders") }
        let source = root.appendingPathComponent("synthetic-import.wav")
        var wave = Data()
        func text(_ value: String) { wave.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) } }
        text("RIFF"); integer(UInt32(356)); text("WAVEfmt "); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(8000)); integer(UInt32(16000)); integer(UInt16(2)); integer(UInt16(16)); text("data"); integer(UInt32(320)); wave.append(Data(repeating: 0, count: 320))
        try wave.write(to: source)
        store.runtimeReady = false
        let scenarios: [(String?, String?, Bool)] = [(english.id, work.id, false), (nil, english.id, false), (work.id, english.id, true)]
        for (destination, nextSidebar, removeDestination) in scenarios {
            let previous = Set(store.meetings.map(\.id))
            store.folderSelection = destination; store.libraryFilter = "Старый фильтр, скрывающий новую встречу"
            store.showingSettings = false; store.error = nil
            store.importFile(source)
            if removeDestination, !store.notes.deleteFolder(work) { throw AppError.message(store.notes.error ?? "Cannot remove import destination") }
            store.folderSelection = nextSidebar
            for _ in 0..<400 {
                if !store.busy && store.meetings.contains(where: { !previous.contains($0.id) }) { break }
                try await Task.sleep(for: .milliseconds(15))
            }
            guard !store.busy, let imported = store.meetings.first(where: { !previous.contains($0.id) }) else { throw AppError.message(store.error ?? "Native import did not finish") }
            let actualDestination = removeDestination ? nil : destination
            guard store.folderID(for: imported.id) == actualDestination, store.folderSelection == actualDestination,
                  store.selection == imported.id, store.librarySection == "meetings", store.tab == "transcript",
                  store.libraryFilter.isEmpty, store.filteredMeetings.contains(where: { $0.id == imported.id }) else {
                throw AppError.message("Imported meeting must stay visible under its captured destination, including explicit no-folder and deleted-folder recovery")
            }
            if removeDestination {
                guard store.error?.contains("Запись сохранена без папки") == true else { throw AppError.message("A deleted destination must expose recovery without starting processing") }
            } else if store.error != nil { throw AppError.message(store.error!) }
            let reopened = NotesStore(root: store.root)
            guard reopened.context(for: imported.id).folderID == actualDestination else { throw AppError.message("Imported destination must survive reopening") }
            store.showingSettings = false
            print("PASS: real WAV import keeps its captured folder and visible selection after sidebar changes; deleted destination=\(removeDestination), no-folder=\(destination == nil)")
        }
    }
}
#endif
