#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Real language selection and native rendering in a disposable, offline library.
@MainActor
enum LocalizationNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Disposable preview required") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable localization root required")
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        try expect(UILocalization.systemLanguage(preferredLanguages: ["ru-RU", "en-US"]) == "ru"
                   && UILocalization.systemLanguage(preferredLanguages: ["en-GB", "ru"]) == "en"
                   && UILocalization.systemLanguage(preferredLanguages: ["fr-FR", "ru_RU"]) == "ru"
                   && UILocalization.systemLanguage(preferredLanguages: ["fr-FR", "de-DE"]) == "en",
                   "System language must respect supported preferences and use English for unsupported languages")
        let app = AppStore(preview: true)
        app.settings.features = .allEnabled; app.saveSettings()
        let localization = UILocalization.shared
        try expect(localization.setLanguage(.ru) && L("Настройки") == "Настройки", "Russian must retain canonical UI copy")
        let meeting = Meeting(title: "Заметки", source: "synthetic.mp3")
        let directory = app.meetingDirectory(meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try app.write(meeting, directory.appendingPathComponent("meta.json"))
        app.reloadLibrary(); app.selection = meeting.id; app.loadSelection(); app.tab = "notes"
        let draft = "Мои мысли: сохранить {0}, English и русский текст."
        app.notes.captureDrafts["inbox"] = draft; app.voice.text = draft
        let dirtyID = UUID()
        UnsavedEditorRegistry.set(id: dirtyID, title: "Моя несохранённая заметка", dirty: true)
        defer { UnsavedEditorRegistry.remove(id: dirtyID) }
        let settingsEncoder = JSONEncoder(); settingsEncoder.outputFormatting = [.sortedKeys]
        let settingsBefore = try settingsEncoder.encode(app.settings)
        let meetingBefore = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        let main = Host(AnyView(LocalizedInterfaceRoot(content: MainView().environmentObject(app))), width: 1260, height: 820)
        defer { main.close() }
        let settings = Host(AnyView(LocalizedInterfaceRoot(content: SettingsView().environmentObject(app))), width: 900, height: 690)
        defer { settings.close() }
        try await settle(settings) { ids(settings).contains("settings.language") && languagePopup(settings) != nil }
        try chooseLanguage(settings, title: "English")
        try await settle(settings) { localization.language == .en && renderedStrings(settings).contains("Interface language") }
        try await settle(main) { renderedStrings(main).contains("Meetings") && renderedStrings(main).contains("Notes") }
        try await settle(main) { menuTitles(NSApp.mainMenu).contains("Import recording…") && menuTitles(NSApp.mainMenu).contains("Meeting") }
        try expect(L("После") == "After" && UILocale().language.languageCode?.identifier == "en", "English name and date formatting must resolve independently of AI language")
        try expect(LF("Подключить {0} из {1}", arguments: ["{1} Савва", "%@"]) == "Connect {1} Савва from %@",
                   "Interpolation arguments must remain verbatim, including Cyrillic, format markers and placeholder-looking text")
        try expect(app.selected?.title == "Заметки" && renderedStrings(main).contains("Заметки")
                   && app.notes.captureDrafts["inbox"] == draft && app.voice.text == draft
                   && UnsavedEditorRegistry.titles.contains("Моя несохранённая заметка")
                   && (try settingsEncoder.encode(app.settings)) == settingsBefore
                   && (try Data(contentsOf: directory.appendingPathComponent("meta.json"))) == meetingBefore,
                   "Live language changes must preserve user text, drafts, model profiles and meeting data")
        let canonicalFailure = "Папка или её настройки изменились. Запустите обработку заново: сохранённые результаты не заменены."
        let configuration = JobConfiguration(command: "voice-plan", extra: [], input: Data("Поручение".utf8), settings: app.settings)
        let job = BackgroundJob(id: "language-fixture", kind: "voice-plan", objectID: meeting.id, inputRevision: "fixture", dependencies: [], config: configuration, resource: "cpu", state: "failed", message: canonicalFailure, title: "Конспект · Синк — руководитель", attempt: 1, paid: false, cancelRequested: false, createdAt: 1, updatedAt: 1)
        try expect(job.canReopenVoiceCommand && job.message == canonicalFailure && job.stateLabel == L(canonicalFailure)
                   && BackgroundJobPresentation.title(job) == "Summary · Синк — руководитель"
                   && BackgroundJobPresentation.metadata(job, historical: false).contains("Attempt 1"),
                   "English queue presentation must keep canonical retry classification, raw errors and Russian meeting titles intact")
        app.error = canonicalFailure
        try await settle(main) { renderedStrings(main).contains(L(canonicalFailure)) }
        try expect(app.error == canonicalFailure, "Error banners must translate only their presentation without changing retry classification data")
        app.error = nil
        try snapshot(main.view, root.appendingPathComponent("localization-en.png"))
        try snapshot(settings.view, root.appendingPathComponent("localization-settings-en.png"))
        print("PASS: real native language picker switches to English; navigation, settings and formatting update while Russian user content, drafts and model profiles remain unchanged")

        let state = root.appendingPathComponent("language-state.json")
        let savedPreference = try Data(contentsOf: state)
        let reopenedRoot = root.appendingPathComponent("language-reopen")
        try FileManager.default.createDirectory(at: reopenedRoot, withIntermediateDirectories: true)
        localization.configure(root: reopenedRoot)
        localization.configure(root: root)
        try expect(localization.language == .en && L("Настройки") == "Settings", "Language choice must survive reloading the data root")
        try expect(!localization.setLanguage(fromString: "fr") && localization.language == .en
                   && (try Data(contentsOf: state)) == savedPreference,
                   "Unsupported preference must leave the saved and displayed language intact")
        try expect(localization.setLanguage(.en) && localization.error == nil, "A valid choice must clear a recoverable language error")
        let backup = root.appendingPathComponent("language-state-check-backup.json")
        try FileManager.default.moveItem(at: state, to: backup)
        do {
            defer {
                try? FileManager.default.removeItem(at: state)
                try? FileManager.default.moveItem(at: backup, to: state)
            }
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
            try expect(!localization.setLanguage(.ru) && localization.language == .en && localization.error != nil,
                       "Failed atomic language save must retain the previous live language")
            try expect(try Data(contentsOf: backup) == savedPreference, "Failed language save must preserve the previous preference bytes")
        }
        try expect(localization.setLanguage(.en) && localization.error == nil, "Restored language file must be writable again")
        print("PASS: language preference persists outside model settings; invalid values and failed writes retain the last good preference")

        try chooseLanguage(settings, title: "Русский")
        try await settle(main) { renderedStrings(main).contains("Встречи") && renderedStrings(main).contains("Заметки") }
        try expect(localization.language == .ru && app.notes.captureDrafts["inbox"] == draft && app.voice.text == draft,
                   "Switching back to Russian must not recreate or clear editor state")
        try chooseLanguage(settings, title: "Как в системе")
        try await settle(settings) { localization.language == .system }
        try expect(localization.resolvedLanguage == UILocalization.systemLanguage(preferredLanguages: Locale.preferredLanguages),
                   "System default must return to the supported macOS language preference")
        try expect(!app.busy && !app.isRecording && app.jobs.activeCount == 0 && !app.calendar.connected && !app.calendar.requesting,
                   "Interface language changes must not start inference, recording or calendar authorization")
        print("PASS: native Russian and system-default choices update live without accessing models, accounts, microphone or calendars")
    }
    private static func menuTitles(_ menu: NSMenu?) -> Set<String> {
        guard let menu else { return [] }
        return menu.items.reduce(into: Set<String>()) { result, item in
            result.insert(item.title); result.formUnion(menuTitles(item.submenu))
        }
    }
    private static func languagePopup(_ host: Host) -> NSPopUpButton? {
        func popups(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups) }
        return roots(host).reversed().flatMap(popups).first { $0.itemTitles.contains("Русский") && $0.itemTitles.contains("English") && $0.itemTitles.count == 3 }
    }
    private static func chooseLanguage(_ host: Host, title: String) throws {
        guard let popup = languagePopup(host), let menu = popup.menu,
              let item = menu.items.first(where: { $0.title == title }) else { throw AppError.message("Native language picker option missing: " + title) }
        popup.select(item); menu.performActionForItem(at: popup.indexOfSelectedItem)
    }
    private static func renderedStrings(_ host: Host) -> Set<String> {
        var result = Set<String>()
        for node in roots(host).flatMap(nodes) {
            if let field = node.object as? NSTextField { result.insert(field.stringValue) }
            if let button = node.object as? NSButton { result.insert(button.title) }
            for selectorName in ["accessibilityLabel", "accessibilityValue", "title"] {
                let selector = NSSelectorFromString(selectorName)
                if node.object.responds(to: selector), let value = node.object.perform(selector)?.takeUnretainedValue() as? String { result.insert(value) }
            }
        }
        return result
    }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
    private static func sheetsClosed(_ host: Host) -> Bool {
        host.window.attachedSheet == nil && host.window.sheets.isEmpty
    }
    private static func settle(_ host: Host, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try? snapshot(host.view, URL(fileURLWithPath: ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] ?? "/private/tmp").appendingPathComponent("localization-failure.png"))
        throw AppError.message("Localization UI did not reach expected state at line \(line); attached sheets: \(host.window.sheets.count). IDs: " + ids(host).sorted().joined(separator: ", "))
    }
    private static func roots(_ host: Host) -> [NSView] {
        var result: [NSView] = [host.view]
        func sheets(_ window: NSWindow) {
            for sheet in window.sheets { if let view = sheet.contentView { result.append(view) }; sheets(sheet) }
        }
        sheets(host.window); return result
    }
    private static func ids(_ host: Host) -> Set<String> { Set(roots(host).flatMap(nodes).compactMap(\.identifier)) }
    private static func editName(_ host: Host, text: String) throws {
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let field = roots(host).reversed().flatMap(fields).first(where: { $0.placeholderString == "Название папки" }) else { throw AppError.message("Native folder name field missing") }
        field.window?.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Native folder name editor missing") }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.shouldChangeText(in: range, replacementString: text) else { throw AppError.message("Native folder name change rejected") }
        editor.replaceCharacters(in: range, with: text); editor.didChangeText()
    }
    private static func doubleClick(_ host: Host, _ identifier: String) throws {
        guard let node = roots(host).flatMap(nodes).first(where: { $0.identifier == identifier }), let frame = node.frame else { throw AppError.message("Native folder row geometry missing") }
        host.window.makeKeyAndOrderFront(nil)
        let point = host.window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for count in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil, eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) else { throw AppError.message("Native double-click event missing") }
                host.window.sendEvent(event)
            }
        }
    }
    private static func press(_ host: Host, _ identifier: String) throws {
        let matching = roots(host).flatMap(nodes).filter { $0.identifier == identifier }
        for node in matching { if node.press() { return } }
        if let node = matching.first, let frame = node.frame {
            let point = NSPoint(x: frame.midX, y: frame.midY)
            var windows = [host.window]
            func addSheets(_ window: NSWindow) { for sheet in window.sheets { windows.append(sheet); addSheets(sheet) } }
            addSheets(host.window)
            if let window = windows.reversed().first(where: { $0.frame.contains(point) }) {
                window.makeKeyAndOrderFront(nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { window.sendEvent(event) }
                }
                return
            }
        }
        throw AppError.message("Localization control cannot be pressed: " + identifier + " types: " + matching.map { String(describing: type(of: $0.object)) }.joined(separator: ", "))
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
            window.isReleasedWhenClosed = false
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
        var frame: NSRect? {
            if let modern { return modern.accessibilityFrame() }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(method, to: Frame.self)(object, selector)
        }
        var children: [Any] {
            let children = modern?.accessibilityChildren() ?? get("accessibilityChildren") as? [Any] ?? []
            let visible = get("accessibilityVisibleChildren") as? [Any] ?? []
            let contents = get("accessibilityContents") as? [Any] ?? []
            let navigation = get("accessibilityChildrenInNavigationOrder") as? [Any] ?? []
            return children + visible + contents + navigation
        }
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
