import Foundation

/// Only metadata lives here; API keys remain in their editor until explicitly
/// saved or cancelled. This distinguishes Settings drafts from hidden documents.
@MainActor
enum SettingsDraftRegistry {
    private struct Entry { var title: String; var busy: Bool }
    private static var entries: [UUID: Entry] = [:]
    static var hasUnsaved: Bool { !entries.isEmpty }
    static var isBusy: Bool { entries.values.contains { $0.busy } }
    static var titles: String { Set(entries.values.map(\.title)).sorted().joined(separator: ", ") }
    static func set(id: UUID, title: String, dirty: Bool, busy: Bool = false) {
        let previousBusy = entries[id]?.busy
        if dirty || busy { entries[id] = Entry(title: title, busy: busy) }
        else { entries.removeValue(forKey: id) }
        UnsavedEditorRegistry.set(id: id, title: title, dirty: dirty || busy)
        if let previousBusy, let current = entries[id], current.busy != previousBusy {
            NotificationCenter.default.post(name: .posleUnsavedEditorsChanged, object: nil)
        }
    }
    static func remove(id: UUID) {
        entries.removeValue(forKey: id)
        UnsavedEditorRegistry.remove(id: id)
    }
}
