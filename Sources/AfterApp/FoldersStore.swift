import AfterPlatformMacOS
import Foundation
import AfterCore

@MainActor
extension NotesStore {
    var folders: [LibraryFolder] {
        workspace.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func folder(_ id: String?) -> LibraryFolder? {
        guard let id else { return nil }
        return workspace.folders.first { $0.id == id }
    }
    func folder(for meetingID: String) -> LibraryFolder? { folder(context(for: meetingID).folderID) }
    @discardableResult func saveFolder(_ folder: LibraryFolder) -> LibraryFolder? {
        do {
            let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(folder))
            let data = try RustBridge.shared.get().request(root: root, command: "folder-save", arguments: ["folder": value])
            let saved = try JSONDecoder().decode(LibraryFolder.self, from: data)
            error = nil; reload()
            return saved
        } catch { self.error = error.localizedDescription; return nil }
    }
    @discardableResult func deleteFolder(_ folder: LibraryFolder) -> Bool {
        do {
            _ = try RustBridge.shared.get().request(root: root, command: "folder-delete", arguments: ["id": folder.id, "revision": folder.revision])
            error = nil; reload(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func assignMeetingFolder(_ meetingID: String, folderID: String?) -> Bool {
        do {
            let context = context(for: meetingID)
            _ = try RustBridge.shared.get().request(root: root, command: "folder-assign-meeting", arguments: [
                "meetingID": meetingID, "folderID": folderID as Any? ?? NSNull(), "revision": context.revision
            ])
            error = nil; reload(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
