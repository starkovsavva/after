import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AppKit
import AfterCore
import SwiftUI

@MainActor
enum OverviewNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Preview fixture required") }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/tmp", "/private/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable data required")
        let app = AppStore(preview: true)
        try expect(app.meetings.isEmpty, "Empty library required")
        let first = Meeting(title: "Поставка оборудования", source: "fixture.wav")
        let second = Meeting(title: "Запуск пилота", source: "fixture.wav")
        let summary = Summary(overview: "Согласовали сроки.", items: [], cards: [], provider: "local", model: "fixture", generatedAt: 1, warnings: [])
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(#"{"duration":10,"segments":[{"id":0,"start":0,"end":10,"speaker":"speaker_1","text":"Согласовали сроки.","overlap":false}],"warnings":[],"model":"fixture"}"#.utf8))
        for meeting in [first, second] {
            let directory = app.meetingDirectory(meeting.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try app.write(meeting, directory.appendingPathComponent("meta.json"))
            try app.write(summary, directory.appendingPathComponent("summary.json"))
            try app.write(transcript, directory.appendingPathComponent("transcript.json"))
        }
        app.reloadLibrary(); app.selection = first.id; app.loadSelection(); app.tab = "summary"
        app.rememberOverviewDraft("Моя правка", meetingID: first.id, original: summary.overview, generatedAt: 1)
        let host = NSHostingView(rootView: MainView().environmentObject(app).frame(width: 1040, height: 700))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await settle(host)
        guard let editor = textViews(host).first(where: { $0.isEditable && $0.string == "Моя правка" }) else { throw AppError.message("Restored summary editor not found") }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" — срок до пятницы", replacementRange: editor.selectedRange())
        try await settle(host)
        let edited = "Моя правка — срок до пятницы"
        try expect(app.overviewDrafts[first.id]?.text == edited, "Native typing must update the durable draft")
        app.tab = "transcript"; try await settle(host)
        try expect(!app.editingOverview, "A hidden editor must release its presentation gate")
        app.tab = "summary"; try await settle(host)
        try expect(textViews(host).contains { $0.isEditable && $0.string == edited }, "Switching tabs must preserve typed text")
        print("PASS: real NSTextView typing survives tab changes at 1040 × 700")
        app.rememberOverviewDraft("Правка второй встречи", meetingID: second.id, original: summary.overview, generatedAt: 1)
        app.openMeeting(second.id); try await settle(host)
        try expect(textViews(host).contains { $0.isEditable && $0.string == "Правка второй встречи" }, "Each meeting must restore its own draft")
        app.openMeeting(first.id); try await settle(host)
        try expect(textViews(host).contains { $0.isEditable && $0.string == edited }, "Returning to the first meeting must restore its draft")
        let reopened = AppStore(preview: true)
        try expect(reopened.overviewDrafts[first.id]?.text == edited && reopened.overviewDrafts[second.id]?.text == "Правка второй встречи", "Drafts must survive AppStore recreation")
        print("PASS: independent per-meeting drafts survive navigation and reopening")
        var regenerated = summary; regenerated.overview = "Новый конспект"; regenerated.generatedAt = 2
        try app.write(regenerated, app.meetingDirectory(first.id).appendingPathComponent("summary.json"))
        app.refreshResults(first.id); try await settle(host)
        try expect(textViews(host).contains { $0.isEditable && $0.string == edited }, "Regeneration must not erase manual edits")
        try expect(!app.saveOverview(edited, meetingID: first.id, expectedOverview: summary.overview, expectedGeneratedAt: 1), "Stale draft must not overwrite regenerated summary")
        let saved: Summary? = app.read(app.meetingDirectory(first.id).appendingPathComponent("summary.json"))
        try expect(saved?.overview == regenerated.overview, "Regenerated source must remain intact")
        print("PASS: summary regeneration preserves draft and rejects stale overwrite")
        try FileManager.default.removeItem(at: app.meetingDirectory(first.id).appendingPathComponent("summary.json"))
        app.refreshResults(first.id); app.tab = "transcript"; try await settle(host)
        app.tab = "summary"; try await settle(host)
        try expect(textViews(host).contains { $0.isEditable && $0.string == edited }, "A missing summary must not hide its recoverable draft")
        try FileManager.default.removeItem(at: app.meetingDirectory(first.id).appendingPathComponent("transcript.json"))
        app.refreshResults(first.id); app.tab = "transcript"; try await settle(host)
        app.tab = "summary"; try await settle(host)
        try expect(textViews(host).contains { $0.isEditable && $0.string == edited }, "A missing transcript must not hide a durable manual draft")
        print("PASS: missing summary or transcript keeps its draft visible and recoverable")
        app.discardOverviewDraft(first.id)
        try expect(app.overviewDrafts[first.id] == nil && app.overviewDrafts[second.id] != nil, "Discard affects only the chosen draft")
        let draftURL = app.root.appendingPathComponent("overview-drafts.json")
        try FileManager.default.removeItem(at: draftURL)
        try FileManager.default.createDirectory(at: draftURL, withIntermediateDirectories: false)
        app.rememberOverviewDraft("Сбой диска", meetingID: first.id, original: summary.overview, generatedAt: 1)
        try expect(!app.flushOverviewDrafts() && app.overviewDrafts[first.id]?.text == "Сбой диска", "A failed atomic save must retain the in-memory draft")
        try FileManager.default.removeItem(at: draftURL)
        try expect(app.flushOverviewDrafts(), "A repaired destination must allow retry")
        let afterRetry = AppStore(preview: true)
        try expect(afterRetry.overviewDrafts[first.id]?.text == "Сбой диска", "Retried draft must persist")
        print("PASS: independent discard, failed disk save and recovery retain every draft")
        var malformed = transcript
        malformed.segments[0].speaker = "speaker_" + String(Int.min)
        malformed.segments[0].start = 1e100; malformed.segments[0].end = 1e100
        app.transcript = malformed; app.tab = "transcript"
        try await settle(host)
        try expect(app.tab == "transcript", "Malformed numeric speaker and timestamp must render without trapping")
        print("PASS: extreme speaker number and timestamp render safely in native transcript")
        print("6 native summary draft and malformed transcript checks passed")
    }
    private static func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
    private static func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(180)); host.layoutSubtreeIfNeeded()
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AppError.message(message) }
    }
}
#endif
