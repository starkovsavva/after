import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AppKit
import Foundation

/// Exercise the actual Picker across AppKit-backed and virtual SwiftUI controls.
/// Modern menu windows need the same macOS window-service access as the app.
@MainActor
enum NativePickerChecks {
    static func contains(identifier: String, in roots: [NSView]) -> Bool {
        picker(identifier, in: roots) != nil
    }

    static func value(_ identifier: String, in roots: [NSView]) -> String? {
        guard let node = picker(identifier, in: roots) else { return nil }
        if let popup = nativePopup(node) { return popup.titleOfSelectedItem }
        return node.get("accessibilityValue") as? String
    }

    static func select(title: String, identifier: String, in roots: [NSView]) async throws {
        // A newly attached SwiftUI sheet can expose its AX nodes before those
        // controls accept interaction. Resolve the node after presentation.
        try await Task.sleep(for: .milliseconds(250))
        guard let node = picker(identifier, in: roots) else {
            throw AppError.message("Native picker missing: " + identifier)
        }
        if value(identifier, in: roots) == title { return }
        var selectedNatively = false
        if let popup = nativePopup(node), let menu = popup.menu {
            menu.delegate?.menuNeedsUpdate?(menu)
            // SwiftUI Menu pull-downs can keep an empty native shell until the
            // public opening delegate callback materializes their real items.
            if !menu.items.contains(where: { $0.title == title && $0.isEnabled }) { menu.delegate?.menuWillOpen?(menu) }
            menu.update()
            if let index = menu.items.firstIndex(where: { $0.title == title && $0.isEnabled }) {
                popup.selectItem(at: index)
                // Pull-down Menu controls can retain their placeholder as the
                // selected item; invoke the requested option's exact action.
                menu.performActionForItem(at: index)
                selectedNatively = true
            }
        }
        if !selectedNatively {
            if node.press() {
                try await selectVisibleRow(title: title, identifier: identifier)
            } else if let popup = nativePopup(node), popup.isEnabled {
                try await trackNativePopup(popup, title: title, identifier: identifier)
            } else {
                let popup = nativePopup(node)
                let items = popup?.menu?.items.map(\.title).joined(separator: " | ") ?? "none"
                throw AppError.message("Native picker cannot open: \(identifier); node=\(type(of: node.object)); popup=\(String(describing: popup.map { type(of: $0) })); enabled=\(String(describing: popup?.isEnabled)); items=\(items)")
            }
        }
        for _ in 0..<100 {
            roots.forEach { $0.layoutSubtreeIfNeeded() }
            if value(identifier, in: roots) == title { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Native picker did not select: \(identifier) → \(title); actual=\(value(identifier, in: roots) ?? "missing")")
    }

    private static func selectVisibleRow(title: String, identifier: String) async throws {
        // SwiftUI first mounts menu rows, then positions the popup around
        // its selected row. Wait for that opening animation before aiming.
        try await Task.sleep(for: .milliseconds(250))
        var selected = false
        for _ in 0..<100 {
            // macOS can expose menu rows as text fields rather than AXMenuItem
            // objects. Inspect the rendered rows for keyboard navigation.
            let menus = NSApp.windows.filter { $0.isVisible && $0.level == .popUpMenu }
                .sorted { $0.windowNumber > $1.windowNumber }
            let fields = menus.compactMap(\.contentView).flatMap(descendants).compactMap { $0 as? NSTextField }
            let rows = fields.filter { !$0.stringValue.isEmpty && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
                .sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
            if let index = rows.firstIndex(where: { $0.stringValue == title }), let window = rows[index].window {
                window.contentView?.layoutSubtreeIfNeeded()
                // Keyboard navigation avoids coupling menu tracking to the
                // physical pointer, which may be outside this test window.
                let keys: [(String, UInt16)] = [("\u{f729}", 115)]
                    + Array(repeating: ("\u{f701}", 125), count: index) + [("\r", 36)]
                for (characters, code) in keys {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, characters: characters, charactersIgnoringModifiers: characters,
                            isARepeat: false, keyCode: code) else { throw AppError.message("Native picker key event missing") }
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                selected = true; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard selected else { throw AppError.message("Native picker menu option missing: \(identifier) → \(title)") }
    }

    private static func trackNativePopup(_ popup: NSPopUpButton, title: String, identifier: String) async throws {
        let driver = PopupTrackingDriver(popup: popup, title: title)
        let timer = Timer(fireAt: Date().addingTimeInterval(0.3), interval: 0.1,
                          target: driver, selector: #selector(PopupTrackingDriver.tick(_:)), userInfo: nil, repeats: true)
        // performClick may synchronously enter AppKit menu tracking. Its timer
        // must run in that mode rather than waiting for another MainActor task.
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        popup.performClick(nil)
        for _ in 0..<150 {
            if driver.finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard driver.finished && driver.sentSelection && !driver.timedOut else {
            popup.menu?.cancelTracking()
            throw AppError.message("Native picker tracking did not select: \(identifier) → \(title)")
        }
    }

    @MainActor private final class PopupTrackingDriver: NSObject {
        private let popup: NSPopUpButton
        private let title: String
        private let deadline = Date().addingTimeInterval(2)
        private(set) var sentSelection = false
        private(set) var timedOut = false
        private(set) var finished = false
        init(popup: NSPopUpButton, title: String) { self.popup = popup; self.title = title }
        @objc func tick(_ timer: Timer) {
            let menus = NSApp.windows.filter { $0.isVisible && $0.level == .popUpMenu }
            if sentSelection && !popup.isHighlighted && menus.isEmpty {
                finished = true; timer.invalidate(); return
            }
            if Date() >= deadline {
                post("\u{1b}", code: 53)
                popup.menu?.cancelTracking()
                timedOut = true; finished = true; timer.invalidate(); return
            }
            guard !sentSelection else { return }
            let nativeItem = popup.menu?.items.contains { $0.title == title && $0.isEnabled } == true
            let visibleItem = menus.compactMap(\.contentView).flatMap(NativePickerChecks.descendants)
                .compactMap { $0 as? NSTextField }.contains { $0.stringValue == title && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
            guard nativeItem || visibleItem || popup.isHighlighted else { return }
            // Menu type-ahead chooses the exact requested label; all events
            // stay inside this disposable test app's own event queue.
            for character in title { post(String(character), code: 0) }
            post("\r", code: 36)
            sentSelection = true
        }
        private func post(_ characters: String, code: UInt16) {
            guard let window = popup.window else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code) { NSApp.postEvent(event, atStart: false) }
            }
        }
    }

    private static func nativePopup(_ node: Node) -> NSPopUpButton? {
        if let popup = node.object as? NSPopUpButton { return popup }
        return (node.object as? NSCell)?.controlView as? NSPopUpButton
    }
    private static func picker(_ identifier: String, in roots: [NSView]) -> Node? {
        nodes(Array(roots.reversed())).first { $0.get("accessibilityIdentifier") as? String == identifier
            && ($0.get("accessibilityRole") as? String == NSAccessibility.Role.popUpButton.rawValue || nativePopup($0) != nil) }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func nodes(_ roots: [NSView]) -> [Node] {
        var result: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for selector in ["accessibilityChildren", "accessibilityVisibleChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"] {
                for child in node.get(selector) as? [Any] ?? [] { visit(child, depth: depth + 1) }
            }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        roots.forEach { visit($0, depth: 0) }
        return result
    }
    private struct Node {
        let object: NSObject
        func get(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Press.self)(object, selector)
        }
    }
}
#endif
