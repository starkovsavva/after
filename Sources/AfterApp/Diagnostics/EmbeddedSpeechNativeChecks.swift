import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AppKit
import Foundation
import AfterCore

@MainActor
enum EmbeddedSpeechNativeChecks {
    static func run() async throws {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--embedded-root"), args.count > index + 1 else {
            throw AppError.message("The check requires an explicit synthetic test root.")
        }
        let root = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
        let meeting = root.appendingPathComponent("meetings/9f9e792a-1b09-441d-9811-87199e5d0d1e")
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: meeting.appendingPathComponent("meta.json"))) as? [String: Any]
        guard root.lastPathComponent == ".test-data", meta?["title"] as? String == "Synthetic embedded ASR verification", meta?["source"] as? String == "synthetic.wav" else {
            throw AppError.message("The check only accepts the owned synthetic fixture.")
        }
        let backend = root.deletingLastPathComponent().appendingPathComponent("backend")
        let interpreter = root.appendingPathComponent("runtime/venv/bin/python")
        let service = EmbeddedSpeechService()
        var beats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                beats += 1
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { heartbeat.cancel() }
        print("Embedded NSApplication check started; app PID=\(getpid())")
        fflush(stdout)
        service.resetCancellation()
        _ = try await service.run(root: root, interpreter: interpreter, backend: backend, command: "transcribe", meeting: meeting, diarization: false) { event in
            if let message = event.message { print("Embedded event: \(message)"); fflush(stdout) }
        }
        let transcript = try JSONSerialization.jsonObject(with: Data(contentsOf: meeting.appendingPathComponent("transcript.json"))) as? [String: Any]
        guard let segments = transcript?["segments"] as? [[String: Any]], segments.contains(where: { !(($0["text"] as? String) ?? "").isEmpty }), beats >= 3 else {
            throw AppError.message("Native ASR produced no text or blocked the main actor.")
        }
        _ = try await service.run(root: root, interpreter: interpreter, backend: backend, command: "probe", meeting: nil) { _ in }
        print("PASS: real Parakeet inference through Swift NSApplication; PID=\(getpid()); main-actor heartbeats=\(beats); segments=\(segments.count)")
        fflush(stdout)
        let session = root.appendingPathComponent("voice-inputs/" + UUID().uuidString.lowercased())
        let input = session.appendingPathComponent("input.wav")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: session) }
        let original = meeting.appendingPathComponent("synthetic.wav")
        let sourceBytes = try Data(contentsOf: original)
        try sourceBytes.write(to: input)
        let libraryBefore = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("meetings").path).sorted()
        let dictationStartedAt = beats
        service.resetCancellation()
        let dictation = try await service.dictate(root: root, interpreter: interpreter, backend: backend, audio: input) { event in
            if let message = event.message { print("Dictation event: \(message)"); fflush(stdout) }
        }
        guard !dictation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dictation.segments.isEmpty, dictation.duration > 0, dictation.pid == Int(getpid()),
              beats - dictationStartedAt >= 3,
              try Data(contentsOf: original) == sourceBytes,
              try Data(contentsOf: input) == sourceBytes,
              try FileManager.default.contentsOfDirectory(atPath: session.path) == ["input.wav"],
              try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("meetings").path).sorted() == libraryBefore else {
            throw AppError.message("Short dictation blocked the app, changed its source/library or left temporary audio.")
        }
        print("PASS E2E: real short Parakeet dictation → text in app PID=\(dictation.pid); main-actor beats=\(beats - dictationStartedAt); unchanged source; no fake meetings or temporary files")
        fflush(stdout)
        if args.contains("--full-flow") { try await meetingFlow(root: root) }
    }

    private static func meetingFlow(root: URL) async throws {
        guard ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] == root.path else {
            throw AppError.message("Full E2E requires POSLE_DATA_DIR to equal the explicit synthetic root.")
        }
        let manager = FileManager.default
        let app = AppStore(preview: true)
        app.settings.autoSummary = false
        app.settings.speechMode = "local"
        app.settings.diarization = true
        app.settings.speakerCount = 1
        // The fixture's pinned runtime was prepared explicitly by the test
        // harness; do not install or download anything from an E2E action.
        guard manager.isExecutableFile(atPath: app.python.path),
              manager.fileExists(atPath: root.appendingPathComponent("runtime/venv/pyvenv.cfg").path),
              manager.fileExists(atPath: app.settings.asrModelPath) else {
            throw AppError.message("Prepare the owned runtime and weights before this E2E.")
        }
        app.runtimeReady = true
        let initialIDs = Set(app.meetings.map(\.id))
        let original = root.appendingPathComponent("meetings/9f9e792a-1b09-441d-9811-87199e5d0d1e/synthetic.wav")
        let input = root.appendingPathComponent("E2E синтетическая встреча \(UUID().uuidString).wav")
        try manager.copyItem(at: original, to: input)
        defer { try? manager.removeItem(at: input) }
        let originalBytes = try Data(contentsOf: input)
        let clock = ContinuousClock()
        let started = clock.now
        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                heartbeats += 1
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        defer { heartbeat.cancel() }
        app.importFile(input)
        try await wait { !app.busy }
        guard let meeting = app.meetings.first(where: { !initialIDs.contains($0.id) }), app.error == nil,
              let transcript = app.transcript, !transcript.segments.isEmpty,
              app.selected?.status == "transcribed", app.selectedASRVerified, heartbeats > 5 else {
            throw AppError.message("Import → native Parakeet → local speaker split failed: \(app.error ?? "missing result")")
        }
        guard try Data(contentsOf: input) == originalBytes else { throw AppError.message("Import changed the input audio") }
        print("PASS E2E: Unicode-file import → real Parakeet → real local diarization → selected transcript; duration=\(started.duration(to: clock.now)); main-actor beats=\(heartbeats)")
        let directory = app.meetingDirectory(meeting.id)
        let source = directory.appendingPathComponent(meeting.source)
        guard try Data(contentsOf: source) == originalBytes else { throw AppError.message("Imported source is not an unchanged owned copy") }
        await app.rediarizeMeeting(meeting.id, speakers: 1)
        guard app.error == nil, let updated = app.transcript,
              updated.segments.map(\.id) == transcript.segments.map(\.id),
              updated.segments.map(\.text) == transcript.segments.map(\.text),
              updated.segments.map(\.start) == transcript.segments.map(\.start),
              updated.segments.map(\.end) == transcript.segments.map(\.end) else {
            throw AppError.message("Re-diarization changed the evidence")
        }
        app.openSegment(updated.segments[0].id)
        guard app.navigationTarget?.segmentID == updated.segments[0].id, !app.isPlaying else { throw AppError.message("Source jump lost its target or autoplayed") }
        print("PASS E2E: repeat speaker calculation → exact source jump; IDs/text/times/source preserved")
        let saved = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let processing = Task { await app.processMeeting(meeting.id) }
        try await wait { app.busy }
        app.cancelJob()
        await processing.value
        guard !app.busy, app.error == nil, app.notice == "Обработка остановлена. Запись сохранена.",
              try Data(contentsOf: directory.appendingPathComponent("transcript.json")) == saved,
              try Data(contentsOf: source) == originalBytes else { throw AppError.message("Stop did not preserve the completed transcription") }
        print("PASS E2E: cancel real app processing → notice, idle UI and byte-identical old result/audio")
        let model = app.settings.asrModelPath
        app.settings.asrModelPath = root.appendingPathComponent("missing-e2e-model").path
        await app.processMeeting(meeting.id)
        guard !app.busy, app.error != nil, try Data(contentsOf: directory.appendingPathComponent("transcript.json")) == saved else { throw AppError.message("Failed retry lost old data or left the app busy") }
        app.settings.asrModelPath = model
        await app.processMeeting(meeting.id)
        guard !app.busy, app.error == nil, app.selected?.status == "transcribed" else { throw AppError.message("Retry after a missing-model error failed") }
        let reopened = AppStore(preview: true)
        guard reopened.meetings.contains(where: { $0.id == meeting.id }) else { throw AppError.message("Reopening lost the imported meeting") }
        let bytes = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        try bytes.write(to: URL(fileURLWithPath: "/private/tmp/posle-e2e-real-transcript.json"), options: .atomic)
        print("PASS E2E: missing model → recoverable error → retry → reopen persisted library; actual transcript=/private/tmp/posle-e2e-real-transcript.json")
        fflush(stdout)
    }

    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw AppError.message("Native E2E timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
