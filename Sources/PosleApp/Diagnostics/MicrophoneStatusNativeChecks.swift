#if DEBUG
import Foundation
import PosleCore

/// Typed nonfatal microphone status through the real app/preflight callbacks.
/// Hardware is replaced by a backend that writes disposable synthetic bytes.
@MainActor
enum MicrophoneStatusNativeChecks {
    static func run(root: URL) async throws {
        let owned = root.resolvingSymlinksInPath()
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"],
              URL(fileURLWithPath: path).resolvingSymlinksInPath() == owned,
              ["/private/tmp", "/tmp"].contains(owned.deletingLastPathComponent().path),
              owned.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Microphone status checks require a disposable preview root")
        }
        try levels()
        try await appCallbacks()
        try await audioCheckCallbacks()
        print("3 native microphone status groups passed")
    }

    private static func levels() throws {
        let levels = AudioLevels()
        levels.receive(microphone: 0.5, system: 0.25)
        levels.receive(state: .switching)
        try expect(levels.microphone == 0 && !levels.microphoneSeen && levels.system == 0.25 && levels.systemSeen,
            "Switching must clear only the microphone meter")
        levels.receive(microphone: 0.8, system: 0.4)
        try expect(levels.microphone == 0 && !levels.microphoneSeen && levels.system == 0.4,
            "A late microphone level must not overwrite switching status; system levels must continue")
        levels.receive(state: .active(name: "Synthetic microphone A"))
        levels.receive(microphone: 0.6, system: nil)
        try expect(levels.microphone == 0.6 && levels.microphoneSeen, "The recovered microphone must accept fresh levels")
        levels.receive(state: .unavailable)
        levels.receive(microphone: 0.9, system: 0.7)
        try expect(levels.microphone == 0 && !levels.microphoneSeen && levels.system == 0.7,
            "An unavailable microphone must stay distinct from silence while system audio continues")
        levels.receive(state: .active(name: "Synthetic microphone B"))
        levels.clear()
        try expect(levels.microphoneState == nil && !levels.microphoneSeen && !levels.systemSeen
            && levels.microphone == 0 && levels.system == 0, "Clearing a session must discard its route status and levels")
        print("PASS: microphone availability is distinct from silence; recovery accepts levels and session reset clears status")
    }

    private static func appCallbacks() async throws {
        let recorder = StatusRecorder()
        let store = AppStore(preview: true, recorder: recorder)
        do {
            recorder.status("unrelated", .unavailable)
            await settle()
            try expect(store.audioLevels.microphoneState == nil, "An inactive app accepted a microphone update")
            store.startingRecording = true; store.startingRecordingID = "status-session-a"
            recorder.status("status-session-a", .switching)
            try await wait { store.audioLevels.microphoneState == .switching }
            try expect(store.pendingRecordingFailure == nil && store.error == nil && recorder.stopCount == 0,
                "A nonfatal microphone transition entered the capture failure/stop path during Start")
            store.startingRecording = false; store.startingRecordingID = nil
            store.isRecording = true; store.recordingID = "status-session-a"
            recorder.status("status-session-a", .unavailable)
            try await wait { store.audioLevels.microphoneState == .unavailable }
            try expect(store.isRecording && store.recordingID == "status-session-a" && recorder.stopCount == 0 && store.error == nil,
                "Microphone loss stopped video/system recording or became a fatal application error")
            recorder.status("status-session-a", .active(name: "Synthetic microphone A"))
            try await wait { store.audioLevels.microphoneState == .active(name: "Synthetic microphone A") }
            recorder.status("old-session", .unavailable)
            await settle()
            try expect(store.audioLevels.microphoneState == .active(name: "Synthetic microphone A"),
                "An old recording's microphone warning replaced the current session")
            store.stoppingRecording = true
            recorder.status("status-session-a", .switching)
            await settle()
            try expect(store.audioLevels.microphoneState == .active(name: "Synthetic microphone A"),
                "A stopping session accepted another microphone transition")
            store.stoppingRecording = false; store.isRecording = false; store.recordingID = nil
            store.audioLevels.clear()
            recorder.status("status-session-a", .unavailable)
            await settle()
            try expect(store.audioLevels.microphoneState == nil, "A completed recording resurrected its microphone warning")
            store.isRecording = true; store.recordingID = "status-session-b"
            recorder.status("status-session-a", .active(name: "Stale microphone A"))
            await settle()
            try expect(store.audioLevels.microphoneState == nil, "A stale callback changed the next recording's microphone")
            recorder.status("status-session-b", .active(name: "Synthetic microphone B"))
            try await wait { store.audioLevels.microphoneState == .active(name: "Synthetic microphone B") }
        } catch {
            store.startingRecording = false; store.startingRecordingID = nil
            store.stoppingRecording = false; store.isRecording = false; store.recordingID = nil
            await store.jobs.shutdown()
            throw error
        }
        store.isRecording = false; store.recordingID = nil; store.audioLevels.clear()
        await store.jobs.shutdown()
        print("PASS: actual AppStore accepts only its current/start session's nonfatal microphone status and keeps capture running")
    }

    private static func audioCheckCallbacks() async throws {
        let recorder = StatusRecorder()
        let check = AudioCheckController(recorder: recorder)
        do {
            check.start(systemAudio: true)
            try await wait { check.running && recorder.sessionID != nil }
            guard let first = recorder.sessionID, let stale = recorder.microphoneStatus else {
                throw AppError.message("Synthetic audio-check callback missing")
            }
            recorder.status(first, .unavailable)
            try await wait { check.levels.microphoneState == .unavailable }
            try expect(check.running && recorder.stopCount == 0 && check.error == nil,
                "A microphone status update stopped the independent system-audio check")
            await check.stop()
            stale(RecordingMicrophoneUpdate(sessionID: first, state: .unavailable))
            await settle()
            try expect(check.levels.microphoneState == nil && !check.running && !recorder.active,
                "A stopped preflight restored an old microphone status")
            check.start(systemAudio: true)
            try await wait { check.running && recorder.sessionID != first }
            guard let second = recorder.sessionID else { throw AppError.message("Second synthetic preflight did not start") }
            recorder.status(second, .active(name: "Synthetic microphone B"))
            try await wait { check.levels.microphoneState == .active(name: "Synthetic microphone B") }
            // Exercise generation and directory identity separately. Even an old
            // callback carrying a new session ID must not affect the new check.
            stale(RecordingMicrophoneUpdate(sessionID: second, state: .unavailable))
            recorder.status(first, .unavailable)
            await settle()
            try expect(check.levels.microphoneState == .active(name: "Synthetic microphone B") && check.running,
                "A stale generation or directory changed the next preflight's microphone state")
            recorder.status(second, .switching)
            try await wait { check.levels.microphoneState == .switching }
            await check.stop()
            try expect(check.levels.microphoneState == nil && !check.running && recorder.stopCount == 2,
                "Preflight Stop did not clear route state or release its backend exactly once")
            try expect(recorder.sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) },
                "Synthetic preflight left disposable microphone files behind")
        } catch { await check.stop(); throw error }
        print("PASS: preflight isolates microphone status by directory and generation; missing microphone stays nonfatal and Stop cleans up")
    }

    private static func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AppError.message("Synthetic microphone status timed out")
    }
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw AppError.message(message) }
    }
    private final class StatusRecorder: MeetingRecordingBackend, @unchecked Sendable {
        var failed: (@Sendable (RecordingFailure) -> Void)?
        var levels: (@Sendable (Double?, Double?) -> Void)?
        var microphoneStatus: (@Sendable (RecordingMicrophoneUpdate) -> Void)?
        private(set) var sessionID: String?
        private(set) var sources: [URL] = []
        private(set) var active = false
        private(set) var stopCount = 0
        func start(url: URL, systemAudio: Bool, video: Bool, videoQuality: RecordingVideoQuality,
                   audioQuality: RecordingAudioQuality, displayID: UInt32?, expectedDisplayUUID: String?) async throws {
            try Data("disposable status fixture".utf8).write(to: url)
            sessionID = url.deletingLastPathComponent().lastPathComponent
            sources.append(url); active = true
        }
        func stop() async throws {
            if active { active = false; stopCount += 1 }
        }
        func status(_ sessionID: String, _ state: RecordingMicrophoneState) {
            microphoneStatus?(RecordingMicrophoneUpdate(sessionID: sessionID, state: state))
        }
    }
}
#endif
