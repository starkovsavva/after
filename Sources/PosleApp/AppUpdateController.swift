import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns preferences, signatures and the installation transaction. This
/// coordinator only decides when a meeting or an unsaved editor may be interrupted.
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var isAvailable = false
    @Published private(set) var canCheck = false
    @Published private(set) var waitingForWork = false
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status: String?
    @Published private(set) var hasDeferredDraft = false
    @Published private(set) var canRevealDraft = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var showsUpdateAnnouncement = false
    private var availableBuild: String?
    private var dismissedBuild: String?
    private var attendedBuild: String?
    private(set) var relaunchRequested = false
    private weak var store: AppStore?
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()
    private var pendingCheck = false
    private var installHandler: (() -> Void)?
    private var retryTimer: Timer?
    private var hasQuickDraft: () -> Bool = { false }
    private var showQuickDraft: () -> Void = {}
    private var sparkleCanCheck = false
    private var promptedQuickDraft = false
    private var promptedCaptureKey: String?
    private var failedLibraryFlush = false
    private var failedOverviewFlush = false
    private var promptedOverviewDraft = false
    private var promptedLibraryDraft = false
    private var flushLibraryDrafts: () -> Bool = { NoteDraftPersistence.flushAll() }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.12.3"
    }
    private var workInProgress: Bool {
        guard let store else { return false }
        return store.startingRecording || store.isRecording || store.stoppingRecording || store.isTerminating || store.busy || store.jobs.activeCount > 0 || store.notes.attachmentBusy || store.voice.isWorking || ChatGPTAccount.shared.isConnecting || ChatGPTAccount.shared.isLoadingModels || ChatGPTAccount.shared.isRefreshing || ChatGPTAccount.shared.isSigningOut || !store.disconnectingChatGPTAccounts.isEmpty
    }
    private var editorOpen: Bool {
        guard let store else { return false }
        return store.voice.isPresented || store.editingOverview || store.notes.editingNewTask || store.showingCaptureDrafts || store.showingSettings || store.showingRecord || store.showingSearch || NSApp.modalWindow != nil ||
            NSApp.windows.contains { $0.attachedSheet != nil || ($0 is NSPanel && $0.isVisible && $0.title == "Быстрая заметка") }
    }
    var canSafelyRelaunch: Bool { !UnsavedEditorRegistry.hasUnsaved && !workInProgress && !editorOpen && !hasQuickDraft() && store?.notes.hasUnsavedCaptureDrafts != true && !failedLibraryFlush && !failedOverviewFlush }

    func start(store: AppStore, hasQuickDraft: @escaping () -> Bool, showQuickDraft: @escaping () -> Void) {
        guard controller == nil, Bundle.main.bundleIdentifier == "app.posle.meetings",
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("--preview"), !args.contains("--snapshot"), !args.contains(where: { $0.hasPrefix("--check-") }) else { return }
        self.store = store; self.hasQuickDraft = hasQuickDraft; self.showQuickDraft = showQuickDraft
        loadReminderPreferences()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            self?.sparkleCanCheck = value; self?.refreshAvailability()
        }.store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] value in
            self?.automaticallyChecks = value
        }.store(in: &observations)
        store.objectWillChange.sink { [weak self] _ in
            // Published fields notify before their new values are assigned.
            DispatchQueue.main.async { self?.refreshAvailability() }
        }.store(in: &observations)
        ChatGPTAccount.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshAvailability() }
        }.store(in: &observations)
        store.notes.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshAvailability() }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .posleUnsavedEditorsChanged).sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshAvailability()
                if self?.installHandler != nil { self?.resumeWhenIdle() }
            }
        }.store(in: &observations)
        controller.startUpdater()
        isAvailable = true
        automaticallyChecks = updater.automaticallyChecksForUpdates
        lastChecked = updater.lastUpdateCheckDate
        refreshAvailability()
        if automaticallyChecks { updater.checkForUpdatesInBackground() }
    }

    func checkForUpdates() {
        guard canCheck, let controller else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        store?.saveSettings()
        status = "Проверяю обновления…"
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = updater.automaticallyChecksForUpdates
        if !enabled {
            pendingCheck = false
            if installHandler == nil { retryTimer?.invalidate(); retryTimer = nil }
        }
    }
    private func refreshAvailability() {
        let waiting = isAvailable && workInProgress
        if waitingForWork != waiting { waitingForWork = waiting }
        let deferred = installHandler != nil && (UnsavedEditorRegistry.hasUnsaved || hasQuickDraft() || store?.notes.hasUnsavedCaptureDrafts == true || failedLibraryFlush || failedOverviewFlush)
        let reveal = deferred && !workInProgress && !editorOpen
        let check = isAvailable && sparkleCanCheck && !workInProgress && installHandler == nil && !relaunchRequested
        if hasDeferredDraft != deferred { hasDeferredDraft = deferred }
        if canRevealDraft != reveal { canRevealDraft = reveal }
        if canCheck != check { canCheck = check }
        let announcement = isAvailable && availableVersion != nil && availableBuild != dismissedBuild && availableBuild != attendedBuild
            && !UnsavedEditorRegistry.hasUnsaved && !workInProgress && !editorOpen && installHandler == nil && !relaunchRequested
        if showsUpdateAnnouncement != announcement { showsUpdateAnnouncement = announcement }
    }
    func dismissUpdateAnnouncement() {
        guard let availableBuild else { return }
        dismissedBuild = availableBuild
        do {
            if let url = reminderURL {
                try validateReminderFile(url)
                let data = try JSONEncoder().encode(["dismissedBuild": availableBuild])
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch { status = "Не удалось сохранить выбор. Обновление можно открыть в настройках." }
        refreshAvailability()
    }
    private var reminderURL: URL? { store?.root.appendingPathComponent("update-reminders.json") }
    private func validateReminderFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 16_384 else {
            throw AppError.message("Неверный файл настроек обновлений.")
        }
    }
    private func loadReminderPreferences() {
        dismissedBuild = nil
        guard let url = reminderURL else { return }
        do {
            try validateReminderFile(url)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            dismissedBuild = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))["dismissedBuild"]
        } catch { /* Reminder preferences must never prevent opening the app. */ }
    }
    private func foundUpdate(version: String, build: String) {
        availableVersion = version; availableBuild = build
        status = "Доступна версия \(version)"
        refreshAvailability()
    }
    private func deferUntilIdle() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.resumeWhenIdle() }
        }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func resumeWhenIdle() {
        refreshAvailability()
        guard !workInProgress && !editorOpen else { return }
        if let handler = installHandler {
            guard !UnsavedEditorRegistry.hasUnsaved else {
                status = "Сохраните правки перед установкой обновления"
                refreshAvailability(); return
            }
            if hasQuickDraft() {
                if !promptedQuickDraft { promptedQuickDraft = true; showQuickDraft() }
                return
            }
            if revealCaptureDraftIfNeeded() { return }
            guard store?.flushOverviewDrafts() != false else {
                failedOverviewFlush = true
                revealOverviewDraftIfNeeded(); refreshAvailability(); return
            }
            failedOverviewFlush = false
            guard flushLibraryDrafts() else {
                failedLibraryFlush = true
                revealLibraryDraftIfNeeded(); refreshAvailability(); return
            }
            failedLibraryFlush = false
            installHandler = nil; relaunchRequested = true
            status = "Устанавливаю обновление…"; refreshAvailability()
            handler()
        } else if automaticallyChecks && pendingCheck, let controller {
            guard controller.updater.canCheckForUpdates else { return }
            pendingCheck = false
            controller.updater.checkForUpdateInformation()
        }
        if installHandler == nil && !pendingCheck {
            retryTimer?.invalidate(); retryTimer = nil
        }
    }
    func revealPendingDraft() {
        guard installHandler != nil, !workInProgress, !editorOpen else { return }
        promptedQuickDraft = false; promptedCaptureKey = nil; promptedLibraryDraft = false; promptedOverviewDraft = false
        if hasQuickDraft() { promptedQuickDraft = true; showQuickDraft() }
        else if !revealCaptureDraftIfNeeded() {
            if failedOverviewFlush { revealOverviewDraftIfNeeded() }
            else { revealLibraryDraftIfNeeded() }
        }
        refreshAvailability()
    }
    private func clearDeferredInstallation() {
        installHandler = nil; promptedQuickDraft = false; promptedCaptureKey = nil
        failedLibraryFlush = false; promptedLibraryDraft = false
        failedOverviewFlush = false; promptedOverviewDraft = false
        relaunchRequested = false
        if !pendingCheck { retryTimer?.invalidate(); retryTimer = nil }
        refreshAvailability()
    }
    private func revealOverviewDraftIfNeeded() {
        guard failedOverviewFlush, !promptedOverviewDraft, let store,
              let id = store.overviewDrafts.keys.sorted().first else { return }
        promptedOverviewDraft = true
        store.openMeeting(id, tab: "summary")
        status = "Сохраните черновик конспекта перед обновлением"
        store.notice = status
    }
    private func revealLibraryDraftIfNeeded() {
        guard failedLibraryFlush, !promptedLibraryDraft, let store else { return }
        promptedLibraryDraft = true
        store.librarySection = "inbox"
        status = "Сохраните черновик заметки перед обновлением"
        store.notice = status
    }
    @discardableResult private func revealCaptureDraftIfNeeded() -> Bool {
        guard let store, let key = store.notes.firstPendingCaptureDraftKey else { return false }
        if promptedCaptureKey != key {
            promptedCaptureKey = key
            if store.noteMeetings.contains(where: { $0.id == key }) { store.openMeeting(key, tab: "notes") }
            else if key == "newtask" || ["taskappend:", "tasksubtask:", "taskmeta:"].contains(where: key.hasPrefix) {
                store.notes.reload(); store.notes.loadTasks()
                let taskID = key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) }
                if key == "newtask" || store.notes.tasks.contains(where: { task in
                    guard let taskID else { return false }
                    return task.id == taskID || task.noteID == taskID || task.taskOrigin?.summaryTaskID == taskID
                }) {
                    store.librarySection = "tasks"; store.notes.selectedTaskID = taskID
                } else {
                    // A removed source must not strand the user's remaining text.
                    if key.hasPrefix("taskmeta:"), let text = store.notes.captureDrafts[key],
                       let data = text.data(using: .utf8), let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        store.notes.captureDrafts[key] = ["Уточнение к задаче", metadata["owner"].map { "Ответственный: \($0)" } ?? "", metadata["due"].map { "Срок: \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
                    }
                    store.recoveryCaptureDraftKey = key; store.showingCaptureDrafts = true
                }
            }
            else { store.recoveryCaptureDraftKey = key; store.showingCaptureDrafts = true }
            store.notice = "Сохраните черновик заметки перед обновлением"
        }
        return true
    }
    private func blockedError() -> NSError {
        NSError(domain: "app.posle.meetings.updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Обновление будет доступно после завершения записи или обработки."])
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if workInProgress || (updateCheck != .updates && editorOpen) {
            if updateCheck != .updates { pendingCheck = true; deferUntilIdle() }
            throw blockedError()
        }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        if workInProgress || (updateCheck != .updates && editorOpen) {
            pendingCheck = automaticallyChecks; deferUntilIdle(); throw blockedError()
        }
    }
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        lastChecked = Date(); status = nil
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundUpdate(version: item.displayVersionString, build: item.versionString)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil; availableBuild = nil; attendedBuild = nil
        status = "Установлена последняя версия"
        refreshAvailability()
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        relaunchRequested = false
        let failure = error as NSError
        if failure.domain != "app.posle.meetings.updates" { clearDeferredInstallation() }
        if failure.domain == SUSparkleErrorDomain && failure.code == Int(SUError.noUpdateError.rawValue) {
            refreshAvailability(); return
        }
        if failure.domain != "app.posle.meetings.updates" {
            status = "Не удалось проверить обновления. Попробуйте позже."
        }
        refreshAvailability()
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        let safe = canSafelyRelaunch
        let overviewFlushed = safe && store?.flushOverviewDrafts() != false
        let flushed = overviewFlushed && flushLibraryDrafts()
        if flushed {
            relaunchRequested = true; refreshAvailability(); return false
        }
        failedOverviewFlush = safe && !overviewFlushed
        failedLibraryFlush = overviewFlushed && !flushed
        installHandler = handler
        status = workInProgress ? "Установлю после завершения обработки" : "Сохраните правки и закройте редакторы для установки"
        store?.notice = status
        if !workInProgress && !editorOpen {
            if hasQuickDraft() { promptedQuickDraft = true; showQuickDraft() }
            else if !revealCaptureDraftIfNeeded() {
                if failedOverviewFlush { revealOverviewDraftIfNeeded() }
                else { revealLibraryDraftIfNeeded() }
            }
        }
        deferUntilIdle(); refreshAvailability()
        return true
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { relaunchRequested = true; refreshAvailability() }
    // This callback can be omitted by Sparkle when resuming an earlier install.
    // AppDelegate repeats canSafelyRelaunch at the final termination boundary.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { relaunchRequested = true; refreshAvailability() }

    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // A scheduled check only adds an in-app affordance. User-initiated
        // checks still use Sparkle's standard signed download/install flow.
        false
    }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        foundUpdate(version: update.displayVersionString, build: update.versionString)
        if state.userInitiated || handleShowingUpdate { attendedBuild = update.versionString }
        refreshAvailability()
    }
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        attendedBuild = update.versionString; refreshAvailability()
    }
    func standardUserDriverWillFinishUpdateSession() {
        let installationWasDeferred = installHandler != nil
        clearDeferredInstallation()
        if installationWasDeferred { status = "Установка отложена. Проверьте обновления ещё раз." }
        else if status == "Проверяю обновления…" { status = nil }
    }

    #if DEBUG
    /// Dependency-free test entry: no framework controller, preferences or network.
    func configureForChecks(store: AppStore, hasQuickDraft: @escaping () -> Bool = { false },
                            flushLibraryDrafts: (() -> Bool)? = nil) {
        self.store = store; self.hasQuickDraft = hasQuickDraft
        loadReminderPreferences()
        self.flushLibraryDrafts = flushLibraryDrafts ?? { NoteDraftPersistence.flushAll() }
    }
    func postponeForChecks(_ handler: @escaping () -> Void) { installHandler = handler }
    func resumeForChecks() { resumeWhenIdle() }
    func announceForChecks(version: String, build: String) {
        isAvailable = true; sparkleCanCheck = true
        foundUpdate(version: version, build: build)
    }
    func refreshForChecks() { refreshAvailability() }
    #endif
}

struct CheckForAppUpdates: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        Button("Проверить обновления…") { updates.checkForUpdates() }.disabled(!updates.canCheck)
    }
}

struct OpenUpdateDraft: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        if updates.hasDeferredDraft {
            Button("Открыть черновик") { updates.revealPendingDraft() }
                .disabled(!updates.canRevealDraft)
                .help("Сохранить черновик перед установкой обновления")
        }
    }
}
