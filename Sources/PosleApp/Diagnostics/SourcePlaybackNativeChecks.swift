#if DEBUG
import Foundation
import CoreMedia
import PosleCore

/// Real AVPlayer with a generated silent WAV and muted output, plus queued
/// timer callbacks for invented meetings. No existing recording or microphone access.
@MainActor
enum SourcePlaybackNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Source playback checks require an explicit disposable preview root")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/tmp", "/private/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable source playback root required")
        try await EvidenceSnapshotNativeChecks.run(root: root)
        let store = AppStore(preview: true)
        let meeting = Meeting(title: "Источник для проверки", source: "fixture.wav")
        let directory = store.meetingDirectory(meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try store.write(meeting, directory.appendingPathComponent("meta.json"))
        let segment = Segment(id: 7, start: 0.1, end: 0.8, speaker: "speaker_1", text: "Исходная реплика")
        var transcript = Transcript(duration: 2, segments: [segment], warnings: [], model: "synthetic")
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        try store.write(transcript, transcriptURL)
        store.reloadLibrary(); store.selection = meeting.id; store.loadSelection(); store.tab = "summary"
        let wav = directory.appendingPathComponent("silent-fixture.wav")
        try silentWAV().write(to: wav)
        let state = SourcePlaybackState()
        defer { state.stop() }
        state.playForChecks(store: store, meetingID: meeting.id, expected: segment, audioURL: wav)
        try await wait { state.playingID == segment.id || state.error != nil }
        try expect(state.error == nil && state.playingID == segment.id, "Muted real AVPlayer did not prepare the source fragment")
        try expect(store.selection == meeting.id && store.tab == "summary" && store.navigationTarget == nil,
                   "Inline source playback must not navigate away from its document")
        try await wait { !state.isActive }
        try expect(state.playingID == nil && store.tab == "summary", "The player must stop at the clip end without navigation")
        print("PASS: real muted source playback preserves the workspace and stops at the segment boundary")
        state.playForChecks(store: store, meetingID: meeting.id, expected: segment, audioURL: wav)
        state.stop()
        try await Task.sleep(for: .milliseconds(300))
        try expect(!state.isActive && state.playingID == nil && state.preparingID == nil, "Dismissal during preparation must not allow late playback")
        state.playForChecks(store: store, meetingID: meeting.id, expected: segment, audioURL: wav)
        try await wait { state.playingID == segment.id || state.error != nil }
        state.stop()
        try expect(!state.isActive && state.playingID == nil, "Closing an active source must release the player")
        print("PASS: closing source playback cancels both pending preparation and active playback")
        try await delayedValidation(store: store, meetingID: meeting.id, segment: segment, audioURL: wav)
        transcript.segments[0].text = "Новая версия реплики"
        try store.write(transcript, transcriptURL)
        store.isPlaying = true
        state.playForChecks(store: store, meetingID: meeting.id, expected: segment, audioURL: wav)
        try await wait { state.error != nil }
        try expect(state.error != nil && !state.isActive, "A changed transcript must reject the displayed stale source before loading audio")
        try expect(store.isPlaying, "Rejecting a stale source must not pause another recording")
        try expect(store.selection == meeting.id && store.tab == "summary", "A stale source must not cause navigation")
        state.stop()
        store.pause()
        try expect(state.error == nil, "Closing a failed source must clear the message before reopening an updated source")
        print("PASS: a stale source snapshot is rejected before playback without navigation")
        try await verifyMeetingPlaybackCallbacks(store: store, first: meeting)
    }
    private static func delayedValidation(store: AppStore, meetingID: String, segment: Segment, audioURL: URL) async throws {
        let worker = EvidenceWorkerGate()
        let delayed = SourcePlaybackState(loadSnapshot: { root, id, ids in
            worker.wait()
            return try EvidenceSourceSnapshot.load(root: root, meetingID: id, ids: ids)
        })
        store.isPlaying = true
        delayed.playForChecks(store: store, meetingID: meetingID, expected: segment, audioURL: audioURL)
        let preparation = delayed.preparationForChecks
        do { try await wait { worker.entered } }
        catch { delayed.stop(); worker.release(); await preparation?.value; throw error }
        let offMain = !worker.onMainThread && !worker.timedOut
        delayed.stop()
        worker.release()
        await preparation?.value
        try expect(offMain && !delayed.isActive && delayed.playingID == nil && delayed.preparingID == nil
            && delayed.error == nil && store.isPlaying,
            "Snapshot validation blocked MainActor, paused another recording, or resumed after dismissal")

        let summary = EvidenceValidationGate()
        let validation = SourcePlaybackState()
        validation.playForChecks(store: store, meetingID: meetingID, expected: segment, audioURL: audioURL,
            additionalValidation: { await summary.wait() })
        let waiting = validation.preparationForChecks
        do { try await wait { summary.entered } }
        catch { validation.stop(); summary.resolve(false); await waiting?.value; throw error }
        let stayedPlaying = store.isPlaying
        validation.stop(); summary.resolve(true)
        await waiting?.value
        try expect(stayedPlaying && store.isPlaying && !validation.isActive && validation.error == nil,
            "Canceled asynchronous summary validation paused playback or admitted a late source")

        validation.playForChecks(store: store, meetingID: meetingID, expected: segment, audioURL: audioURL,
            additionalValidation: { false })
        await validation.preparationForChecks?.value
        try expect(validation.error != nil && !validation.isActive && store.isPlaying,
            "A rejected claim validation paused another recording or began playback")
        validation.stop(); store.pause()
        print("PASS: compact snapshot work stays off MainActor and late/rejected asynchronous validations cannot pause or restart playback")
    }
    private static func verifyMeetingPlaybackCallbacks(store: AppStore, first: Meeting) async throws {
        let second = Meeting(title: "Другая запись для проверки таймера", source: "synthetic-no-audio.wav")
        let directory = store.meetingDirectory(second.id)
        try store.write(second, directory.appendingPathComponent("meta.json"))
        try store.write(Transcript(duration: 2, segments: [], warnings: [], model: "synthetic"), directory.appendingPathComponent("transcript.json"))
        store.reloadLibrary(); store.selection = first.id; store.loadSelection()
        let firstCallback = store.playbackTimeCallbackForChecks()
        let pendingFirst = firstCallback(CMTime(seconds: 1.9, preferredTimescale: 600))
        // Remain on this MainActor turn until the new source is loaded, exactly
        // as a user's selection can outrun the observer's already queued task.
        store.selection = second.id; store.loadSelection()
        store.playbackTime = 0.25; store.isPlaying = true
        await pendingFirst.value
        try expect(store.playbackTime == 0.25 && store.isPlaying,
                   "A previous recording's queued timer changed the new recording's position or stopped playback")

        let currentCallback = store.playbackTimeCallbackForChecks()
        await currentCallback(CMTime(seconds: 0.6, preferredTimescale: 600)).value
        try expect(store.playbackTime == 0.6 && store.isPlaying, "The current recording's timer must still update its position")
        await currentCallback(CMTime(seconds: 1.9, preferredTimescale: 600)).value
        try expect(!store.isPlaying, "The current recording's own end tick must still finish playback")

        let beforeReload = currentCallback(CMTime(seconds: 1.9, preferredTimescale: 600))
        store.loadSelection(); store.playbackTime = 0.4; store.isPlaying = true
        await beforeReload.value
        try expect(store.playbackTime == 0.4 && store.isPlaying,
                   "Reloading the same meeting must invalidate its previous player's queued timer")
        let reloadedCallback = store.playbackTimeCallbackForChecks()
        let beforeSelectionLoad = reloadedCallback(CMTime(seconds: 1.9, preferredTimescale: 600))
        store.selection = first.id
        await beforeSelectionLoad.value
        try expect(store.playbackTime == 0.4 && store.isPlaying,
                   "A changed selection must reject a timer even before its new source finishes loading")
        store.loadSelection()
        let beforeClear = store.playbackTimeCallbackForChecks()(CMTime(seconds: 1.9, preferredTimescale: 600))
        store.selection = nil; store.loadSelection()
        await beforeClear.value
        try expect(store.playbackTime == 0 && !store.isPlaying,
                   "Clearing the selection must not let a pending player callback restore an obsolete position")
        print("PASS: actual queued playback callbacks ignore previous/reloaded/cleared sources while current ticks still update and finish playback")
    }
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 16_000
        let sampleBytes: UInt32 = sampleRate * 2 * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(sampleBytes + 36); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(sampleRate); append(sampleRate * 2)
        append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(sampleBytes)
        data.append(Data(repeating: 0, count: Int(sampleBytes)))
        return data
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Source playback check timed out")
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AppError.message(message) }
    }
}

private final class EvidenceWorkerGate: @unchecked Sendable {
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

@MainActor
private final class EvidenceValidationGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func resolve(_ value: Bool) {
        continuation?.resume(returning: value); continuation = nil
    }
}
#endif
