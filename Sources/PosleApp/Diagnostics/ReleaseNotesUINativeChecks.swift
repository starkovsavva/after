#if DEBUG
import AppKit
import Darwin
import Foundation
import PosleCore
import SwiftUI

/// Generated preferences and actual native views only. The check never opens
/// a recording device, account browser, calendar or a personal data root.
@MainActor
enum ReleaseNotesUINativeChecks {
    @MainActor private final class Presentation: ObservableObject {
        @Published var settings = false
        var section = ""
        var dismissalCount = 0
    }
    private struct Flow: View {
        @ObservedObject var app: AppStore
        @ObservedObject var controller: GuidanceController
        @ObservedObject var state: Presentation
        var body: some View {
            Color.clear.frame(width: 1050, height: 800)
                .sheet(item: $controller.presentation, onDismiss: {
                    controller.finishPresentation()
                    state.dismissalCount += 1
                    if case let .settings(section)? = controller.takeAction() {
                        state.section = section; state.settings = true
                    }
                }) { _ in GuidanceSheet(controller: controller).environmentObject(app) }
                .sheet(isPresented: $state.settings) {
                    SettingsView(section: state.section).environmentObject(app)
                }
        }
    }

    static func run(root: URL) async throws {
        let owned = root.standardizedFileURL.resolvingSymlinksInPath()
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              ["/private/tmp", "/tmp"].contains(owned.deletingLastPathComponent().path),
              owned.lastPathComponent.hasPrefix("posle-native-check-"),
              ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] == root.path else {
            throw AppError.message("Release notes checks require a disposable configured preview root")
        }
        let history: [String: Any] = ["introSeen": true, "lastLaunchedVersion": "0.17.6.4", "knownVersion": "0.17.6.4",
                                      "usedFeatureIDs": ["recording", "sources"], "usageSeeded": true]
        try JSONSerialization.data(withJSONObject: history).write(to: root.appendingPathComponent("guidance.json"), options: .atomic)
        let app = AppStore(preview: true)
        let originalTheme = ThemeRuntime.shared.palette
        let originalLanguage = UILocalization.shared.language
        let languageOverride = ProcessInfo.processInfo.environment["POSLE_UI_LANGUAGE"]
        let mode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let priorAX = NSApp.accessibilityAttributeValue(mode)
        NSApp.accessibilitySetValue(true, forAttribute: mode)
        defer {
            ThemeRuntime.shared.set(originalTheme)
            if let languageOverride { setenv("POSLE_UI_LANGUAGE", languageOverride, 1) }
            else { unsetenv("POSLE_UI_LANGUAGE") }
            _ = UILocalization.shared.setLanguage(originalLanguage)
            NSApp.accessibilitySetValue(priorAX, forAttribute: mode)
        }
        let controller = GuidanceController(version: "0.17.6.5")
        controller.configure(root: root, preview: true)
        app.settings.features.calendar = false
        controller.updateFeatures(app.settings.features)
        let initialFeatures = app.settings.features
        controller.presentWhatsNew()
        let updates = controller.featureGroups.flatMap(\.updates)
        try expect(!updates.isEmpty, "The actual release catalogue must supply native UI content")
        let state = Presentation()
        let flow = Host(AnyView(Flow(app: app, controller: controller, state: state)), width: 1050, height: 800)
        defer { flow.close() }
        try await wait(flow) { node("releases.settings", in: flow) != nil }
        try expect(values(flow).contains(LF("Обновлено с версии {0}", arguments: ["0.17.6.4"])),
                   "Native version header must reflect the exact saved launch version")
        let first = try required(updates.first(where: { $0.id == "recording" }), "Recording release entry missing")
        try press("releases.feature." + first.id, in: flow)
        try await wait(flow) { controller.selectedFeatureID == first.id && values(flow).contains(L(first.titleKey)) }
        let expectedText = try required(first.changes.first?.textKey, "Actual change text missing")
        try await wait(flow) { values(flow).contains(L(expectedText)) }
        try expect(!controller.isUnread(first.id), "Selecting the real native feature must mark its changes read")

        let order = controller.featureGroups.flatMap(\.updates).map(\.id)
        if let index = order.firstIndex(of: first.id), index + 1 < order.count {
            try key(flow, characters: "\u{f701}", code: 125)
            try await wait(flow) { controller.selectedFeatureID == order[index + 1] }
            try press("releases.feature." + first.id, in: flow)
        }
        try press("releases.settings", in: flow)
        try await wait(flow) { state.settings && node("settings." + first.settingsSection, in: flow) != nil }
        try expect(controller.presentation == nil && state.dismissalCount == 1 && state.section == first.settingsSection,
                   "Settings must consume the actual feature route only after release sheet dismissal")
        try expect(flow.window.sheets.count == 1 && flow.window.attachedSheet?.sheets.isEmpty == true,
                   "Settings and release notes cannot stack modal sheets")
        state.settings = false
        try await wait(flow) { flow.window.sheets.isEmpty }
        controller.presentWhatsNew()
        try await wait(flow) { node("releases.feature.calendar", in: flow) != nil }
        try press("releases.feature.calendar", in: flow)
        try await wait(flow) { controller.selectedFeatureID == "calendar" && values(flow).contains(L("Включить в настройках")) }
        try press("releases.settings", in: flow)
        try await wait(flow) { state.settings && node("settings.features", in: flow) != nil }
        try expect(state.section == "features" && app.settings.features == initialFeatures,
                   "An off feature must open the real opt-in settings without enabling itself")
        state.settings = false
        try await wait(flow) { flow.window.sheets.isEmpty }
        controller.presentWhatsNew()
        try await wait(flow) { node("releases.close", in: flow) != nil }
        try key(flow, characters: "\u{1b}", code: 53)
        try await wait(flow) { controller.presentation == nil && flow.window.sheets.isEmpty }
        try expect(!app.isRecording && !app.busy && app.jobs.activeCount == 0 && !app.calendar.connected,
                   "Reading changes and opening settings cannot start recording, processing or calendar access")
        print("PASS: native feature selection exposes real release text, keyboard navigation and settings only after dismissal; Escape closes without starting work")

        flow.close()
        for language in [UILanguage.ru, .en] {
            // Other native drivers deliberately pin DEBUG check processes to
            // Russian. The existing explicit override exercises the public
            // language API in this isolated process and is restored above.
            setenv("POSLE_UI_LANGUAGE", language.rawValue, 1)
            try expect(UILocalization.shared.setLanguage(language) && UILocalization.shared.resolvedLanguage == language.rawValue,
                       "Synthetic release language could not be selected")
            for density in ["regular", "compact"] {
                for dark in [false, true] {
                    var palette = originalTheme; palette.textSize = 18; palette.density = density
                    ThemeRuntime.shared.set(palette)
                    controller.presentWhatsNew()
                    controller.selectFeature(first.id)
                    let host = Host(AnyView(ReleaseNotesView(controller: controller)
                        .environment(\.locale, UILocale()).environment(\.colorScheme, dark ? .dark : .light)), width: 900, height: 680, dark: dark)
                    defer { host.close() }
                    try await wait(host) { node("releases.detail.title", in: host) != nil && values(host).contains(L(expectedText)) }
                    for id in ["releases.close", "releases.settings", "releases.done", "releases.hints"] {
                        let frame = try required(node(id, in: host)?.frame, "Release control lacks native bounds: " + id)
                        let bounds = host.window.convertToScreen(host.view.convert(host.view.bounds, to: nil))
                        try expect(bounds.insetBy(dx: -2, dy: -2).contains(frame), "Release control is clipped at largest font: " + id)
                    }
                    let name = "release-notes-\(language.rawValue)-\(density)-\(dark ? "dark" : "light").png"
                    try snapshot(host.view, to: root.appendingPathComponent(name))
                    host.close()
                }
            }
        }
        controller.finishPresentation()
        print("PASS: release notes render real full text and reachable controls at 900 px, 18 pt in RU/EN, both densities and light/dark appearances")
    }

    @MainActor private final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        init(_ content: AnyView, width: CGFloat, height: CGFloat, dark: Bool = false) {
            view = NSHostingView(rootView: AnyView(content.frame(width: width, height: height).background(Ink.paper)))
            view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            NSApp.activate(ignoringOtherApps: true); window.center(); window.makeKeyAndOrderFront(nil)
        }
        func close() { window.orderOut(nil); window.contentView = nil }
    }
    @MainActor private struct Node {
        let object: NSObject
        func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        var identifier: String? { attribute("accessibilityIdentifier") as? String }
        var text: [String] { [attribute("accessibilityValue"), attribute("accessibilityLabel"), attribute("accessibilityTitle")].compactMap { $0 as? String } }
        var frame: NSRect? {
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias GetFrame = @convention(c) (AnyObject, Selector) -> NSRect
            let rect = unsafeBitCast(method, to: GetFrame.self)(object, selector)
            return rect.width > 0 && rect.height > 0 ? rect : nil
        }
        var children: [Any] {
            ["accessibilityChildren", "accessibilityVisibleChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { attribute($0) as? [Any] ?? [] }
        }
        func press() -> Bool {
            if let button = object as? NSButton, button.isEnabled { button.performClick(nil); return true }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }
    private static func nodes(_ host: Host) -> [Node] {
        let roots = host.window.sheets.compactMap(\.contentView) + [host.view]
        var seen = Set<ObjectIdentifier>(), result: [Node] = []
        func visit(_ value: Any, depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.children { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        roots.forEach { visit($0, depth: 0) }; return result
    }
    private static func node(_ id: String, in host: Host) -> Node? {
        nodes(host).first { $0.identifier == id && $0.frame != nil }
    }
    private static func values(_ host: Host) -> Set<String> { Set(nodes(host).flatMap(\.text)) }
    private static func press(_ id: String, in host: Host) throws {
        try expect(try required(node(id, in: host), "Actual release control missing: " + id).press(), "Native press failed: " + id)
    }
    private static func key(_ host: Host, characters: String, code: UInt16) throws {
        let window = host.window.attachedSheet ?? host.window
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: code) else { throw AppError.message("Native release key event unavailable") }
        window.sendEvent(event)
    }
    private static func wait(_ host: Host, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        checkpoint(host, name: "release-failure-\(line)")
        throw AppError.message("Release notes UI timed out at line \(line); IDs: " + nodes(host).compactMap(\.identifier).joined(separator: ","))
    }
    private static func checkpoint(_ host: Host, name: String) {
        guard let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { return }
        for (index, window) in ([host.window] + host.window.sheets).enumerated() {
            print("RELEASE GEOMETRY \(name) window=\(index) frame=\(window.frame) content=\(String(describing: window.contentView?.frame)) bounds=\(String(describing: window.contentView?.bounds)) visible=\(window.isVisible)")
            if index > 0, let content = window.contentView {
                try? snapshot(content, to: URL(fileURLWithPath: path).appendingPathComponent("\(name)-sheet-\(index).png"))
            }
        }
        for node in nodes(host) where node.identifier?.hasPrefix("releases.") == true {
            print("RELEASE AX \(name) id=\(node.identifier ?? "nil") frame=\(String(describing: node.frame))")
        }
    }
    private static func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Release notes own-view render unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Release notes PNG unavailable") }
        try data.write(to: url)
    }
    private static func required<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw AppError.message(message) }; return value }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw AppError.message(message) } }
}
#endif
