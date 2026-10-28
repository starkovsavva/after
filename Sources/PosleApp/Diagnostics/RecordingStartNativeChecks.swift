#if DEBUG
import Foundation
import PosleCore

/// Calls the actual capture coordinator with only consent/hardware injected.
/// No microphone, screen, system permission, account or real library is used.
@MainActor
enum RecordingStartNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Recording-start checks require a disposable preview")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path)
                   && root.lastPathComponent.hasPrefix("posle-native-check-"), "Refusing real capture data")
        let recorder = PendingRecorder()
        let app = AppStore(preview: true, recorder: recorder)
        try expect(app.meetings.isEmpty, "An empty capture fixture is required")
        app.settings.recordDisplayUUID = "stale-disconnected-monitor"
        app.settings.recordVideo = true
        let cancelled = Task { await app.startRecording(systemAudio: true, video: true, title: "Cancel native selection") }
        try await wait { await recorder.gate.entered }
        try expect(app.startingRecording && !app.isRecording, "Pending consent must not report active capture")
        await app.cancelRecordingStart()
        await cancelled.value
        try expect(!app.startingRecording && !app.isRecording && app.meetings.isEmpty && app.error == nil
                   && app.recordingAssertion == 0 && app.startingRecordingID == nil && app.pendingRecordingFailure == nil,
                   "Canceling selection left a phantom meeting, error, identity or power assertion")
        try expect(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("meetings"), includingPropertiesForKeys: nil).isEmpty,
                   "Canceled uncommitted capture left an orphan source directory")
        print("PASS: a stale saved monitor cannot block Start; canceling consent cleans up without a phantom meeting")

        recorder.behavior = .failWhileStarting
        await app.startRecording(systemAudio: true, title: "Early stream failure")
        try expect(!app.startingRecording && !app.isRecording && app.meetings.isEmpty
                   && app.error == "Synthetic stream stopped before commit" && app.recordingAssertion == 0,
                   "An early stream callback was lost and committed a false active recording")
        print("PASS: a stream failure between backend startup and meeting commit cannot become a false active recording")

        recorder.behavior = .success
        await app.startRecording(systemAudio: true, title: "Stop from macOS")
        guard let id = app.recordingID else { throw AppError.message("Synthetic recording did not start") }
        recorder.failed?(RecordingFailure(sessionID: id, message: "Synthetic user Stop", userInitiated: true))
        try await wait { !app.isRecording }
        try expect(app.error == nil && app.notice?.contains("Исходная запись сохранена") == true
                   && FileManager.default.fileExists(atPath: app.meetingDirectory(id).appendingPathComponent("recording.mov").path),
                   "A native user Stop must preserve source and show a neutral saved notice")
        let data = try RustBridge.shared.get().request(root: root, command: "job-list")
        let jobs = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["jobs"] as? [[String: Any]] ?? []
        try expect(!jobs.contains { ($0["objectID"] as? String) == id }, "Native Stop unexpectedly started encoding or inference")
        print("PASS: stopping in macOS saves original capture without an error banner or unrequested processing")

        recorder.behavior = .waitForSelection
        await recorder.gate.reset()
        let pendingQuit = Task { await app.startRecording(systemAudio: true, title: "Quit during selection") }
        try await wait { await recorder.gate.entered }
        await app.prepareForTermination()
        await pendingQuit.value
        try expect(app.isTerminating && !app.startingRecording && !app.isRecording && app.meetings.count == 1
                   && app.recordingAssertion == 0 && app.startingRecordingID == nil,
                   "Quit while selecting failed to cancel startup or created another meeting")
        print("PASS: quitting during screen selection cancels pending capture and completes teardown")
        print("4 native recording-start checks passed")
    }

    private final class PendingRecorder: MeetingRecordingBackend, @unchecked Sendable {
        enum Behavior { case waitForSelection, failWhileStarting, success }
        var failed: (@Sendable (RecordingFailure) -> Void)?
        var levels: (@Sendable (Double?, Double?) -> Void)?
        var behavior = Behavior.waitForSelection
        let gate = SelectionGate()
        func start(url: URL, systemAudio: Bool, video: Bool, videoQuality: RecordingVideoQuality,
                   audioQuality: RecordingAudioQuality, displayID: UInt32?, expectedDisplayUUID: String?) async throws {
            guard displayID == nil, expectedDisplayUUID == nil else { throw AppError.message("Saved monitor leaked into per-session consent") }
            switch behavior {
            case .waitForSelection: try await gate.wait()
            case .failWhileStarting:
                failed?(RecordingFailure(sessionID: url.deletingLastPathComponent().lastPathComponent,
                                         message: "Synthetic stream stopped before commit"))
                for _ in 0..<8 { await Task.yield() }
            case .success: try Data("synthetic authorized recording".utf8).write(to: url)
            }
        }
        func stop() async throws {}
        func cancelPendingStart() async { await gate.cancel() }
    }
    private actor SelectionGate {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Error>?
        private var cancelled = false
        func wait() async throws {
            entered = true
            guard !cancelled else { throw CancellationError() }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func cancel() {
            cancelled = true
            let pending = continuation; continuation = nil
            pending?.resume(throwing: CancellationError())
        }
        func reset() { entered = false; cancelled = false }
    }
    private static func wait(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !(await condition()) {
            guard Date() < deadline else { throw AppError.message("Recording-start lifecycle timeout") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw AppError.message(message) }
    }
}
#endif
