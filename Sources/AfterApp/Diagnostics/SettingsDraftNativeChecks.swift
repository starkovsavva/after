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
enum SettingsDraftNativeChecks {
    private struct Harness: View {
        @ObservedObject var app: AppStore
        let section: String
        var body: some View {
            Color.clear.frame(width: 1040, height: 760)
                .sheet(isPresented: $app.showingSettings) { SettingsView(section: section).environmentObject(app) }
        }
    }
    static func run(app: AppStore, updates: AppUpdateController) async throws {
        guard app.isPreview && ProcessInfo.processInfo.arguments.contains("--preview") else { throw AppError.message("Settings draft checks require preview") }
        let mode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(mode)
        NSApp.accessibilitySetValue(true, forAttribute: mode)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: mode) }
        for section in ["ai", "speech", "semantic"] {
            try await verify(section: section, app: app, updates: updates)
        }
        print("PASS: real cloud/speech key and semantic forms retain dirty input through update and tab switching; explicit Cancel releases installation")
    }
    private static func verify(section: String, app: AppStore, updates: AppUpdateController) async throws {
        try expect(!SettingsDraftRegistry.hasUnsaved && !UnsavedEditorRegistry.hasUnsaved, "Settings form fixture must start clean")
        app.settings.mode = "cloud"; app.settings.cloudProvider = "openai"; app.settings.speechMode = "cloud"
        app.settingsSection = section
        let host = NSHostingView(rootView: Harness(app: app, section: section))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 1040, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { app.showingSettings = false; window.orderOut(nil); window.contentView = nil; updates.standardUserDriverWillFinishUpdateSession() }
        try await Task.sleep(for: .milliseconds(60))
        app.showingSettings = true
        func activeRoot() -> NSView { window.attachedSheet?.contentView ?? host }
        func settle(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<180 {
                host.layoutSubtreeIfNeeded(); activeRoot().layoutSubtreeIfNeeded(); window.displayIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw AppError.message("Settings \(section): " + message)
        }
        try await settle("real Settings window must mount", { updates.hasSettingsWindowForChecks && window.attachedSheet != nil })
        func field() -> NSTextField? {
            if section == "semantic" { return descendants(activeRoot(), as: NSTextField.self).first { $0.placeholderString == "qwen3-embedding:0.6b" } }
            return descendants(activeRoot(), as: NSSecureTextField.self).first
        }
        try await settle("native input must mount", { field() != nil })
        try expect(!SettingsDraftRegistry.hasUnsaved, "Loading \(section) must not invent a dirty draft")
        guard let input = field(), let sheet = window.attachedSheet else { throw AppError.message("Native settings field missing") }
        sheet.makeKeyAndOrderFront(nil); sheet.makeFirstResponder(input)
        guard let editor = input.currentEditor() as? NSTextView else { throw AppError.message("Settings field editor missing") }
        let synthetic = section == "semantic" ? "embedding-fixture-v2" : "fixture-key-" + section
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.shouldChangeText(in: range, replacementString: synthetic) else { throw AppError.message("Settings editor refused synthetic typing") }
        editor.replaceCharacters(in: range, with: synthetic); editor.didChangeText()
        try await settle("typing must register a protected local draft", { SettingsDraftRegistry.hasUnsaved && UnsavedEditorRegistry.hasUnsaved })
        var installs = 0
        updates.postponeForChecks { installs += 1 }
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(app.showingSettings && window.attachedSheet === sheet && installs == 0 && !updates.canSafelyRelaunch && updates.settingsDraftStatus != nil,
                   "A dirty \(section) form must keep its Save/Cancel controls visible and block installation")
        if section == "ai" {
            guard let mode = descendants(activeRoot(), as: NSSegmentedControl.self).first else { throw AppError.message("AI mode selector missing") }
            mode.selectedSegment = 0
            _ = mode.sendAction(mode.action, to: mode.target)
            try await settle("switching to local mode must preserve cloud key draft", { app.settings.mode == "cloud" && field() != nil })
            try expect(editor.string == synthetic && SettingsDraftRegistry.hasUnsaved, "Rejected mode switch must retain the cloud key")
        }
        app.settingsSection = "general"
        try await settle("changing Settings tabs must preserve its unsaved form", { app.settingsSection == section })
        try expect(editor.string == synthetic && installs == 0, "Blocked tab switch must retain complete synthetic input")
        let cancelID = section == "ai" ? "cloud.key.cancel" : section == "speech" ? "speech.key.cancel" : "semantic.cancel"
        try await settle("explicit Cancel must be visible", { nodes(activeRoot()).contains { $0.identifier == cancelID } })
        guard let cancel = nodes(activeRoot()).first(where: { $0.identifier == cancelID }), cancel.press() else { throw AppError.message("Settings Cancel action missing") }
        try await settle("explicit Cancel must clear its own dirty guard", { !SettingsDraftRegistry.hasUnsaved && !UnsavedEditorRegistry.hasUnsaved })
        updates.resumeForChecks()
        try await settle("clean Settings must detach after cancelling local changes", { window.attachedSheet == nil })
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(installs == 1 && updates.relaunchRequested, "Cancelling \(section) changes must resume installation exactly once")
        let settings = try String(contentsOf: app.root.appendingPathComponent("settings.json"), encoding: .utf8)
        try expect(!settings.contains("fixture-key-"), "Synthetic API keys must never enter plain settings storage")
        updates.standardUserDriverWillFinishUpdateSession()
        try expect(!SettingsDraftRegistry.hasUnsaved, "Unmounting clean \(section) must not leave a ghost registry entry")
    }
    private static func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
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
        var result: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0); return result
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message(message) }
    }
}
#endif
