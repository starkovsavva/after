import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AppKit
import Foundation
import AfterCore
import AfterLocalization
import SwiftUI

@MainActor
enum MaterialFilterNativeNavigation {
    static func roots(_ host: NSView) -> [NSView] {
        [host] + NSApp.windows.filter(\.isVisible).compactMap(\.contentView).filter { $0 !== host }
    }
    static func contains(_ identifier: String, host: NSView) -> Bool {
        roots(host).contains { NativeTabNavigation.contains(identifier, in: $0) }
    }
    static func press(_ identifier: String, host: NSView) throws {
        guard let root = roots(host).first(where: { NativeTabNavigation.contains(identifier, in: $0) }) else {
            throw AppError.message("Material filter control missing: " + identifier)
        }
        try NativeTabNavigation.press(identifier, in: root)
    }
    static func add(_ title: String, prefix: String, host: NSView) async throws {
        // A popover can publish its Apply node before the action Menu mounts.
        // SwiftUI may expose that Menu as a virtual menu button rather than an
        // NSPopUpButton/AXPopUpButton, so resolve its own AX identifier directly.
        let identifier = prefix + ".add"
        var candidates: [NativeTabNavigation.Node] = []
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            roots(host).forEach { $0.layoutSubtreeIfNeeded() }
            candidates = roots(host).flatMap { NativeTabNavigation.nodes(in: $0) }.filter { $0.identifier == identifier && $0.enabled }
            if !candidates.isEmpty { break }
        }
        guard !candidates.isEmpty else { throw AppError.message("Material filter condition menu missing: " + identifier) }
        try await Task.sleep(for: .milliseconds(200))
        candidates = roots(host).flatMap { NativeTabNavigation.nodes(in: $0) }.filter { $0.identifier == identifier && $0.enabled }
        for node in candidates {
            let popup = (node.object as? NSPopUpButton) ?? ((node.object as? NSCell)?.controlView as? NSPopUpButton)
            if let menu = popup?.menu {
                menu.delegate?.menuNeedsUpdate?(menu); menu.delegate?.menuWillOpen?(menu); menu.update()
                if let index = menu.items.firstIndex(where: { $0.title == title && $0.isEnabled }) {
                    menu.performActionForItem(at: index)
                    return
                }
            }
        }
        let owner = roots(host).first { NativeTabNavigation.contains(identifier, in: $0) }?.window ?? host.window
        guard let owner else { throw AppError.message("Material filter menu window missing: " + identifier) }
        let driver = MenuActionDriver(title: title, window: owner)
        let timer = Timer(fireAt: Date().addingTimeInterval(0.2), interval: 0.05,
                          target: driver, selector: #selector(MenuActionDriver.tick(_:)), userInfo: nil, repeats: true)
        // A real menu's AX press may enter synchronous native tracking. Its
        // selection driver must run in that loop as well as the normal loop.
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        guard candidates.contains(where: { $0.press() }) else { throw AppError.message("Material filter menu AX press failed: " + identifier) }
        for _ in 0..<150 {
            if driver.finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard driver.finished && driver.sentSelection && !driver.timedOut else {
            throw AppError.message("Material filter action menu did not select: " + identifier + " → " + title)
        }
    }
    @MainActor private final class MenuActionDriver: NSObject {
        let title: String
        weak var window: NSWindow?
        let deadline = Date().addingTimeInterval(2.5)
        private(set) var sentSelection = false
        private(set) var timedOut = false
        private(set) var finished = false
        init(title: String, window: NSWindow) { self.title = title; self.window = window }
        @objc func tick(_ timer: Timer) {
            let menus = NSApp.windows.filter { $0.isVisible && $0.level == .popUpMenu }
            if sentSelection && menus.isEmpty { finished = true; timer.invalidate(); return }
            if Date() >= deadline {
                post("\u{1b}", code: 53)
                timedOut = true; finished = true; timer.invalidate(); return
            }
            guard !sentSelection, !menus.isEmpty else { return }
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            let exactItems = menus.compactMap(\.contentView).flatMap { NativeTabNavigation.nodes(in: $0) }.filter {
                $0.enabled && $0.role == NSAccessibility.Role.menuItem.rawValue &&
                    ($0.value == title || ($0.object as? any NSAccessibilityProtocol)?.accessibilityLabel() == title)
            }
            if exactItems.contains(where: { $0.press() }) { sentSelection = true; return }
            // Native menu type-ahead treats Cyrillic labels sharing a prefix
            // as incremental cycling. Select the exact rendered row instead.
            guard let row = menus.compactMap(\.contentView).flatMap(fields).first(where: {
                $0.stringValue == title && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
            }), let menuWindow = row.window else { return }
            let rect = row.convert(row.bounds, to: nil)
            let point = NSPoint(x: rect.midX, y: rect.midY)
            var events: [NSEvent] = []
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: menuWindow.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
                events.append(event)
            }
            events.forEach { NSApp.postEvent($0, atStart: false) }
            sentSelection = true
        }
        private func post(_ characters: String, code: UInt16) {
            guard let window else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
    }
}

/// Exercises the shipped Rust ABI, view model and native list on an empty,
/// disposable fixture. No model, account, clipboard or capture permissions.
@MainActor
enum CardsNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Cards checks require an explicit disposable preview root")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable cards root required")
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode) }
        let registration = UUID()
        UnsavedEditorRegistry.set(id: registration, title: "Новая карточка", dirty: true)
        try expect(UnsavedEditorRegistry.hasUnsaved && UnsavedEditorRegistry.titles.contains("Новая карточка"), "Unsaved editor was not registered")
        UnsavedEditorRegistry.set(id: registration, title: "Новая карточка", dirty: false)
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Saving a draft did not release the exit gate")
        UnsavedEditorRegistry.set(id: registration, title: "Карточка", dirty: true)
        UnsavedEditorRegistry.remove(id: registration)
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Closing an editor did not release the exit gate")
        let app = AppStore(preview: true)
        try expect(app.meetings.isEmpty, "Cards checks require an empty fixture")
        let bridge = try RustBridge.shared.get()
        let data = try bridge.request(root: root, command: "card-save", arguments: ["front": "circle back", "back": "Вернуться к вопросу", "newDeckTitle": "Рабочие фразы"])
        let created = try JSONDecoder().decode(CardSaveResult.self, from: data)
        let id = created.meeting.id
        for (front, back) in [("follow up", "Уточнить результат"), ("trade-off", "Компромисс")] {
            _ = try bridge.request(root: root, command: "card-save", arguments: ["meetingID": id, "front": front, "back": back])
        }
        app.reloadLibrary()
        let workspace = CardsWorkspace()
        await workspace.reload(root: root, meetingID: id)
        try expect(workspace.entries.count == 3 && workspace.errors.isEmpty && workspace.error == nil, "Native ABI could not load three manual cards")
        let original = workspace.entries[0]
        await workspace.preview(root: root, entry: original)
        try expect(workspace.options[1] == "1 мин" && workspace.options[2] == "5 мин 30 с" && workspace.options[3] == "10 мин", "FSRS preview intervals do not match the real learning steps")
        await workspace.rate(root: root, entry: original, rating: 3, meetingID: id)
        try expect(workspace.canUndo && workspace.entries[0].review?.count == 1, "Native grading failed")
        await workspace.undo(root: root, meetingID: id)
        try expect(!workspace.canUndo && workspace.entries[0].review == nil, "Native undo did not restore the unreviewed state")
        print("PASS: Swift → Rust card creation, loading, exact FSRS intervals, rating and undo")
        var edit = CardsWorkspace.arguments(original)
        edit["front"] = "circle back on"; edit["back"] = "Вернуться к обсуждению"
        _ = try bridge.request(root: root, command: "card-save", arguments: edit)
        do { _ = try bridge.request(root: root, command: "card-save", arguments: edit); throw AppError.message("Stale edit was accepted") }
        catch { try expect(error.localizedDescription != "Stale edit was accepted", "Stale card editor overwrote a newer version") }
        await workspace.reload(root: root, meetingID: id)
        let edited = workspace.entries[0]
        try expect(edited.card.front == "circle back on", "Edited text did not reload")
        await workspace.mutate(root: root, entry: edited, delete: false, meetingID: id)
        try expect(workspace.entries[0].suspended && !workspace.entries[0].isDue, "Paused card remained in the review queue")
        await workspace.mutate(root: root, entry: workspace.entries[0], delete: false, meetingID: id)
        await workspace.mutate(root: root, entry: workspace.entries[2], delete: true, meetingID: id)
        try expect(workspace.entries.count == 2, "Deleted card remained in the library")
        print("PASS: stale edit conflict, persistence, pause/resume and deletion")
        let host = NSHostingView(rootView: CardsWorkspaceView(meetingID: id).environmentObject(app).frame(width: 960, height: 660))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 960, height: 660)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await wait(host, window) { NativeTabNavigation.contains("cards.mode.all", in: host) }
        try expect(NativeTabNavigation.isSelected("cards.mode.study", in: host), "Cards must start in the selected review tab")
        try NativeTabNavigation.press("cards.mode.all", in: host)
        try await wait(host, window) { NativeTabNavigation.isSelected("cards.mode.all", in: host) && !NativeTabNavigation.isSelected("cards.mode.study", in: host) }
        try await wait(host, window) { descendants(host, as: NSTableView.self).contains { $0.numberOfRows >= 2 } }
        let table = descendants(host, as: NSTableView.self).first { $0.numberOfRows >= 2 }!
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await wait(host, window) { table.selectedRow == 1 }
        var summaryData = try bridge.read(root: root, url: app.meetingDirectory(id).appendingPathComponent("summary.json"))
        var summary = try JSONSerialization.jsonObject(with: summaryData) as! [String: Any]
        var cards = summary["cards"] as! [[String: Any]]
        for index in cards.indices { cards[index]["id"] = "replaced-\(index)" }
        summary["cards"] = cards
        _ = try bridge.request(root: root, command: "write", arguments: ["path": "meetings/\(id)/summary.json", "value": summary])
        NotificationCenter.default.post(name: .posleJobsChanged, object: nil)
        try await wait(host, window) { descendants(host, as: NSTableView.self).contains { $0.numberOfRows == 2 && $0.selectedRow == 0 } }
        summaryData = try bridge.read(root: root, url: app.meetingDirectory(id).appendingPathComponent("summary.json"))
        let intact = summaryData
        print("PASS: actual native All cards list selection survives replacement IDs with a real fallback card")
        let bad = app.meetingDirectory(id).appendingPathComponent("examples.json")
        try Data("malformed".utf8).write(to: bad)
        await workspace.reload(root: root, meetingID: id)
        try expect(!workspace.errors.isEmpty && workspace.error == nil, "Read failure masqueraded as an empty library")
        try FileManager.default.removeItem(at: bad)
        await workspace.reload(root: root, meetingID: id)
        try expect(workspace.errors.isEmpty && workspace.entries.count == 2, "Retry did not recover readable cards")
        let afterRetry = try bridge.read(root: root, url: app.meetingDirectory(id).appendingPathComponent("summary.json"))
        try expect(afterRetry == intact, "Load failure changed card data")
        print("PASS: visible per-deck errors and retry preserve the underlying cards")
        try await verifyOriginFilters(root: root, app: app)
        try await AppTabBarNativeChecks.run()
        print("6 native card workflow checks passed")
    }
    private static func verifyOriginFilters(root: URL, app: AppStore) async throws {
        let bridge = try RustBridge.shared.get()
        let data = try bridge.request(root: root, command: "card-save", arguments: [
            "front": "origin common manual", "back": "Ручная карточка", "newDeckTitle": "Origins fixture"
        ])
        let created = try JSONDecoder().decode(CardSaveResult.self, from: data)
        let meetingID = created.meeting.id
        for name in ["common ai", "imported", "legacy", "future"] {
            _ = try bridge.request(root: root, command: "card-save", arguments: [
                "meetingID": meetingID, "front": "origin " + name, "back": "Источник " + name
            ])
        }
        let summaryURL = app.meetingDirectory(meetingID).appendingPathComponent("summary.json")
        var summary = try JSONSerialization.jsonObject(with: bridge.read(root: root, url: summaryURL)) as! [String: Any]
        var cards = summary["cards"] as! [[String: Any]]
        // One meeting contains every origin; citations cannot stand in for authorship.
        let origins: [String?] = ["manual", "ai", "imported", nil, "future-origin"]
        for index in cards.indices {
            cards[index]["creationOrigin"] = origins[index]
            cards[index]["segmentIDs"] = [7]
            cards[index]["context"] = "Сохранённая цитата источника"
        }
        cards[2]["kind"] = "concept"
        summary["cards"] = cards
        // Seed synthetic provenance only inside run()'s guarded disposable root.
        // Production creation commands own these fields and generic writes cannot forge them.
        try JSONSerialization.data(withJSONObject: summary).write(to: summaryURL, options: .atomic)
        let otherData = try bridge.request(root: root, command: "card-save", arguments: [
            "front": "other origin common ai", "back": "Другая колода", "newDeckTitle": "Other origins fixture"
        ])
        let other = try JSONDecoder().decode(CardSaveResult.self, from: otherData)
        let otherURL = app.meetingDirectory(other.meeting.id).appendingPathComponent("summary.json")
        var otherSummary = try JSONSerialization.jsonObject(with: bridge.read(root: root, url: otherURL)) as! [String: Any]
        var otherCards = otherSummary["cards"] as! [[String: Any]]
        otherCards[0]["creationOrigin"] = "ai"; otherSummary["cards"] = otherCards
        try JSONSerialization.data(withJSONObject: otherSummary).write(to: otherURL, options: .atomic)
        app.reloadLibrary()
        let workspace = CardsWorkspace()
        await workspace.reload(root: root, meetingID: meetingID)
        try expect(workspace.errors.isEmpty && workspace.entries.map(\.card.creationOrigin) == [.manual, .ai, .imported, .unknown, .unknown],
                   "Card DTO must use per-card origin; absent and future values remain unknown even with meeting citations")
        guard let manual = workspace.entries.first else { throw AppError.message("Origin fixture is missing") }
        await workspace.rate(root: root, entry: manual, rating: 3, meetingID: meetingID)
        try expect(workspace.error == nil && workspace.entries.first?.review?.count == 1 && workspace.entries.first?.isDue == false,
                   "Rated manual fixture must be scheduled in the future")
        let protectedNames = ["summary.json", "review-state.json", "cards-review-undo.json", "review-log.jsonl"]
        var protected: [String: Data?] = [:]
        for name in protectedNames { protected[name] = .some(try? Data(contentsOf: app.meetingDirectory(meetingID).appendingPathComponent(name))) }
        let preferences = OriginFilterPreferences(); preferences.configure(root: root)
        preferences.notesFilter = .manual; preferences.cardsFilter = .all
        func snapshotRoot(_ scheme: ColorScheme) -> some View {
            CardsWorkspaceView().environmentObject(app).frame(width: 960, height: 700)
                .background(Ink.paper).environment(\.colorScheme, scheme)
        }
        let host = NSHostingView(rootView: snapshotRoot(.light))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 960, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func hasCount(_ value: Int) -> Bool {
            NativeTabNavigation.nodes(in: host).contains { $0.identifier == "cards.count" && $0.value == String(value) }
        }
        func hasOrigin(_ origin: MaterialOriginFilter) -> Bool {
            let reopened = OriginFilterPreferences(); reopened.configure(root: root)
            return reopened.cardsFilter == origin
                && (origin == .all || NativeTabNavigation.contains("cards.filters.chip.origin", in: host))
        }
        func chooseOrigin(_ origin: MaterialOriginFilter, count: Int) async throws {
            try NativeTabNavigation.press("cards.filters.button", in: host)
            try await wait(host, window) { MaterialFilterNativeNavigation.contains("cards.filters.apply", host: host) }
            if MaterialFilterNativeNavigation.contains("cards.filters.row.remove.origin", host: host) {
                try MaterialFilterNativeNavigation.press("cards.filters.row.remove.origin", host: host)
            }
            if origin != .all {
                try await MaterialFilterNativeNavigation.add(L("Происхождение"), prefix: "cards.filters", host: host)
                try await wait(host, window) { MaterialFilterNativeNavigation.contains("cards.filters.origin." + origin.rawValue, host: host) }
                try MaterialFilterNativeNavigation.press("cards.filters.origin." + origin.rawValue, host: host)
            }
            try MaterialFilterNativeNavigation.press("cards.filters.apply", host: host)
            try await wait(host, window) {
                hasOrigin(origin) && hasCount(count) && !MaterialFilterNativeNavigation.contains("cards.filters.apply", host: host)
            }
        }
        func snapshot(_ name: String, scheme: ColorScheme = .light, origin: MaterialOriginFilter, count: Int) async throws {
            host.rootView = snapshotRoot(scheme)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(80))
            try await wait(host, window) { hasOrigin(origin) && hasCount(count) }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw AppError.message("Card origin snapshot unavailable")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw AppError.message("Card origin PNG unavailable")
            }
            try png.write(to: root.appendingPathComponent("cards-origin-" + name + ".png"))
            host.rootView = snapshotRoot(.light)
            window.appearance = NSAppearance(named: .aqua)
            try await Task.sleep(for: .milliseconds(80))
            try await wait(host, window) { hasOrigin(origin) && hasCount(count) }
        }
        func search(_ text: String, count: Int) async throws {
            guard let field = descendants(host, as: NSTextField.self).first(where: { $0.placeholderString == L("Найти карточку") }) else {
                throw AppError.message("Cards search field missing")
            }
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Cards search editor missing") }
            let range = NSRange(location: 0, length: (editor.string as NSString).length)
            guard editor.shouldChangeText(in: range, replacementString: text) else { throw AppError.message("Cards search typing rejected") }
            editor.replaceCharacters(in: range, with: text); editor.didChangeText()
            window.makeFirstResponder(nil)
            try await wait(host, window) { hasCount(count) }
        }
        try await wait(host, window) { NativeTabNavigation.contains("cards.filters.button", in: host) && NativePickerChecks.contains(identifier: "cards.deck", in: [host]) }
        try NativeTabNavigation.press("cards.mode.all", in: host)
        try await wait(host, window) { NativeTabNavigation.isSelected("cards.mode.all", in: host) }
        try await chooseOrigin(.ai, count: 2)
        try await NativePickerChecks.select(title: "Origins fixture", identifier: "cards.deck", in: [host])
        try await wait(host, window) { hasCount(1) && descendants(host, as: NSTableView.self).contains { $0.numberOfRows == 1 && $0.selectedRow == 0 } }
        try await chooseOrigin(.all, count: 5)
        try NativeTabNavigation.press("cards.filters.button", in: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("cards.filters.apply", host: host) }
        try await MaterialFilterNativeNavigation.add(L("Происхождение"), prefix: "cards.filters", host: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("cards.filters.origin.manual", host: host) }
        try MaterialFilterNativeNavigation.press("cards.filters.origin.manual", host: host)
        try MaterialFilterNativeNavigation.press("cards.filters.cancel", host: host)
        try await wait(host, window) { hasOrigin(.all) && hasCount(5) && !MaterialFilterNativeNavigation.contains("cards.filters.apply", host: host) }
        try NativeTabNavigation.press("cards.filters.button", in: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("cards.filters.apply", host: host) }
        try await MaterialFilterNativeNavigation.add(L("Происхождение"), prefix: "cards.filters", host: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("cards.filters.origin.ai", host: host) }
        try MaterialFilterNativeNavigation.press("cards.filters.origin.manual", host: host)
        try MaterialFilterNativeNavigation.press("cards.filters.origin.ai", host: host)
        try expect(hasCount(5), "Editing filter conditions must not change the library before Apply")
        try await Task.sleep(for: .milliseconds(80))
        if let popover = MaterialFilterNativeNavigation.roots(host).first(where: {
            $0 !== host && NativeTabNavigation.contains("cards.filters.popover", in: $0)
        }), let bitmap = popover.bitmapImageRepForCachingDisplay(in: popover.bounds) {
            popover.cacheDisplay(in: popover.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Filter builder PNG unavailable") }
            try png.write(to: root.appendingPathComponent("cards-filters-builder-light.png"))
        } else { throw AppError.message("Filter builder native capture unavailable") }
        try MaterialFilterNativeNavigation.press("cards.filters.apply", host: host)
        try await wait(host, window) {
            hasCount(2) && NativeTabNavigation.contains("cards.filters.chip.origin", in: host)
                && !MaterialFilterNativeNavigation.contains("cards.filters.apply", host: host)
        }
        try NativeTabNavigation.press("cards.filters.button", in: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("cards.filters.apply", host: host) }
        try await MaterialFilterNativeNavigation.add(L("Тип карточки"), prefix: "cards.filters", host: host)
        try await wait(host, window) { MaterialFilterNativeNavigation.contains("cards.filters.kind.concept", host: host) }
        try MaterialFilterNativeNavigation.press("cards.filters.kind.concept", host: host)
        try MaterialFilterNativeNavigation.press("cards.filters.apply", host: host)
        try await wait(host, window) {
            hasCount(0) && NativeTabNavigation.contains("cards.filters.chip.kind", in: host)
                && !MaterialFilterNativeNavigation.contains("cards.filters.apply", host: host)
        }
        try NativeTabNavigation.press("cards.filters.remove.kind", in: host)
        try await wait(host, window) { hasCount(2) && !NativeTabNavigation.contains("cards.filters.chip.kind", in: host) }
        try NativeTabNavigation.press("cards.filters.remove.origin", in: host)
        try await wait(host, window) { hasOrigin(.all) && hasCount(5) }
        try await snapshot("all-light", origin: .all, count: 5)
        try await search("common", count: 2)
        try await chooseOrigin(.manual, count: 1)
        try await snapshot("manual-light", origin: .manual, count: 1)
        try await chooseOrigin(.ai, count: 1)
        try await snapshot("ai-dark", scheme: .dark, origin: .ai, count: 1)
        try await search("manual", count: 0)
        try expect(NativeTabNavigation.contains("cards.empty.filters", in: host) && NativeTabNavigation.contains("cards.filters.clear-all", in: host),
                   "A query/origin intersection must expose an explicit empty state and clear control")
        try NativeTabNavigation.press("cards.filters.clear-all", in: host)
        try await wait(host, window) { hasOrigin(.all) && hasCount(1) }
        try await search("", count: 5)
        try NativeTabNavigation.press("cards.mode.study", in: host)
        try await wait(host, window) { NativeTabNavigation.isSelected("cards.mode.study", in: host) && hasCount(4) }
        try await chooseOrigin(.manual, count: 0)
        try await chooseOrigin(.ai, count: 1)
        try NativeTabNavigation.press("cards.mode.all", in: host)
        try await wait(host, window) { hasCount(1) && descendants(host, as: NSTableView.self).contains { $0.numberOfRows == 1 && $0.selectedRow == 0 } }
        app.navigationTarget = AppStore.NavigationTarget(meetingID: meetingID, kind: "card", cardID: cards[3]["id"] as? String)
        try await wait(host, window) {
            hasOrigin(.all) && hasCount(5)
                && descendants(host, as: NSTableView.self).contains { $0.numberOfRows == 5 && $0.selectedRow == 3 }
        }
        try await chooseOrigin(.ai, count: 1)
        app.navigationTarget = nil
        let reopened = OriginFilterPreferences(); reopened.configure(root: root)
        try expect(reopened.cardsFilter == .ai && reopened.notesFilter == .manual && reopened.error == nil,
                   "Cards selection must persist independently from notes after reopening preferences")
        for name in protectedNames {
            let after = try? Data(contentsOf: app.meetingDirectory(meetingID).appendingPathComponent(name))
            try expect(after == protected[name]!, "Filter changes mutated card content, schedule, rating or undo: " + name)
        }
        await workspace.reload(root: root, meetingID: meetingID)
        try expect(workspace.entries.first?.review?.count == 1 && workspace.entries.first?.card.segmentIDs == [7]
                   && workspace.entries.first?.card.context == "Сохранённая цитата источника",
                   "Origin filters must preserve ratings and source links")
        let restartedHost = NSHostingView(rootView: CardsWorkspaceView(meetingID: meetingID).environmentObject(app).frame(width: 700, height: 560))
        restartedHost.sizingOptions = []; restartedHost.frame = NSRect(x: 0, y: 0, width: 700, height: 560)
        let restartedWindow = NSWindow(contentRect: restartedHost.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        restartedWindow.isReleasedWhenClosed = false; restartedWindow.contentView = restartedHost; restartedWindow.makeKeyAndOrderFront(nil)
        defer { restartedWindow.orderOut(nil); restartedWindow.contentView = nil }
        try await wait(restartedHost, restartedWindow) {
            NativeTabNavigation.contains("cards.filters.chip.origin", in: restartedHost)
                && NativeTabNavigation.nodes(in: restartedHost).contains { $0.identifier == "cards.count" && $0.value == "1" }
        }
        print("PASS: native filter builder Apply/Cancel, OR origins, AND kind, removable chips, Study/All, query/deck intersections, separate persistence and unchanged review/source data")
    }
    private static func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }
    private static func wait(_ host: NSView, _ window: NSWindow, line: UInt = #line, condition: () -> Bool) async throws {
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("CARDS WAIT FAILED", line, "WINDOWS", NSApp.windows.filter(\.isVisible).map { ($0.title, $0.frame) })
        print("CARDS FILTER NODES", MaterialFilterNativeNavigation.roots(host).flatMap { NativeTabNavigation.nodes(in: $0) }.filter { $0.identifier?.hasPrefix("cards.filters") == true }.map { ($0.identifier, $0.role, $0.frame) })
        if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            if let png = image.representation(using: .png, properties: [:]), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] {
                try? png.write(to: URL(fileURLWithPath: path).appendingPathComponent("cards-filter-failure.png"))
            }
        }
        throw AppError.message("Native cards workflow timed out at line \(line)")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message(message) }
    }
}
#endif
