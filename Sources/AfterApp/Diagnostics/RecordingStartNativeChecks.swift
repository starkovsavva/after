import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import Foundation
import AfterCore

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
        try await microphonePermission()
        try await queuedStartCancellation()
        try await completedStartCancellation()
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
                   && !app.recordingSleepLease.isActive && app.startingRecordingID == nil && app.pendingRecordingFailure == nil,
                   "Canceling selection left a phantom meeting, error, identity or power assertion")
        try expect(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("meetings"), includingPropertiesForKeys: nil).isEmpty,
                   "Canceled uncommitted capture left an orphan source directory")
        print("PASS: a stale saved monitor cannot block Start; canceling consent cleans up without a phantom meeting")

        recorder.behavior = .failWhileStarting
        await app.startRecording(systemAudio: true, title: "Early stream failure")
        try expect(!app.startingRecording && !app.isRecording && app.meetings.isEmpty
                   && app.error == "Synthetic stream stopped before commit" && !app.recordingSleepLease.isActive,
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
                   && !app.recordingSleepLease.isActive && app.startingRecordingID == nil,
                   "Quit while selecting failed to cancel startup or created another meeting")
        print("PASS: quitting during screen selection cancels pending capture and completes teardown")
        print("7 native recording-start checks passed")
    }

    private static func microphonePermission() async throws {
        // Exercise the actual recorder before it reaches hardware. A system TCC
        // reply may never arrive until the user answers; Cancel and Quit must
        // release the app's waiter independently of that system-owned prompt.
        let replies = PermissionReplies()
        let app = AppStore(preview: true, recorder: MeetingRecorder(requestMicrophonePermission: { replies.request($0) }))
        let cancelled = Task { await app.startRecording(systemAudio: false, title: "Cancel microphone authorization") }
        try await wait { replies.count == 1 }
        await app.cancelRecordingStart()
        try await wait { !app.startingRecording }
        await cancelled.value
        try expect(!app.isRecording && app.meetings.isEmpty && app.error == nil && !app.recordingSleepLease.isActive,
                   "Cancel waited for a microphone permission reply or retained an uncommitted recording")
        replies.reply(at: 0, allowed: true)
        for _ in 0..<8 { await Task.yield() }
        try expect(!app.isRecording && app.meetings.isEmpty,
                   "A late permission approval revived a canceled recording")

        let denied = Task { await app.startRecording(systemAudio: false, title: "Denied microphone authorization") }
        try await wait { replies.count == 2 }
        replies.reply(at: 0, allowed: true) // The previous prompt cannot authorize this start.
        for _ in 0..<8 { await Task.yield() }
        try expect(app.startingRecording && !app.isRecording,
                   "An old microphone reply was reused by the next recording")
        replies.reply(at: 1, allowed: false)
        try await wait { !app.startingRecording }
        await denied.value
        try expect(!app.isRecording && app.meetings.isEmpty && app.error?.contains("Микрофон") == true,
                   "Denied microphone access did not preserve its actionable permission error")

        // AudioCheckController stops its recorder by canceling the same task,
        // then awaits it. That path must also finish without a system reply.
        let cancelledTask = Task { await app.startRecording(systemAudio: false, title: "Task cancellation during microphone prompt") }
        try await wait { replies.count == 3 }
        cancelledTask.cancel()
        try await wait { !app.startingRecording }
        await cancelledTask.value
        try expect(app.error == nil && !app.isRecording && !app.recordingSleepLease.isActive,
                   "Task cancellation waited for microphone authorization")

        let quitting = Task { await app.startRecording(systemAudio: false, title: "Quit during microphone prompt") }
        try await wait { replies.count == 4 }
        let shutdown = Task { await app.prepareForTermination() }
        try await wait { app.isTerminating && !app.startingRecording }
        await quitting.value; await shutdown.value
        replies.reply(at: 2, allowed: true); replies.reply(at: 3, allowed: true)
        for _ in 0..<8 { await Task.yield() }
        try expect(!app.isRecording && app.meetings.isEmpty && !app.recordingSleepLease.isActive && app.error == nil,
                   "Quit during microphone authorization waited for a reply or a late callback restarted capture")
        print("PASS: actual recorder cancels microphone permission waits on Cancel, task cancellation and Quit; late replies cannot authorize another start")
    }

    private final class PermissionReplies: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [RecordingPermissionRequest.Reply] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return replies.count }
        func request(_ reply: @escaping RecordingPermissionRequest.Reply) {
            lock.lock(); replies.append(reply); lock.unlock()
        }
        func reply(at index: Int, allowed: Bool) {
            lock.lock(); let reply = replies[index]; lock.unlock()
            reply(allowed)
        }
    }

    private static func queuedStartCancellation() async throws {
        let recorder = QueuedStartRecorder()
        let app = AppStore(preview: true, recorder: recorder)
        let start = Task { await app.startRecording(systemAudio: false, title: "Cancel before backend reserves startup") }
        try await wait { await recorder.gate.entered }
        await app.cancelRecordingStart()
        await recorder.gate.release()
        try await wait { !app.startingRecording }
        await start.value
        let cancelledRequests = await recorder.gate.permissionRequests
        try expect(cancelledRequests == 0 && !app.isRecording && app.meetings.isEmpty && app.error == nil,
                   "Cancellation before backend reservation was lost at the executor hop")
        await app.startRecording(systemAudio: false, title: "Retry after queued cancellation")
        let retriedRequests = await recorder.gate.permissionRequests
        try expect(retriedRequests == 1 && !app.startingRecording && app.error == "Synthetic permission result",
                   "A canceled previous start poisoned the next recording's task")
        await app.jobs.shutdown()
        print("PASS: cancellation before backend reservation remains attached to that start and does not block a later retry")
    }

    private final class QueuedStartRecorder: MeetingRecordingBackend, @unchecked Sendable {
        var failed: (@Sendable (RecordingFailure) -> Void)?
        var levels: (@Sendable (Double?, Double?) -> Void)?
        let gate = QueuedStartGate()
        func start(url: URL, systemAudio: Bool, video: Bool, videoQuality: RecordingVideoQuality,
                   audioQuality: RecordingAudioQuality, displayID: UInt32?, expectedDisplayUUID: String?) async throws {
            // Model the backend's executor hop before reserveStart(): its own
            // cancelPendingStart has no request to cancel yet.
            await gate.wait()
            try Task.checkCancellation()
            await gate.requestPermission()
            throw AppError.message("Synthetic permission result")
        }
        func stop() async throws {}
    }

    private actor QueuedStartGate {
        private(set) var entered = false
        private(set) var permissionRequests = 0
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            entered = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
        func requestPermission() { permissionRequests += 1 }
    }

    private static func completedStartCancellation() async throws {
        let recorder = CompletedStartRecorder()
        let app = AppStore(preview: true, recorder: recorder)
        recorder.beforeReturningSuccess = { [weak app] in await app?.cancelRecordingStart() }
        await app.startRecording(systemAudio: false, title: "Cancel after successful backend startup")
        try expect(!app.isRecording && !app.startingRecording && app.meetings.isEmpty && app.error == nil
                   && app.recordingStartTask == nil && !app.recordingSleepLease.isActive,
                   "A successful backend value overrode an explicit canceled start and committed a phantom recording")
        await app.jobs.shutdown()
        print("PASS: Cancel after backend success still prevents the coordinator from committing a recording")
    }

    private final class CompletedStartRecorder: MeetingRecordingBackend, @unchecked Sendable {
        var failed: (@Sendable (RecordingFailure) -> Void)?
        var levels: (@Sendable (Double?, Double?) -> Void)?
        var beforeReturningSuccess: (@Sendable () async -> Void)?
        func start(url: URL, systemAudio: Bool, video: Bool, videoQuality: RecordingVideoQuality,
                   audioQuality: RecordingAudioQuality, displayID: UInt32?, expectedDisplayUUID: String?) async throws {
            try Data("synthetic completed capture".utf8).write(to: url)
            // Model a backend that has already finished its internal startup
            // and returns success even after cancelPendingStart becomes a no-op.
            await beforeReturningSuccess?()
        }
        func stop() async throws {}
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
