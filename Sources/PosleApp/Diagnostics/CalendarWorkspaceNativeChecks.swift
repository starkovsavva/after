#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Exercises the actual calendar workspace with invented events and own-process AX.
/// Preview never creates an EKEventStore or opens system accounts. No Save is pressed.
@MainActor
enum CalendarWorkspaceNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else {
            throw AppError.message("Calendar workspace checks require --preview and a disposable root")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) &&
                   root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable calendar workspace root required")
        let app = AppStore(preview: true)
        try expect(app.error == nil && app.meetings.isEmpty && app.notes.notes.isEmpty,
                   "Calendar workspace checks require an empty fixture")
        let calendar = app.calendar
        try expect(calendar.preview && !calendar.connected && calendar.events.isEmpty, "Calendar must start in isolated preview mode")
        let clock = Calendar.current
        let anchor = clock.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
        calendar.selectedDate = anchor; calendar.seedPreview()
        let original = signature(calendar.events)
        let firstEvent = try required(calendar.events.first(where: { !$0.allDay }), "Invented timed event missing")
        let firstDay = clock.startOfDay(for: firstEvent.start)
        calendar.selectedDate = firstDay; calendar.displayMode = .week
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibilityMode = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        let originalPalette = ThemeRuntime.shared.palette
        defer {
            NSApp.accessibilitySetValue(previousAccessibilityMode, forAttribute: accessibilityMode)
            ThemeRuntime.shared.set(originalPalette)
        }
        let host = NativeHost(AnyView(CalendarView().environmentObject(app)
            .environment(\.locale, Locale(identifier: "ru_RU"))), width: 820, height: 620)
        defer { host.close() }
        try await settle(host) { node("calendar.mode", in: host) != nil && node("calendar.grid", in: host) != nil }
        try assertVisible(host, identifiers: ["calendar.sources", "calendar.add", "calendar.today", "calendar.previous", "calendar.next", "calendar.period", "calendar.mode"])
        let grid = try required(node("calendar.grid", in: host), "Calendar grid missing").frame
        try expect(grid.width >= 600 && grid.height >= 250, "Calendar must use the available workspace, not a mini month: \(grid)")
        print("PASS: actual native calendar exposes mode, navigation and full workspace grid at 820 × 620")

        for mode in CalendarDisplayMode.allCases {
            calendar.selectedDate = firstDay; calendar.displayMode = mode
            let expectedDays = mode == .day ? 1 : mode == .threeDays ? 3 : 7
            try await settle(host) {
                if mode == .month { return nodes(host).contains { $0.identifier?.hasPrefix("calendar.month.day.") == true } }
                return !nodes(host).contains { $0.identifier?.hasPrefix("calendar.month.day.") == true } && nodes(host).filter { $0.identifier?.hasPrefix("calendar.day.") == true }.count == expectedDays
            }
            try expect(signature(calendar.events) == original, "Switching \(mode.rawValue) must not alter source events")
            try expect(nodes(host).contains { $0.text.contains(firstEvent.title) }, "\(mode.rawValue) must expose an actual fixture event in AX")
            try assertVisible(host, identifiers: ["calendar.mode", "calendar.period", "calendar.previous", "calendar.next"])
            let oldDate = calendar.selectedDate
            let previousDate = mode.shiftedDate(from: oldDate, by: -1, calendar: clock)
            try expect(try required(node("calendar.previous", in: host), "Previous period missing").press(), "Previous period must support real AX press")
            try await settle(host) { calendar.selectedDate == previousDate }
            try expect(try required(node("calendar.next", in: host), "Next period missing").press(), "Next period must support real AX press")
            try await settle(host) { calendar.selectedDate == oldDate }
        }
        print("PASS: day / three days / week / month expose dates and events; actual previous/next move exactly one selected period")

        try expect(try required(node("calendar.today", in: host), "Today missing").press(), "Today must support real AX press")
        try await settle(host) { clock.isDateInToday(calendar.selectedDate) }
        try expect(signature(calendar.events) == original, "Today navigation must preserve events")
        print("PASS: actual Today control navigates to the local date without modifying events")

        calendar.selectedDate = firstDay; calendar.displayMode = .week
        for source in calendar.calendars { calendar.toggleVisible(source.id) }
        try await settle(host) { node("calendar.hiddenSources", in: host) != nil }
        try expect(calendar.events(on: firstDay).isEmpty && node("calendar.grid", in: host) != nil,
                   "Hidden calendars need an explicit restore affordance and a navigable grid")
        for source in calendar.calendars { calendar.toggleVisible(source.id) }
        try await settle(host) { node("calendar.hiddenSources", in: host) == nil }
        try expect(signature(calendar.events) == original && !calendar.events(on: firstDay).isEmpty, "Hiding and restoring calendars must retain source data")
        calendar.selectedDate = clock.date(byAdding: .month, value: 6, to: firstDay)!
        calendar.displayMode = .day
        try await settle(host) { nodes(host).filter { $0.identifier?.hasPrefix("calendar.day.") == true }.count == 1 }
        try expect(calendar.events(on: calendar.selectedDate).isEmpty && nodes(host).contains { $0.identifier?.hasPrefix("calendar.slot.") == true && $0.isEnabled },
                   "An empty date must still offer enabled creation slots")
        print("PASS: hidden sources have a restore affordance; an empty date remains usable for creating events")
        host.close()

        calendar.selectedDate = firstDay; calendar.displayMode = .day
        let captured = CapturedActions()
        let scheduleHost = NativeHost(AnyView(CalendarScheduleView(calendar: calendar, canCreate: true,
            create: { captured.start = $0 }, open: { captured.opened = $0.id }, showDay: { captured.day = $0 })
            .environment(\.locale, Locale(identifier: "ru_RU"))), width: 820, height: 620)
        defer { scheduleHost.close() }
        let slotID = "calendar.slot.\(clock.component(.weekday, from: firstDay)).17"
        try await settle(scheduleHost) { node(slotID, in: scheduleHost) != nil }
        let slot = try required(node(slotID, in: scheduleHost), "08:30 empty slot missing")
        try expect(slot.isEnabled && slot.frame.intersects(scheduleHost.screenBounds), "Empty creation slot must be visible and enabled")
        try expect(slot.press(), "Empty creation slot must support native AX press")
        let expectedStart = clock.date(bySettingHour: 8, minute: 30, second: 0, of: firstDay)!
        try await settle(scheduleHost) { captured.start == expectedStart }
        try expect(captured.opened == nil && captured.day == nil && signature(calendar.events) == original,
                   "Pressing an empty slot must preserve its time and avoid unrelated open/day or write actions")
        scheduleHost.close()
        print("PASS: actual empty-slot press delivers the exact local 08:30 date without writing or opening an event")

        calendar.selectedDate = firstDay; calendar.displayMode = .month
        let monthActions = CapturedActions()
        let monthHost = NativeHost(AnyView(CalendarScheduleView(calendar: calendar, canCreate: false,
            create: { monthActions.start = $0 }, open: { monthActions.opened = $0.id },
            showDay: { monthActions.day = $0; calendar.selectedDate = $0; calendar.displayMode = .day })
            .environment(\.locale, Locale(identifier: "ru_RU"))), width: 820, height: 620)
        defer { monthHost.close() }
        let monthEventID = "calendar.month.event.\(Int(firstDay.timeIntervalSince1970)).\(firstEvent.id)"
        try await settle(monthHost) { node(monthEventID, in: monthHost) != nil }
        let monthEvent = try required(node(monthEventID, in: monthHost), "Fixture month event missing")
        try expect(monthEvent.isEnabled && monthEvent.frame.intersects(monthHost.screenBounds), "Month event must remain visible and enabled when creation is unavailable")
        try expect(monthEvent.press(), "Actual month event must support native AX press")
        try await settle(monthHost) { monthActions.opened == firstEvent.id }
        try expect(monthActions.day == nil && monthActions.start == nil && calendar.displayMode == .month &&
                   signature(calendar.events) == original, "Opening a month event must dispatch only that event, retain month mode and preserve all source data")
        monthHost.close()
        print("PASS: actual month event press opens exactly that event without also opening its day or changing the view")

        calendar.selectedDate = firstDay; calendar.displayMode = .day
        let readOnlyActions = CapturedActions()
        let readOnlyHost = NativeHost(AnyView(CalendarScheduleView(calendar: calendar, canCreate: false,
            create: { readOnlyActions.start = $0 }, open: { readOnlyActions.opened = $0.id }, showDay: { readOnlyActions.day = $0 })
            .environment(\.locale, Locale(identifier: "ru_RU"))), width: 820, height: 620)
        defer { readOnlyHost.close() }
        try await settle(readOnlyHost) { node(slotID, in: readOnlyHost) != nil }
        let readOnlySlot = try required(node(slotID, in: readOnlyHost), "Read-only empty slot missing")
        try expect(!readOnlySlot.isEnabled, "An empty slot must be disabled when calendar creation is unavailable")
        try expect(readOnlyActions.start == nil && signature(calendar.events) == original,
                   "Rendering unavailable creation controls must not produce drafts or writes")
        readOnlyHost.close()
        print("PASS: unavailable calendar creation disables actual empty-slot controls without invoking them")

        let editor = NativeHost(AnyView(CalendarEventEditor(calendar: calendar, initialStart: expectedStart)
            .environmentObject(app).environment(\.locale, Locale(identifier: "ru_RU"))), width: 560, height: 420)
        defer { editor.close() }
        try await settle(editor) { datePickers(in: editor.view).count >= 2 }
        let pickerDates = datePickers(in: editor.view).map(\.dateValue)
        try expect(pickerDates.contains { abs($0.timeIntervalSince(expectedStart)) < 1 } &&
                   pickerDates.contains { abs($0.timeIntervalSince(expectedStart.addingTimeInterval(1800))) < 1 },
                   "Editor must retain the selected slot and its 30-minute default end, not replace it onAppear")
        try expect(signature(calendar.events) == original && app.meetings.isEmpty && app.notes.notes.isEmpty,
                   "Opening a draft editor must not create calendar events, meetings or notes")
        print("PASS: native editor initialStart survives load with a 30-minute end; Save is never invoked")
        editor.close()
        try await verifyConnectionFlow(app: app, root: root)
        print("11 native calendar workspace checks passed")
    }

    private static func verifyConnectionFlow(app: AppStore, root: URL) async throws {
        app.settings.features.calendar = false
        app.saveSettings()
        try await CalendarConnectionChecks.settle { !app.calendar.featureEnabledForChecks }
        var folder = LibraryFolder(name: "Рабочие встречи")
        folder.overrides.features = FolderFeatureOverrides()
        folder.overrides.features?.calendar = true
        guard let saved = app.notes.saveFolder(folder) else { throw AppError.message(app.notes.error ?? "Cannot create calendar folder") }
        app.folderSelection = saved.id
        try await CalendarConnectionChecks.settle {
            app.visibleFeatures.calendar && app.availableFeatures.calendar && app.calendar.featureEnabledForChecks
        }
        app.librarySection = "calendar"
        try expect(app.folderSelection == saved.id && app.librarySection == "calendar" && !app.settings.features.calendar,
            "A new folder must enable the calendar workflow without changing app defaults or its selected folder")
        print("PASS: a new folder enables the shared calendar lifecycle before its visible connection workflow is used")
        let fixture = CalendarReadFixture()
        let calendar = CalendarStore(root: root, preview: true, readClient: fixture.client)
        let host = NativeHost(AnyView(CalendarWorkspace(calendar: calendar).environmentObject(app)
            .environment(\.locale, Locale(identifier: "ru_RU"))), width: 820, height: 620)
        defer { host.close(); calendar.stop(); fixture.finish() }
        try await settle(host) { node("calendar.connect", in: host) != nil }
        let connect = try required(node("calendar.connect", in: host), "Connect calendar missing")
        try expect(connect.isEnabled && connect.press(), "The actual Connect control must start authorization")
        try await settle(host) { fixture.accessRequests == 1 && calendar.requesting && node("calendar.connect", in: host)?.isEnabled == false }
        try expect(node("calendar.grid", in: host) == nil, "Pending authorization must keep onboarding visible")
        fixture.grant(true, status: .fullAccess)
        try await settle(host) { node("calendar.grid", in: host) != nil && fixture.reads.count == 1 }
        try expect(node("calendar.connect", in: host) == nil && calendar.refreshing,
            "Actual UI must leave onboarding after permission, before the delayed read completes")
        try expect(node("calendar.mode", in: host)?.isEnabled == true && node("calendar.refresh", in: host)?.isEnabled == false,
            "Loading only disables refresh; period navigation remains usable")
        fixture.fail(0)
        try await settle(host) { !calendar.refreshing && calendar.error != nil }
        try expect(node("calendar.noSources", in: host) == nil && node("calendar.refresh", in: host)?.isEnabled == true,
            "An unsuccessful first read cannot claim there are no calendars or send the user to add an account")
        try expect(try required(node("calendar.refresh", in: host), "Retry refresh missing").press(),
            "A failed initial read must be retryable through the actual refresh control")
        try await settle(host) { fixture.reads.count == 2 }
        fixture.complete(1, empty: true)
        try await settle(host) { !calendar.refreshing && node("calendar.noSources", in: host) != nil }
        try expect(calendar.error == nil && node("calendar.add", in: host)?.isEnabled == false,
            "Only a successful empty source read may offer account setup")
        try expect(try required(node("calendar.refresh", in: host), "Refresh after adding an account missing").press(),
            "The verified empty state must allow refreshing after account setup")
        try await settle(host) { fixture.reads.count == 3 }
        fixture.complete(2)
        try await settle(host) { !calendar.refreshing && node("calendar.add", in: host)?.isEnabled == true }
        try expect(node("calendar.noSources", in: host) == nil && calendar.error == nil,
            "A successful retry must replace the empty-state guidance with the real writable schedule")
        print("PASS: failed source reads do not claim missing accounts; real refresh recovers through verified empty and populated states")
        fixture.status = .denied
        calendar.refreshIfNeeded()
        try await settle(host) { node("calendar.permissions", in: host) != nil && node("calendar.grid", in: host) == nil }
        try expect(node("calendar.connect", in: host)?.isEnabled == true && calendar.events.isEmpty,
            "Revoked access must show an actionable retry and clear old event text")
        print("PASS: actual Connect disables repeated requests, opens the schedule while loading and shows retry when permission is revoked")
    }

    @MainActor private final class CapturedActions {
        var start: Date?
        var opened: String?
        var day: Date?
    }
    @MainActor private final class NativeHost {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        init(_ root: AnyView, width: CGFloat, height: CGFloat) {
            view = NSHostingView(rootView: root); view.sizingOptions = []
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = view; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
        var screenBounds: NSRect { window.convertToScreen(view.convert(view.bounds, to: nil)) }
        func close() { window.orderOut(nil) }
    }
    /// SwiftUI virtual nodes expose public AppKit selectors without adopting NSAccessibilityProtocol.
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
    private static func node(_ identifier: String, in host: NativeHost) -> AccessibilityNode? { nodes(host).first { $0.identifier == identifier } }
    private static func settle(_ host: NativeHost, until condition: () -> Bool) async throws {
        for _ in 0..<150 {
            host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded()
            if condition() {
                try await Task.sleep(for: .milliseconds(100)); host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded(); return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        for item in nodes(host) where item.identifier?.hasPrefix("calendar.") == true {
            print("CALENDAR AX: id=\(item.identifier ?? "") text=\(item.text) frame=\(item.frame)")
        }
        throw AppError.message("Native calendar workspace did not settle")
    }
    private static func assertVisible(_ host: NativeHost, identifiers: [String]) throws {
        let bounds = host.screenBounds.insetBy(dx: -1, dy: -1)
        for identifier in identifiers {
            let item = try required(node(identifier, in: host), "Native calendar control missing: " + identifier)
            try expect(!item.frame.isEmpty && bounds.contains(item.frame), "Calendar control is clipped at 820 × 620: \(identifier), \(item.frame), bounds \(bounds)")
        }
    }
    private static func datePickers(in view: NSView) -> [NSDatePicker] {
        (view as? NSDatePicker).map { [$0] } ?? view.subviews.flatMap { datePickers(in: $0) }
    }
    private static func signature(_ events: [CalendarAgendaEvent]) -> [String] {
        events.map { "\($0.id)|\($0.title)|\($0.start.timeIntervalSince1970)|\($0.end.timeIntervalSince1970)|\($0.allDay)|\($0.calendarID)|\($0.taskID ?? "")" }.sorted()
    }
    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw AppError.message(message) }; return value
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AppError.message(message) }
    }
}
#endif
