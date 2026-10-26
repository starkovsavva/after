#if DEBUG
import AppKit
import Foundation
import PosleCore

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
        let app = AppStore(preview: true), updates = app.updates
        var draft = false
        updates.configureForChecks(store: app, hasQuickDraft: { draft })
        try expect(!updates.isAvailable && !updates.canCheck, "Preview must never start a real updater")
        try expect(updates.canSafelyRelaunch, "Idle fixture should allow relaunch")
        for activity in ["recording", "stopping", "processing", "attachment"] {
            app.isRecording = activity == "recording"; app.stoppingRecording = activity == "stopping"
            app.busy = activity == "processing"; app.notes.attachmentBusy = activity == "attachment"
            try expect(!updates.canSafelyRelaunch, "Active \(activity) must block relaunch")
        }
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
        try QuickCaptureController.verifyDraftPreservation(store: app)
        print("7 native updater checks passed (no production feed, preferences or installation)")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message(message) }
    }
}
#endif
