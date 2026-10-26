#if DEBUG
import Foundation
import PosleCore

/// Real AVPlayer with a generated silent WAV and muted output. The test never
/// opens an existing recording, navigates a workspace or requests microphone access.
@MainActor
enum SourcePlaybackNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Source playback checks require an explicit disposable preview root")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/tmp", "/private/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable source playback root required")
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
        transcript.segments[0].text = "Новая версия реплики"
        try store.write(transcript, transcriptURL)
        state.playForChecks(store: store, meetingID: meeting.id, expected: segment, audioURL: wav)
        try expect(state.error != nil && !state.isActive, "A changed transcript must reject the displayed stale source before loading audio")
        try expect(store.selection == meeting.id && store.tab == "summary", "A stale source must not cause navigation")
        state.stop()
        try expect(state.error == nil, "Closing a failed source must clear the message before reopening an updated source")
        print("PASS: a stale source snapshot is rejected before playback without navigation")
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
#endif
