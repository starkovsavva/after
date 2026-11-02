import AfterCore
import AfterLocalization
import AfterPlatform
import Combine
import Foundation

enum MaterialFilterTarget: Equatable, Sendable { case notes, cards }

struct MaterialFilterTopic: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let noteIDs: Set<String>
    let meetingIDs: Set<String>
}

/// Filters use explicit membership of the selected Knowledge Base topics.
@MainActor
final class MaterialFilterController: ObservableObject {
    typealias Request = KnowledgeMixedTopicsController.Request
    @Published private(set) var topics: [MaterialFilterTopic] = []
    @Published private(set) var topicsLoading = false
    @Published private(set) var canLoadMoreTopics = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var resultsRevision = UUID()

    private struct Context: Equatable {
        let root: URL
        let folderID: String?
        let features: AppFeatures
        let revision: String
        @MainActor init(store: AppStore, revision: String) {
            root = store.root.standardizedFileURL; folderID = store.folderSelection
            features = store.visibleFeatures; self.revision = revision
        }
        @MainActor func isCurrent(_ store: AppStore) -> Bool {
            root == store.root.standardizedFileURL && folderID == store.folderSelection && features == store.visibleFeatures
        }
    }
    private struct Version: Decodable, Equatable, Sendable {
        let workspaceRevision: UInt64
        let kbRevision: UInt64
    }
    private struct TopicSource: Decodable, Sendable { let noteID: String }
    private struct TopicGroup: Decodable, Sendable {
        let id: String
        let terms: [String]
        let sources: [TopicSource]
    }
    private struct Collection: Decodable, Sendable {
        let id: String
        let name: String
        let nameRedacted: Bool
        let hidden: Bool
        let sources: [TopicSource]
    }
    private struct TopicPage: Decodable, Sendable {
        let topics: [TopicGroup]
        let collections: [Collection]
        let nextOffset: Int?
        let partial: Bool
        let noteLimitReached: Bool
        let topicLimitReached: Bool
    }
    private struct Catalog: Sendable {
        var rows: [String: MaterialFilterTopic] = [:]
        var version: Version?
        var noteOffset: Int? = 0
        var mixedOffset: Int? = 0
        var partial = false
        var capped = false
        var errors: [String] = []
    }

    private let request: Request
    private weak var store: AppStore?
    private var context: Context?
    private var selectedTopicIDs: Set<String> = []
    private var topicError: String?
    private var topicContext: Context?
    private var catalog = Catalog()
    private var topicsRequested = false
    private var topicsLoaded = false
    private var topicGeneration = UUID()
    private var topicRequestID: String?
    private var topicTask: Task<Void, Never>?
    nonisolated private static let topicLimit = 1_000
    nonisolated private static let pagesPerBatch = 5

    init(request: @escaping Request = KnowledgeMixedTopicsController.liveRequest) {
        self.request = request
    }

    func update(store: AppStore, filters: MaterialFilterSet, target: MaterialFilterTarget, revision: String = "") {
        self.store = store
        let next = Context(store: store, revision: revision)
        if context != next {
            context = next
            stopTopics(clear: true)
        }
        selectedTopicIDs = filters.topicIDs
        if !selectedTopicIDs.isEmpty || topicsRequested { loadTopics(store: store) }
        refreshMessages()
    }

    func loadTopics(store: AppStore) {
        self.store = store; topicsRequested = true
        let next = Context(store: store, revision: context?.revision ?? "")
        if context != next { context = next; stopTopics(clear: true) }
        guard store.isFeatureEnabled(.knowledgeBase) else {
            stopTopics(clear: true)
            topicError = L("Для фильтра по теме источника включите базу знаний в настройках → Возможности.")
            refreshMessages(); return
        }
        guard topicContext != next || (!topicsLoading && !topicsLoaded) else { return }
        stopTopics(clear: true); topicContext = next
        startTopics(store: store, context: next, more: false)
    }

    func loadMoreTopics(store: AppStore) {
        guard let context = topicContext, context.isCurrent(store), canLoadMoreTopics, !topicsLoading else { return }
        startTopics(store: store, context: context, more: true)
    }

    func cancel() {
        stopTopics(clear: true); topicsRequested = false; context = nil
        topicError = nil; error = nil; notice = nil
        resultsRevision = UUID()
    }

    func matchesNote(noteID: String, meetingID: String?, filters: MaterialFilterSet) -> Bool {
        matchesTopic(noteID: noteID, meetingID: meetingID, filters: filters)
    }

    func matchesCard(meetingID: String, cardID: String, filters: MaterialFilterSet) -> Bool {
        matchesTopic(noteID: nil, meetingID: meetingID, filters: filters)
    }

    private func matchesTopic(noteID: String?, meetingID: String?, filters: MaterialFilterSet) -> Bool {
        guard !filters.topicIDs.isEmpty else { return true }
        guard let store, let topicContext, topicContext == context, topicContext.isCurrent(store) else { return false }
        return topics.contains { topic in
            filters.topicIDs.contains(topic.id) &&
                (noteID.map(topic.noteIDs.contains) == true || meetingID.map(topic.meetingIDs.contains) == true)
        }
    }

    private func refreshMessages() {
        var notices: [String] = []
        if catalog.partial { notices.append(L("Темы построены по ограниченной части материалов; некоторые связи могли не попасть в список.")) }
        if catalog.capped { notices.append(L("Достигнут предел списка: 1000 тем. Уточните папку, чтобы увидеть другие темы.")) }
        else if canLoadMoreTopics { notices.append(L("Загружена часть тем. Можно показать ещё темы.")) }
        if !selectedTopicIDs.isEmpty, !topicsLoading, topicsLoaded,
           !selectedTopicIDs.isSubset(of: Set(topics.map(\.id))) {
            notices.append(canLoadMoreTopics
                ? L("Некоторые выбранные темы ещё не найдены в загруженной части списка. Покажите ещё темы.")
                : L("Некоторые выбранные темы больше недоступны. Обновите выбор тем."))
        }
        error = topicError
        var seen = Set<String>()
        notice = notices.filter { seen.insert($0).inserted }.joined(separator: "\n").nilIfEmpty
    }

    private func startTopics(store: AppStore, context: Context, more: Bool) {
        let current = UUID(); topicGeneration = current
        let requestID = UUID().uuidString.lowercased(); topicRequestID = requestID
        topicsLoading = true; topicError = nil
        let request = request, initial = more ? catalog : Catalog()
        topicTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(200))
                let value = try await Self.loadCatalog(root: context.root, folderID: context.folderID,
                                                       requestID: requestID, initial: initial, request: request)
                guard current == topicGeneration, !Task.isCancelled else { return }
                guard context.isCurrent(store), self.context == context else { stopTopics(clear: true); refreshMessages(); return }
                catalog = value; topics = value.rows.values.sorted {
                    let order = $0.title.localizedStandardCompare($1.title)
                    return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                }
                topicsLoading = false; topicsLoaded = true; topicTask = nil; topicRequestID = nil
                canLoadMoreTopics = !value.capped && (value.noteOffset != nil || value.mixedOffset != nil)
                topicError = value.errors.isEmpty ? nil : value.errors.joined(separator: "\n")
                resultsRevision = UUID(); refreshMessages()
            } catch {
                guard current == topicGeneration, !Task.isCancelled else { return }
                guard context.isCurrent(store), self.context == context else { stopTopics(clear: true); refreshMessages(); return }
                topicsLoading = false; topicsLoaded = false; topicTask = nil; topicRequestID = nil
                topics = []; catalog = Catalog(); canLoadMoreTopics = false
                topicError = error.localizedDescription; resultsRevision = UUID(); refreshMessages()
            }
        }
        refreshMessages()
    }

    private func stopTopics(clear: Bool) {
        topicGeneration = UUID(); topicTask?.cancel(); topicTask = nil
        let id = topicRequestID, root = topicContext?.root, request = request
        topicRequestID = nil; topicsLoading = false
        if clear {
            topics = []; topicContext = nil; topicsLoaded = false; catalog = Catalog()
            canLoadMoreTopics = false; topicError = nil; resultsRevision = UUID()
        }
        if let id, let root, let arguments = try? JSONEncoder().encode(["requestID": id]) {
            Task {
                _ = try? await request(root, "kb-topics-cancel", arguments)
                _ = try? await request(root, "kb-mixed-topics-cancel", arguments)
            }
        }
    }

    nonisolated private static func loadCatalog(root: URL, folderID: String?, requestID: String,
                                               initial: Catalog, request: Request) async throws -> Catalog {
        var result = initial
        let versionData = try await request(root, "kb-snapshot", Data("{}".utf8))
        let version = try JSONDecoder().decode(Version.self, from: versionData)
        guard result.version == nil || result.version == version else {
            throw AppError.message(L("Материалы или связи изменились. Откройте список тем заново."))
        }
        result.version = version
        func arguments(offset: Int, notes: Bool) throws -> Data {
            var values: [String: Any] = ["offset": offset, "requestID": requestID]
            if let folderID { values["folderID"] = folderID }
            if notes { values["expectedWorkspaceRevision"] = version.workspaceRevision; values["expectedKBRevision"] = version.kbRevision }
            return try JSONSerialization.data(withJSONObject: values)
        }
        func title(_ terms: [String]) -> String { terms.isEmpty ? L("Тема") : terms.joined(separator: " · ") }
        func add(_ row: MaterialFilterTopic) {
            if result.rows[row.id] != nil || result.rows.count < topicLimit { result.rows[row.id] = row }
            else { result.capped = true }
        }
        do {
            for _ in 0..<pagesPerBatch {
                guard let offset = result.noteOffset, !result.capped else { break }
                try Task.checkCancellation()
                let data = try await request(root, "kb-topics", arguments(offset: offset, notes: true))
                let page = try JSONDecoder().decode(TopicPage.self, from: data)
                for collection in page.collections where !collection.hidden {
                    add(MaterialFilterTopic(id: "collection:" + collection.id,
                        title: collection.nameRedacted || collection.name.isEmpty ? L("Подборка доступных материалов") : collection.name,
                        noteIDs: Set(collection.sources.map(\.noteID)), meetingIDs: []))
                }
                for topic in page.topics {
                    add(MaterialFilterTopic(id: "topic:" + topic.id, title: title(topic.terms),
                                           noteIDs: Set(topic.sources.map(\.noteID)), meetingIDs: []))
                }
                result.partial = result.partial || page.partial || page.noteLimitReached || page.topicLimitReached
                result.noteOffset = page.nextOffset
            }
        } catch {
            try Task.checkCancellation(); result.noteOffset = nil; result.errors.append(error.localizedDescription)
        }
        do {
            for _ in 0..<pagesPerBatch {
                guard let offset = result.mixedOffset, !result.capped else { break }
                try Task.checkCancellation()
                let data = try await request(root, "kb-mixed-topics", arguments(offset: offset, notes: false))
                let page = try JSONDecoder().decode(MixedTopicResult.self, from: data)
                for topic in page.topics {
                    add(MaterialFilterTopic(id: "mixed:" + topic.id, title: title(topic.terms),
                        noteIDs: Set(topic.sources.filter { $0.kind == "note" }.compactMap(\.noteID)),
                        meetingIDs: Set(topic.sources.filter { $0.kind == "meeting" }.compactMap(\.meetingID))))
                }
                result.partial = result.partial || page.partial
                result.mixedOffset = page.nextOffset
            }
        } catch {
            try Task.checkCancellation(); result.mixedOffset = nil; result.errors.append(error.localizedDescription)
        }
        try Task.checkCancellation()
        let final = try await request(root, "kb-snapshot", Data("{}".utf8))
        guard try JSONDecoder().decode(Version.self, from: final) == version else {
            throw AppError.message(L("Материалы или связи изменились. Откройте список тем заново."))
        }
        if result.rows.count >= topicLimit && (result.noteOffset != nil || result.mixedOffset != nil) { result.capped = true }
        return result
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
