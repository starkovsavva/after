import SwiftUI

extension View {
    /// Has no layout or runtime effect in release builds. Debug probes measure
    /// the actual native window only during the explicitly requested UI check.
    @ViewBuilder func appLayoutAnchor(_ identifier: String) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-ui-consistency") {
            self.background(AppLayoutGeometryProbe(identifier: identifier))
        } else { self }
        #else
        self
        #endif
    }
}

#if DEBUG
import AppKit
import Foundation
import PosleCore

private struct AppLayoutCheckScope: EnvironmentKey {
    static let defaultValue = ""
}
private extension EnvironmentValues {
    var appLayoutCheckScope: String {
        get { self[AppLayoutCheckScope.self] }
        set { self[AppLayoutCheckScope.self] = newValue }
    }
}
private struct AppLayoutFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}
private struct AppLayoutEnabledPreference: PreferenceKey {
    static var defaultValue: [String: Bool] = [:]
    static func reduce(value: inout [String: Bool], nextValue: () -> [String: Bool]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}
private struct AppLayoutGeometryProbe: View {
    let identifier: String
    @State private var instance = UUID()
    @Environment(\.appLayoutCheckScope) private var scope
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: AppLayoutFramePreference.self,
                                   value: [identifier: geometry.frame(in: .global)])
                .preference(key: AppLayoutEnabledPreference.self, value: [identifier: isEnabled])
        }.onPreferenceChange(AppLayoutFramePreference.self) { frames in
            UIConsistencyChecks.record(frames, scope: scope, instance: instance)
        }.onPreferenceChange(AppLayoutEnabledPreference.self) { values in
            UIConsistencyChecks.recordEnabled(values, scope: scope)
        }.onDisappear { UIConsistencyChecks.remove(identifier, scope: scope, instance: instance) }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Uses one NSHostingView and changes its real ObservableObject state between
/// measurements. No microphone, screen capture, model, HTTP, Keychain or
/// process runner is started. The explicit disposable fixture is mandatory.
@MainActor
enum UIConsistencyChecks {
    private static var scope = ""
    private static var frames: [String: CGRect] = [:]
    private static var enabledStates: [String: Bool] = [:]
    private static var owners: [String: UUID] = [:]
    private static let tolerance: CGFloat = 0.75

    fileprivate static func record(_ values: [String: CGRect], scope candidate: String, instance: UUID) {
        guard !scope.isEmpty, candidate == scope else { return }
        for (identifier, frame) in values { frames[identifier] = frame; owners[identifier] = instance }
    }

    fileprivate static func recordEnabled(_ values: [String: Bool], scope candidate: String) {
        guard !scope.isEmpty, candidate == scope else { return }
        enabledStates.merge(values, uniquingKeysWith: { _, newest in newest })
    }

    fileprivate static func remove(_ identifier: String, scope candidate: String, instance: UUID) {
        guard !scope.isEmpty, candidate == scope, owners[identifier] == instance else { return }
        frames.removeValue(forKey: identifier); enabledStates.removeValue(forKey: identifier); owners.removeValue(forKey: identifier)
    }

    static func run() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"],
              isDisposableRoot(path) else {
            throw AppError.message("UI consistency checks require --preview and an explicit /private/tmp/posle-ui-check-* fixture")
        }
        if arguments.contains("--check-cloud-audio-setup") {
            scope = UUID().uuidString; frames = [:]; enabledStates = [:]; owners = [:]
            defer { scope = ""; frames = [:]; enabledStates = [:]; owners = [:] }
            try await checkCloudAudioSetup()
            print("1 native cloud audio setup check passed")
            return
        }
        let store = AppStore(preview: true)
        guard let meeting = store.meetings.first(where: { $0.id.hasPrefix("demo-") }) else {
            throw AppError.message("Generate the disposable demo fixture with scripts/preview.py before checking UI consistency")
        }
        store.selection = meeting.id; store.loadSelection(); store.tab = "summary"; store.librarySection = "meetings"
        store.error = nil; store.notice = nil; store.notes.error = nil; store.notes.notice = nil
        let originalMeetings = store.meetings
        scope = UUID().uuidString; frames = [:]; enabledStates = [:]; owners = [:]
        let host = NSHostingView(rootView: MainView().environmentObject(store)
            .environment(\.appLayoutCheckScope, scope)
            .frame(width: 1040, height: 700))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer {
            store.busy = false; store.isRecording = false; store.stoppingRecording = false
            store.error = nil; store.notice = nil; store.notes.error = nil; store.notes.notice = nil
            scope = ""; frames = [:]; enabledStates = [:]; owners = [:]; window.orderOut(nil)
        }
        let baseline = try await measure(host, window)
        try expectNear(baseline["toolbar"]!.height, AppLayout.toolbarHeight, "Toolbar uses the shared fixed height")
        try expectNear(baseline["status"]!.height, AppLayout.statusHeight, "Status uses the shared fixed height")
        try expectNear(baseline["workspace"]!.minY, baseline["toolbar"]!.maxY, "Workspace follows toolbar without a gap")
        try expectNear(baseline["status"]!.minY, baseline["workspace"]!.maxY, "Status follows workspace without a gap")
        print("PASS: compact native toolbar, playback footer and continuous workspace at 1040 × 700")

        func check(_ label: String, extra: [String] = []) async throws {
            let measured = try await measure(host, window)
            try expectUnchanged(baseline, measured, label, extra: extra)
        }
        store.busy = true; store.canCancelJob = true; store.processingID = meeting.id
        store.progressText = "Распознаю речь и разделяю собеседников"; store.progress = -1
        try await check("starting an indeterminate job")
        store.progress = 0.42; store.progressText = "Распознаю речь · часть 4 из 12"
        try await check("changing to determinate progress")
        store.canCancelJob = false
        try await check("hiding job cancellation")
        store.busy = false; store.processingID = nil; store.progressText = ""; store.progress = -1
        try await check("finishing a job")
        print("PASS: start/finish, indeterminate/determinate progress and cancellation keep native chrome stationary")

        store.error = "Не удалось найти выбранную модель. Откройте настройки и выберите папку модели. Запись встречи сохранена."
        try await check("showing an error")
        store.error = nil; store.notice = "Конспект и карточки сохранены."
        try await check("showing a notice")
        store.notice = nil
        try await check("dismissing notifications")
        print("PASS: error and notice presentation do not move workspace or toolbar controls")

        // Only published presentation state is changed. Never call recorder,
        // stopRecording, processMeeting or any model/network operation here.
        store.isRecording = true; store.recordingDate = Date().addingTimeInterval(-125)
        try await check("mock recording")
        store.stoppingRecording = true; store.busy = true
        store.progressText = "Сохраняю запись и готовлю MP3…"
        try await check("mock recording save")
        store.isRecording = false; store.stoppingRecording = false; store.busy = false
        store.recordingDate = nil; store.progressText = ""
        try await check("finishing mock save")
        print("PASS: recording/save presentation states keep the same status slot without accessing recording hardware")

        for tab in ["notes", "transcript", "cards", "summary"] {
            store.tab = tab
            try await check("switching meeting tab to " + tab, extra: ["meeting.tabs"])
        }
        if let index = store.meetings.firstIndex(where: { $0.id == meeting.id }) {
            store.meetings[index].title = "Длинное демонстрационное название встречи: обсуждение бюджета, следующего этапа проекта и договорённостей с командой"
            try await check("using a long meeting title", extra: ["meeting.tabs"])
            store.meetings = originalMeetings
            try await check("restoring a short meeting title", extra: ["meeting.tabs"])
        }
        print("PASS: meeting tabs and short/long titles preserve native workspace geometry")

        for section in ["inbox", "tasks", "contexts", "cards", "meetings"] {
            store.librarySection = section
            let sectionBaseline = try await measure(host, window)
            try expectNear(sectionBaseline["toolbar"]!.height, AppLayout.toolbarHeight, "Toolbar height in " + section)
            if section != "meetings" {
                guard sectionBaseline["status"] == nil else { throw AppError.message("Idle footer wastes content space in " + section) }
                try expectNear(sectionBaseline["workspace"]!.maxY, baseline["status"]!.maxY, "Workspace reclaims footer space in " + section)
            }
            store.busy = true; store.canCancelJob = true; store.progressText = "Проверка состояния интерфейса"
            try expectUnchanged(sectionBaseline, try await measure(host, window), "starting work in " + section)
            store.busy = false; store.canCancelJob = false; store.progressText = ""
            store.notice = "Изменения сохранены"
            try expectUnchanged(sectionBaseline, try await measure(host, window), "notice in " + section)
            store.notice = nil
        }
        store.tab = "notes"
        let notesBaseline = try await measure(host, window)
        guard notesBaseline["notes.composer"] != nil else {
            throw AppError.message("Missing native layout anchor: notes.composer")
        }
        store.notes.notice = "Заметка сохранена"
        let withNotice = try await measure(host, window)
        try expectUnchanged(notesBaseline, withNotice, "showing note success", extra: ["notes.composer"])
        store.notes.notice = nil; store.notes.error = "Не удалось сохранить заметку. Ваш текст остался в редакторе."
        let withError = try await measure(host, window)
        try expectUnchanged(notesBaseline, withError, "showing note error", extra: ["notes.composer"])
        store.notes.error = nil
        print("PASS: library sections and note success/error preserve chrome and anchored composer geometry")
        try await checkCloudAudioSetup()
        try await checkReviewBar()
        try await checkTimedQueues()
        print("9 native UI consistency checks passed")
    }

    /// Rendering and the control's actual isEnabled environment only. Never activate the button: the
    /// fixture must prove onboarding is reachable without downloading anything.
    private static func checkCloudAudioSetup() async throws {
        let store = AppStore(preview: true)
        store.settings.speechMode = "cloud"
        store.settings.speechCloudProvider = "openai"
        let host = NSHostingView(rootView: SettingsView(section: "speech").environmentObject(store)
            .environment(\.appLayoutCheckScope, scope).environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.colorScheme, .light)
            .frame(width: 900, height: 690).background(Ink.paper))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 690),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host; window.appearance = NSAppearance(named: .aqua); window.makeKeyAndOrderFront(nil)
        defer { store.busy = false; store.isRecording = false; window.orderOut(nil) }
        for format in ["json", "diarized_json", "verbose_json"] {
            for ready in [false, true] {
                for diarization in [false, true] {
                    store.settings.speechResponseFormat = format
                    store.settings.diarization = diarization
                    store.runtimeReady = ready
                    _ = try await measure(host, window, requireWorkspaceAnchors: false)
                    guard enabledStates["speech.cloud.prepare-audio"] == true,
                          let rect = frames["speech.cloud.prepare-audio"], rect.width > 80, rect.height > 16 else {
                        throw AppError.message("Cloud audio setup is unreachable: format=\(format), ready=\(ready), diarization=\(diarization)")
                    }
                }
            }
        }
        store.settings.speechResponseFormat = "json"; store.runtimeReady = false
        for recording in [false, true] {
            store.busy = !recording; store.isRecording = recording
            _ = try await measure(host, window, requireWorkspaceAnchors: false)
            guard enabledStates["speech.cloud.prepare-audio"] == false else {
                throw AppError.message("Cloud audio setup must wait while a job or recording is active")
            }
        }
        print("PASS: cloud audio preparation remains visible and enabled for every response format and readiness/diarization state; active work disables setup")
    }

    private static func checkReviewBar() async throws {
        let state = ReviewBarCheckState()
        let view = NSHostingView(rootView: ReviewBarCheckView(state: state)
            .environment(\.appLayoutCheckScope, scope).frame(width: 760, height: 110))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 110),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        _ = try await measure(view, window)
        guard let front = frames["cards.review"] else { throw AppError.message("Missing shared card review footer") }
        try expectNear(front.height, 56, "Shared review footer height")
        for flipped in [true, false, true] {
            state.flipped = flipped
            _ = try await measure(view, window)
            guard let current = frames["cards.review"] else { throw AppError.message("Shared review footer disappeared") }
            for (before, after) in [(front.minX, current.minX), (front.minY, current.minY), (front.width, current.width), (front.height, current.height)] {
                try expectNear(before, after, "Showing a card answer must not move its controls")
            }
        }
        state.enabled = false
        _ = try await measure(view, window)
        guard state.ratings.isEmpty else { throw AppError.message("Changing review state must not grade a card") }
        print("PASS: shared card answer/grade controls keep the same 56 pt footer without auto-grading")
    }

    /// Advance real wall-clock time without publishing any app state: a due
    /// counter, card and its controls must all wake from an empty queue together.
    private static func checkTimedQueues() async throws {
        for section in ["meetings", "cards"] {
            let store = AppStore(preview: true)
            let due = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5))
            let data = try JSONSerialization.data(withJSONObject: ["due": due, "count": 1, "lastRating": 3])
            let review = try JSONDecoder().decode(ReviewState.self, from: data)
            for meeting in store.meetings {
                let summary: Summary? = store.read(store.meetingDirectory(meeting.id).appendingPathComponent("summary.json"))
                let reviews = Dictionary(uniqueKeysWithValues: (summary?.cards ?? []).map { ($0.id, review) })
                try store.write(reviews, store.meetingDirectory(meeting.id).appendingPathComponent("review-state.json"))
            }
            store.selection = store.meetings.first?.id; store.loadSelection()
            store.tab = "cards"; store.librarySection = section
            scope = UUID().uuidString; frames = [:]; enabledStates = [:]; owners = [:]
            let host = NSHostingView(rootView: MainView().environmentObject(store)
                .environment(\.appLayoutCheckScope, scope).frame(width: 1040, height: 700))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            _ = try await measure(host, window)
            guard frames["cards.review"] == nil else { throw AppError.message("Future cards must start outside the review queue in " + section) }
            // The production queue ticks every 30 seconds. No reload, selection
            // change or other ObservableObject notification is allowed here.
            try await Task.sleep(for: .seconds(31))
            _ = try await measure(host, window)
            guard let footer = frames["cards.review"] else { throw AppError.message("A newly due card did not reveal its review controls in " + section) }
            try expectNear(footer.height, 56, "Newly due card review footer in " + section)
            print("PASS: " + section + " review queue wakes from empty when a card becomes due without a state change")
        }
    }

    private static func measure(_ view: NSView, _ window: NSWindow, requireWorkspaceAnchors: Bool = true) async throws -> [String: CGRect] {
        // Yield to SwiftUI's transaction/layout/geometry-preference passes.
        for _ in 0..<10 {
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        for identifier in requireWorkspaceAnchors ? ["toolbar", "workspace"] : [] {
            guard let frame = frames[identifier], frame.width > 0, frame.height > 0,
                  frame.origin.x.isFinite, frame.origin.y.isFinite else {
                throw AppError.message("Missing/invalid native layout anchor: " + identifier)
            }
        }
        return frames
    }
    private static func expectUnchanged(_ before: [String: CGRect], _ after: [String: CGRect], _ label: String,
                                        extra: [String] = []) throws {
        let optional = ["status", "sidebar", "toolbar.note", "toolbar.file", "toolbar.record", "meeting.tab.notes", "meeting.tab.summary", "meeting.tab.transcript", "meeting.tab.cards"] + extra
        for identifier in ["toolbar", "workspace"] + optional where before[identifier] != nil {
            guard let first = before[identifier], let second = after[identifier] else {
                throw AppError.message("Native layout anchor disappeared while " + label + ": " + identifier)
            }
            for (name, a, b) in [("x", first.minX, second.minX), ("y", first.minY, second.minY),
                                 ("width", first.width, second.width), ("height", first.height, second.height)] {
                if abs(a - b) > tolerance {
                    throw AppError.message("Layout moved while \(label): \(identifier).\(name), \(a) → \(b)")
                }
            }
        }
    }
    private static func expectNear(_ first: CGFloat, _ second: CGFloat, _ message: String) throws {
        if abs(first - second) > tolerance { throw AppError.message(message + ": \(first) ≠ \(second)") }
    }
    private static func isDisposableRoot(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return ["/private/tmp", "/tmp"].contains(url.deletingLastPathComponent().path) && url.lastPathComponent.hasPrefix("posle-ui-check-")
    }
}
@MainActor
private final class ReviewBarCheckState: ObservableObject {
    @Published var flipped = false
    @Published var enabled = true
    @Published var query = ""
    var ratings: [Int] = []
}
private struct ReviewBarCheckView: View {
    @ObservedObject var state: ReviewBarCheckState
    var body: some View {
        VStack(spacing: 0) {
            TextField("Найти карточку", text: $state.query).textFieldStyle(.roundedBorder).padding(8)
            StudyReviewBar(flipped: $state.flipped, enabled: state.enabled, review: nil) { state.ratings.append($0) }
        }
    }
}
#endif
