import AfterPlatform
import AfterPlatformMacOS
import AfterLocalization
import AfterCore
import Combine
import Foundation

struct MixedMeetingAnchor: Codable, Equatable, Sendable {
    let kind: String
    let meetingID: String
    let segmentID: Int?
    let itemIndex: Int?
    let title: String
    let text: String
    let contentFingerprint: String
    let policyFingerprint: String
}
struct MixedTopicSource: Codable, Equatable, Identifiable, Sendable {
    let kind: String
    let noteID: String?
    let meetingID: String?
    let revision: UInt64?
    let title: String
    let fingerprint: String
    let source: MixedMeetingAnchor?
    let partial: Bool?
    var id: String {kind + ":" + (noteID ?? meetingID ?? "")}
}
struct MixedTopic: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let terms: [String]
    let sources: [MixedTopicSource]
    let method: String
}
struct MixedTopicResult: Decodable, Sendable {
    let topics: [MixedTopic]
    let examined: Int
    let total: Int
    let partial: Bool
    let semanticIndexed: Int
    let nextOffset: Int?
    let offset: Int
}

/// Owns the asynchronous lifetime of mixed suggestions and source navigation.
/// Rust still validates source identity and policy; the controller prevents a
/// valid but superseded response from navigating a different screen or scope.
@MainActor
final class KnowledgeMixedTopicsController: ObservableObject {
    typealias Request = @Sendable (URL, String, Data) async throws -> Data
    @Published private(set) var result: MixedTopicResult?
    @Published private(set) var busy = false
    @Published private(set) var opening = false
    @Published private(set) var error: String?
    private let request: Request
    private var generation = UUID()
    private var openingGeneration = UUID()
    private var requestID: String?
    private var work: Task<Void, Never>?
    private var openingTask: Task<Void, Never>?

    init(request: @escaping Request = KnowledgeMixedTopicsController.liveRequest) { self.request = request }

    nonisolated static func liveRequest(root: URL, command: String, arguments: Data) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard let input = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
                throw AppError.message(L("Не удалось подготовить запрос."))
            }
            return try RustBridge.shared.get().request(root: root, command: command, arguments: input)
        }.value
    }

    func stop(root: URL) {
        generation = UUID()
        let id = requestID
        requestID = nil; work?.cancel(); work = nil
        cancelOpening()
        busy = false; result = nil
        if let id, let arguments = try? JSONEncoder().encode(["requestID": id]) {
            let request = request
            Task { _ = try? await request(root, "kb-mixed-topics-cancel", arguments) }
        }
    }

    func cancelOpening() {
        openingGeneration = UUID(); openingTask?.cancel(); openingTask = nil; opening = false
    }

    func load(store: AppStore, offset: Int) {
        stop(root: store.root); error = nil
        guard !store.isRecording, !store.startingRecording, !store.stoppingRecording else { return }
        let id = UUID().uuidString.lowercased(), current = generation
        requestID = id; busy = true
        let root = store.root, folder = store.folderSelection, features = store.visibleFeatures
        work = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                var input: [String: Any] = ["requestID": id, "offset": offset]
                if let folder { input["folderID"] = folder }
                let arguments = try JSONSerialization.data(withJSONObject: input)
                let data = try await request(root, "kb-mixed-topics", arguments)
                let value = try JSONDecoder().decode(MixedTopicResult.self, from: data)
                guard generation == current, !Task.isCancelled else { return }
                guard store.folderSelection == folder, store.visibleFeatures == features else {
                    stop(root: root); return
                }
                result = value; busy = false; work = nil; requestID = nil
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                self.error = error.localizedDescription; busy = false; work = nil; requestID = nil
            }
        }
    }

    @discardableResult
    func open(_ source: MixedTopicSource, store: AppStore) -> Task<Void, Never>? {
        guard !opening, contains(source), store.isFeatureEnabled(.knowledgeBase) else { return nil }
        let current = generation, navigation = openingGeneration, root = store.root
        let folder = store.folderSelection, features = store.visibleFeatures
        opening = true; error = nil
        let task = Task {
            defer {
                if generation == current, openingGeneration == navigation { opening = false; openingTask = nil }
            }
            do {
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))
                var input: [String: Any] = ["source": object]
                if let folder { input["folderID"] = folder }
                let arguments = try JSONSerialization.data(withJSONObject: input)
                let data = try await request(root, "kb-topic-source-validate", arguments)
                guard generation == current, openingGeneration == navigation, !Task.isCancelled, contains(source),
                      store.folderSelection == folder, store.visibleFeatures == features,
                      store.isFeatureEnabled(.knowledgeBase) else { return }
                struct Validation: Decodable { let valid: Bool }
                guard try JSONDecoder().decode(Validation.self, from: data).valid else {
                    throw AppError.message(L("Материал изменился или стал недоступен. Обновите подсказки."))
                }
                if let id = source.noteID {
                    store.notes.reload()
                    guard let note = store.notes.notes.first(where: {
                        $0.id == id && $0.trashedAt == nil && $0.revision >= 0 && UInt64($0.revision) == source.revision
                    }) else { throw AppError.message(L("Заметка больше недоступна.")) }
                    store.openCapturedNote(note)
                } else if let id = source.meetingID, let anchor = source.source {
                    store.openMeeting(id, tab: anchor.kind == "transcript" ? "transcript" : "summary", segmentID: anchor.segmentID)
                }
            } catch {
                guard generation == current, openingGeneration == navigation, !Task.isCancelled,
                      store.folderSelection == folder, store.visibleFeatures == features else { return }
                self.error = error.localizedDescription
            }
        }
        openingTask = task
        return task
    }

    private func contains(_ source: MixedTopicSource) -> Bool {
        result?.topics.contains { $0.sources.contains(source) } == true
    }
}
