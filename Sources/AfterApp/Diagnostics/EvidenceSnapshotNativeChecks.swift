import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import Foundation
import AfterCore

/// Invented snapshots and private temporary meeting files exercise the actual
/// async state and compact bridge. No models, media, accounts, or UI are opened.
@MainActor
enum EvidenceSnapshotNativeChecks {
    static func run(root: URL) async throws {
        let owned = root.resolvingSymlinksInPath()
        guard let configured = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"],
              URL(fileURLWithPath: configured).resolvingSymlinksInPath() == owned,
              ["/private/tmp", "/tmp"].contains(owned.deletingLastPathComponent().path),
              owned.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Evidence snapshot checks require an explicit disposable preview root")
        }
        let store = AppStore(preview: true)
        var a = Meeting(title: "Invented source A", source: "unused.wav")
        var b = Meeting(title: "Invented source B", source: "unused.wav")
        a.speakerNames = ["speaker_1": "Before"]
        b.speakerNames = ["speaker_1": "Other meeting"]
        let first = Segment(id: 7, start: 0, end: 1, speaker: "speaker_1", text: "Invented quote A")
        let second = Segment(id: 7, start: 2, end: 3, speaker: "speaker_1", text: "Invented quote B")
        let snapshotA = EvidenceSourceSnapshot(meeting: a, segments: [first], summary: nil)
        let snapshotB = EvidenceSourceSnapshot(meeting: b, segments: [second], summary: nil)
        try await latestRequestWins(root: owned, store: store, a: snapshotA, b: snapshotB)
        try await cancellationDropsLateResults(root: owned, snapshot: snapshotA)
        try verifyIndexAndSummaryIdentity(store: store, meeting: a, segment: first)
        try await compactNonselectedSource(root: owned, store: store, a: a, b: b, segment: first)
        print("4 native evidence snapshot checks passed")
    }

    private static func latestRequestWins(root: URL, store: AppStore,
                                         a: EvidenceSourceSnapshot, b: EvidenceSourceSnapshot) async throws {
        let blocked = EvidenceSnapshotBarrier()
        let state = EvidenceSourceState(load: { _, id, _, _ in
            if id == a.meeting.id { blocked.wait(); return a }
            return b
        })
        let first = Task { await state.load(root: root, meetingID: a.meeting.id, ids: [7]) }
        do { try await wait { blocked.entered } }
        catch { state.cancel(); blocked.release(); await first.value; throw error }
        // This MainActor navigation must run while the worker is held. A slow
        // source read cannot freeze workspace interaction behind the popover.
        store.selection = b.meeting.id
        store.navigationTarget = AppStore.NavigationTarget(meetingID: b.meeting.id, kind: "transcript", segmentID: 7)
        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        do { try await wait { heartbeat } }
        catch { state.cancel(); blocked.release(); await first.value; throw error }
        await state.load(root: root, meetingID: b.meeting.id, ids: [7])
        let responsive = !blocked.onMainThread && !blocked.timedOut
            && state.snapshot?.meeting.id == b.meeting.id && state.snapshot?.segments == b.segments
            && store.selection == b.meeting.id && store.navigationTarget?.meetingID == b.meeting.id
        blocked.release()
        await first.value
        try expect(responsive && state.snapshot?.meeting.id == b.meeting.id
            && state.snapshot?.segments == b.segments && !state.loading && state.error == nil,
            "Delayed source A blocked MainActor/navigation or replaced the newer B snapshot")
        state.cancel()
        print("PASS: blocked source A leaves MainActor responsive and cannot overwrite completed source B")
    }

    private static func cancellationDropsLateResults(root: URL, snapshot: EvidenceSourceSnapshot) async throws {
        for cancelParent in [false, true] {
            let blocked = EvidenceSnapshotBarrier()
            let state = EvidenceSourceState(load: { _, _, _, _ in blocked.wait(); return snapshot })
            let load = Task { await state.load(root: root, meetingID: snapshot.meeting.id, ids: [7]) }
            do { try await wait { blocked.entered } }
            catch { state.cancel(); blocked.release(); await load.value; throw error }
            if cancelParent { load.cancel() } else { state.cancel() }
            blocked.release()
            await load.value
            try expect(!blocked.onMainThread && !blocked.timedOut && state.snapshot == nil
                && !state.loading && state.error == nil,
                "Canceled evidence work published a stale snapshot/error or retained its loading state")
        }
        print("PASS: explicit close and task cancellation both discard an uncooperative late snapshot")
    }

    private static func verifyIndexAndSummaryIdentity(store: AppStore, meeting: Meeting, segment: Segment) throws {
        var duplicate = segment
        duplicate.text = "Duplicate ID must not win"
        let before = store.transcriptRevision
        store.transcript = Transcript(duration: 3, segments: [segment, duplicate], warnings: [], model: "synthetic")
        try expect(store.transcriptSegment(segment.id) == segment && store.transcriptSegment(999) == nil
            && store.transcriptRevision == before &+ 1,
            "The indexed transcript changed first-match semantics or reused its old revision")
        store.transcript?.segments[0].text = "Updated first quote"
        try expect(store.transcriptSegment(segment.id)?.text == "Updated first quote"
            && store.transcriptRevision == before &+ 2,
            "An in-place transcript edit left stale indexed source text")
        store.transcript = nil
        try expect(store.transcriptSegment(segment.id) == nil, "Clearing the transcript retained its previous source index")

        let summary = try summaryFixture()
        let valid = EvidenceSourceSnapshot(meeting: meeting, segments: [segment], summary: summary)
        try expect(valid.matches(summary), "A coherent overview claim did not verify against its source")
        var changed = summary
        changed.overviewClaims = []
        try expect(!EvidenceSourceSnapshot(meeting: meeting, segments: [segment], summary: changed).matches(summary),
            "A claims-only edit reused generatedAt/overview/items to keep obsolete citation links")
        changed = summary; changed.sourceStale = true
        let sourceStale = EvidenceSourceSnapshot(meeting: meeting, segments: [segment], summary: changed)
        try expect(!sourceStale.matches(summary) && !sourceStale.matches(changed),
            "Source-stale claims were accepted with an unchanged generation timestamp")
        changed = summary; changed.overviewStale = true
        let overviewStale = EvidenceSourceSnapshot(meeting: meeting, segments: [segment], summary: changed)
        try expect(!overviewStale.matches(summary) && !overviewStale.matches(changed),
            "Overview-stale claims were accepted with unchanged prose/items")
        try expect(!EvidenceSourceSnapshot(meeting: meeting, segments: [], summary: summary).matches(summary),
            "A claim stayed verified after its cited source disappeared")
        var renamed = meeting
        renamed.title = "Renamed meeting"; renamed.speakerNames[segment.speaker] = "Renamed speaker"
        let metadata = EvidenceSourceSnapshot(meeting: renamed, segments: [segment], summary: summary)
        try expect(metadata.matches(summary) && metadata.meeting.speakerName(segment.speaker) == "Renamed speaker",
            "A metadata rename invalidated unchanged quote provenance or retained the wrong display name")
        let summaryRevision = store.summaryRevision
        store.summary = summary
        store.summary?.sourceStale = true
        store.summary?.overviewClaims = []
        try expect(store.summaryRevision == summaryRevision &+ 3,
            "In-place summary/claim edits failed to invalidate revision-bound evidence views")
        print("PASS: source index keeps first duplicates and summary identity distinguishes claims/stale flags from metadata renames")
    }

    private static func compactNonselectedSource(root: URL, store: AppStore, a: Meeting, b: Meeting,
                                                segment: Segment) async throws {
        for meeting in [a, b] {
            try store.write(meeting, store.meetingDirectory(meeting.id).appendingPathComponent("meta.json"))
        }
        let ids = [7, 13, 21, 34, 55, 89]
        let segments = ids.map { Segment(id: $0, start: Double($0), end: Double($0) + 1,
            speaker: "speaker_1", text: "Quote \($0) from B") }
        try store.write(Transcript(duration: 100, segments: segments, warnings: [], model: "synthetic"),
            store.meetingDirectory(b.id).appendingPathComponent("transcript.json"))
        store.selection = a.id
        store.transcript = Transcript(duration: 1, segments: [segment], warnings: [], model: "selected A")
        let meetingID = b.id
        let result = try await Task.detached(priority: .userInitiated) {
            try EvidenceSourceSnapshot.load(root: root, meetingID: meetingID, ids: [55, 7, 21, 13, 34, 7, 999])
        }.value
        try expect(result.meeting.id == b.id && result.meeting.speakerNames == b.speakerNames
            && result.segments.map(\.id) == [55, 7, 21, 13, 34] && result.summary == nil
            && result.segments.allSatisfy { $0.text.contains("from B") }
            && store.selection == a.id && store.transcriptSegment(7) == segment,
            "The compact bridge mixed the selected transcript into an explicit other-meeting request")
        print("PASS: actual compact endpoint returns five ordered other-meeting quotes, omitting duplicate/missing refs without navigation")
    }

    private static func summaryFixture() throws -> Summary {
        let data = Data(#"{"overview":"Verified claim.","items":[{"kind":"fact","text":"Verified fact","owner":"","due":"","segmentIDs":[7]}],"cards":[],"provider":"synthetic","model":"fixture","generatedAt":1,"warnings":[],"overviewClaims":[{"text":"Verified claim.","itemIndices":[0]}]}"#.utf8)
        return try JSONDecoder().decode(Summary.self, from: data)
    }

    private static func wait(_ ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !ready() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppError.message("Evidence snapshot fixture timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppError.message(message) }
    }
}

private final class EvidenceSnapshotBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var reached = false
    private var main = false
    private var timeout = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    var onMainThread: Bool { lock.lock(); defer { lock.unlock() }; return main }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timeout }
    func wait() {
        lock.lock(); reached = true; main = Thread.isMainThread; lock.unlock()
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            lock.lock(); timeout = true; lock.unlock()
        }
    }
    func release() { semaphore.signal() }
}
#endif
