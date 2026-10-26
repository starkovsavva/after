#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Exercises the real settings store and native recording controls against an
/// empty disposable fixture. It never calls the recorder or enumerates devices.
@MainActor
enum RecordingNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Recording checks require --preview and an explicit disposable root")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) &&
                   root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable recording root required")
        let app = AppStore(preview: true)
        try expect(app.error == nil && app.meetings.isEmpty && app.notes.notes.isEmpty &&
                   !FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path),
                   "Recording checks require an empty fixture with no saved settings")
        let settingsURL = root.appendingPathComponent("settings.json")
        var legacy = AppSettings()
        legacy.startSection = "tasks"; legacy.language = "en"; legacy.speakerCount = 4
        legacy.localProvider = "lmstudio"; legacy.localEndpoint = "http://127.0.0.1:1234"
        legacy.focus = "Decisions and exact deadlines"; legacy.notesAutoTimestamp = false
        var oldObject = try jsonObject(legacy)
        for key in ["recordAudioQuality", "recordVideoQuality", "recordDisplayUUID"] { oldObject.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: oldObject).write(to: settingsURL, options: .atomic)
        let migrated = AppStore(preview: true)
        try expect(migrated.error == nil && migrated.settings.recordAudioQuality == .standard &&
                   migrated.settings.recordVideoQuality == .compact && migrated.settings.recordDisplayUUID.isEmpty,
                   "Old settings must load recording defaults")
        try expect(migrated.settings.speakerCount == 4 && migrated.settings.startSection == "tasks" &&
                   migrated.settings.localProvider == "lmstudio" && migrated.settings.focus == legacy.focus &&
                   !migrated.settings.notesAutoTimestamp, "Recording migration must retain unrelated preferences")
        migrated.settings.recordAudioQuality = .high; migrated.settings.recordVideoQuality = .native
        migrated.settings.recordVideo = true; migrated.settings.recordDisplayUUID = "preview-external"
        migrated.saveSettings()
        let reopened = AppStore(preview: true)
        try expect(reopened.error == nil && reopened.settings.recordAudioQuality == .high &&
                   reopened.settings.recordVideoQuality == .native && reopened.settings.recordVideo &&
                   reopened.settings.recordDisplayUUID == "preview-external", "Recording choices must survive save and reopen")
        try expect(reopened.settings.language == "en" && reopened.settings.speakerCount == 4 &&
                   reopened.settings.localEndpoint == legacy.localEndpoint && reopened.settings.focus == legacy.focus &&
                   !reopened.settings.notesAutoTimestamp, "Saving recording choices must preserve other preferences")
        print("PASS: old settings migrate and audio/video quality plus display UUID survive native save/reopen")

        var futureObject = try jsonObject(reopened.settings)
        futureObject["recordAudioQuality"] = "future-audio"; futureObject["recordVideoQuality"] = "future-video"
        try JSONSerialization.data(withJSONObject: futureObject).write(to: settingsURL, options: .atomic)
        let future = AppStore(preview: true)
        try expect(future.error == nil && future.settings.recordAudioQuality == .standard &&
                   future.settings.recordVideoQuality == .compact && future.settings.recordDisplayUUID == "preview-external" &&
                   future.settings.speakerCount == 4 && future.settings.localProvider == "lmstudio",
                   "Unknown quality values must fall back independently without resetting settings")
        reopened.saveSettings()
        print("PASS: unknown future quality values preserve the rest of the saved settings")

        let displays = RecordingDisplay.choices(preview: true)
        try expect(displays.count == 2 && displays.filter(\.isMain).count == 1 &&
                   Set(displays.map(\.persistentID)).count == displays.count,
                   "Preview monitors must have stable unique invented identities")
        try expect(RecordingDisplay.selectionIsAvailable("", in: displays) &&
                   RecordingDisplay.selectionIsAvailable("preview-external", in: displays),
                   "Current primary and explicit connected display must resolve")
        let replaced = [RecordingDisplay(id: displays[1].id, title: "Другой экран", pixelWidth: 1920,
                                        pixelHeight: 1080, isMain: true, persistentID: "replacement-display")]
        try expect(!RecordingDisplay.selectionIsAvailable("preview-external", in: replaced) &&
                   !RecordingDisplay.selectionIsAvailable("missing-display", in: displays) &&
                   !RecordingDisplay.selectionIsAvailable("", in: []),
                   "A disconnected UUID must never resolve to a different monitor with the same transient ID")
        print("PASS: disconnected display UUIDs cannot silently select another monitor, including transient ID reuse")

        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        let originalPalette = ThemeRuntime.shared.palette
        defer {
            NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode)
            ThemeRuntime.shared.set(originalPalette)
        }
        let options = OptionState()
        let optionHost = NativeHost(AnyView(ObservedOptions(state: options, displays: displays)
            .padding(28).frame(width: 560)), height: 420)
        defer { optionHost.close() }
        try await settle(optionHost) { node("record.audioQuality", in: optionHost) != nil }
        try expect(node("record.display", in: optionHost) == nil && node("record.videoQuality", in: optionHost) == nil,
                   "Audio-only options must not expose video controls")
        let videoToggle = try required(node("record.video", in: optionHost), "Native video toggle missing")
        try expect(videoToggle.press(), "Native video toggle must support accessibility press")
        try await settle(optionHost) { options.video && node("record.videoQuality", in: optionHost) != nil }
        try expect(node("record.display", in: optionHost) != nil && node("record.dimensions", in: optionHost) != nil,
                   "Turning on video must reveal screen, quality and full-frame dimensions")
        options.videoQuality = .native; options.displayUUID = "preview-external"
        try await settle(optionHost) {
            let text = node("record.dimensions", in: optionHost)?.text ?? ""
            return text.contains("3840") && text.contains("2160")
        }
        options.displayUUID = "missing-display"
        try await settle(optionHost) { node("record.displayUnavailable", in: optionHost) != nil }
        try expect(options.displayUUID == "missing-display" && node("record.dimensions", in: optionHost) == nil,
                   "Disconnected selection must show an error without replacing its identity or stale dimensions")
        print("PASS: actual native video toggle updates bindings, conditional controls, dimensions and disconnected state")
        optionHost.close()

        for density in ["regular", "compact"] {
            ThemeRuntime.shared.set(ThemePalette(textSize: 18, density: density))
            reopened.settings.recordVideo = true; reopened.settings.recordDisplayUUID = "missing-display"
            reopened.runtimeReady = true
            let recordHost = NativeHost(AnyView(RecordView().environmentObject(reopened)
                .environment(\.locale, Locale(identifier: "ru_RU"))), height: 680)
            defer { recordHost.close() }
            try await settle(recordHost) {
                node("record.displayUnavailable", in: recordHost) != nil && node("record.start", in: recordHost) != nil
            }
            let start = try required(node("record.start", in: recordHost), "Native Start button missing")
            try expect(!start.isEnabled, "Start must be disabled for an unavailable selected video screen")
            try assertVisibleControls(recordHost, identifiers: ["record.audioQuality", "record.video", "record.display",
                "record.videoQuality", "record.displayUnavailable", "record.start"])
            try expect(try required(node("record.video", in: recordHost), "Native video toggle missing").press(),
                       "Record dialog video toggle must support accessibility press")
            try await settle(recordHost) {
                node("record.displayUnavailable", in: recordHost) == nil && node("record.start", in: recordHost)?.isEnabled == true
            }
            try assertVisibleControls(recordHost, identifiers: ["record.audioQuality", "record.video", "record.start"])
            try expect(!reopened.isRecording && !reopened.busy && reopened.meetings.isEmpty,
                       "Rendering and toggling options must never start a recording or create a meeting")
            recordHost.close()
        }
        print("PASS: 560 px native dialog fits both densities at largest text size, disables disconnected video and permits audio-only")
        print("5 native recording checks passed")
    }

    @MainActor private final class OptionState: ObservableObject {
        @Published var audioQuality: RecordingAudioQuality = .standard
        @Published var video = false
        @Published var videoQuality: RecordingVideoQuality = .compact
        @Published var displayUUID = ""
    }
    private struct ObservedOptions: View {
        @ObservedObject var state: OptionState
        let displays: [RecordingDisplay]
        var body: some View {
            RecordingOptionsView(audioQuality: $state.audioQuality, video: $state.video,
                                 videoQuality: $state.videoQuality, displayUUID: $state.displayUUID, displays: displays)
        }
    }
    @MainActor private final class NativeHost {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        init(_ root: AnyView, height: CGFloat) {
            view = NSHostingView(rootView: root)
            view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: 560, height: height)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = view; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
        func close() { window.orderOut(nil) }
    }
    /// Public AppKit selectors also support SwiftUI's virtual accessibility nodes,
    /// which do not declare NSAccessibilityProtocol conformance.
    private struct AccessibilityNode {
        let object: NSObject
        private var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
        private func value(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        var identifier: String? { modern?.accessibilityIdentifier() ?? value("accessibilityIdentifier") as? String }
        var text: String {
            let value = modern?.accessibilityValue() ?? self.value("accessibilityValue")
            return (value as? String) ?? modern?.accessibilityLabel() ?? self.value("accessibilityLabel") as? String ?? ""
        }
        var children: [Any] { modern?.accessibilityChildren() ?? value("accessibilityChildren") as? [Any] ?? [] }
        var isEnabled: Bool {
            if let modern { return modern.isAccessibilityEnabled() }
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Getter.self)(object, selector)
        }
        var frame: NSRect {
            if let modern { return modern.accessibilityFrame() }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return .zero }
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(implementation, to: Getter.self)(object, selector)
        }
        func press() -> Bool {
            if let modern { return modern.accessibilityPerformPress() }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Press.self)(object, selector)
        }
    }
    private static func nodes(_ host: NativeHost) -> [AccessibilityNode] {
        var result: [AccessibilityNode] = []; var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = AccessibilityNode(object: object); result.append(node)
            for child in node.children { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(host.view, depth: 0); return result
    }
    private static func node(_ identifier: String, in host: NativeHost) -> AccessibilityNode? {
        nodes(host).first { $0.identifier == identifier }
    }
    private static func settle(_ host: NativeHost, until condition: () -> Bool) async throws {
        for _ in 0..<150 {
            host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded()
            if condition() {
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded(); return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        for item in nodes(host) where item.identifier?.hasPrefix("record.") == true {
            print("RECORD AX: id=\(item.identifier ?? "") text=\(item.text) enabled=\(item.isEnabled) frame=\(item.frame)")
        }
        throw AppError.message("Native recording controls did not settle")
    }
    private static func assertVisibleControls(_ host: NativeHost, identifiers: [String]) throws {
        let bounds = host.window.convertToScreen(host.view.convert(host.view.bounds, to: nil)).insetBy(dx: -1, dy: -1)
        for identifier in identifiers {
            let item = try required(node(identifier, in: host), "Native recording control missing: " + identifier)
            let frame = item.frame
            try expect(!frame.isEmpty && frame.minX.isFinite && frame.minY.isFinite && bounds.contains(frame),
                       "Recording control is clipped at 560 px: \(identifier), \(frame), host \(bounds)")
        }
    }
    private static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            throw AppError.message("Expected settings object")
        }
        return object
    }
    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw AppError.message(message) }; return value
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AppError.message(message) }
    }
}
#endif
