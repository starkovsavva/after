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
private struct AppLayoutGeometryProbe: View {
    let identifier: String
    @State private var instance = UUID()
    @Environment(\.appLayoutCheckScope) private var scope
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: AppLayoutFramePreference.self,
                                   value: [identifier: geometry.frame(in: .global)])
        }.onPreferenceChange(AppLayoutFramePreference.self) { frames in
            UIConsistencyChecks.record(frames, scope: scope, instance: instance)
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
    private static var owners: [String: UUID] = [:]
    private static let tolerance: CGFloat = 0.75

    fileprivate static func record(_ values: [String: CGRect], scope candidate: String, instance: UUID) {
        guard !scope.isEmpty, candidate == scope else { return }
        for (identifier, frame) in values { frames[identifier] = frame; owners[identifier] = instance }
    }

    fileprivate static func remove(_ identifier: String, scope candidate: String, instance: UUID) {
        guard !scope.isEmpty, candidate == scope, owners[identifier] == instance else { return }
        frames.removeValue(forKey: identifier); owners.removeValue(forKey: identifier)
    }

    static func run() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"],
              isDisposableRoot(path) else {
            throw AppError.message("UI consistency checks require --preview and an explicit /private/tmp/posle-ui-check-* fixture")
        }
        let store = AppStore(preview: true)
        guard let meeting = store.meetings.first(where: { $0.id.hasPrefix("demo-") }) else {
            throw AppError.message("Generate the disposable demo fixture with scripts/preview.py before checking UI consistency")
        }
        store.selection = meeting.id; store.loadSelection(); store.tab = "summary"; store.librarySection = "meetings"
        store.error = nil; store.notice = nil; store.notes.error = nil; store.notes.notice = nil
        let originalMeetings = store.meetings
        scope = UUID().uuidString; frames = [:]; owners = [:]
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
            scope = ""; frames = [:]; owners = [:]; window.orderOut(nil)
        }
        let baseline = try await measure(host, window)
        try expectNear(baseline["toolbar"]!.height, AppLayout.toolbarHeight, "Toolbar uses the shared fixed height")
        try expectNear(baseline["status"]!.height, AppLayout.statusHeight, "Status uses the shared fixed height")
        try expectNear(baseline["workspace"]!.minY, baseline["toolbar"]!.maxY, "Workspace follows toolbar without a gap")
        try expectNear(baseline["status"]!.minY, baseline["workspace"]!.maxY, "Status follows workspace without a gap")
        print("PASS: native fixed toolbar/status and continuous workspace at 1040 × 700")

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
            try await check("switching library section to " + section)
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
        print("6 native UI consistency checks passed")
    }

    private static func measure(_ view: NSView, _ window: NSWindow) async throws -> [String: CGRect] {
        // Yield to SwiftUI's transaction/layout/geometry-preference passes.
        for _ in 0..<10 {
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        for identifier in ["toolbar", "workspace", "status"] {
            guard let frame = frames[identifier], frame.width > 0, frame.height > 0,
                  frame.origin.x.isFinite, frame.origin.y.isFinite else {
                throw AppError.message("Missing/invalid native layout anchor: " + identifier)
            }
        }
        return frames
    }
    private static func expectUnchanged(_ before: [String: CGRect], _ after: [String: CGRect], _ label: String,
                                        extra: [String] = []) throws {
        let optional = ["sidebar", "toolbar.note", "toolbar.file", "toolbar.record"] + extra
        for identifier in ["toolbar", "workspace", "status"] + optional where before[identifier] != nil {
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
#endif
