#if DEBUG
import Foundation
import PosleCore

/// Calls the actual AppStore capture/finalization flow with only the hardware
/// boundary and expensive executor injected. Source files are disposable bytes.
@MainActor
enum RecordingSessionNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Recording session checks need --preview and disposable data")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path)
                   && root.lastPathComponent.hasPrefix("posle-native-check-"), "Refusing non-disposable capture data")
        let watchdog = RecordingSessionWatchdog(); watchdog.start(); defer { watchdog.finish() }
        let fake = SyntheticMeetingRecorder(), gate = RecordingFinalizationGate()
        let store = AppStore(preview: true, recorder: fake) { job, cancellation, event in
            try await gate.execute(job, cancellation: cancellation, event: event)
        }
        try expect(store.meetings.isEmpty, "Recording session checks need an empty library")
        store.settings.mode = "local"; store.settings.localProvider = "lmstudio"; store.settings.localModel = "global-model"
        store.saveSettings()
        var englishOverrides = FolderOverrides()
        englishOverrides.features = FolderFeatureOverrides(); englishOverrides.features?.cards = true
        englishOverrides.generateCards = true; englishOverrides.language = "en"; englishOverrides.localModel = "english-model"
        var workOverrides = FolderOverrides()
        workOverrides.features = FolderFeatureOverrides(); workOverrides.features?.cards = false
        workOverrides.generateCards = false; workOverrides.language = "ru"; workOverrides.localModel = "work-model"
        guard let english = store.notes.saveFolder(LibraryFolder(name: "Английский", overrides: englishOverrides)),
              let work = store.notes.saveFolder(LibraryFolder(name: "Рабочие синки", overrides: workOverrides)) else {
            throw AppError.message(store.notes.error ?? "Recording folder fixtures failed")
        }
        store.runtimeReady = false; store.busy = true
        store.folderSelection = english.id
        store.libraryFilter = "Несовпадающий старый поиск"
        let destination = RecordingDestination(folderID: english.id, generateCards: false)
        let admission = RecordingAdmissionGate()
        fake.startGate = admission
        let starting = Task { await store.startRecording(systemAudio: false, title: "Запись без установленной модели", destination: destination) }
        try await wait { await admission.entered }
        store.folderSelection = work.id
        await admission.release(); await starting.value
        fake.startGate = nil
        try expect(store.isRecording && store.captureMeetingID != nil, "Model setup or unrelated work blocked capture")
        let first = store.captureMeetingID!
        try expect(store.folderID(for: first) == english.id && store.folderSelection == english.id
                   && store.filteredMeetings.contains(where: { $0.id == first }) && store.selected?.generateCards == false,
                   "A sidebar change during capture authorization changed the explicitly selected destination or per-meeting override")
        try expect(store.effectiveSettings(for: first).language == "en" && store.effectiveSettings(for: first).localModel == "english-model"
                   && store.settings.localModel == "global-model" && !store.generatesCards(for: store.selected!),
                   "Recorded meeting did not resolve its folder language/model or ignored explicit generation-off")
        store.busy = false; store.processAfterRecording = false
        let savingWithoutModels = Task { await store.stopRecording() }
        try await wait { await gate.started(first) }
        await gate.release(first); await savingWithoutModels.value
        try expect(!store.isRecording && store.captureMeetingID == nil && store.recordingAssertion == 0, "Raw capture did not release its lifecycle/power lease")
        try expect(FileManager.default.fileExists(atPath: store.meetingDirectory(first).appendingPathComponent("recording.m4a").path), "Recording without models did not preserve its source")
        let captured = await gate.job(first)
        try expect(captured?.config.folderID == english.id && captured?.config.settings.localModel == "english-model",
                   "Finalization did not capture the recorded meeting's canonical folder profile")
        let reopened = AppStore(preview: true)
        try expect(reopened.folderID(for: first) == english.id && reopened.meetings.first(where: { $0.id == first })?.generateCards == false
                   && reopened.effectiveSettings(for: first).language == "en", "Recording folder or card override was lost after reopening")
        print("PASS: actual capture preserves selected folder and per-meeting card override across authorization, queueing and reopening")
        print("PASS: actual capture saves source and admits media finalization without installed ASR models")

        store.runtimeReady = true; store.settings.autoSummary = false; store.folderSelection = work.id
        for fails in [false, true] {
            await store.startRecording(systemAudio: false, title: fails ? "Первая с ошибкой обработки" : "Первая запись")
            guard let oldID = store.captureMeetingID else { throw AppError.message("First synthetic capture did not start") }
            store.processAfterRecording = false
            if fails { await gate.fail(oldID) }
            let stopping = Task { await store.stopRecording() }
            try await wait { await gate.started(oldID) }
            try expect(!store.isRecording && !store.stoppingRecording, "Encoding monopolized the capture controls")
            await store.startRecording(systemAudio: false, title: "Следующая запись")
            guard let newID = store.captureMeetingID, let newDate = store.recordingDate else { throw AppError.message("Second capture was blocked by prior finalization") }
            try expect(store.folderID(for: newID) == work.id && !store.effectiveSettings(for: newID).features.cards
                       && store.effectiveSettings(for: newID).language == "ru" && store.selected?.generateCards == nil,
                       "A new recording failed to inherit its selected work folder independently")
            store.processAfterRecording = false
            try expect(oldID != newID, "Two captures reused one meeting identity")
            fake.failed?(RecordingFailure(sessionID: oldID, message: "late writer callback"))
            try await Task.sleep(for: .milliseconds(30))
            try expect(store.isRecording && store.captureMeetingID == newID && fake.active && store.error == nil,
                       "A stale capture failure stopped or reported an error for the next recording")
            await gate.release(oldID); await stopping.value
            try expect(store.isRecording && store.captureMeetingID == newID && store.recordingDate == newDate && !store.stoppingRecording,
                       "Earlier finalization cleared or changed the new capture")
            try expect(fake.active, "Earlier finalization stopped the injected new recorder")
            await gate.release(newID); await store.stopRecording()
            try expect(!store.isRecording && store.recordingAssertion == 0 && !fake.active, "Second capture did not stop cleanly")
            for id in [oldID, newID] {
                try expect(FileManager.default.fileExists(atPath: store.meetingDirectory(id).appendingPathComponent("recording.m4a").path), "A finalization result discarded an original recording")
            }
        }
        print("PASS: delayed success and failure from recording A preserve recording B, its date, identity and source")
        try expect(fake.startCount == 5 && fake.stopCount == 5, "Capture lifecycle started or stopped the wrong number of sessions")
        await store.startRecording(systemAudio: false, title: "Deleted destination", destination: RecordingDestination(folderID: "missing-folder"))
        try expect(!store.isRecording && !store.startingRecording && fake.startCount == 5 && store.error?.contains("Папка удалена") == true,
                   "Deleted recording folder must fail before admitting hardware capture")
        let baseDestination = RecordingDestination(folderID: nil)
        store.folderSelection = english.id
        let backgroundID = UUID().uuidString
        let background = Task { try await store.worker("finalize", id: backgroundID) }
        try await wait { await gate.started(backgroundID) }
        await store.startRecording(systemAudio: false, title: "Запись при выходе", destination: baseDestination)
        guard let exitCaptureID = store.captureMeetingID else { throw AppError.message("Quit capture did not start") }
        try expect(store.folderID(for: exitCaptureID) == nil && store.effectiveSettings(for: exitCaptureID).localModel == "global-model",
                   "An explicit base-library destination borrowed a changed sidebar folder")
        // Model a legacy preparation operation which exits only when explicitly cancelled.
        store.beginJob(id: nil)
        let legacy = Task {
            while !store.cancellationRequested { try? await Task.sleep(for: .milliseconds(5)) }
            store.endJob()
        }
        await store.prepareForTermination()
        await legacy.value
        do { _ = try await background.value; throw AppError.message("Quit did not cancel the blocked background operation") }
        catch is CancellationError {}
        try expect(store.isTerminating && !store.busy && !store.isRecording && !fake.active
                   && store.recordingAssertion == 0 && store.assertions == 0, "Quit left capture or legacy work alive")
        try expect(FileManager.default.fileExists(atPath: store.meetingDirectory(exitCaptureID).appendingPathComponent("recording.m4a").path),
                   "Quit failed to flush original audio")
        let data = try RustBridge.shared.get().request(root: root, command: "job-list")
        let records = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["jobs"] as? [[String: Any]] ?? []
        try expect(!records.contains { ($0["objectID"] as? String) == exitCaptureID }, "Quit started expensive encoding instead of saving raw capture")
        await store.startRecording(systemAudio: false, title: "Must not start while terminating")
        try expect(fake.startCount == 6 && fake.stopCount == 6, "Termination admitted another capture")
        do { _ = try await store.worker("finalize", id: exitCaptureID); throw AppError.message("Termination admitted new queued work") }
        catch is CancellationError {}
        print("PASS: quit cancels blocked background and legacy work while flushing raw capture without starting encoding")
        try await runtimeAdmission()
        try await CaptureSelectionNativeChecks.run()
        try await CaptureWriterNativeChecks.run(root: root)
        try await CaptureAudioNativeChecks.run(root: root)
        try CaptureClockNativeChecks.run()
        try await MicrophoneStatusNativeChecks.run(root: root)
        try await MicrophoneRouteNativeChecks.run(root: root)
        try CaptureDriftNativeChecks.run()
        print("Recording session, writer, audio, clock and microphone route checks passed"); fflush(stdout)
    }
    private static func runtimeAdmission() async throws {
        let lease = LocalRuntimeLease()
        for _ in 0..<2 {
            let held = try await lease.acquire()
            let entered = RuntimeAdmissionProbe()
            let waiting = Task {
                let token = try await lease.acquire()
                await entered.mark()
                return token
            }
            let cancelled = Task { try await lease.acquire() }
            try await Task.sleep(for: .milliseconds(40))
            try expect(await entered.value == false, "Runtime admitted overlapping preparation and inference")
            cancelled.cancel()
            do { _ = try await cancelled.value; throw AppError.message("Cancelled runtime waiter was admitted") }
            catch is CancellationError {}
            await lease.release(held)
            let next = try await waiting.value
            try expect(await entered.value, "Runtime failed to admit the next operation")
            await lease.release(next)
        }
        let final = try await lease.acquire(); await lease.release(final)
        print("PASS: shared runtime excludes preparation/inference in both directions and cancellation releases queued admission")
    }
    private static func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<600 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw AppError.message("Synthetic recording finalization timed out")
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
}
private final class SyntheticMeetingRecorder: MeetingRecordingBackend, @unchecked Sendable {
    var failed: (@Sendable (RecordingFailure) -> Void)?
    var levels: (@Sendable (Double?, Double?) -> Void)?
    private(set) var active = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startGate: RecordingAdmissionGate?
    func start(url: URL, systemAudio: Bool, video: Bool, videoQuality: RecordingVideoQuality,
               audioQuality: RecordingAudioQuality, displayID: UInt32?, expectedDisplayUUID: String?) async throws {
        guard !active else { throw AppError.message("Synthetic recorder already active") }
        if let startGate { try await startGate.wait() }
        try Data("owned synthetic capture".utf8).write(to: url, options: .atomic)
        active = true; startCount += 1
    }
    func stop() async throws { if active { active = false; stopCount += 1 } }
}
private actor RecordingAdmissionGate {
    private(set) var entered = false
    private var released = false
    func wait() async throws {
        entered = true
        while !released { try await Task.sleep(for: .milliseconds(5)) }
    }
    func release() { released = true }
}
private actor RecordingFinalizationGate {
    private var jobs: [String: BackgroundJob] = [:]
    private var startedIDs: Set<String> = []
    private var released: Set<String> = []
    private var failures: Set<String> = []
    func execute(_ job: BackgroundJob, cancellation: JobCancellation, event: @escaping @Sendable (WorkerEvent) -> Void) async throws -> WorkerEvent? {
        guard job.kind == "finalize" else { throw AppError.message("Unexpected expensive operation in recording session test") }
        jobs[job.objectID] = job
        startedIDs.insert(job.objectID)
        while !released.contains(job.objectID) {
            if cancellation.isCancelled { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
        if failures.contains(job.objectID) { throw AppError.message("Synthetic finalization failed") }
        return WorkerEvent(event: "done", message: "Synthetic finalization completed")
    }
    func job(_ id: String) -> BackgroundJob? { jobs[id] }
    func started(_ id: String) -> Bool { startedIDs.contains(id) }
    func release(_ id: String) { released.insert(id) }
    func fail(_ id: String) { failures.insert(id) }
}
private actor RuntimeAdmissionProbe {
    private(set) var value = false
    func mark() { value = true }
}
private final class RecordingSessionWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func start() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) { [self] in
            lock.lock(); let timedOut = !finished; lock.unlock()
            if timedOut { fputs("Recording session regression timed out\n", stderr); fflush(stderr); exit(2) }
        }
    }
    func finish() { lock.lock(); finished = true; lock.unlock() }
}
#endif
