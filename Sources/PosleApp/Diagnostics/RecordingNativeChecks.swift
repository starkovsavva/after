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

        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        let originalPalette = ThemeRuntime.shared.palette
        defer {
            NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode)
            ThemeRuntime.shared.set(originalPalette)
        }
        let options = OptionState()
        let optionHost = NativeHost(AnyView(ObservedOptions(state: options)
            .padding(28).frame(width: 560)), height: 420)
        defer { optionHost.close() }
        try await settle(optionHost) { node("record.audioQuality", in: optionHost) != nil }
        try expect(node("record.display", in: optionHost) == nil && node("record.videoQuality", in: optionHost) == nil
                   && node("record.screenSelection", in: optionHost) != nil && node("record.audioSelection", in: optionHost) != nil,
                   "System-audio options must explain per-session screen consent without enumerating monitors")
        let videoToggle = try required(node("record.video", in: optionHost), "Native video toggle missing")
        try expect(videoToggle.press(), "Native video toggle must support accessibility press")
        try await settle(optionHost) { options.video && node("record.videoQuality", in: optionHost) != nil }
        try expect(node("record.display", in: optionHost) == nil && node("record.format", in: optionHost) != nil
                   && node("record.audioSelection", in: optionHost) == nil,
                   "Video must show format and quality, without guessing a display or dimensions before selection")
        options.video = false; options.systemAudio = false
        try await settle(optionHost) { node("record.screenSelection", in: optionHost) == nil }
        print("PASS: native recording controls explain per-session screen consent only for video or Mac audio")
        optionHost.close()

        for density in ["regular", "compact"] {
            ThemeRuntime.shared.set(ThemePalette(textSize: 18, density: density))
            reopened.settings.recordVideo = true; reopened.settings.recordDisplayUUID = "missing-display"
            reopened.runtimeReady = true
            let recordHost = NativeHost(AnyView(RecordView().environmentObject(reopened)
                .environment(\.locale, Locale(identifier: "ru_RU"))), height: 680)
            defer { recordHost.close() }
            try await settle(recordHost) {
                node("record.screenSelection", in: recordHost) != nil && node("record.start", in: recordHost) != nil
            }
            let start = try required(node("record.start", in: recordHost), "Native Start button missing")
            try expect(start.isEnabled, "A stale saved display must not block per-session screen selection")
            try expect(node("record.display", in: recordHost) == nil && node("record.displayUnavailable", in: recordHost) == nil,
                       "Recording must not resurrect the legacy monitor selector")
            try assertVisibleControls(recordHost, identifiers: ["record.audioQuality", "record.video",
                "record.videoQuality", "record.screenSelection", "record.start", "record.cancel"])
            try expect(try required(node("record.video", in: recordHost), "Native video toggle missing").press(),
                       "Record dialog video toggle must support accessibility press")
            try await settle(recordHost) {
                node("record.videoQuality", in: recordHost) == nil && node("record.start", in: recordHost)?.isEnabled == true
            }
            try assertVisibleControls(recordHost, identifiers: ["record.audioQuality", "record.video", "record.start", "record.cancel"])
            try expect(!reopened.isRecording && !reopened.busy && reopened.meetings.isEmpty,
                       "Rendering and toggling options must never start a recording or create a meeting")
            recordHost.close()
        }
        print("PASS: 560 px native dialog fits both densities at largest text size; stale display preference cannot block Start")
        try await folderProfiles(root: root)
        print("6 native recording groups passed")
    }

    private static func folderProfiles(root: URL) async throws {
        ThemeRuntime.shared.set(ThemePalette(textSize: 14, density: "regular"))
        let recorder = ProfileRecorder()
        let app = AppStore(preview: true, recorder: recorder)
        app.settings.recordVideo = false; app.saveSettings()
        var englishOverrides = FolderOverrides()
        englishOverrides.features = FolderFeatureOverrides(); englishOverrides.features?.cards = true
        englishOverrides.generateCards = true; englishOverrides.language = "en"
        englishOverrides.localModel = "English test model"; englishOverrides.mode = "local"
        englishOverrides.focus = "Полезные фразы и домашние задания"
        var workOverrides = FolderOverrides()
        workOverrides.features = FolderFeatureOverrides(); workOverrides.features?.cards = false
        workOverrides.generateCards = false; workOverrides.language = "ru"
        workOverrides.localModel = "Work test model"; workOverrides.mode = "local"
        guard let english = app.notes.saveFolder(LibraryFolder(name: "Английский", overrides: englishOverrides)),
              let work = app.notes.saveFolder(LibraryFolder(name: "Рабочие синки", overrides: workOverrides)) else {
            throw AppError.message(app.notes.error ?? "Native recording folders could not be created")
        }
        app.folderSelection = english.id
        let host = NativeHost(AnyView(RecordView().environmentObject(app)), height: 720)
        defer { host.close() }
        try await settle(host) { node("record.processing", in: host)?.text.contains("English test model") == true }
        try await chooseFolder("Рабочие синки", in: host)
        try await settle(host) { node("record.processing", in: host)?.text.contains("Work test model") == true }
        try expect(node("record.processing", in: host)?.text.contains("Русский") == true,
                   "Native folder selection did not update the inherited language")
        try expect(try required(node("record.processing", in: host), "Processing button missing").press(), "Processing popover cannot open")
        try await settle(host) { node("record.cardsUnavailable", in: host) != nil }
        try expect(node("record.generateCards", in: host) == nil, "Disabled folder must explain unavailable cards instead of exposing an inert control")
        try expect(try required(node("record.processing.done", in: host), "Processing Done missing").press(), "Processing Done cannot be pressed")
        try await settle(host) { node("record.processing.done", in: host) == nil }
        try await chooseFolder("Английский", in: host)
        try await settle(host) { node("record.processing", in: host)?.text.contains("English test model") == true }
        try expect(try required(node("record.processing", in: host), "Processing button missing").press(), "Processing popover cannot open")
        try await settle(host) { node("record.generateCards.off", in: host) != nil }
        try expect(try required(node("record.generateCards.off", in: host), "Generation-off choice missing").press(), "Generation-off choice cannot be selected")
        try expect(try required(node("record.processing.done", in: host), "Processing Done missing").press(), "Processing Done cannot be pressed")
        try await settle(host) { node("record.processing.done", in: host) == nil }
        try snapshot(host.view, root.appendingPathComponent("record-folder-profile.png"))
        try expect(try required(node("record.start", in: host), "Record Start missing").press(), "Native Record Start cannot be pressed")
        try await settle(host) { app.isRecording }
        guard let id = app.captureMeetingID, let meeting = app.meetings.first(where: { $0.id == id }) else {
            throw AppError.message("Native start did not persist a meeting")
        }
        try expect(app.folderID(for: id) == english.id && app.folderSelection == english.id
                   && app.filteredMeetings.contains(where: { $0.id == id }) && meeting.generateCards == false && !app.generatesCards(for: meeting),
                   "Native Record Start ignored the selected folder or per-meeting card choice")
        await app.stopRecording(finalize: false)
        let reopened = AppStore(preview: true)
        try expect(reopened.folderID(for: id) == english.id && reopened.meetings.first(where: { $0.id == id })?.generateCards == false,
                   "Native recording choices failed to survive reopen")
        try expect(recorder.startCount == 1 && !recorder.active && !app.busy,
                   "Native recording profile flow started unrelated work or failed to stop injected capture")
        print("PASS: actual recording controls select independent folder profiles, explain disabled cards and persist per-meeting override through native Start/reopen")
    }
    private static func chooseFolder(_ title: String, in host: NativeHost) async throws {
        try await NativePickerChecks.select(title: title, identifier: "record.folder", in: [host.view])
    }
    private static func snapshot(_ view: NSView, _ url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Recording snapshot missing") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Recording PNG missing") }
        try data.write(to: url)
    }
    private final class ProfileRecorder: MeetingRecordingBackend, @unchecked Sendable {
        var failed: (@Sendable (RecordingFailure) -> Void)?
        var levels: (@Sendable (Double?, Double?) -> Void)?
        private(set) var active = false
        private(set) var startCount = 0
        func start(url: URL, systemAudio: Bool, video: Bool, videoQuality: RecordingVideoQuality,
                   audioQuality: RecordingAudioQuality, displayID: UInt32?, expectedDisplayUUID: String?) async throws {
            guard displayID == nil, expectedDisplayUUID == nil else {
                throw AppError.message("Legacy monitor preference reached the recording backend")
            }
            try Data("synthetic native capture".utf8).write(to: url, options: .atomic)
            active = true; startCount += 1
        }
        func stop() async throws { active = false }
    }
    @MainActor private final class OptionState: ObservableObject {
        @Published var audioQuality: RecordingAudioQuality = .standard
        @Published var video = false
        @Published var videoQuality: RecordingVideoQuality = .compact
        @Published var systemAudio = true
    }
    private struct ObservedOptions: View {
        @ObservedObject var state: OptionState
        var body: some View {
            RecordingOptionsView(audioQuality: $state.audioQuality, video: $state.video,
                                 videoQuality: $state.videoQuality, systemAudio: state.systemAudio)
        }
    }
    @MainActor private final class NativeHost {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        init(_ root: AnyView, height: CGFloat) {
            view = NSHostingView(rootView: AnyView(root.frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.paper)))
            view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: 560, height: height)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = view; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
        func close() { window.orderOut(nil) }
    }
    /// Public AppKit selectors also support SwiftUI's virtual accessibility nodes,
    /// which do not declare NSAccessibilityProtocol conformance.
    @MainActor private struct AccessibilityNode {
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
            if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton, button.isEnabled { button.performClick(nil); return true }
            if let control = object as? NSControl, control.isEnabled { control.performClick(nil); return true }
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
        visit(host.view, depth: 0)
        func visitChildren(_ window: NSWindow) {
            for child in window.childWindows ?? [] {
                if let content = child.contentView { visit(content, depth: 0) }
                visitChildren(child)
            }
        }
        visitChildren(host.window)
        return result
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
