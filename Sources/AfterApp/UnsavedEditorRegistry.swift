import Foundation

/// Editors register only unsaved user text. The app can protect Quit and
/// updates without inventing partial saves or knowing an editor's data format.
@MainActor
enum UnsavedEditorRegistry {
    private static var entries: [UUID: String] = [:]
    private static var revealers: [UUID: () -> Void] = [:]
    static var hasUnsaved: Bool { !entries.isEmpty }
    static var titles: [String] { entries.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    static func set(id: UUID, title: String, dirty: Bool, reveal: (() -> Void)? = nil) {
        let previous = entries[id]
        if dirty { entries[id] = title; revealers[id] = reveal }
        else { entries.removeValue(forKey: id); revealers.removeValue(forKey: id) }
        if entries[id] != previous { NotificationCenter.default.post(name: .posleUnsavedEditorsChanged, object: nil) }
    }
    /// Only an explicit recovery action invokes callbacks. Legacy editors need
    /// not provide one; dirty/title notifications retain their existing meaning.
    @discardableResult static func revealFirst() -> Bool {
        let ordered = entries.keys.sorted {
            let comparison = (entries[$0] ?? "").localizedStandardCompare(entries[$1] ?? "")
            return comparison == .orderedSame ? $0.uuidString < $1.uuidString : comparison == .orderedAscending
        }
        guard let reveal = ordered.compactMap({ revealers[$0] }).first else { return false }
        reveal(); return true
    }
    static func remove(id: UUID) {
        revealers.removeValue(forKey: id)
        if entries.removeValue(forKey: id) != nil { NotificationCenter.default.post(name: .posleUnsavedEditorsChanged, object: nil) }
    }
}
extension Notification.Name {
    static let posleUnsavedEditorsChanged = Notification.Name("PosleUnsavedEditorsChanged")
}
