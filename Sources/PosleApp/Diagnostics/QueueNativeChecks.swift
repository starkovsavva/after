#if DEBUG
import Foundation
import PosleCore

/// Real Swift actor/SQLite boundary with synthetic executors. No capture,
/// accounts, network, model loading, or production data is touched.
@MainActor
enum QueueNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Queue checks require --preview and a disposable POSLE_DATA_DIR")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path)
                   && root.lastPathComponent.hasPrefix("posle-native-check-"), "Refusing a non-disposable queue library")
        let existing = try RustBridge.shared.get().request(root: root, command: "job-list")
        let existingJSON = try JSONSerialization.jsonObject(with: existing) as? [String: Any]
        try expect((existingJSON?["jobs"] as? [Any])?.isEmpty == true, "Queue checks need an empty library")
        let watchdog = QueueCheckWatchdog(); watchdog.start(); defer { watchdog.finish() }
        try await limits(root.appendingPathComponent("limits"))
        try await subscriptions(root.appendingPathComponent("subscriptions"))
        try await restartChain(root.appendingPathComponent("chain"))
        try await interrupted(root.appendingPathComponent("interrupted"))
        try await storageFailure(root.appendingPathComponent("storage"))
        try await committedCancellation(root.appendingPathComponent("committed"))
        try await powerLease(root.appendingPathComponent("power"))
        try await ephemeralDictation(root.appendingPathComponent("dictation"))
        try await failedChain(root.appendingPathComponent("failed-chain"))
        print("9 native durable queue groups passed"); fflush(stdout)
    }
    private static func configuration(_ command: String = "example", object: String, autoSummary: Bool = false) -> JobConfiguration {
        var settings = AppSettings(); settings.autoSummary = autoSummary; settings.mode = "local"
        return JobConfiguration(command: command, meetingID: object, extra: [], input: nil, settings: settings)
    }
    private static func submit(_ coordinator: JobCoordinator, _ object: String, resource: String = "cloud", paid: Bool = false,
                               command: String = "example", autoSummary: Bool = false) -> Task<WorkerEvent?, Error> {
        let config = configuration(command, object: object, autoSummary: autoSummary)
        return Task { try await coordinator.submit(config, resource: resource, revision: "v1", title: object, paid: paid) }
    }
    private static func coordinator(_ root: URL, probe: QueueCheckProbe, errors: QueueErrorBox = QueueErrorBox()) async throws -> JobCoordinator {
        let value = JobCoordinator(root: root, changed: { _ in }, failed: { errors.record($0) })
        try await value.start { job, cancellation, event in try await probe.execute(job, cancellation, event) }
        return value
    }
    private static func limits(_ root: URL) async throws {
        let probe = QueueCheckProbe(); let queue = try await coordinator(root, probe: probe)
        await queue.setRecording(true)
        let tasks = [submit(queue, "heavy-a", resource: "local-heavy"), submit(queue, "heavy-b", resource: "local-heavy"),
                     submit(queue, "cloud-a"), submit(queue, "cloud-b"), submit(queue, "cloud-c")]
        try await wait { await probe.activeCount("cloud") == 2 }
        try expect(await probe.startedCount("local-heavy") == 0, "Recording must defer new heavy inference")
        await probe.release("cloud-a"); await probe.release("cloud-b")
        try await wait { await probe.startedCount("cloud") == 3 }
        await queue.setRecording(false)
        try await wait { await probe.startedCount("local-heavy") == 1 }
        await probe.releaseAll()
        for task in tasks { _ = try await task.value }
        let heavyMaximum = await probe.maximum("local-heavy"), cloudMaximum = await probe.maximum("cloud")
        try expect(heavyMaximum == 1 && cloudMaximum == 2, "Queue exceeded hardware/provider concurrency limits")
        print("PASS: actual actor admits two cloud jobs and one heavy job; recording defers heavy admission")
    }
    private static func subscriptions(_ root: URL) async throws {
        let probe = QueueCheckProbe(); let queue = try await coordinator(root, probe: probe)
        let first = submit(queue, "shared")
        try await wait { await probe.startedCount("cloud") == 1 }
        let second = submit(queue, "shared")
        let id = try await queue.snapshot().first!.id
        try await wait { await queue.subscriberCount(id) == 2 }
        first.cancel(); try await expectCancelled(first)
        try await wait { await queue.subscriberCount(id) == 1 }
        try expect(await probe.isCancelled("shared") == false, "Cancelling one subscriber stopped another subscriber's work")
        await probe.release("shared"); _ = try await second.value
        try expect(await probe.startedCount("cloud") == 1, "Dedup ran the same input twice")
        let running = submit(queue, "cancel-running")
        try await wait { await probe.startedCount("cloud") == 2 }
        let runningID = try await queue.snapshot().first { $0.objectID == "cancel-running" }!.id
        await queue.cancel(runningID); try await expectCancelled(running)
        await queue.setRecording(true)
        let queued = submit(queue, "cancel-queued", resource: "local-heavy")
        try await wait { try await queue.snapshot().contains { $0.objectID == "cancel-queued" && $0.state == "queued" } }
        let queuedID = try await queue.snapshot().first { $0.objectID == "cancel-queued" }!.id
        await queue.cancel(queuedID); try await expectCancelled(queued)
        await queue.setRecording(false)
        try expect(await probe.startedCount("local-heavy") == 0, "Cancelled queued work was executed")
        let immediate = submit(queue, "cancel-immediate"); immediate.cancel(); try await expectCancelled(immediate)
        try expect(try await queue.snapshot().allSatisfy { $0.objectID != "cancel-immediate" }, "Already-cancelled submission persisted an unwanted job")
        print("PASS: dedup subscribers cancel independently; queued/immediate cancellation does not start an executor")
    }
    private static func restartChain(_ root: URL) async throws {
        let before = QueueCheckProbe(); let queue = try await coordinator(root, probe: before)
        await queue.setRecording(true)
        let task = submit(queue, "chain", resource: "local-heavy", command: "transcribe", autoSummary: true)
        try await wait { try await queue.snapshot().count == 2 }
        await queue.shutdown(); try await expectCancelled(task)
        let saved = try await queue.snapshot()
        try expect(saved.allSatisfy { $0.state == "queued" }, "Shutdown discarded queued stages")
        let after = QueueCheckProbe(automatic: true); let relaunched = try await coordinator(root, probe: after)
        // Connecting again must not mark the currently executing attempt interrupted.
        try await relaunched.start { job, cancellation, event in try await after.execute(job, cancellation, event) }
        try await wait { try await relaunched.snapshot().allSatisfy { $0.state == "succeeded" } }
        try expect(await after.order() == ["transcribe", "summarize"], "Durable child did not run after its parent on relaunch")
        print("PASS: atomic transcription→summary chain survives close/relaunch; repeated start is harmless")
    }
    private static func interrupted(_ root: URL) async throws {
        let before = QueueCheckProbe(); let queue = try await coordinator(root, probe: before)
        let task = submit(queue, "paid", paid: true)
        try await wait { await before.startedCount("cloud") == 1 }
        await queue.shutdown(); try await expectCancelled(task)
        try await wait { await queue.isDrained() }
        let after = QueueCheckProbe(automatic: true); let relaunched = try await coordinator(root, probe: after)
        let job = try await relaunched.snapshot().first!
        try expect(job.state == "interrupted", "Shutdown interruption was misreported as an explicit user cancellation")
        do { try await relaunched.retry(job.id, confirmPaid: false); throw AppError.message("Paid retry was not confirmed") }
        catch { try expect(error.localizedDescription != "Paid retry was not confirmed", "Paid retry bypassed confirmation") }
        try expect(await after.startedCount("cloud") == 0, "Relaunch silently repeated a potentially billed request")
        try await relaunched.retry(job.id, confirmPaid: true)
        try await wait { try await relaunched.snapshot().first?.state == "succeeded" }
        try expect(try await relaunched.snapshot().first?.attempt == 2, "Explicit retry did not preserve attempt identity")
        print("PASS: interrupted paid work stays paused until an explicit confirmed retry")
    }
    private static func storageFailure(_ root: URL) async throws {
        let probe = QueueCheckProbe(); let errors = QueueErrorBox(); let queue = try await coordinator(root, probe: probe, errors: errors)
        await queue.setRecording(true)
        let task = submit(queue, "disk-problem", resource: "local-heavy")
        try await wait { try await queue.snapshot().count == 1 }
        let database = root.appendingPathComponent("jobs.sqlite"), saved = root.appendingPathComponent("saved.sqlite")
        try FileManager.default.moveItem(at: database, to: saved)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: false)
        await queue.setRecording(false)
        do { _ = try await task.value; throw AppError.message("Queue failure stranded or succeeded a waiter") }
        catch { try expect(error.localizedDescription != "Queue failure stranded or succeeded a waiter", "Queue storage failure was hidden") }
        try expect(!errors.message.isEmpty, "Queue storage failure was not reported to the UI")
        await queue.shutdown()
        try FileManager.default.removeItem(at: database); try FileManager.default.moveItem(at: saved, to: database)
        let restored = try await coordinator(root, probe: QueueCheckProbe(automatic: true))
        try await wait { try await restored.snapshot().first?.state == "succeeded" }
        print("PASS: SQLite failure reaches waiting callers/UI; intact queued work recovers on a fresh coordinator")
    }
    private static func committedCancellation(_ root: URL) async throws {
        let probe = QueueCheckProbe(ignoreCancellation: true); let queue = try await coordinator(root, probe: probe)
        let task = submit(queue, "committed")
        try await wait { await probe.startedCount("cloud") == 1 }
        let id = try await queue.snapshot().first!.id
        await queue.cancel(id); await probe.release("committed"); _ = try await task.value
        await probe.lateProgress("committed")
        try await Task.sleep(for: .milliseconds(50))
        let job = try await queue.snapshot().first!
        try expect(job.state == "succeeded" && job.progress == 1 && job.message == "Готово", "Late cancel/progress hid a committed result")
        print("PASS: committed success wins a late cancellation; stale progress cannot overwrite terminal state")
    }
    private static func powerLease(_ root: URL) async throws {
        let power = QueuePowerProbe(); let probe = QueueCheckProbe()
        let controller = BackgroundJobsController(root: root, activityChanged: { power.transitions.append($0) })
        controller.connect { job, cancellation, event in try await probe.execute(job, cancellation, event) }
        let config = configuration(object: "lease")
        let task = Task { try await controller.submit(config, resource: "cloud", revision: "v1", title: "Lease", paid: false) }
        try await wait { await probe.startedCount("cloud") == 1 }
        try expect(controller.activeCount > 0 && power.transitions == [true], "Pending/executing jobs did not acquire exactly one activity lease")
        await probe.release("lease"); _ = try await task.value
        try await wait { controller.activeCount == 0 }
        try expect(power.transitions == [true, false], "Completed work leaked its activity lease")
        await controller.shutdown()
        try expect(power.transitions == [true, false], "Shutdown released a lease twice")
        print("PASS: queued/running work shares one generation lease; completion/shutdown releases it once")
    }
    private static func ephemeralDictation(_ root: URL) async throws {
        let probe = QueueCheckProbe(); let queue = try await coordinator(root, probe: probe)
        await queue.setRecording(true)
        let queued = submit(queue, "ephemeral-queued", resource: "local-heavy", command: "dictate")
        try await wait { try await queue.snapshot().count == 1 }
        await queue.shutdown(); try await expectCancelled(queued)
        try expect(try await queue.snapshot().first?.state == "cancelled", "Shutdown retained queued dictation whose temporary audio will disappear")
        let after = QueueCheckProbe(automatic: true); let relaunched = try await coordinator(root, probe: after)
        try expect(await after.startedCount("local-heavy") == 0, "Relaunch executed cancelled dictation")
        // Reproduce a process dying after a dictation was claimed, before normal
        // shutdown could mark its result. New startup must cancel this path too.
        let bridge = try RustBridge.shared.get()
        let config = configuration("dictate", object: "ephemeral-interrupted")
        let configJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        _ = try bridge.request(root: root, command: "job-enqueue", arguments: ["kind": "dictate", "objectID": "ephemeral-interrupted", "config": configJSON, "resource": "local-heavy"])
        _ = try bridge.request(root: root, command: "job-claim")
        await relaunched.shutdown()
        let recovered = try await coordinator(root, probe: after)
        try expect(try await recovered.snapshot().allSatisfy { $0.state == "cancelled" }, "Startup offered a retry of missing ephemeral audio")
        try expect(await after.startedCount("local-heavy") == 0, "Startup uploaded or recognized missing dictation audio")
        print("PASS: queued and crash-interrupted dictation is cancelled before stale audio can be replayed")
    }
    private static func failedChain(_ root: URL) async throws {
        let power = QueuePowerProbe(); let probe = QueueCheckProbe(automatic: true, failFirstTranscription: true)
        let controller = BackgroundJobsController(root: root, activityChanged: { power.transitions.append($0) })
        controller.connect { job, cancellation, event in try await probe.execute(job, cancellation, event) }
        let config = configuration("transcribe", object: "retry-chain", autoSummary: true)
        do { _ = try await controller.submit(config, resource: "local-heavy", revision: "v1", title: "Chain", paid: false); throw AppError.message("Synthetic transcription unexpectedly succeeded") }
        catch { try expect(error.localizedDescription != "Synthetic transcription unexpectedly succeeded", "Expected first transcription failure") }
        try await wait { controller.jobs.count == 2 && controller.activeCount == 0 }
        try expect(controller.jobs.contains { $0.kind == "summarize" && $0.state == "blocked" }, "Failed parent stranded an active child")
        try expect(power.transitions == [true, false], "Failed chain held an idle-sleep/update gate forever")
        guard let parent = controller.jobs.first(where: { $0.kind == "transcribe" }) else { throw AppError.message("Chain parent missing") }
        controller.retry(parent)
        try await wait { controller.jobs.count == 2 && controller.jobs.allSatisfy { $0.state == "succeeded" } && controller.activeCount == 0 }
        try expect(power.transitions == [true, false, true, false], "Retry briefly released the lease before its dependent stage")
        await controller.shutdown()
        print("PASS: failed dependency releases active/power gates; explicit retry resumes only its dependent stage")
    }
    private static func expectCancelled(_ task: Task<WorkerEvent?, Error>) async throws {
        do { _ = try await task.value; throw AppError.message("Expected cancellation") }
        catch is CancellationError {} catch { throw error }
    }
    private static func wait(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<600 { if try await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw AppError.message("Queue scenario timed out")
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
}

private actor QueueCheckProbe {
    private let automatic: Bool
    private let ignoreCancellation: Bool
    private let failFirstTranscription: Bool
    private var released: Set<String> = []
    private var releaseEverything = false
    private var active: [String: BackgroundJob] = [:]
    private var cancellations: [String: JobCancellation] = [:]
    private var started: [BackgroundJob] = []
    private var maxima: [String: Int] = [:]
    private var callbacks: [String: @Sendable (WorkerEvent) -> Void] = [:]
    init(automatic: Bool = false, ignoreCancellation: Bool = false, failFirstTranscription: Bool = false) {
        self.automatic = automatic; self.ignoreCancellation = ignoreCancellation; self.failFirstTranscription = failFirstTranscription
    }
    func execute(_ job: BackgroundJob, _ cancellation: JobCancellation, _ event: @escaping @Sendable (WorkerEvent) -> Void) async throws -> WorkerEvent? {
        active[job.id] = job; started.append(job); cancellations[job.objectID] = cancellation; callbacks[job.objectID] = event
        maxima[job.resource] = max(maxima[job.resource] ?? 0, active.values.filter { $0.resource == job.resource }.count)
        defer { active.removeValue(forKey: job.id) }
        event(WorkerEvent(event: "progress", message: "Synthetic executor started"))
        while !automatic && !releaseEverything && !released.contains(job.objectID) {
            if cancellation.isCancelled && !ignoreCancellation { throw AppError.message("Synthetic terminated subprocess") }
            try await Task.sleep(for: .milliseconds(5))
        }
        if cancellation.isCancelled && !ignoreCancellation { throw AppError.message("Synthetic terminated subprocess") }
        if failFirstTranscription && job.kind == "transcribe" && job.attempt == 1 { throw AppError.message("Synthetic transcription failed") }
        return WorkerEvent(event: "done", message: job.id)
    }
    func release(_ id: String) { released.insert(id) }
    func releaseAll() { releaseEverything = true }
    func activeCount(_ resource: String) -> Int { active.values.filter { $0.resource == resource }.count }
    func startedCount(_ resource: String) -> Int { started.filter { $0.resource == resource }.count }
    func maximum(_ resource: String) -> Int { maxima[resource] ?? 0 }
    func isCancelled(_ object: String) -> Bool { cancellations[object]?.isCancelled ?? false }
    func order() -> [String] { started.map(\.kind) }
    func lateProgress(_ object: String) { var event = WorkerEvent(event: "progress", message: "Late stale progress"); event.fraction = 0.2; callbacks[object]?(event) }
}
@MainActor
private final class QueuePowerProbe { var transitions: [Bool] = [] }
private final class QueueErrorBox: @unchecked Sendable {
    private let lock = NSLock(); private var stored = ""
    var message: String { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ value: String) { lock.lock(); stored = value; lock.unlock() }
}
private final class QueueCheckWatchdog: @unchecked Sendable {
    private let lock = NSLock(); private var finished = false
    func start() { DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [self] in
        lock.lock(); let done = finished; lock.unlock()
        if !done { fputs("Native queue checks timed out\n", stderr); fflush(stderr); exit(2) }
    } }
    func finish() { lock.lock(); finished = true; lock.unlock() }
}
#endif
