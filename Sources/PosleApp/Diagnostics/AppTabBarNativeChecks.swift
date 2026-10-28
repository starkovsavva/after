#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Public accessibility and window-local events only: never change navigation
/// bindings directly to make a native-control regression pass.
@MainActor
enum NativeTabNavigation {
    @MainActor struct Node {
        let object: NSObject
        private var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
        private func get(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        private func flag(_ name: String) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Getter.self)(object, selector)
        }
        var identifier: String? { modern?.accessibilityIdentifier() ?? get("accessibilityIdentifier") as? String }
        var value: String? { modern?.accessibilityValue() as? String ?? get("accessibilityValue") as? String }
        var role: String? { modern?.accessibilityRole()?.rawValue ?? get("accessibilityRole") as? String }
        var enabled: Bool { modern?.isAccessibilityEnabled() ?? flag("isAccessibilityEnabled") }
        var focused: Bool { modern?.isAccessibilityFocused() ?? flag("isAccessibilityFocused") }
        var selected: Bool { modern?.isAccessibilitySelected() ?? flag("isAccessibilitySelected") }
        var frame: NSRect? {
            if let modern { return modern.accessibilityFrame() }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(method, to: Frame.self)(object, selector)
        }
        var children: [Any] {
            let children = modern?.accessibilityChildren() ?? get("accessibilityChildren") as? [Any] ?? []
            return children + (get("accessibilityVisibleChildren") as? [Any] ?? [])
                + (get("accessibilityContents") as? [Any] ?? [])
                + (get("accessibilityChildrenInNavigationOrder") as? [Any] ?? [])
        }
        func press() -> Bool {
            guard enabled else { return false }
            if let button = object as? NSButton { button.performClick(nil); return true }
            if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton { button.performClick(nil); return true }
            if let modern { return modern.accessibilityPerformPress() }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }
    static func nodes(in root: NSView) -> [Node] {
        var result: [Node] = []; var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.children { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0); return result
    }
    static func contains(_ identifier: String, in root: NSView) -> Bool { nodes(in: root).contains { $0.identifier == identifier } }
    static func isSelected(_ identifier: String, in root: NSView) -> Bool {
        nodes(in: root).contains { $0.identifier == identifier && ($0.selected || $0.value == L("Выбрана")) }
    }
    static func isFocused(_ identifier: String, in root: NSView) -> Bool {
        nodes(in: root).contains { $0.identifier == identifier && $0.focused }
    }
    static func press(_ identifier: String, in root: NSView) throws {
        let candidates = nodes(in: root).filter { $0.identifier == identifier }
        for candidate in candidates { if candidate.press() { return } }
        throw AppError.message("Native tab cannot be activated: " + identifier)
    }
    static func click(_ identifier: String, in root: NSView, window: NSWindow) throws {
        guard let candidate = nodes(in: root).first(where: { $0.identifier == identifier && $0.enabled && $0.frame?.isEmpty == false }),
              let frame = candidate.frame else { throw AppError.message("Native tab click geometry missing: " + identifier) }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw AppError.message("Native tab click event unavailable")
            }
            // Queue both events before returning to AppKit. A native button's
            // mouseDown may enter tracking and wait for its queued mouseUp.
            NSApp.postEvent(event, atStart: false)
        }
    }
    static func key(_ characters: String, code: UInt16, window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, characters: characters,
                                              charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                throw AppError.message("Native tab key event unavailable")
            }
            NSApp.postEvent(event, atStart: false)
        }
    }
}

/// Runs inside the already guarded disposable cards workflow. Exercises the
/// shared shipped tab view, actual text input, focus, keyboard and AX selection.
@MainActor
enum AppTabBarNativeChecks {
    static func run() async throws {
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        let state = TabBarCheckState()
        let host = NSHostingView(rootView: TabBarCheckView(state: state).frame(width: 620, height: 220).background(Ink.paper))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 620, height: 220)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { UnsavedEditorRegistry.remove(id: state.editorID); window.orderOut(nil) }
        try await settle(host, window) { NativeTabNavigation.contains("tab-regression.alpha", in: host) }
        print("TAB CHECK: fixture mounted")
        try expect(NativeTabNavigation.isSelected("tab-regression.alpha", in: host)
                   && !NativeTabNavigation.isSelected("tab-regression.gamma", in: host), "Initial tab must publish exactly one selected AX state")
        let beta = NativeTabNavigation.nodes(in: host).filter { $0.identifier == "tab-regression.beta" }
        try expect(!beta.isEmpty && beta.allSatisfy { !$0.enabled }, "Disabled tabs must expose their disabled AX state")

        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let field = fields(host).first(where: { $0.placeholderString == "Draft for tab regression" }) else { throw AppError.message("Native tab draft field missing") }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Native tab draft field editor missing") }
        let draft = "Unsaved мысль {0} before navigation"
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.shouldChangeText(in: range, replacementString: draft) else { throw AppError.message("Native draft typing rejected") }
        editor.replaceCharacters(in: range, with: draft); editor.didChangeText()
        try await settle(host, window) { state.draft == draft }
        print("TAB CHECK: typed draft reached binding")
        try expect(UnsavedEditorRegistry.titles.contains("Tab navigation draft"), "Typing must register the real unsaved draft")

        try NativeTabNavigation.click("tab-regression.gamma", in: host, window: window)
        try await settle(host, window) { state.selection == "gamma" && NativeTabNavigation.isFocused("tab-regression.gamma", in: host) }
        print("TAB CHECK: native click selected and focused Gamma")
        if let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] {
            let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path),
                  root.lastPathComponent.hasPrefix("posle-native-check-") else {
                throw AppError.message("Tab snapshots require a disposable fixture")
            }
            for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                window.appearance = NSAppearance(named: appearance)
                try await settle(host, window) { NativeTabNavigation.isFocused("tab-regression.gamma", in: host) }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("Tab snapshot unavailable") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Tab PNG unavailable") }
                try png.write(to: root.appendingPathComponent("tab-focus-" + name + ".png"))
            }
            window.appearance = NSAppearance(named: .aqua)
        }
        var count = 1
        for (characters, keyCode, destination) in [("\u{f729}", UInt16(115), "alpha"), ("\u{f703}", UInt16(124), "gamma"),
                                                    ("\u{f702}", UInt16(123), "alpha"), ("\u{f72b}", UInt16(119), "gamma")] {
            try NativeTabNavigation.key(characters, code: keyCode, window: window); count += 1
            try await settle(host, window) { state.selection == destination && NativeTabNavigation.isFocused("tab-regression." + destination, in: host) }
            print("TAB CHECK: key reached " + destination)
            try expect(state.changes == count && NativeTabNavigation.isSelected("tab-regression." + destination, in: host)
                       && !NativeTabNavigation.isSelected("tab-regression.beta", in: host), "Native arrows/Home/End must skip disabled tabs, focus their destination and publish selected AX state once")
        }
        try NativeTabNavigation.key(" ", code: 49, window: window)
        try await settle(host, window) { state.selection == "gamma" }
        try expect(state.draft == draft && field.stringValue == draft && state.changes == count
                   && UnsavedEditorRegistry.titles.contains("Tab navigation draft"), "Mouse, keyboard and Space activation must retain the typed draft and its unsaved guard")
        print("PASS: actual underlined tabs support native mouse/focus, arrows/Home/End skipping disabled tabs, selected AX state and preserve typed unsaved drafts")
    }
    private static func settle(_ host: NSView, _ window: NSWindow, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            // Even a no-op activation (Space on the selected tab) must reach
            // the native event loop before its preservation assertions run.
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { return }
        }
        for node in NativeTabNavigation.nodes(in: host) where node.identifier?.hasPrefix("tab-regression") == true {
            print("TAB AX: id=\(node.identifier ?? "nil") role=\(node.role ?? "nil") selected=\(node.selected) focused=\(node.focused) enabled=\(node.enabled) value=\(node.value ?? "nil") frame=\(String(describing: node.frame))")
        }
        throw AppError.message("Native tab navigation did not reach the expected focus/selection/draft state")
    }
    private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw AppError.message(message) } }
}

@MainActor
private final class TabBarCheckState: ObservableObject {
    let editorID = UUID()
    @Published var selection = "alpha" { didSet { if selection != oldValue { changes += 1 } } }
    @Published var draft = "" { didSet { UnsavedEditorRegistry.set(id: editorID, title: "Tab navigation draft", dirty: !draft.isEmpty) } }
    var changes = 0
}
private struct TabBarCheckView: View {
    @ObservedObject var state: TabBarCheckState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppTabBar(label: "Native tab regression", selection: $state.selection,
                      tabs: [AppTab("Alpha", value: "alpha"), AppTab("Disabled", value: "beta", isEnabled: false), AppTab("Gamma", value: "gamma")],
                      identifier: "tab-regression")
            TextField("Draft for tab regression", text: $state.draft).textFieldStyle(.roundedBorder)
            Text(state.selection)
        }.padding(24)
    }
}
#endif
