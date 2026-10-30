import Combine
import Foundation
import PosleCore

/// Immutable values cross the worker boundary. Core models are value types;
/// none of the mutable AppStore or playback objects leave the main actor.
struct EvidenceSourceSnapshot: Decodable, @unchecked Sendable {
    let meeting: Meeting
    let segments: [Segment]
    let summary: Summary?

    static func load(root: URL, meetingID: String, ids: [Int], includeSummary: Bool = false) throws -> Self {
        let data = try RustBridge.shared.get().request(root: root, command: "source-snapshot", arguments: [
            "meetingID": meetingID, "segmentIDs": ids, "includeSummary": includeSummary
        ])
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func matches(_ expected: Summary) -> Bool {
        guard let summary else { return false }
        return summary.generatedAt == expected.generatedAt && summary.overview == expected.overview
            && summary.items == expected.items && summary.overviewClaims == expected.overviewClaims
            && summary.sourceStale == expected.sourceStale && summary.overviewStale == expected.overviewStale
            && summary.hasVerifiedOverviewClaims(transcript: Transcript(duration: 0, segments: segments,
                warnings: [], model: ""))
    }
}

@MainActor
final class EvidenceSourceState: ObservableObject {
    typealias Loader = @Sendable (URL, String, [Int], Bool) throws -> EvidenceSourceSnapshot
    @Published private(set) var snapshot: EvidenceSourceSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private let loadSnapshot: Loader
    private var generation = UUID()
    private var worker: Task<EvidenceSourceSnapshot, Error>?

    init(load: @escaping Loader = { try EvidenceSourceSnapshot.load(root: $0, meetingID: $1, ids: $2, includeSummary: $3) }) {
        loadSnapshot = load
    }

    func prepare() { cancel(); loading = true }

    func load(root: URL, meetingID: String, ids: [Int], expectedSummary: Summary? = nil) async {
        cancel()
        let token = generation
        loading = true
        let loader = loadSnapshot, includeSummary = expectedSummary != nil
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try loader(root, meetingID, ids, includeSummary)
        }
        worker = operation
        defer {
            if generation == token { loading = false; worker = nil }
        }
        do {
            let result = try await withTaskCancellationHandler { try await operation.value }
                onCancel: { operation.cancel() }
            guard generation == token, !Task.isCancelled else { return }
            guard result.meeting.id == meetingID,
                  expectedSummary.map({ result.matches($0) }) ?? true else {
                throw AppError.message(L("Источник изменился. Откройте актуальный конспект."))
            }
            snapshot = result
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = L("Источник недоступен. Обновите конспект.")
        }
    }

    func cancel() {
        generation = UUID(); worker?.cancel(); worker = nil
        snapshot = nil; loading = false; error = nil
    }
}
