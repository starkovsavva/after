import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AppKit
import AfterCore
import AfterLocalization
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
        try await verifyControls()
        for section in ["ai", "speech", "semantic"] {
            try await verify(section: section, app: app, updates: updates)
        }
        print("PASS: real cloud/speech key and semantic forms retain dirty input through update and tab switching; explicit Cancel releases installation")
    }

    @MainActor private final class ControlState: ObservableObject {
        @Published var menu = "short"
        @Published var menuEnabled = true
        @Published var menuOptions = [AfterPickerOption(title: "Short", value: "short"),
                                      .init(title: "Disabled menu value", value: "blocked", isEnabled: false),
                                      .init(title: "Longer value", value: "long"),
                                      .init(title: "Alternative", value: "alternative")]
        @Published var choice = "local"
        @Published var draft = ""
        @Published var confirmations = 0
        @Published var cancellations = 0
        @Published var catalog = 1
        @Published var catalogEnabled = true
        @Published var options = (1...12).map { AfterPickerOption(title: "Catalog \($0)", value: $0) }
    }
    private struct ControlHarness: View {
        @ObservedObject var state: ControlState
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                AfterCompactPicker("Short menu", selection: $state.menu,
                    options: state.menuOptions,
                    showsLabel: false, identifier: "soft-check.menu")
                    .disabled(!state.menuEnabled)
                AfterChoicePicker("Mode", selection: $state.choice, options: [
                    .init(title: "Local", value: "local"), .init(title: "Disabled", value: "blocked", isEnabled: false),
                    .init(title: "Cloud", value: "cloud")], showsLabel: false, identifier: "soft-check.choice")
                AfterCompactPicker("Catalog", selection: $state.catalog, options: state.options,
                    showsLabel: false, searchable: true, identifier: "soft-check.catalog")
                    .disabled(!state.catalogEnabled)
                TextField("Draft for soft control check", text: $state.draft).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { state.cancellations += 1 }.keyboardShortcut(.cancelAction)
                    Button("Confirm") { state.confirmations += 1 }.keyboardShortcut(.defaultAction)
                        .buttonStyle(AfterSoftButtonStyle(.primary))
                }
            }.padding(20).frame(width: 400, height: 310).appControlDefaults()
        }
    }
    private static func verifyControls() async throws {
        let state = ControlState()
        let host = NSHostingView(rootView: ControlHarness(state: state))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 400, height: 310)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func settle(_ message: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<150 {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw AppError.message("Soft controls: " + message)
        }
        try await settle("native compact menu must mount", { NativePickerChecks.contains(identifier: "soft-check.menu", in: [host]) })
        let menuWidths = NativeTabNavigation.nodes(in: host).filter { $0.identifier == "soft-check.menu" }.compactMap(\.frame).filter { !$0.isEmpty }.map(\.width)
        try expect(!menuWidths.isEmpty && menuWidths.allSatisfy { $0 < 160 }, "A short menu must keep its content width rather than filling the form")
        guard let nativeMenu = NativePickerChecks.nativeControl("soft-check.menu", in: [host]) else {
            throw AppError.message("The compact menu must expose its real NSPopUpButton")
        }
        // Inspect the published AX tree, not the hidden native cell. A working
        // mouse target is insufficient when VoiceOver sees an unknown element.
        let menuNodes = NativeTabNavigation.nodes(in: host).filter { $0.identifier == "soft-check.menu" }
        let menuRoles = menuNodes.map { "\(type(of: $0.object)):role=\($0.role ?? "nil"),value=\($0.value ?? "nil")" }.joined(separator: " | ")
        let cellRole = (nativeMenu.cell as? any NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? "nil"
        try expect(!nativeMenu.pullsDown && menuNodes.contains(where: { $0.role == NSAccessibility.Role.popUpButton.rawValue && $0.value == "Short" && $0.enabled })
                   && nativeMenu.accessibilityLabel() == "Short menu",
                   "A mutually exclusive native selector must publish the pop-up role, label and current value; pullsDown=\(nativeMenu.pullsDown), viewRole=\(nativeMenu.accessibilityRole()?.rawValue ?? "nil"), cellRole=\(cellRole); nodes=\(menuRoles)")
        nativeMenu.setAccessibilityFocused(true)
        try await settle("native selector must publish keyboard focus", { NativeTabNavigation.isFocused("soft-check.menu", in: host) })
        try await NativePickerChecks.selectWithKeyboard(title: "Longer value", identifier: "soft-check.menu", in: [host])
        try expect(state.menu == "long", "The compact native menu must update its real binding")
        try expect(NativeTabNavigation.nodes(in: host).contains(where: {
            $0.identifier == "soft-check.menu" && $0.role == NSAccessibility.Role.popUpButton.rawValue && $0.value == "Longer value"
        }), "The published native selector must expose its complete new value after AX press and keyboard selection")
        try expect(nativeMenu.selectedItem?.state == .on, "The actual current native menu row must be checked")
        state.menu = "unlisted"
        try await settle("unknown native value must remain visible", { nativeMenu.titleOfSelectedItem == "unlisted" })
        try expect(state.menu == "unlisted" && nativeMenu.selectedItem?.isEnabled == false,
                   "A missing catalog value must not be silently replaced")
        state.menu = "short"
        try await settle("known native value must restore", { nativeMenu.titleOfSelectedItem == "Short" })
        guard let removedItem = nativeMenu.menu?.items.first(where: { $0.title == "Longer value" }),
              let blockedItem = nativeMenu.menu?.items.first(where: { $0.title == "Disabled menu value" }) else {
            throw AppError.message("Native selector guard fixtures missing")
        }
        // Invoke the real target/action after state changes, as a late menu
        // callback would. Neither a stale row nor a disabled form may commit.
        func invoke(_ item: NSMenuItem) {
            if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        }
        invoke(blockedItem)
        try expect(state.menu == "short", "A disabled native row must not commit")
        state.menuOptions.removeAll { $0.value == "long" }
        try await settle("removed native row must leave the menu", { nativeMenu.menu?.items.contains(where: { $0.title == "Longer value" }) == false })
        invoke(removedItem)
        try expect(state.menu == "short", "A late callback for a removed native row must not commit")
        guard let enabledItem = nativeMenu.menu?.items.first(where: { $0.title == "Alternative" }) else {
            throw AppError.message("Native selector enabled fixture missing")
        }
        state.menuEnabled = false
        try await settle("native form must become disabled", { !nativeMenu.isEnabled })
        try expect(!nativeMenu.isAccessibilityEnabled() && !nativeMenu.accessibilityPerformPress(),
                   "A disabled native selector must publish its disabled AX state and reject AX activation")
        invoke(enabledItem)
        try expect(state.menu == "short", "A disabled native form must reject late menu callbacks")
        state.menuEnabled = true
        try await settle("native form must re-enable", { nativeMenu.isEnabled })
        let disabled = NativeTabNavigation.nodes(in: host).filter { $0.identifier == "soft-check.choice.blocked" }
        try expect(!disabled.isEmpty && disabled.allSatisfy { !$0.enabled }, "Disabled choices must retain their native disabled state")
        try NativeTabNavigation.click("soft-check.choice.cloud", in: host, window: window)
        try await settle("clicked choice must publish selection and focus", {
            state.choice == "cloud" && NativeTabNavigation.isSelected("soft-check.choice.cloud", in: host)
                && NativeTabNavigation.isFocused("soft-check.choice.cloud", in: host)
        })
        try NativeTabNavigation.key("\u{f702}", code: 123, window: window)
        try await settle("arrow navigation must skip disabled choices", { state.choice == "local" })
        guard let field = descendants(host, as: NSTextField.self).first(where: { $0.placeholderString == "Draft for soft control check" }) else {
            throw AppError.message("Soft controls draft field missing")
        }
        window.makeFirstResponder(field)
        try NativeTabNavigation.key("\r", code: 36, window: window)
        try await settle("Return must retain the default primary action", { state.confirmations == 1 })
        try NativeTabNavigation.key("\u{1b}", code: 53, window: window)
        try await settle("Escape must retain the cancel action", { state.cancellations == 1 })
        func searchField() -> NSTextField? {
            NSApp.windows.filter { $0.isVisible && $0 !== window }.compactMap(\.contentView)
                .flatMap { descendants($0, as: NSTextField.self) }.first { $0.placeholderString == L("Поиск") }
        }
        try NativeTabNavigation.press("soft-check.catalog", in: host)
        try await settle("large catalog must open its search field", { searchField() != nil })
        guard let search = searchField(), let popover = search.window else { throw AppError.message("Catalog search missing") }
        popover.makeFirstResponder(search)
        guard let editor = search.currentEditor() as? NSTextView else { throw AppError.message("Catalog field editor missing") }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.shouldChangeText(in: range, replacementString: "Catalog 12") else { throw AppError.message("Catalog query rejected") }
        editor.replaceCharacters(in: range, with: "Catalog 12"); editor.didChangeText()
        try await Task.sleep(for: .milliseconds(80))
        state.options.removeAll { $0.value == 12 }
        try await Task.sleep(for: .milliseconds(80))
        try NativeTabNavigation.key("\r", code: 36, window: popover)
        try await Task.sleep(for: .milliseconds(80))
        try expect(state.catalog == 1 && searchField() != nil, "Enter must not commit a filtered option removed while the catalog is open")
        state.catalogEnabled = false
        try await settle("disabling the enclosing form must close its open catalog", { searchField() == nil })
        try expect(state.catalog == 1, "Disabling an open catalog must not change its selection")
        print("PASS: compact native popup sizing, real menu keyboard selection, checked/unknown values and stale/disabled action guards")
        print("PASS: soft choices disabled/selected/focus and arrows; Return/Escape action semantics")
        print("PASS: searchable catalog rejects removed results and closes without a commit when the enclosing control is disabled")
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
        if section == "semantic" {
            try await settle("semantic provider selector must mount", {
                NativePickerChecks.contains(identifier: "semantic.provider", in: [activeRoot()])
            })
        } else {
            try await settle("native input must mount", { field() != nil })
        }
        try expect(!SettingsDraftRegistry.hasUnsaved, "Loading \(section) must not invent a dirty draft")
        var initialSemanticProvider: String?
        if section == "semantic" {
            guard let provider = NativePickerChecks.value("semantic.provider", in: [activeRoot()]) else {
                throw AppError.message("Native semantic provider must expose its current value")
            }
            initialSemanticProvider = provider
            // The managed model has no editable model field. Choose the actual
            // external-provider UI without starting discovery or a model request.
            try await NativePickerChecks.select(title: "Ollama", identifier: "semantic.provider", in: [activeRoot()])
            try await settle("external semantic provider must expose its model input", { field() != nil })
        }
        guard let input = field(), let sheet = window.attachedSheet else { throw AppError.message("Native settings field missing") }
        sheet.makeKeyAndOrderFront(nil); sheet.makeFirstResponder(input)
        guard let editor = input.currentEditor() as? NSTextView else { throw AppError.message("Settings field editor missing") }
        let synthetic = section == "semantic" ? "embedding-fixture-v2" : "fixture-key-" + section
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.shouldChangeText(in: range, replacementString: synthetic) else { throw AppError.message("Settings editor refused synthetic typing") }
        editor.replaceCharacters(in: range, with: synthetic); editor.didChangeText()
        func currentDraftIsIntact() -> Bool {
            guard let mountedInput = field() else { return false }
            // AppKit ends or reuses its shared field editor when a choice takes
            // focus. Inspect the currently mounted input and its active editor.
            let currentValue = (mountedInput.currentEditor() as? NSTextView)?.string ?? mountedInput.stringValue
            return currentValue == synthetic
        }
        try await settle("typing must register a protected local draft", {
            currentDraftIsIntact() && SettingsDraftRegistry.hasUnsaved && UnsavedEditorRegistry.hasUnsaved
        })
        var installs = 0
        updates.postponeForChecks { installs += 1 }
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(app.showingSettings && window.attachedSheet === sheet && installs == 0 && !updates.canSafelyRelaunch && updates.settingsDraftStatus != nil,
                   "A dirty \(section) form must keep its Save/Cancel controls visible and block installation")
        if section == "ai" {
            try NativeTabNavigation.press("settings.processingMode.local", in: activeRoot())
            try await settle("switching to local mode must preserve cloud key draft", { app.settings.mode == "cloud" && field() != nil })
            try expect(currentDraftIsIntact() && SettingsDraftRegistry.hasUnsaved && UnsavedEditorRegistry.hasUnsaved,
                       "Rejected mode switch must retain the cloud key; mountedValueMatches=\(currentDraftIsIntact()), formerEditorMatches=\(editor.string == synthetic), fieldStillMounted=\(field() != nil), dirty=\(SettingsDraftRegistry.hasUnsaved)")
            if editor.string != synthetic {
                print("PASS: mounted cloud key retains the complete draft after AppKit releases its former field editor")
            }
        }
        app.settingsSection = "general"
        try await settle("changing Settings tabs must preserve its unsaved form", { app.settingsSection == section })
        try expect(currentDraftIsIntact() && SettingsDraftRegistry.hasUnsaved && UnsavedEditorRegistry.hasUnsaved && installs == 0,
                   "Blocked tab switch must retain complete synthetic input; mountedValueMatches=\(currentDraftIsIntact()), fieldStillMounted=\(field() != nil), dirty=\(SettingsDraftRegistry.hasUnsaved)")
        let cancelID = section == "ai" ? "cloud.key.cancel" : section == "speech" ? "speech.key.cancel" : "semantic.cancel"
        try await settle("explicit Cancel must be visible", { nodes(activeRoot()).contains { $0.identifier == cancelID } })
        guard let cancel = nodes(activeRoot()).first(where: { $0.identifier == cancelID }), cancel.press() else { throw AppError.message("Settings Cancel action missing") }
        try await settle("explicit Cancel must clear its own dirty guard", { !SettingsDraftRegistry.hasUnsaved && !UnsavedEditorRegistry.hasUnsaved })
        if let initialSemanticProvider {
            try await settle("Cancel must restore the original semantic provider", {
                NativePickerChecks.value("semantic.provider", in: [activeRoot()]) == initialSemanticProvider
            })
        }
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
