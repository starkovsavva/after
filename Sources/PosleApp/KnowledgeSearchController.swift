import Combine
import Foundation
import PosleCore

/// Search runs on a utility thread; a generation prevents a late result from
/// replacing a newer query or navigating after the search has been dismissed.
@MainActor
final class KnowledgeSearchController: ObservableObject {
    @Published private(set) var sources: [KnowledgeSource] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var searching = false
    @Published private(set) var openingID: String?
    @Published private(set) var error: String?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private static var activeNetwork: Task<Data, Error>?
    private static var activeNetworkID: UUID?
    func cancel() { generation = UUID(); work?.cancel(); work = nil; searching = false; openingID = nil }
    #if DEBUG
    func seedPreview(_ values: [KnowledgeSource]) {
        cancel(); sources = values; warnings = []; error = nil
    }
    #endif
    func update(store: AppStore, query: String, scope: String, immediate: Bool) {
        cancel(); sources = []; warnings = []; error = nil
        guard store.isFeatureEnabled(.semanticSearch),
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let features = store.visibleFeatures, folderID = store.folderSelection
        guard features.normalizedSearchScope(scope, byMeaning: true) == scope else { return }
        let current = generation, root = store.root, preview = store.isPreview
        searching = true
        work = Task {
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(350)) }
                // A cancelled observer cannot cancel a blocking FFI request.
                // Drain that single request before admitting the latest query;
                // superseded queries stop here without starting another call.
                if let previous = Self.activeNetwork { _ = try? await previous.value }
                try Task.checkCancellation()
                guard current == generation else { return }
                guard store.visibleFeatures == features && store.folderSelection == folderID else { cancel(); sources = []; return }
                var args: [String: Any] = ["text": query, "query": query]
                let kinds = ["notes":["note"], "tasks":["task"], "cards":["card"], "meetings":["meeting"], "transcript":["transcript"], "code":["code"]]
                args["kinds"] = kinds[scope] ?? features.knowledgeSearchKinds
                if let folderID { args["folderID"] = folderID }
                if !preview {
                    struct Envelope: Decodable { var config: SemanticSearchConfiguration; var fingerprint: String }
                    let data = try RustBridge.shared.get().request(root: root, command: "semantic-config")
                    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                    let config = envelope.config
                    if config.enabled, let account = config.keyAccount { let key = try Keychain.readChecked(account: account); if !key.isEmpty { args["embeddingAPIKey"] = key; args["embeddingConfigFingerprint"] = envelope.fingerprint } }
                }
                let request = args
                let networkID = UUID()
                let network = Task.detached(priority: .utility) { try RustBridge.shared.get().request(root: root, command: "knowledge-search", arguments: request) }
                Self.activeNetwork = network; Self.activeNetworkID = networkID
                let data: Data
                do { data = try await network.value }
                catch {
                    if Self.activeNetworkID == networkID { Self.activeNetwork = nil; Self.activeNetworkID = nil }
                    throw error
                }
                if Self.activeNetworkID == networkID { Self.activeNetwork = nil; Self.activeNetworkID = nil }
                struct Results: Decodable { var sources: [KnowledgeSource]; var warnings: [String]; var truncated: Bool }
                let results = try JSONDecoder().decode(Results.self, from: data)
                guard current == generation, !Task.isCancelled else { return }
                guard store.visibleFeatures == features && store.folderSelection == folderID else { cancel(); sources = []; return }
                sources = results.sources.filter { store.permitsKnowledgeSource($0) }; warnings = results.warnings
                if results.truncated { warnings.append("Показана часть найденных источников. Уточните запрос, чтобы сузить поиск.") }
                searching = false
            } catch {
                guard current == generation else { return }
                guard store.visibleFeatures == features && store.folderSelection == folderID else { cancel(); sources = []; return }
                searching = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func open(_ source: KnowledgeSource, store: AppStore) {
        guard store.isFeatureEnabled(.semanticSearch), store.permitsKnowledgeSource(source) else {
            cancel(); sources = []; return
        }
        guard openingID == nil, sources.contains(source) else { return }
        let features = store.visibleFeatures, folderID = store.folderSelection
        let current = generation, root = store.root; openingID = source.id; error = nil
        work = Task {
            do {
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))
                let valid = try await Task.detached(priority: .userInitiated) {
                    struct Validation: Decodable { var valid: Bool }
                    return try JSONDecoder().decode(Validation.self, from: RustBridge.shared.get().request(root: root, command: "knowledge-validate-source", arguments: ["source": object])).valid
                }.value
                guard current == generation, !Task.isCancelled, sources.contains(source) else { return }
                guard store.visibleFeatures == features && store.folderSelection == folderID, store.permitsKnowledgeSource(source) else { cancel(); sources = []; return }
                openingID = nil
                guard valid else { throw AppError.message("Источник изменился или удалён. Повторите поиск.") }
                try store.revealKnowledgeSource(source)
                store.showingSearch = false
            } catch {
                guard current == generation else { return }
                guard store.visibleFeatures == features && store.folderSelection == folderID else { cancel(); sources = []; return }
                openingID = nil; self.error = error.localizedDescription
            }
        }
    }
}
