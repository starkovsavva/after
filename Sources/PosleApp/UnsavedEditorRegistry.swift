import Foundation

/// Editors register only unsaved user text. The app can protect Quit and
/// updates without inventing partial saves or knowing an editor's data format.
@MainActor
enum UnsavedEditorRegistry {
    private static var entries: [UUID: String] = [:]
    static var hasUnsaved: Bool { !entries.isEmpty }
    static var titles: [String] { entries.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    static func set(id: UUID, title: String, dirty: Bool) {
        let previous = entries[id]
        if dirty { entries[id] = title }
        else { entries.removeValue(forKey: id) }
        if entries[id] != previous { NotificationCenter.default.post(name: .posleUnsavedEditorsChanged, object: nil) }
    }
    static func remove(id: UUID) {
        if entries.removeValue(forKey: id) != nil { NotificationCenter.default.post(name: .posleUnsavedEditorsChanged, object: nil) }
    }
}
extension Notification.Name {
    static let posleUnsavedEditorsChanged = Notification.Name("PosleUnsavedEditorsChanged")
}
