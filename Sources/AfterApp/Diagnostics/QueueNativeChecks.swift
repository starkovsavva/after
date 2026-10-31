import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import Foundation
import AfterCore

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
        try BackgroundJobPresentationChecks.run()
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
        try await chatGPTQuota(root.appendingPathComponent("chatgpt-quota"))
        try await chatGPTSignOut(root.appendingPathComponent("chatgpt-signout"))
        try await historyRetry(root.appendingPathComponent("history-retry"))
        try await BackgroundJobsUINativeChecks.run(root: root.appendingPathComponent("history-ui"))
        print("14 native durable queue groups passed"); fflush(stdout)
    }
    private static func historyRetry(_ root: URL) async throws {
        let queue = JobCoordinator(root: root, changed: { _ in })
        try await queue.start { job, _, _ in
            if job.config.settings.cloudModel == "quota-model" && job.attempt == 1 {
                throw AppError.message("ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded. Fixture limit.")
            }
            return WorkerEvent(event: "done")
        }
        var config = planConfiguration(object: "same-summary", account: "quota-account"); config.command = "summarize"; config.settings.cloudModel = "quota-model"
        do { _ = try await queue.submit(config, resource: "cloud", revision: "v1", title: "Конспект", paid: true); throw AppError.message("Quota fixture unexpectedly succeeded") }
        catch { try expect(error.localizedDescription.contains("subscription_sharing_usage_limit_exceeded"), "Quota fixture did not pause") }
        guard let failure = try await queue.snapshot().first else { throw AppError.message("Quota fixture job missing") }
        var replacement = config; replacement.settings.cloudProvider = "custom"; replacement.settings.cloudModel = "new-model"
        _ = try await queue.submit(replacement, resource: "cloud", revision: "v2", title: "Конспект", paid: false)
        try expect(await queue.chatGPTAdmissionPaused("quota-account"), "Another route's success cannot silently resume the paused account")
        // The Continue queue control uses the separately persisted pause even
        // when other completed work pushes its failure beyond visible history.
        for index in 0..<55 { _ = try await submit(queue, "quota-history-\(index)", resource: "light").value }
        try expect(try await queue.snapshot().allSatisfy { $0.id != failure.id }, "Quota recovery fixture must exceed the terminal history window")
        try expect(await queue.chatGPTAdmissionPaused("quota-account"), "Clipping visible history lost the durable account pause")
        for account in [nil, "unrelated-account"] as [String?] {
            do { try await queue.retry(failure.id, confirmPaid: true, requiringLatestGeneration: true, resumingPausedAccount: account); throw AppError.message("Historical retry guard bypassed") }
            catch { try expect(error.localizedDescription.contains("более новая попытка"), "Historical retry did not reject an unrelated old job") }
        }
        do { try await queue.retry(failure.id, confirmPaid: false, requiringLatestGeneration: true, resumingPausedAccount: "quota-account"); throw AppError.message("Unconfirmed quota recovery succeeded") }
        catch { try expect(error.localizedDescription.contains("Подтвердите повтор платного запроса"), "Clipped quota recovery must reach and enforce paid confirmation") }
        try expect(await queue.chatGPTAdmissionPaused("quota-account"), "Unconfirmed quota recovery cleared the pause")
        try await queue.retry(failure.id, confirmPaid: true, requiringLatestGeneration: true, resumingPausedAccount: "quota-account")
        _ = try await queue.observe(failure.id)
        try expect(!(await queue.chatGPTAdmissionPaused("quota-account")), "Explicit confirmed quota recovery did not resume its exact account")
        await queue.shutdown()
        print("PASS: historical Retry is rejected; confirmed exact-account Continue recovers quota failures beyond the visible history window")
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
    private static func planConfiguration(object: String, account: String) -> JobConfiguration {
        var config = configuration(object: object)
        config.settings.mode = "cloud"; config.settings.cloudProvider = "chatgpt"
        config.settings.chatGPTAccountID = account; config.settings.cloudModel = "fixture-model"
        return config
    }
    private static func planSubmit(_ queue: JobCoordinator, object: String, account: String) -> Task<WorkerEvent?, Error> {
        let config = planConfiguration(object: object, account: account)
        return Task { try await queue.submit(config, resource: "cloud", revision: "v1", title: object, paid: true) }
    }
    private static func chatGPTQuota(_ root: URL) async throws {
        let probe = QueueCheckProbe(quotaFailureObjects: ["plan-limit"])
        let queue = try await coordinator(root.appendingPathComponent("admission"), probe: probe)
        let limited = planSubmit(queue, object: "plan-limit", account: "account-a")
        try await wait { await probe.startedObjects().contains("plan-limit") }
        let running = submit(queue, "already-running")
        try await wait { await probe.activeCount("cloud") == 2 }
        let pending = planSubmit(queue, object: "plan-pending", account: "account-a")
        let cancelled = planSubmit(queue, object: "plan-cancelled", account: "account-a")
        let otherAccount = planSubmit(queue, object: "other-account", account: "account-b")
        let otherProvider = submit(queue, "other-provider")
        try await wait { try await queue.snapshot().count == 6 }
        await probe.release("plan-limit")
        do { _ = try await limited.value; throw AppError.message("Quota response unexpectedly succeeded") }
        catch { try expect(error.localizedDescription.contains("subscription_sharing_usage_limit_exceeded"), "Exact quota failure was not returned to its caller") }
        try await wait { await queue.chatGPTAdmissionPaused("account-a") }
        try await wait { await probe.startedObjects().contains("other-account") }
        let failedID = try await queue.snapshot().first { $0.objectID == "plan-limit" }!.id
        let pendingJob = try await queue.snapshot().first { $0.objectID == "plan-pending" }!
        try expect(pendingJob.state == "queued" && pendingJob.attempt == 0, "Quota-paused work was claimed or failed")
        try expect(!(await probe.startedObjects()).contains("plan-pending"), "A new request used the exhausted account")
        try expect(await probe.isCancelled("already-running") == false, "Quota pause cancelled an already-running request")
        await probe.release("other-account"); _ = try await otherAccount.value
        try await wait { await probe.startedObjects().contains("other-provider") }
        await probe.release("other-provider"); _ = try await otherProvider.value
        await probe.release("already-running"); _ = try await running.value
        cancelled.cancel(); try await expectCancelled(cancelled)
        let cancelledID = try await queue.snapshot().first { $0.objectID == "plan-cancelled" }!.id
        try expect(await queue.subscriberCount(cancelledID) == 0, "Cancelling a quota-paused caller stranded a waiter")
        do { try await queue.retry(failedID, confirmPaid: false); throw AppError.message("Unconfirmed retry bypassed quota pause") }
        catch { try expect(error.localizedDescription != "Unconfirmed retry bypassed quota pause", "Paid retry did not require confirmation") }
        try expect(await queue.chatGPTAdmissionPaused("account-a"), "Rejected retry cleared the account pause")
        try await queue.retry(failedID, confirmPaid: true)
        _ = try await queue.observe(failedID)
        try await wait { await probe.startedObjects().contains("plan-pending") }
        await probe.release("plan-pending"); _ = try await pending.value
        try expect(!(await queue.chatGPTAdmissionPaused("account-a")), "Explicit retry did not resume the selected account")
        try expect(try await queue.snapshot().first { $0.id == failedID }?.attempt == 2, "Confirmed quota retry lost attempt identity")
        await queue.shutdown()

        // Paused duplicate subscribers must release the activity lease and all
        // waiting callers when the app closes, while SQLite retains their work.
        let power = QueuePowerProbe(), cleanupProbe = QueueCheckProbe(quotaFailureObjects: ["cleanup-limit"])
        let cleanup = BackgroundJobsController(root: root.appendingPathComponent("cleanup"), activityChanged: { power.transitions.append($0) })
        cleanup.connect { job, cancellation, event in try await cleanupProbe.execute(job, cancellation, event) }
        let limitConfig = planConfiguration(object: "cleanup-limit", account: "cleanup-account")
        let cleanupLimit = Task { try await cleanup.submit(limitConfig, resource: "cloud", revision: "v1", title: "Limit", paid: true) }
        try await wait { await cleanupProbe.startedObjects().contains("cleanup-limit") }
        let busyConfig = configuration(object: "cleanup-running")
        let cleanupRunning = Task { try await cleanup.submit(busyConfig, resource: "cloud", revision: "v1", title: "Other provider", paid: false) }
        try await wait { await cleanupProbe.activeCount("cloud") == 2 }
        let waitingConfig = planConfiguration(object: "cleanup-pending", account: "cleanup-account")
        let firstWaiter = Task { try await cleanup.submit(waitingConfig, resource: "cloud", revision: "v1", title: "Paused", paid: true) }
        let secondWaiter = Task { try await cleanup.submit(waitingConfig, resource: "cloud", revision: "v1", title: "Paused", paid: true) }
        try await wait { cleanup.pendingSubmissions == 4 && cleanup.jobs.count == 3 }
        await cleanupProbe.release("cleanup-limit")
        do { _ = try await cleanupLimit.value; throw AppError.message("Cleanup quota response unexpectedly succeeded") }
        catch { try expect(error.localizedDescription.contains("subscription_sharing_usage_limit_exceeded"), "Cleanup quota error missing") }
        await cleanupProbe.release("cleanup-running"); _ = try await cleanupRunning.value
        try await wait { cleanup.activeCount == 0 && cleanup.pausedChatGPTAccounts.contains("cleanup-account") }
        try expect(power.transitions == [true, false], "Quota-only waiters kept the idle-sleep/update gate active")
        try expect(cleanup.jobs.contains { $0.objectID == "cleanup-pending" && $0.state == "queued" && cleanup.isPaused($0) }, "Paused status did not reach the controller")
        await cleanup.shutdown(); try await expectCancelled(firstWaiter); try await expectCancelled(secondWaiter)
        try expect(cleanup.jobs.contains { $0.objectID == "cleanup-pending" && $0.state == "queued" }, "Shutdown discarded quota-paused durable work")
        try expect(power.transitions == [true, false], "Quota shutdown leaked or double-released the activity lease")
        let resumedProbe = QueueCheckProbe(automatic: true)
        let resumed = try await coordinator(root.appendingPathComponent("cleanup"), probe: resumedProbe)
        try expect(await resumed.chatGPTAdmissionPaused("cleanup-account"), "Relaunch lost the account's explicit quota pause")
        try expect(try await resumed.snapshot().contains { $0.objectID == "cleanup-pending" && $0.state == "queued" && $0.attempt == 0 },
                   "Relaunch silently admitted a subscription request before Continue queue was confirmed")
        _ = try await planSubmit(resumed, object: "reopened-other-account", account: "other-account").value
        _ = try await submit(resumed, "reopened-other-provider").value
        try expect(!(await resumedProbe.startedObjects()).contains("cleanup-pending"), "Other account/provider traffic bypassed the restored quota pause")
        guard let pausedFailure = try await resumed.snapshot().first(where: { $0.objectID == "cleanup-limit" }) else {
            throw AppError.message("Durable quota failure missing on relaunch")
        }
        do { try await resumed.retry(pausedFailure.id, confirmPaid: false); throw AppError.message("Relaunch bypassed paid confirmation") }
        catch { try expect(error.localizedDescription != "Relaunch bypassed paid confirmation", "Restored quota recovery must require confirmation") }
        try expect(await resumed.chatGPTAdmissionPaused("cleanup-account"), "Rejected confirmation cleared the durable quota pause")
        try await resumed.retry(pausedFailure.id, confirmPaid: true)
        _ = try await resumed.observe(pausedFailure.id)
        try await wait { try await resumed.snapshot().first { $0.objectID == "cleanup-pending" }?.state == "succeeded" }
        await resumed.shutdown()
        let reopened = try await coordinator(root.appendingPathComponent("cleanup"), probe: QueueCheckProbe(automatic: true))
        try expect(!(await reopened.chatGPTAdmissionPaused("cleanup-account")), "Relaunch resurrected an explicitly resumed quota pause")
        await reopened.shutdown()
        // The same word in an unrelated error, or a speech command using its
        // own API key, cannot put ChatGPT plan inference into a quota pause.
        for (index, command, message) in [
            (0, "example", "ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded_extra. Not the exact code."),
            (1, "transcribe", "ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded. Speech fixture.")
        ] {
            let unrelated = JobCoordinator(root: root.appendingPathComponent("not-quota-\(index)"), changed: { _ in })
            try await unrelated.start { _, _, _ in throw AppError.message(message) }
            var config = planConfiguration(object: "unrelated", account: "unrelated-account"); config.command = command
            do {
                _ = try await unrelated.submit(config, resource: "cloud", revision: "v1", title: "Unrelated", paid: true)
                throw AppError.message("Unrelated fixture unexpectedly succeeded")
            } catch { try expect(error.localizedDescription == message, "Unrelated fixture changed its error") }
            try expect(!(await unrelated.chatGPTAdmissionPaused("unrelated-account")), "Unrelated error or speech paused ChatGPT plan requests")
            await unrelated.shutdown()
        }
        print("PASS: account-scoped quota pause survives relaunch until confirmed Continue; other routes proceed, and cancellation/shutdown releases waiters and power")
    }
    private static func chatGPTSignOut(_ root: URL) async throws {
        let probe = QueueCheckProbe(), queue = try await coordinator(root, probe: probe)
        let first = planSubmit(queue, object: "signout-running-a", account: "signed-out-account")
        let second = planSubmit(queue, object: "signout-running-b", account: "signed-out-account")
        try await wait { await probe.activeCount("cloud") == 2 }
        let queued = planSubmit(queue, object: "signout-queued", account: "signed-out-account")
        let other = planSubmit(queue, object: "signout-other-account", account: "other-account")
        var speechConfig = planConfiguration(object: "signout-speech", account: "signed-out-account")
        speechConfig.command = "transcribe"; speechConfig.settings.speechMode = "cloud"
        let speech = Task { try await queue.submit(speechConfig, resource: "cloud", revision: "v1", title: "Speech", paid: true) }
        try await wait { try await queue.snapshot().count == 5 }
        await queue.cancelChatGPTAccount("signed-out-account")
        try await expectCancelled(first); try await expectCancelled(second); try await expectCancelled(queued)
        try await wait {
            let started = await probe.startedObjects()
            return started.contains("signout-other-account") && started.contains("signout-speech")
        }
        try expect(!(await probe.startedObjects()).contains("signout-queued"), "Sign-out batch admitted a queued request between cancellations")
        try expect(await probe.isCancelled("signout-other-account") == false, "Sign-out cancelled another account")
        try expect(await probe.isCancelled("signout-speech") == false, "Sign-out cancelled API-backed speech")
        await probe.release("signout-other-account"); await probe.release("signout-speech")
        _ = try await other.value; _ = try await speech.value
        try expect(!(await queue.chatGPTAdmissionPaused("signed-out-account")), "Temporary sign-out admission gate leaked after cancellation")
        await queue.shutdown()
        print("PASS: signing out cancels only that account's running/queued ChatGPT AI requests before admission resumes; other accounts and speech continue")
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
    private let quotaFailureObjects: Set<String>
    private var released: Set<String> = []
    private var releaseEverything = false
    private var active: [String: BackgroundJob] = [:]
    private var cancellations: [String: JobCancellation] = [:]
    private var started: [BackgroundJob] = []
    private var maxima: [String: Int] = [:]
    private var callbacks: [String: @Sendable (WorkerEvent) -> Void] = [:]
    init(automatic: Bool = false, ignoreCancellation: Bool = false, failFirstTranscription: Bool = false,
         quotaFailureObjects: Set<String> = []) {
        self.automatic = automatic; self.ignoreCancellation = ignoreCancellation; self.failFirstTranscription = failFirstTranscription
        self.quotaFailureObjects = quotaFailureObjects
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
        if quotaFailureObjects.contains(job.objectID), job.attempt == 1 {
            throw AppError.message("ChatGPT: HTTP 200 · subscription_sharing_usage_limit_exceeded. Fixture limit.")
        }
        return WorkerEvent(event: "done", message: job.id)
    }
    func release(_ id: String) { released.insert(id) }
    func releaseAll() { releaseEverything = true }
    func activeCount(_ resource: String) -> Int { active.values.filter { $0.resource == resource }.count }
    func startedCount(_ resource: String) -> Int { started.filter { $0.resource == resource }.count }
    func startedObjects() -> [String] { started.map(\.objectID) }
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
