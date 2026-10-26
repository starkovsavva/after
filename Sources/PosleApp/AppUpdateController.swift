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
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status: String?
    @Published private(set) var hasDeferredDraft = false
    @Published private(set) var canRevealDraft = false
    private(set) var relaunchRequested = false
    private weak var store: AppStore?
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()
    private var pendingCheck = false
    private var pendingPresentation = false
    private var probingDeferredCheck = false
    private var installHandler: (() -> Void)?
    private var retryTimer: Timer?
    private var hasQuickDraft: () -> Bool = { false }
    private var showQuickDraft: () -> Void = {}
    private var sparkleCanCheck = false
    private var promptedQuickDraft = false
    private var promptedCaptureKey: String?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.8.0"
    }
    private var workInProgress: Bool {
        guard let store else { return false }
        return store.isRecording || store.stoppingRecording || store.busy || store.notes.attachmentBusy
    }
    private var editorOpen: Bool {
        guard let store else { return false }
        return store.editingOverview || store.notes.editingNewTask || store.showingCaptureDrafts || store.showingSettings || store.showingRecord || store.showingSearch || NSApp.modalWindow != nil ||
            NSApp.windows.contains { $0.attachedSheet != nil || ($0 is NSPanel && $0.isVisible && $0.title == "Быстрая заметка") }
    }
    var canSafelyRelaunch: Bool { !workInProgress && !editorOpen && !hasQuickDraft() && store?.notes.hasUnsavedCaptureDrafts != true }

    func start(store: AppStore, hasQuickDraft: @escaping () -> Bool, showQuickDraft: @escaping () -> Void) {
        guard controller == nil, Bundle.main.bundleIdentifier == "app.posle.meetings",
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("--preview"), !args.contains("--snapshot"), !args.contains(where: { $0.hasPrefix("--check-") }) else { return }
        self.store = store; self.hasQuickDraft = hasQuickDraft; self.showQuickDraft = showQuickDraft
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
        store.notes.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshAvailability() }
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
            pendingCheck = false; pendingPresentation = false; probingDeferredCheck = false
            if installHandler == nil { retryTimer?.invalidate(); retryTimer = nil }
        }
    }
    private func refreshAvailability() {
        let deferred = installHandler != nil && (hasQuickDraft() || store?.notes.hasUnsavedCaptureDrafts == true)
        let reveal = deferred && !workInProgress && !editorOpen
        let check = isAvailable && sparkleCanCheck && !workInProgress && installHandler == nil && !relaunchRequested
        if hasDeferredDraft != deferred { hasDeferredDraft = deferred }
        if canRevealDraft != reveal { canRevealDraft = reveal }
        if canCheck != check { canCheck = check }
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
            if hasQuickDraft() {
                if !promptedQuickDraft { promptedQuickDraft = true; showQuickDraft() }
                return
            }
            if revealCaptureDraftIfNeeded() { return }
            guard NoteDraftPersistence.flushAll() else { return }
            installHandler = nil; relaunchRequested = true
            status = "Устанавливаю обновление…"; refreshAvailability()
            handler()
        } else if automaticallyChecks && (pendingCheck || pendingPresentation), let controller {
            guard controller.updater.canCheckForUpdates else { return }
            let presenting = pendingPresentation
            pendingCheck = false; pendingPresentation = false
            if presenting { controller.checkForUpdates(nil) }
            else { probingDeferredCheck = true; controller.updater.checkForUpdateInformation() }
        }
        if installHandler == nil && !pendingCheck && !pendingPresentation {
            retryTimer?.invalidate(); retryTimer = nil
        }
    }
    func revealPendingDraft() {
        guard installHandler != nil, !workInProgress, !editorOpen else { return }
        promptedQuickDraft = false; promptedCaptureKey = nil
        if hasQuickDraft() { promptedQuickDraft = true; showQuickDraft() }
        else { revealCaptureDraftIfNeeded() }
        refreshAvailability()
    }
    private func clearDeferredInstallation() {
        installHandler = nil; promptedQuickDraft = false; promptedCaptureKey = nil
        relaunchRequested = false
        if !pendingCheck && !pendingPresentation { retryTimer?.invalidate(); retryTimer = nil }
        refreshAvailability()
    }
    @discardableResult private func revealCaptureDraftIfNeeded() -> Bool {
        guard let store, let key = store.notes.firstPendingCaptureDraftKey else { return false }
        if promptedCaptureKey != key {
            promptedCaptureKey = key
            if store.noteMeetings.contains(where: { $0.id == key }) { store.openMeeting(key, tab: "notes") }
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
        status = "Доступна версия \(item.displayVersionString)"
        if probingDeferredCheck && automaticallyChecks {
            probingDeferredCheck = false; pendingPresentation = true; deferUntilIdle()
        }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        probingDeferredCheck = false
        status = "Установлена последняя версия"
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        relaunchRequested = false; probingDeferredCheck = false
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
        if canSafelyRelaunch && NoteDraftPersistence.flushAll() {
            relaunchRequested = true; refreshAvailability(); return false
        }
        installHandler = handler
        status = workInProgress ? "Установлю после завершения обработки" : "Сохраните правки и закройте редакторы для установки"
        store?.notice = status
        if !workInProgress && !editorOpen {
            if hasQuickDraft() { promptedQuickDraft = true; showQuickDraft() }
            else { revealCaptureDraftIfNeeded() }
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
        !workInProgress && !editorOpen
    }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            pendingPresentation = true; deferUntilIdle()
        }
    }
    func standardUserDriverWillFinishUpdateSession() {
        let installationWasDeferred = installHandler != nil
        pendingPresentation = false
        clearDeferredInstallation()
        if installationWasDeferred { status = "Установка отложена. Проверьте обновления ещё раз." }
        else if status == "Проверяю обновления…" { status = nil }
    }

    #if DEBUG
    /// Dependency-free test entry: no framework controller, preferences or network.
    func configureForChecks(store: AppStore, hasQuickDraft: @escaping () -> Bool = { false }) {
        self.store = store; self.hasQuickDraft = hasQuickDraft
    }
    func postponeForChecks(_ handler: @escaping () -> Void) { installHandler = handler }
    func resumeForChecks() { resumeWhenIdle() }
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
