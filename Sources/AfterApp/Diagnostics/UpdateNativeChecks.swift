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
import Sparkle
import SwiftUI

/// Real AppStore state and native sheets, isolated from production updater/feed.
@MainActor
enum UpdateNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"],
              ["/tmp", "/private/tmp"].contains(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path),
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Updater checks require an explicit disposable preview fixture")
        }
        try verifyVersionDisplay()
        let app = AppStore(preview: true), updates = app.updates
        var draft = false
        updates.configureForChecks(store: app, hasQuickDraft: { draft })
        try expect(!updates.isAvailable && !updates.canCheck, "Preview must never start a real updater")
        try expect(updates.canSafelyRelaunch, "Idle fixture should allow relaunch")
        for activity in ["starting", "recording", "stopping", "terminating", "processing", "attachment"] {
            app.startingRecording = activity == "starting"; app.isTerminating = activity == "terminating"
            app.isRecording = activity == "recording"; app.stoppingRecording = activity == "stopping"
            app.busy = activity == "processing"; app.notes.attachmentBusy = activity == "attachment"
            try expect(!updates.canSafelyRelaunch, "Active \(activity) must block relaunch")
        }
        app.startingRecording = false; app.isTerminating = false
        app.isRecording = false; app.stoppingRecording = false; app.busy = false; app.notes.attachmentBusy = false
        print("PASS: recording, saving, processing and attachment work block update restart")
        app.editingOverview = true; try expect(!updates.canSafelyRelaunch, "Inline overview draft blocks restart")
        app.editingOverview = false
        app.notes.editingNewTask = true; try expect(!updates.canSafelyRelaunch, "Inline new task draft blocks restart")
        app.notes.editingNewTask = false
        app.notes.captureDrafts["missing-meeting"] = "Скрытая заметка"
        try expect(!updates.canSafelyRelaunch, "Hidden composer drafts block restart")
        app.notes.captureDrafts.removeAll()
        app.showingSettings = true; try expect(!updates.canSafelyRelaunch, "Settings fields are unsaved editors")
        app.showingSettings = false; app.showingRecord = true; try expect(!updates.canSafelyRelaunch, "Recording sheet blocks restart")
        app.showingRecord = false; app.showingSearch = true; try expect(!updates.canSafelyRelaunch, "Search sheet blocks restart")
        app.showingSearch = false
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        parent.beginSheet(editor, completionHandler: { _ in })
        try expect(!updates.canSafelyRelaunch, "Native editor sheets block restart independently of store flags")
        parent.endSheet(editor); editor.orderOut(nil); parent.orderOut(nil)
        try await verifySettingsInstallation(app: app, updates: updates)
        try await SettingsDraftNativeChecks.run(app: app, updates: updates)
        try await verifyHiddenQuickCapture(app: app, updates: updates)
        updates.configureForChecks(store: app, hasQuickDraft: { draft })
        draft = true
        try expect(!updates.canSafelyRelaunch, "Hidden quick-capture draft must survive update")
        print("PASS: settings, native sheets and hidden quick-capture drafts block restart")
        var resumed = 0
        updates.postponeForChecks { resumed += 1 }
        updates.resumeForChecks(); try expect(resumed == 0, "Hidden draft cannot trigger install callback")
        draft = false
        app.notes.captureDrafts["inbox"] = "Скрытый черновик входящих"
        updates.resumeForChecks()
        try expect(resumed == 0 && app.showingCaptureDrafts && app.notes.captureDrafts["inbox"] == "Скрытый черновик входящих", "Pending hidden inbox draft must be revealed and kept intact")
        app.showingCaptureDrafts = false
        updates.resumeForChecks()
        try expect(updates.hasDeferredDraft && updates.canRevealDraft, "Dismissed recovery must remain reachable through the menu action")
        updates.revealPendingDraft()
        try expect(app.showingCaptureDrafts && app.notes.captureDrafts["inbox"] == "Скрытый черновик входящих", "Explicit reopen must preserve a dismissed recovery draft")
        app.notes.captureDrafts["inbox"] = ""; app.showingCaptureDrafts = false
        app.busy = true; updates.resumeForChecks(); try expect(resumed == 0, "Late processing race cannot trigger install callback")
        app.busy = false
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(resumed == 1 && updates.relaunchRequested, "Install resumes exactly once after all guards clear")
        let delegate = AppDelegate(); delegate.store = app
        app.isRecording = true
        try expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Final termination boundary must preserve a late-started recording")
        app.isRecording = false
        try expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "Idle fixture allows final updater termination")
        print("PASS: deferred installation resumes once; final quit guard catches a late recording without stopping it")
        updates.postponeForChecks { resumed += 1 }
        updates.standardUserDriverWillFinishUpdateSession()
        updates.resumeForChecks()
        try expect(resumed == 1 && !updates.relaunchRequested && !updates.hasDeferredDraft,
                   "Ending an aborted Sparkle session must release the old handler and allow retry")
        print("PASS: ending an update session discards a stale install callback without touching the draft")
        var canFlushLibrary = false
        updates.configureForChecks(store: app, flushLibraryDrafts: { canFlushLibrary })
        app.librarySection = "meetings"
        updates.postponeForChecks { resumed += 1 }
        updates.resumeForChecks()
        try expect(resumed == 1 && updates.hasDeferredDraft && updates.canRevealDraft && app.librarySection == "inbox",
                   "A conflicting hidden library note must be revealed and remain reachable")
        app.librarySection = "meetings"
        updates.revealPendingDraft()
        try expect(app.librarySection == "inbox", "A dismissed library draft must reopen through update recovery")
        canFlushLibrary = true
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(resumed == 2 && !updates.hasDeferredDraft && updates.relaunchRequested,
                   "Library draft recovery must resume installation exactly once")
        updates.standardUserDriverWillFinishUpdateSession()
        print("PASS: failed hidden library saves remain reachable and successful recovery resumes installation once")
        let meeting = Meeting(title: "Правка перед обновлением", source: "fixture.wav")
        try FileManager.default.createDirectory(at: app.meetingDirectory(meeting.id), withIntermediateDirectories: true)
        try app.write(meeting, app.meetingDirectory(meeting.id).appendingPathComponent("meta.json"))
        app.reloadLibrary()
        app.rememberOverviewDraft("Первый черновик", meetingID: meeting.id, original: "Конспект", generatedAt: 1)
        let draftURL = app.root.appendingPathComponent("overview-drafts.json")
        try FileManager.default.removeItem(at: draftURL)
        try FileManager.default.createDirectory(at: draftURL, withIntermediateDirectories: false)
        app.rememberOverviewDraft("Правка при сбое диска", meetingID: meeting.id, original: "Конспект", generatedAt: 1)
        updates.postponeForChecks { resumed += 1 }
        updates.resumeForChecks()
        try expect(resumed == 2 && updates.hasDeferredDraft && app.selection == meeting.id && app.tab == "summary",
                   "Failed overview save must defer update and reveal its own meeting")
        app.librarySection = "inbox"; updates.revealPendingDraft()
        try expect(app.librarySection == "meetings" && app.overviewDrafts[meeting.id]?.text == "Правка при сбое диска",
                   "Dismissed overview recovery must stay reachable and retain the text")
        try FileManager.default.removeItem(at: draftURL)
        try expect(app.flushOverviewDrafts(), "Overview destination recovery must allow saving")
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(resumed == 3 && !updates.hasDeferredDraft && updates.relaunchRequested,
                   "Persisting the durable overview resumes installation exactly once")
        updates.standardUserDriverWillFinishUpdateSession()
        print("PASS: failed overview persistence defers update, reveals its meeting and safely resumes after retry")
        let unsavedID = UUID()
        UnsavedEditorRegistry.set(id: unsavedID, title: "Исправление транскрипта", dirty: true)
        defer { UnsavedEditorRegistry.remove(id: unsavedID) }
        try expect(!updates.canSafelyRelaunch, "Dirty registered editors must block the final restart gate")
        var registryResumed = 0
        updates.postponeForChecks { registryResumed += 1 }
        updates.resumeForChecks()
        try expect(registryResumed == 0 && updates.hasDeferredDraft, "An unsaved editor must defer the actual installation callback")
        UnsavedEditorRegistry.remove(id: unsavedID)
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(registryResumed == 1, "Saving the registered editor must release the installation callback exactly once")
        updates.standardUserDriverWillFinishUpdateSession()
        print("PASS: registered unsaved editors gate both final restart and the deferred installation callback")
        let reminder = AppUpdateController(); reminder.configureForChecks(store: app)
        reminder.announceForChecks(version: "99.1", build: "901")
        try expect(reminder.showsUpdateAnnouncement && reminder.canCheck && !reminder.waitingForWork, "An idle app must offer an unobtrusive update action without a stale waiting reason")
        app.busy = true; reminder.refreshForChecks()
        try expect(!reminder.showsUpdateAnnouncement && !reminder.canCheck && reminder.waitingForWork, "Processing must disable update actions and expose the reason")
        app.busy = false; reminder.refreshForChecks()
        try expect(reminder.showsUpdateAnnouncement && reminder.canCheck && !reminder.waitingForWork, "The announcement and manual actions must return without the waiting reason when the app becomes idle")
        reminder.dismissUpdateAnnouncement()
        try expect(!reminder.showsUpdateAnnouncement && reminder.canCheck && reminder.availableVersion == "99.1",
                   "Later must hide only the reminder, leaving manual update checking available")
        let reopenedReminder = AppUpdateController(); reopenedReminder.configureForChecks(store: app)
        reopenedReminder.announceForChecks(version: "99.1", build: "901")
        try expect(!reopenedReminder.showsUpdateAnnouncement, "Reminder dismissal must survive reopening for this exact build")
        reopenedReminder.announceForChecks(version: "99.2", build: "902")
        try expect(reopenedReminder.showsUpdateAnnouncement, "A later build must have its own optional reminder")
        print("PASS: gentle update availability waits for idle; Later persists per build and leaves manual checks enabled")
        app.jobs.setRecording(true)
        let queued = Task {
            try await app.jobs.submit(JobConfiguration(command: "summarize", meetingID: nil, extra: [], input: nil, settings: app.settings),
                                      resource: "local-heavy", revision: "updater-fixture", title: "Проверка защиты обновления", paid: false)
        }
        for _ in 0..<100 where app.jobs.activeCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try expect(app.jobs.activeCount > 0, "The test must create an actual queued operation")
        reopenedReminder.refreshForChecks()
        try expect(!reopenedReminder.canSafelyRelaunch && !reopenedReminder.canCheck && !reopenedReminder.showsUpdateAnnouncement && reopenedReminder.waitingForWork,
                   "Queued work must block restart and update actions with an explicit waiting reason")
        queued.cancel()
        _ = try? await queued.value
        for _ in 0..<100 where app.jobs.activeCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        app.jobs.setRecording(false)
        reopenedReminder.refreshForChecks()
        try expect(app.jobs.activeCount == 0 && reopenedReminder.canSafelyRelaunch && reopenedReminder.showsUpdateAnnouncement && reopenedReminder.canCheck && !reopenedReminder.waitingForWork,
                   "Cancelling the isolated queued job must release the update gate and clear its waiting reason")
        print("PASS: real queued job blocks restart independently of the legacy busy flag")
        try QuickCaptureController.verifyDraftPreservation(store: app)
        print("14 native updater checks passed (no production feed, preferences or installation)")
    }
    private static func verifyVersionDisplay() throws {
        let metadata: [String: Any] = ["CFBundleShortVersionString": "0.17.6", "CFBundleVersion": "30",
                                       "PosleProductVersion": "0.17.6.1"]
        let display: SUVersionDisplay = AppUpdateVersionDisplay(info: metadata)
        // The public dictionary initializer is used only for inert display
        // fixtures. No updater, network request or installation is started.
        func item(version: String, build: String) throws -> SUAppcastItem {
            guard let item = SUAppcastItem(dictionary: ["sparkle:version": build,
                "sparkle:shortVersionString": version, "link": "https://example.invalid/update"]) else {
                throw AppError.message("Could not create the updater display fixture")
            }
            return item
        }
        let matching = try item(version: "0.17.6.1", build: "30")
        try expect(display.formatBundleDisplayVersion?("0.17.6", withBundleVersion: "30", matchingUpdate: matching) == "0.17.6.1",
                   "Sparkle's no-update message must show the installed public hotfix version")
        try expect(display.formatBundleDisplayVersion?("0.17.6", withBundleVersion: "30", matchingUpdate: nil) == "0.17.6.1",
                   "Sparkle must retain the public version even when no matching feed item exists")
        let next = try item(version: "0.17.6.2", build: "31")
        var installed: NSString = "0.17.6"
        let candidate = display.formatUpdateVersion(fromUpdate: next, andBundleDisplayVersion: &installed, withBundleVersion: "30")
        try expect(installed == "0.17.6.1" && candidate == "0.17.6.2" && next.versionString == "31",
                   "The next-update dialog must show both public versions without changing candidate build ordering")
        let sameLabel = try item(version: "0.17.6.1", build: "31")
        installed = "0.17.6"
        let distinguished = display.formatUpdateVersion(fromUpdate: sameLabel, andBundleDisplayVersion: &installed, withBundleVersion: "30")
        try expect(installed == "0.17.6.1 (30)" && distinguished == "0.17.6.1 (31)",
                   "Two builds sharing a public label must retain Sparkle's build disambiguation")
        try expect(display.formatBundleDisplayVersion?("another-host", withBundleVersion: "29", matchingUpdate: nil) == "another-host",
                   "The formatter must not apply product metadata to an unrelated host build")
        let legacy = AppUpdateVersionDisplay(info: ["CFBundleShortVersionString": "0.17.6", "CFBundleVersion": "29"])
        try expect(legacy.formatBundleDisplayVersion("0.17.6", withBundleVersion: "29", matchingUpdate: nil) == "0.17.6",
                   "Legacy metadata must preserve its existing display version")
        var invalid = metadata; invalid["PosleProductVersion"] = "untrusted-canary"
        try expect(AppUpdateVersionDisplay(info: invalid).formatBundleDisplayVersion("0.17.6", withBundleVersion: "30", matchingUpdate: nil) == "0.17.6",
                   "Invalid product metadata must fall back to the validated bundle short version")
        try expect(AppUpdateController().standardUserDriverRequestsVersionDisplayer() is AppUpdateVersionDisplay,
                   "The real standard updater delegate must install the product version formatter")
        print("PASS: Sparkle displays public hotfix versions for latest/next updates; candidate builds and legacy labels remain intact")
    }

    private struct SettingsHarness: View {
        @ObservedObject var app: AppStore
        var body: some View {
            Color.clear.frame(width: 1040, height: 760)
                .sheet(isPresented: $app.showingSettings) {
                    SettingsView(section: "updates").environmentObject(app)
                }
        }
    }
    private static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(condition(), message)
    }
    private static func verifyHiddenQuickCapture(app: AppStore, updates: AppUpdateController) async throws {
        let capture = QuickCaptureController(store: app)
        defer { capture.stop(); updates.standardUserDriverWillFinishUpdateSession() }
        capture.show()
        func visiblePanel() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.title == "Быстрая заметка" } }
        func textEditor(in view: NSView) -> PlainNoteTextView? {
            if let editor = view as? PlainNoteTextView { return editor }
            for child in view.subviews { if let editor = textEditor(in: child) { return editor } }
            return nil
        }
        guard let panel = visiblePanel(), let content = panel.contentView else { throw AppError.message("Quick-capture panel did not open") }
        try await waitUntil("Quick-capture native editor must appear") { textEditor(in: content) != nil }
        guard let editor = textEditor(in: content) else { throw AppError.message("Quick-capture native editor is missing") }
        editor.insertText("Не потерять мысль при обновлении", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil("Native typing must register the unsaved quick-capture draft") { capture.hasUnsavedDraft && UnsavedEditorRegistry.hasUnsaved }
        panel.performClose(nil)
        try expect(visiblePanel() == nil, "Quick-capture fixture must hide its own native panel")
        var installs = 0, reveals = 0
        updates.configureForChecks(store: app, hasQuickDraft: { capture.hasUnsavedDraft }, showQuickDraft: {
            reveals += 1; capture.show()
        })
        updates.postponeForChecks { installs += 1 }
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(reveals == 1 && installs == 0 && capture.hasUnsavedDraft && UnsavedEditorRegistry.hasUnsaved,
                   "A registered hidden quick-capture draft must reveal its editor instead of being stranded behind the generic dirty gate")
        guard let recoveredPanel = visiblePanel(), let recoveredContent = recoveredPanel.contentView else { throw AppError.message("Update recovery did not reveal quick capture") }
        try await waitUntil("Recovered native editor must retain the full draft") { textEditor(in: recoveredContent)?.string == "Не потерять мысль при обновлении" }
        guard let recovered = textEditor(in: recoveredContent) else { throw AppError.message("Recovered editor is missing") }
        recovered.selectAll(nil); recovered.deleteBackward(nil)
        try await waitUntil("Clearing the fixture draft must release its dirty registration") { !capture.hasUnsavedDraft && !UnsavedEditorRegistry.hasUnsaved }
        recoveredPanel.performClose(nil)
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(installs == 1, "Resolving the quick-capture draft must resume installation exactly once")
        updates.standardUserDriverWillFinishUpdateSession()
        print("PASS: updater reveals a real hidden quick-capture draft without losing text or bypassing the install gate")
    }
    private static func verifySettingsInstallation(app: AppStore, updates: AppUpdateController) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: SettingsHarness(app: app))
        window.makeKeyAndOrderFront(nil)
        defer {
            app.showingSettings = false; window.orderOut(nil); window.contentViewController = nil; window.contentView = nil
            updates.standardUserDriverWillFinishUpdateSession()
        }
        var installs = 0, installedWhileAttached = false
        app.showingSettings = true
        try await waitUntil("The real Settings sheet must register its own native window") { updates.hasSettingsWindowForChecks }
        app.settings.language = "en"
        app.busy = true
        updates.postponeForChecks {
            installs += 1; installedWhileAttached = installedWhileAttached || window.attachedSheet != nil
        }
        updates.resumeForChecks()
        try expect(app.showingSettings && installs == 0, "An install request must preserve Settings while processing is active")
        app.busy = false
        let dirty = UUID()
        UnsavedEditorRegistry.set(id: dirty, title: "Шаблон", dirty: true)
        updates.resumeForChecks()
        try expect(!app.showingSettings && installs == 0 && UnsavedEditorRegistry.hasUnsaved,
                   "Closing clean Settings must preserve a dirty document and block installation")
        try await waitUntil("Clean Settings must detach while unrelated draft remains protected") { window.attachedSheet == nil }
        updates.resumeForChecks()
        try expect(installs == 0, "A hidden dirty document must keep the actual install callback blocked")
        app.showingSettings = true
        try await waitUntil("Settings must reopen without losing the protected draft") { updates.hasSettingsWindowForChecks }
        guard let sheet = window.attachedSheet else { throw AppError.message("Settings sheet disappeared before install") }
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.beginSheet(child, completionHandler: { _ in })
        UnsavedEditorRegistry.remove(id: dirty)
        updates.resumeForChecks()
        try expect(app.showingSettings && installs == 0, "A nested editor must retain its sheet independently of registry timing")
        sheet.endSheet(child); child.orderOut(nil)
        try await waitUntil("The nested sheet must detach") { sheet.attachedSheet == nil }
        updates.resumeForChecks()
        try expect(!app.showingSettings && !installedWhileAttached, "Install must dismiss clean Settings without installing before native detach")
        try await waitUntil("Settings must detach without a manual close") { window.attachedSheet == nil }
        updates.resumeForChecks(); updates.resumeForChecks()
        let persisted: AppSettings? = app.read(app.root.appendingPathComponent("settings.json"))
        try expect(installs == 1 && !installedWhileAttached && updates.relaunchRequested && persisted?.language == "en",
                   "Clean Settings must persist and resume installation exactly once")
        updates.standardUserDriverWillFinishUpdateSession()
        app.showingSettings = true
        try await waitUntil("Settings must reopen for a failed-save regression") { updates.hasSettingsWindowForChecks }
        let settingsURL = app.root.appendingPathComponent("settings.json")
        try FileManager.default.removeItem(at: settingsURL)
        try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: false)
        app.settings.language = "ru"
        updates.postponeForChecks {
            installs += 1; installedWhileAttached = installedWhileAttached || window.attachedSheet != nil
        }
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(app.showingSettings && installs == 1 && updates.settingsSaveFailed && !updates.canSafelyRelaunch,
                   "A settings write failure must keep the sheet and live preferences intact without retrying each timer tick")
        try FileManager.default.removeItem(at: settingsURL)
        updates.retryInstallation()
        try await waitUntil("Explicit retry must dismiss Settings after durable saving") { window.attachedSheet == nil }
        updates.resumeForChecks(); updates.resumeForChecks()
        let recovered: AppSettings? = app.read(settingsURL)
        try expect(installs == 2 && !installedWhileAttached && !updates.settingsSaveFailed && recovered?.language == "ru",
                   "Retry after disk recovery must install once with the latest saved preferences")
        updates.standardUserDriverWillFinishUpdateSession()
        app.error = nil
        print("PASS: real Settings saves and dismisses for install; dirty documents, child sheets, work and failed writes remain protected")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message(message) }
    }
}
#endif
