#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Exercises real native switches and navigation in a disposable preview library.
/// No accounts, model inference, microphone or calendar access are used.
@MainActor
enum FeatureUINativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Disposable preview required") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable feature UI root required")
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        let app = AppStore(preview: true)
        app.settings.features = AppFeatures()
        let features: [AppFeature] = [.cards, .tasks, .calendar, .assistant, .semanticSearch]
        let main = Host(AnyView(MainView().environmentObject(app)), width: 1260, height: 820)
        defer { main.close() }
        try await settle(main) { ids(main).contains("library.meetings") }
        try expect(ids(main).contains("library.inbox") && ids(main).contains("library.trash"), "Base notes and trash remain available")
        for identifier in ["library.cards", "library.tasks", "library.calendar", "library.contexts", "voice.open"] {
            try expect(!ids(main).contains(identifier), "Disabled optional control leaked: " + identifier)
        }
        print("PASS: default native sidebar shows meetings and notes without optional workflows")

        app.librarySection = "cards"
        try await settle(main) { ids(main).contains("features.openSettings") }
        try expect(!app.settings.isEnabled(.cards), "Deep route must not turn on cards")
        try press(main, "features.openSettings")
        try await settle(main) { app.showingSettings && app.settingsSection == "features" }
        app.showingSettings = false
        app.librarySection = "meetings"
        print("PASS: disabled deep route offers capabilities without enabling or mutating stored content")

        let settings = Host(AnyView(SettingsView(section: "features").environmentObject(app)), width: 900, height: 690)
        defer { settings.close() }
        try await settle(settings) { ids(settings).contains("features.cards") }
        for feature in features {
            try press(settings, "features." + FeaturePresentation.identifier(feature))
            try await settle(settings) { app.settings.isEnabled(feature) }
        }
        try await settle(main) { ids(main).contains("library.cards") && ids(main).contains("library.tasks") && ids(main).contains("voice.open") }
        try expect(ids(main).contains("library.calendar") && ids(main).contains("library.contexts"), "Enabled modules appear in native navigation")
        try await settle(settings) { ids(settings).contains("settings.semantic") && ids(settings).contains("settings.integrations") }
        print("PASS: all five real native switches reveal their navigation and settings independently")

        let dirtyEditor = UUID()
        let beforeDirtyChange = app.settings.features
        UnsavedEditorRegistry.set(id: dirtyEditor, title: "Правка карточки", dirty: true)
        try expect(!app.setFeature(.cards, enabled: false) && app.settings.features == beforeDirtyChange,
                   "Disabling a module must preserve its unsaved editor")
        UnsavedEditorRegistry.remove(id: dirtyEditor)
        app.error = nil
        print("PASS: module changes preserve unsaved editor drafts until explicit save or discard")

        for feature in features { try press(settings, "features." + FeaturePresentation.identifier(feature)) }
        try await settle(main) { !ids(main).contains("library.cards") && !ids(main).contains("library.tasks") && !ids(main).contains("voice.open") }
        try await settle(settings) { !ids(settings).contains("settings.semantic") && !ids(settings).contains("settings.integrations") }
        let persisted: AppSettings? = app.read(root.appendingPathComponent("settings.json"))
        try expect(persisted.map { settings in features.allSatisfy { !settings.isEnabled($0) } } == true, "Switches persist after returning to base mode")
        let meeting = Meeting(title: "Синк с руководителем", source: "source.mp3")
        let directory = app.meetingDirectory(meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try app.write(meeting, directory.appendingPathComponent("meta.json"))
        app.reloadLibrary(); app.selection = meeting.id; app.loadSelection()
        app.settings.features.cards = true
        let cards = Host(AnyView(MeetingCardGenerationToggle().environmentObject(app).padding(24)), width: 480, height: 120)
        defer { cards.close() }
        try await settle(cards) { ids(cards).contains("summary-generate-cards") }
        try expect(app.selected?.generateCards == nil, "Existing meeting must start with generation off without rewriting metadata")
        try press(cards, "summary-generate-cards")
        try await settle(cards) { app.selected?.generateCards == true }
        let enabledMeeting: Meeting? = app.read(directory.appendingPathComponent("meta.json"))
        try expect(enabledMeeting?.generateCards == true, "Per-meeting card choice persists after native switch")
        try press(cards, "summary-generate-cards")
        try await settle(cards) { app.selected?.generateCards == false }
        let disabledMeeting: Meeting? = app.read(directory.appendingPathComponent("meta.json"))
        try expect(disabledMeeting?.generateCards == false, "Turning card generation off persists for this meeting")
        try press(cards, "summary-inherit-cards")
        try await settle(cards) { app.selected?.generateCards == nil }
        let inheritedMeeting: Meeting? = app.read(directory.appendingPathComponent("meta.json"))
        try expect(inheritedMeeting?.generateCards == nil && !app.generatesCards(for: inheritedMeeting!),
                   "Native reset must persist inheritance rather than copying the current default")
        app.settings.features.cards = false; app.saveSettings()
        try await settle(cards) { !ids(cards).contains("summary-generate-cards") }
        print("PASS: production per-meeting card switch defaults off, persists on/off and hides with global cards")

        try expect(!app.busy && !app.isRecording && app.jobs.activeCount == 0 && !app.calendar.connected && !app.calendar.requesting, "Feature UI must not start recording, inference, jobs or calendar authorization")
        let settingsURL = root.appendingPathComponent("settings.json")
        let backupURL = root.appendingPathComponent("settings-feature-check-backup.json")
        let persistedBeforeFailure = try Data(contentsOf: settingsURL)
        let meetingBeforeFailure = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        let featuresBeforeFailure = app.settings.features
        try FileManager.default.moveItem(at: settingsURL, to: backupURL)
        do {
            defer {
                try? FileManager.default.removeItem(at: settingsURL)
                try? FileManager.default.moveItem(at: backupURL, to: settingsURL)
            }
            try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: false)
            app.error = nil
            try press(settings, "features.calendar")
            try await settle(settings) { app.error != nil }
            try expect(app.settings.features == featuresBeforeFailure && !app.calendar.connected && !app.calendar.requesting,
                       "Failed settings save must not publish consent or activate the calendar")
            try expect(try Data(contentsOf: directory.appendingPathComponent("meta.json")) == meetingBeforeFailure,
                       "Failed feature save must preserve meeting data")
            try expect(try Data(contentsOf: backupURL) == persistedBeforeFailure,
                       "Failed feature save must preserve previous preferences bytes")
        }
        app.error = nil
        try expect(try Data(contentsOf: settingsURL) == persistedBeforeFailure, "Original preferences restored after failure fixture")
        print("PASS: real switch save failure keeps runtime features, existing settings and meeting data unchanged")

        try snapshot(settings.view, root.appendingPathComponent("features-settings.png"))
        try snapshot(main.view, root.appendingPathComponent("features-base.png"))
        print("PASS: disabling removes optional UI, persists preferences and leaves base workflows idle")
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
    private static func settle(_ host: Host, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try? snapshot(host.view, URL(fileURLWithPath: ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] ?? "/private/tmp").appendingPathComponent("features-failure.png"))
        throw AppError.message("Feature UI did not reach expected state. IDs: " + ids(host).sorted().joined(separator: ", "))
    }
    private static func ids(_ host: Host) -> Set<String> { Set(nodes(host.view).compactMap(\.identifier)) }
    private static func press(_ host: Host, _ identifier: String) throws {
        let matching = nodes(host.view).filter { $0.identifier == identifier }
        for node in matching { if node.press() { return } }
        throw AppError.message("Feature control cannot be pressed: " + identifier + " types: " + matching.map { String(describing: type(of: $0.object)) }.joined(separator: ", "))
    }
    private static func snapshot(_ view: NSView, _ url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Feature snapshot failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Feature PNG failed") }
        try data.write(to: url)
    }
    @MainActor private final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        init(_ root: AnyView, width: CGFloat, height: CGFloat) {
            view = NSHostingView(rootView: root); view.sizingOptions = []
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = view; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
        func close() { window.orderOut(nil) }
    }
    @MainActor private struct Node {
        let object: NSObject
        private var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
        private func get(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        var identifier: String? { modern?.accessibilityIdentifier() ?? get("accessibilityIdentifier") as? String }
        var children: [Any] { modern?.accessibilityChildren() ?? get("accessibilityChildren") as? [Any] ?? [] }
        func press() -> Bool {
            if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton, button.isEnabled { button.performClick(nil); return true }
            if let control = object as? NSControl, control.isEnabled { control.performClick(nil); return true }
            if let modern { return modern.accessibilityPerformPress() }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }
    private static func nodes(_ root: NSView) -> [Node] {
        var result: [Node] = []; var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.children { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0); return result
    }
}
#endif
