import AfterCore
import AfterLocalization
import AfterPlatformMacOS
import Combine
import Foundation

/// Library-private view preferences. Each change merges only its own key, so
/// an already mounted notes pane cannot reset the cards pane's saved choice.
@MainActor
final class OriginFilterPreferences: ObservableObject {
    @Published var notesFilters = MaterialFilterSet() { didSet { if notesFilters != oldValue { persist("notes", notesFilters) } } }
    @Published var cardsFilters = MaterialFilterSet() { didSet { if cardsFilters != oldValue { persist("cards", cardsFilters) } } }
    @Published private(set) var error: String?
    private var root: URL?
    private var loading = false
    private let path = "material-filters.json"

    // Compatibility conveniences for older call sites and diagnostics. The
    // filter set remains the sole source of truth.
    var notesFilter: MaterialOriginFilter {
        get { legacyFilter(notesFilters) }
        set { notesFilters.origins = originSet(newValue) }
    }
    var cardsFilter: MaterialOriginFilter {
        get { legacyFilter(cardsFilters) }
        set { cardsFilters.origins = originSet(newValue) }
    }

    func configure(root: URL) {
        let root = root.standardizedFileURL
        guard self.root != root else { return }
        self.root = root; loading = true
        defer { loading = false }
        do {
            let value = try read()
            notesFilters = try decode(value["notes"])
            cardsFilters = try decode(value["cards"])
            error = nil
        } catch {
            notesFilters = MaterialFilterSet(); cardsFilters = MaterialFilterSet()
            self.error = L("Не удалось загрузить фильтр. Показаны все материалы.")
        }
    }

    private func read() throws -> [String: Any] {
        guard let root else { return [:] }
        let data = try RustBridge.shared.get().request(root: root, command: "read", arguments: ["path": path])
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return value as? [String: Any] ?? [:]
    }
    private func legacyFilter(_ filters: MaterialFilterSet) -> MaterialOriginFilter {
        if filters.origins == [.manual] { return .manual }
        if filters.origins == [.ai] { return .ai }
        return .all
    }
    private func originSet(_ filter: MaterialOriginFilter) -> Set<MaterialCreationOrigin> {
        switch filter { case .all: []; case .manual: [.manual]; case .ai: [.ai] }
    }
    private func decode(_ value: Any?) throws -> MaterialFilterSet {
        guard let value else { return MaterialFilterSet() }
        if let scalar = value as? String {
            return MaterialFilterSet(origins: originSet(MaterialOriginFilter(rawValue: scalar) ?? .all))
        }
        return try JSONDecoder().decode(MaterialFilterSet.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func persist(_ key: String, _ filters: MaterialFilterSet) {
        guard !loading, let root else { return }
        do {
            var value = try read()
            var section = value[key] as? [String: Any] ?? [:]
            // A removed experimental condition must never revive as a hidden
            // filter when preferences from the local preview are loaded.
            section.removeValue(forKey: "meaning")
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(filters)) as? [String: Any] ?? [:]
            section.merge(encoded) { _, new in new }
            value["version"] = 2; value[key] = section
            _ = try RustBridge.shared.get().request(root: root, command: "write", arguments: ["path": path, "value": value])
            error = nil
        } catch { self.error = L("Не удалось сохранить фильтр. Выбор действует до закрытия окна.") }
    }
}
