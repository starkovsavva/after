import AppKit
import Combine
import CryptoKit
import Foundation
import IOKit.pwr_mgt
import PosleCore
import SwiftUI

struct JobConfiguration: Codable {
    var command: String
    var meetingID: String?
    var extra: [String]
    var input: Data?
    var settings: AppSettings
    var folderProfile: Data? = nil
    var folderID: String? = nil
    var profileMeetingID: String? = nil
    /// Explicit recovery creates a new operation; old attempts stay in history.
    var restartOfJobID: String? = nil

    /// Speech keeps its separate API-key billing path even when summaries use ChatGPT.
    var chatGPTPlanAccountID: String? {
        guard settings.mode == "cloud", settings.cloudProvider == "chatgpt",
              ["summarize", "example", "expand-notes", "voice-plan"].contains(command),
              !settings.chatGPTAccountID.isEmpty else { return nil }
        return settings.chatGPTAccountID
    }
}

struct BackgroundJob: Decodable, Identifiable {
    var id: String
    var kind: String
    var objectID: String
    var inputRevision: String
    var dependencies: [String]
    var config: JobConfiguration
    var resource: String
    var state: String
    var progress: Double?
    var message: String
    var title: String
    var attempt: Int
    var paid: Bool
    var cancelRequested: Bool
    var createdAt: Double
    var updatedAt: Double
    var active: Bool { ["queued", "running"].contains(state) }
    var hasProfileFailure: Bool {
        guard ["failed", "interrupted"].contains(state) else { return false }
        return ["Настройки модели не совпадают с сохранённым профилем операции.",
                "Профиль папки изменился после постановки в очередь.",
                "Профиль папки изменился во время обработки.",
                "Папка или её настройки изменились.", "У встречи появилась папка.",
                "У фоновой операции нет сохранённого профиля папки."].contains { message.hasPrefix($0) }
    }
    var canReopenVoiceCommand: Bool {
        kind == "voice-plan" && config.command == "voice-plan" && config.input != nil
            && (hasProfileFailure || (["failed", "interrupted"].contains(state) && message.hasPrefix("Данные изменились после постановки в очередь.")))
    }
    static let changedNoteSourceMessage = "Исходная заметка или запись изменились. Запустите дополнение заново с текущими данными."
    var canRestartWithCurrentProfile: Bool {
        let changedNoteSource = config.command == "expand-notes" && ["failed", "interrupted"].contains(state)
            && message == Self.changedNoteSourceMessage
        guard kind == config.command, hasProfileFailure || changedNoteSource else { return false }
        switch config.command {
        case "summarize", "example": return config.meetingID != nil
        case "expand-notes":
            return config.extra.firstIndex(of: "--note").map { config.extra.indices.contains($0 + 1) && !config.extra[$0 + 1].isEmpty } == true
        default: return false
        }
    }
    var retryTitle: String {
        if canReopenVoiceCommand { return L("Открыть поручение…") }
        if canRestartWithCurrentProfile { return L("Запустить заново…") }
        return L("Повторить")
    }
    var retryHelp: String {
        if canReopenVoiceCommand { return L("Открыть исходный текст в помощнике. Новый запуск использует текущие настройки и требует нажатия «Выполнить».") }
        if canRestartWithCurrentProfile { return L("Создать новую операцию с текущими настройками папки. Предыдущая попытка останется в истории; перед запуском будут показаны выбранные модель и провайдер.") }
        return L("Повторить с сохранёнными настройками этой операции.")
    }
    var stateLabel: String {
        switch state {
        case "queued": return L("В очереди")
        case "running": return message.isEmpty ? L("Выполняется") : L(message)
        case "succeeded": return L("Готово")
        case "cancelled": return L("Отменено")
        case "interrupted": return L("Прервано — можно повторить")
        case "blocked": return L("Ожидает предыдущего этапа")
        default: return message.isEmpty ? L("Не удалось завершить") : L(message)
        }
    }
}

/// Cancellation and the process handle belong to one attempt, never the app.
final class JobCancellation: @unchecked Sendable {
    let runner = ProcessRunner()
    private let lock = NSLock()
    private var cancelled = false
    private var embeddedCancel: (() -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attachEmbedded(_ action: @escaping () -> Void) throws {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        embeddedCancel = action
        lock.unlock()
    }
    func cancel() {
        lock.lock(); cancelled = true; let embedded = embeddedCancel; lock.unlock()
        runner.cancel(); embedded?()
    }
}

/// SQLite is authoritative; this actor owns live handles and admission only.
/// CPU inference stays in the existing native/background executors.
actor JobCoordinator {
    typealias Executor = @Sendable (BackgroundJob, JobCancellation, @escaping @Sendable (WorkerEvent) -> Void) async throws -> WorkerEvent?
    private struct RunningAttempt {
        let number: Int
        let cancellation: JobCancellation
    }
    private let root: URL
    private let changed: @Sendable ([BackgroundJob]) -> Void
    private let failed: @Sendable (String) -> Void
    private let admissionChanged: @Sendable ([String: BackgroundJob]) -> Void
    private var pausedChatGPTFailures: [String: BackgroundJob] = [:]
    private var signingOutChatGPTAccounts: Set<String> = []
    private var executor: Executor?
    private var running: [String: RunningAttempt] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<WorkerEvent?, Error>]] = [:]
    private var recording = false
    private var stopping = false
    private var started = false
    private var queueFailure: String?
    private var lastProgress: [String: Date] = [:]

    init(root: URL, changed: @escaping @Sendable ([BackgroundJob]) -> Void,
         failed: @escaping @Sendable (String) -> Void = { _ in },
         admissionChanged: @escaping @Sendable ([String: BackgroundJob]) -> Void = { _ in }) {
        self.root = root; self.changed = changed; self.failed = failed; self.admissionChanged = admissionChanged
    }
    private func request(_ command: String, _ arguments: [String: Any] = [:]) throws -> Data {
        try RustBridge.shared.get().request(root: root, command: command, arguments: arguments)
    }
    func snapshot() throws -> [BackgroundJob] {
        struct Response: Decodable { var jobs: [BackgroundJob] }
        return try JSONDecoder().decode(Response.self, from: request("job-list")).jobs
    }
    private func failQueue(_ error: Error) {
        let message = LF("Не удалось обновить очередь. Операции сохранены; перезапустите приложение. {0}", arguments: [String(describing: error.localizedDescription)])
        if queueFailure != message { failed(message) }
        queueFailure = message
        let pendingIDs = waiters.keys.filter { running[$0] == nil }
        for id in pendingIDs {
            for continuation in waiters.removeValue(forKey: id)?.values ?? Dictionary<UUID, CheckedContinuation<WorkerEvent?, Error>>().values {
                continuation.resume(throwing: AppError.message(message))
            }
        }
    }
    private func publish() {
        admissionChanged(pausedChatGPTFailures)
        do { changed(try snapshot()) } catch { failQueue(error) }
    }
    private func admissionPaused(_ job: BackgroundJob) -> Bool {
        job.config.chatGPTPlanAccountID.map { pausedChatGPTFailures[$0] != nil || signingOutChatGPTAccounts.contains($0) } == true
    }
    private static func reachedChatGPTLimit(_ error: Error) -> Bool {
        // Match the transport's exact allowlisted code, not a provider message
        // containing the same word or a longer unrelated code.
        error.localizedDescription.range(of: #"^ChatGPT: HTTP [0-9]{3} · subscription_sharing_usage_limit_exceeded\."#,
                                         options: .regularExpression) != nil
    }
    func start(executor: @escaping Executor) throws {
        // A second UI connection must never recover an attempt still executing.
        guard !started else { return }
        _ = try request("job-recover")
        // Dictation audio is an ephemeral capture draft. Its caller removes it
        // on exit, so a new process must never upload/replay a stale path.
        for job in try snapshot() where job.kind == "dictate" && ["queued", "interrupted", "blocked"].contains(job.state) {
            _ = try request("job-cancel", ["jobID": job.id])
        }
        self.executor = executor; started = true
        publish(); pump()
    }
    func setRecording(_ value: Bool) { recording = value; pump() }
    func submit(_ config: JobConfiguration, resource: String, revision: String, title: String, paid: Bool) async throws -> WorkerEvent? {
        try Task.checkCancellation()
        guard !stopping else { throw CancellationError() }
        if let queueFailure { throw AppError.message(queueFailure) }
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        struct Response: Decodable { var job: BackgroundJob }
        let objectID = config.meetingID ?? "app:\(config.command)"
        var enqueue: [String: Any] = [
            "kind": config.command, "objectID": objectID, "inputRevision": revision,
            "config": json, "resource": resource, "title": title, "paid": paid, "dependencies": []
        ]
        if config.command == "transcribe", config.settings.autoSummary, config.settings.mode == "local" {
            let summary = JobConfiguration(command: "summarize", meetingID: config.meetingID, extra: [], input: nil, settings: config.settings, folderProfile: config.folderProfile, folderID: config.folderID, profileMeetingID: config.profileMeetingID)
            enqueue["followUps"] = [["kind": "summarize", "objectID": objectID, "inputRevision": "dependency:$parent",
                "config": try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)),
                "resource": "local-heavy", "title": title.replacingOccurrences(of: "Распознавание", with: "Конспект"), "paid": false]]
        }
        let response = try JSONDecoder().decode(Response.self, from: request("job-enqueue", enqueue))
        guard response.job.state != "interrupted" else {
            publish()
            throw AppError.message(L("Предыдущая операция прервалась. Повторите её в списке фоновых задач."))
        }
        let subscriber = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    cancelSubscription(response.job.id, subscriber: subscriber)
                    return
                }
                waiters[response.job.id, default: [:]][subscriber] = continuation
                publish(); pump()
            }
        } onCancel: { Task { await self.cancelSubscription(response.job.id, subscriber: subscriber) } }
    }
    private func pump() {
        guard !stopping, queueFailure == nil, let executor else { return }
        do {
            while true {
                struct Claim: Decodable { var job: BackgroundJob? }
                let allowed = recording ? ["cloud", "light"] : ["local-heavy", "cloud", "light"]
                let job: BackgroundJob?
                if pausedChatGPTFailures.isEmpty && signingOutChatGPTAccounts.isEmpty {
                    job = try JSONDecoder().decode(Claim.self, from: request("job-claim", ["allowedResources": allowed])).job
                } else {
                    // Keep paused rows durably queued. Asking SQLite to claim
                    // an exact eligible ID still enforces dependencies, object
                    // exclusion and resource capacity atomically.
                    var eligible: BackgroundJob?
                    for candidate in try snapshot() where candidate.state == "queued"
                        && allowed.contains(candidate.resource) && !admissionPaused(candidate) {
                        let claim = try JSONDecoder().decode(Claim.self, from: request("job-claim", ["allowedResources": allowed, "jobID": candidate.id]))
                        if let claimed = claim.job { eligible = claimed; break }
                    }
                    job = eligible
                }
                guard let job else { break }
                let cancellation = JobCancellation()
                running[job.id] = RunningAttempt(number: job.attempt, cancellation: cancellation)
                Task {
                    do {
                        let value = try await executor(job, cancellation) { event in
                            Task { await self.progress(job, event) }
                        }
                        self.finish(job, result: .success(value))
                    } catch { self.finish(job, result: .failure(error)) }
                }
            }
            publish()
        } catch { failQueue(error); publish() }
    }
    private func progress(_ job: BackgroundJob, _ event: WorkerEvent) {
        guard queueFailure == nil, running[job.id]?.number == job.attempt else { return }
        let now = Date()
        if event.event == "progress", now.timeIntervalSince(lastProgress[job.id] ?? .distantPast) < 0.15 { return }
        lastProgress[job.id] = now
        var arguments: [String: Any] = ["jobID": job.id, "expectedAttempt": job.attempt, "state": "running"]
        if let message = event.message { arguments["message"] = message }
        if let fraction = event.fraction, fraction.isFinite, fraction >= 0 { arguments["progress"] = min(fraction, 1) }
        do { _ = try request("job-update", arguments); publish() } catch { failQueue(error) }
    }
    private func finish(_ job: BackgroundJob, result: Result<WorkerEvent?, Error>) {
        guard let attempt = running[job.id], attempt.number == job.attempt else { return }
        let cancelled = attempt.cancellation.isCancelled
        var arguments: [String: Any] = ["jobID": job.id, "expectedAttempt": job.attempt]
        switch result {
        case .success:
            // Success means the executor committed its result. A cancellation
            // arriving immediately after publication cannot make that unsaved.
            arguments["state"] = "succeeded"; arguments["message"] = L("Готово")
        case .failure(let error):
            if !cancelled, !(error is CancellationError), let account = job.config.chatGPTPlanAccountID,
               Self.reachedChatGPTLimit(error) {
                var failure = job; failure.state = "failed"; failure.message = String(error.localizedDescription.prefix(1000))
                pausedChatGPTFailures[account] = failure
            }
            let interrupted = stopping && (cancelled || error is CancellationError)
            arguments["state"] = interrupted ? "interrupted" : cancelled || error is CancellationError ? "cancelled" : "failed"
            arguments["message"] = interrupted ? L("Работа прервалась при закрытии приложения.") : cancelled || error is CancellationError ? L("Отменено") : String(error.localizedDescription.prefix(1000))
        }
        var delivery = result
        if case .failure(let error) = result, cancelled || error is CancellationError { delivery = .failure(CancellationError()) }
        do { _ = try request("job-update", arguments) }
        catch { failQueue(error); delivery = .failure(AppError.message(L("Результат операции сохранён отдельно, но статус очереди обновить не удалось. Перезапустите приложение."))) }
        running.removeValue(forKey: job.id); lastProgress.removeValue(forKey: job.id)
        for continuation in waiters.removeValue(forKey: job.id)?.values ?? Dictionary<UUID, CheckedContinuation<WorkerEvent?, Error>>().values {
            continuation.resume(with: delivery)
        }
        publish(); pump()
    }
    private func cancelSubscription(_ id: String, subscriber: UUID) {
        if let continuation = waiters[id]?.removeValue(forKey: subscriber) { continuation.resume(throwing: CancellationError()) }
        guard waiters[id]?.isEmpty ?? true else { return }
        waiters.removeValue(forKey: id)
        cancel(id)
    }
    func cancel(_ id: String) {
        do { _ = try request("job-cancel", ["jobID": id]) } catch { failQueue(error) }
        running[id]?.cancellation.cancel()
        if running[id] == nil {
            for continuation in waiters.removeValue(forKey: id)?.values ?? Dictionary<UUID, CheckedContinuation<WorkerEvent?, Error>>().values { continuation.resume(throwing: CancellationError()) }
        }
        publish(); pump()
    }
    func cancelChatGPTAccount(_ accountID: String) {
        guard !accountID.isEmpty else { return }
        // Admission closes before the first cancellation: cancel() may pump
        // other routes, but cannot start the next job belonging to this account.
        signingOutChatGPTAccounts.insert(accountID)
        defer { signingOutChatGPTAccounts.remove(accountID); publish(); pump() }
        do {
            for job in try snapshot() where job.active && job.config.chatGPTPlanAccountID == accountID { cancel(job.id) }
        } catch { failQueue(error) }
    }
    func retry(_ id: String, confirmPaid: Bool, requiringLatestGeneration: Bool = false, resumingPausedAccount: String? = nil) throws {
        guard !stopping else { throw CancellationError() }
        if let queueFailure { throw AppError.message(queueFailure) }
        if requiringLatestGeneration {
            let current = try snapshot()
            let quotaRecovery = resumingPausedAccount.map { account in
                pausedChatGPTFailures[account]?.id == id && current.first(where: { $0.id == id })?.config.chatGPTPlanAccountID == account
            } == true
            guard quotaRecovery || BackgroundJobPresentation.latestIDs(in: current).contains(id) else {
                throw AppError.message(L("У операции есть более новая попытка. Используйте её в списке фоновых задач."))
            }
        }
        struct Response: Decodable { var job: BackgroundJob }
        let response = try JSONDecoder().decode(Response.self, from: request("job-retry", ["jobID": id, "confirmPaid": confirmPaid]))
        // Only a successful explicit retry authorizes new requests for this
        // account. A rejected paid confirmation leaves admission paused.
        if let account = response.job.config.chatGPTPlanAccountID { pausedChatGPTFailures.removeValue(forKey: account) }
        publish(); pump()
    }
    func observe(_ id: String) async throws -> WorkerEvent? {
        struct Response: Decodable { var job: BackgroundJob }
        let job = try JSONDecoder().decode(Response.self, from: request("job-get", ["jobID": id])).job
        if job.state == "succeeded" { return nil }
        guard job.active else {
            if job.state == "cancelled" { throw CancellationError() }
            throw AppError.message(job.message.isEmpty ? job.stateLabel : job.message)
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id, default: [:]][UUID()] = continuation
        }
    }
    func shutdown() {
        stopping = true
        if let values = try? snapshot() {
            for job in values where job.kind == "dictate" && ["queued", "blocked", "interrupted"].contains(job.state) {
                do { _ = try request("job-cancel", ["jobID": job.id]) } catch { failQueue(error) }
            }
        }
        // Persist queued work for next launch, but don't strand callers which
        // are awaiting it in the process that is now closing.
        for subscribers in waiters.values { for continuation in subscribers.values { continuation.resume(throwing: CancellationError()) } }
        waiters.removeAll()
        for attempt in running.values { attempt.cancellation.cancel() }
    }
    func isDrained() -> Bool { running.isEmpty }
    #if DEBUG
    func subscriberCount(_ id: String) -> Int { waiters[id]?.count ?? 0 }
    func chatGPTAdmissionPaused(_ accountID: String) -> Bool { pausedChatGPTFailures[accountID] != nil }
    #endif
}

@MainActor
final class BackgroundJobsController: ObservableObject {
    @Published private(set) var jobs: [BackgroundJob] = [] { didSet { updateActivityLease() } }
    @Published var error: String?
    @Published var showing = false
    var reopenVoiceCommand: ((BackgroundJob) -> Void)?
    var restartWithCurrentProfile: ((BackgroundJob) -> Void)?
    @Published private(set) var pendingSubmissions = 0 { didSet { updateActivityLease() } }
    @Published private(set) var pausedChatGPTAccounts: Set<String> = [] { didSet { updateActivityLease() } }
    @Published private(set) var pausedChatGPTFailures: [BackgroundJob] = []
    private var pendingAccounts: [UUID: String] = [:] {
        didSet { pendingSubmissions = pendingAccounts.count }
    }
    private var coordinator: JobCoordinator!
    private let activityChanged: (Bool) -> Void
    private var activityHeld = false
    private var shuttingDown = false
    private var leaseClosed = false
    var activeCount: Int {
        let runnable = jobs.filter { $0.active && !isPaused($0) }.count
        let pending = pendingAccounts.values.filter { !pausedChatGPTAccounts.contains($0) }.count
        return max(runnable, pending)
    }
    func isPaused(_ job: BackgroundJob) -> Bool {
        job.state == "queued" && job.config.chatGPTPlanAccountID.map { pausedChatGPTAccounts.contains($0) } == true
    }
    var latestAttemptIDs: Set<String> { BackgroundJobPresentation.latestIDs(in: jobs) }
    var needsAttention: Bool { !pausedChatGPTAccounts.isEmpty || BackgroundJobPresentation.needsAttention(in: jobs) }
    init(root: URL, activityChanged: ((Bool) -> Void)? = nil) {
        if let activityChanged { self.activityChanged = activityChanged }
        else {
            let lease = BackgroundJobSleepLease()
            self.activityChanged = { lease.update($0) }
        }
        coordinator = JobCoordinator(root: root) { [weak self] values in
            Task { @MainActor in
                guard let self else { return }
                let completed = values.filter { next in !next.active && self.jobs.contains { $0.id == next.id && $0.active } }
                self.jobs = values
                if !completed.isEmpty { NotificationCenter.default.post(name: .posleJobsChanged, object: nil) }
            }
        } failed: { [weak self] message in
            Task { @MainActor in self?.error = message }
        } admissionChanged: { [weak self] failures in
            Task { @MainActor in
                self?.pausedChatGPTFailures = failures.values.sorted { $0.createdAt < $1.createdAt }
                self?.pausedChatGPTAccounts = Set(failures.keys)
            }
        }
    }
    func connect(_ executor: @escaping JobCoordinator.Executor) {
        Task { do { try await coordinator.start(executor: executor) } catch { self.error = error.localizedDescription } }
    }
    func submit(_ config: JobConfiguration, resource: String, revision: String, title: String, paid: Bool) async throws -> WorkerEvent? {
        guard !shuttingDown else { throw CancellationError() }
        let subscription = UUID()
        pendingAccounts[subscription] = config.chatGPTPlanAccountID ?? ""
        defer { pendingAccounts.removeValue(forKey: subscription) }
        return try await coordinator.submit(config, resource: resource, revision: revision, title: title, paid: paid)
    }
    func setRecording(_ value: Bool) { Task { await coordinator.setRecording(value) } }
    func contains(objectID: String, kinds: [String] = []) -> Bool {
        jobs.contains { $0.active && $0.objectID == objectID && (kinds.isEmpty || kinds.contains($0.kind)) }
    }
    func cancel(_ id: String) { Task { await coordinator.cancel(id) } }
    func cancelChatGPTAccount(_ accountID: String) async { await coordinator.cancelChatGPTAccount(accountID) }
    func retry(_ job: BackgroundJob, resumingPausedAccount: Bool = false) {
        let quotaAccount = resumingPausedAccount ? job.config.chatGPTPlanAccountID.flatMap { account in
            pausedChatGPTFailures.contains(where: { $0.id == job.id && $0.config.chatGPTPlanAccountID == account }) ? account : nil
        } : nil
        guard quotaAccount != nil || latestAttemptIDs.contains(job.id) else {
            error = L("У операции есть более новая попытка. Используйте её в списке фоновых задач.")
            return
        }
        if job.canReopenVoiceCommand {
            guard let reopenVoiceCommand else { error = L("Откройте помощника и запустите поручение заново с текущими настройками."); return }
            error = nil; showing = false; reopenVoiceCommand(job)
            return
        }
        if job.canRestartWithCurrentProfile {
            guard let restartWithCurrentProfile else { error = L("Откройте исходную встречу или заметку и запустите обработку заново с текущими настройками."); return }
            error = nil; restartWithCurrentProfile(job)
            return
        }
        var confirmed = !job.paid
        if job.paid {
            let alert = NSAlert()
            alert.messageText = L("Повторить облачный запрос?")
            alert.informativeText = job.config.settings.cloudProvider == "chatgpt" && ["summarize", "example", "expand-notes", "voice-plan"].contains(job.config.command)
                ? L("ChatGPT мог обработать предыдущий запрос до прерывания. Повтор снова использует лимит подписки. Будут использованы сохранённые настройки этой операции.")
                : L("Сервис мог обработать предыдущий запрос до прерывания. Повтор может оплачиваться ещё раз. Будут использованы сохранённые настройки этой операции.")
            alert.addButton(withTitle: L("Повторить")); alert.addButton(withTitle: L("Отмена"))
            confirmed = alert.runModal() == .alertFirstButtonReturn
        }
        guard confirmed else { return }
        let subscription = UUID()
        // A confirmed retry is an active admission action even while the
        // coordinator is clearing the account's previous quota pause.
        pendingAccounts[subscription] = ""
        Task {
            defer { pendingAccounts.removeValue(forKey: subscription) }
            do {
                try await coordinator.retry(job.id, confirmPaid: confirmed, requiringLatestGeneration: true, resumingPausedAccount: quotaAccount)
                _ = try await coordinator.observe(job.id)
                self.error = nil
            }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func updateActivityLease() {
        let active = activeCount > 0 && !leaseClosed
        guard active != activityHeld else { return }
        activityHeld = active; activityChanged(active)
    }
    func shutdown() async {
        shuttingDown = true
        await coordinator.shutdown()
        while !(await coordinator.isDrained()) { try? await Task.sleep(for: .milliseconds(50)) }
        // Queued records survive shutdown, but no executor remains in this app.
        leaseClosed = true; updateActivityLease()
    }
}

/// Owns one transient idle-sleep assertion, separate from capture and legacy
/// preparation. No persistent power setting is modified.
private final class BackgroundJobSleepLease {
    private var assertion: IOPMAssertionID = 0
    func update(_ active: Bool) {
        if active, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), L("После обрабатывает фоновые задачи") as CFString, &assertion)
        } else if !active, assertion != 0 {
            IOPMAssertionRelease(assertion); assertion = 0
        }
    }
    deinit { if assertion != 0 { IOPMAssertionRelease(assertion) } }
}

extension Notification.Name { static let posleJobsChanged = Notification.Name("PosleJobsChanged") }

struct BackgroundJobsButton: View {
    @ObservedObject var jobs: BackgroundJobsController
    var body: some View {
        Button { jobs.showing.toggle() } label: {
            Label(jobs.activeCount == 0 ? L("Фоновые задачи") : LF("Фоновые задачи · {0}", arguments: [String(describing: jobs.activeCount)]), systemImage: jobs.needsAttention ? "exclamationmark.circle" : "clock.arrow.circlepath")
                .font(AppTypography.caption)
        }.buttonStyle(.borderless).accessibilityIdentifier("jobs.open")
            .popover(isPresented: $jobs.showing) { BackgroundJobsView(jobs: jobs) }
    }
}

struct BackgroundJobsView: View {
    @ObservedObject var jobs: BackgroundJobsController
    var body: some View {
        let latest = jobs.latestAttemptIDs
        return VStack(alignment: .leading, spacing: 16) {
            Text(L("Фоновые задачи")).font(AppTypography.modalTitle)
            if jobs.jobs.isEmpty { Text(L("Здесь появятся операции обработки встреч и генерации.")).foregroundStyle(.secondary) }
            if !jobs.pausedChatGPTAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("Запросы ChatGPT приостановлены"), systemImage: "pause.circle")
                        .font(AppTypography.controlStrong)
                    Text(L("Проверьте лимиты и нажмите «Продолжить очередь». Неудавшийся запрос будет повторён после подтверждения."))
                        .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                    HStack(spacing: 12) {
                        Link(L("Использование ChatGPT"), destination: URL(string: "https://chatgpt.com/settings/usage")!)
                            .font(AppTypography.caption)
                        if jobs.pausedChatGPTFailures.count == 1, let failed = jobs.pausedChatGPTFailures.first {
                            Button(L("Продолжить очередь")) { jobs.retry(failed, resumingPausedAccount: true) }.buttonStyle(.borderless)
                                .help(L("Повторить неудавшийся запрос после подтверждения и продолжить очередь этого аккаунта."))
                        } else if !jobs.pausedChatGPTFailures.isEmpty {
                            Menu(L("Продолжить очередь")) {
                                ForEach(jobs.pausedChatGPTFailures) { failed in
                                    Button(L("Повторить: ") + BackgroundJobPresentation.title(failed)) { jobs.retry(failed, resumingPausedAccount: true) }
                                }
                            }.menuStyle(.borderlessButton)
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(BackgroundJobPresentation.ordered(jobs.jobs).prefix(30))) { job in
                        let historical = !latest.contains(job.id)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top) {
                                Text(BackgroundJobPresentation.title(job)).font(AppTypography.controlStrong)
                                Spacer()
                                if job.active || job.state == "blocked" {
                                    Button { jobs.cancel(job.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel(LF("Отменить {0}", arguments: [BackgroundJobPresentation.title(job)]))
                                } else if !historical && job.kind != "dictate" && ["failed", "interrupted", "cancelled"].contains(job.state) {
                                    Button(job.retryTitle) { jobs.retry(job) }
                                        .buttonStyle(.borderless).fixedSize(horizontal: true, vertical: false)
                                        .accessibilityIdentifier("jobs.retry." + job.id)
                                        .help(job.retryHelp)
                                }
                            }
                            let metadata = BackgroundJobPresentation.metadata(job, historical: historical)
                            Text(metadata).font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                                .lineLimit(1).truncationMode(.middle).help(metadata)
                            Text(jobs.isPaused(job) ? L("Ожидает: лимит подписки ChatGPT") : job.stateLabel).font(AppTypography.caption).foregroundStyle(job.state == "failed" && !historical ? Ink.warning : Ink.secondaryText).textSelection(.enabled)
                            if job.state == "running" { if let fraction = job.progress, fraction >= 0 { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) } }
                        }
                    }
                }
            }.frame(maxHeight: 380)
            if let error = jobs.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
        }.padding(22).frame(width: 410).appControlDefaults()
    }
}
