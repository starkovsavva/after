import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
import AfterLocalization
#if DEBUG
import AppKit
import Foundation
import AfterCore
import SwiftUI

/// A tiny generated meeting exercises the real claim button and native popover.
/// The hosted button deliberately retains its original Summary value, so a
/// reopened obsolete claim must be rejected by the fresh worker snapshot.
@MainActor
enum ClaimSourcesNativeChecks {
    private static let quote = "CLAIM-NATIVE-QUOTE-A"
    private static let otherQuote = "CLAIM-NATIVE-QUOTE-B"
    private static let originalSpeaker = "CLAIM-NATIVE-SPEAKER-BEFORE"
    private static let renamedSpeaker = "CLAIM-NATIVE-SPEAKER-AFTER"

    static func run(root: URL) async throws {
        let owned = root.resolvingSymlinksInPath()
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let configured = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"],
              URL(fileURLWithPath: configured).resolvingSymlinksInPath() == owned,
              ["/private/tmp", "/tmp"].contains(owned.deletingLastPathComponent().path),
              owned.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Claim source checks require the configured disposable preview root")
        }
        let store = AppStore(preview: true)
        var meeting = Meeting(title: "Generated claim source fixture", source: "no-recording.wav", status: "ready")
        meeting.duration = 6; meeting.speakerNames = ["speaker_1": originalSpeaker]
        let directory = store.meetingDirectory(meeting.id)
        let summaryURL = directory.appendingPathComponent("summary.json")
        let transcript = Transcript(duration: 6, segments: [
            Segment(id: 7, start: 1, end: 2, speaker: "speaker_1", text: quote),
            Segment(id: 19, start: 3, end: 4, speaker: "speaker_1", text: otherQuote),
            Segment(id: 31, start: 5, end: 6, speaker: "speaker_1", text: "Uncited generated quote")
        ], warnings: [], model: "claim-source-fixture")
        let summary = try JSONDecoder().decode(Summary.self, from: Data(#"{"overview":"Claim A. Claim B.","items":[{"kind":"fact","text":"CLAIM-NATIVE-FACT-A","owner":"","due":"","segmentIDs":[7]},{"kind":"fact","text":"CLAIM-NATIVE-FACT-B","owner":"","due":"","segmentIDs":[19]}],"cards":[],"provider":"synthetic","model":"claim-source-fixture","generatedAt":42,"warnings":[],"overviewClaims":[{"text":"Claim A.","itemIndices":[0]},{"text":"Claim B.","itemIndices":[1]}]}"#.utf8))
        try store.write(meeting, directory.appendingPathComponent("meta.json"))
        try store.write(transcript, directory.appendingPathComponent("transcript.json"))
        try store.write(summary, summaryURL)
        store.reloadLibrary(); store.selection = meeting.id; store.loadSelection(); store.tab = "summary"
        let mode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(mode)
        NSApp.accessibilitySetValue(true, forAttribute: mode)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: mode) }
        let host = Host(button: ClaimReferenceButton(claim: summary.overviewClaims[0], number: 1,
            summary: summary).environmentObject(store))
        defer { host.close() }

        try await open(host)
        try await verified(host, speaker: originalSpeaker)
        try expect(!hasText(host, otherQuote) && store.selection == meeting.id && store.tab == "summary" && !store.isPlaying,
            "Claim sources navigated, played audio, or displayed another claim's quote")
        // Claim A displays only segment 7, but validation must also request
        // segment 19 supporting Claim B. Otherwise full provenance rejects A.
        print("PASS: native claim sources verify the union of distinct claims and display only the chosen quote")

        var stale = summary; stale.sourceStale = true
        try store.write(stale, summaryURL); store.summary = stale
        try await wait(host) { closeButton(host) == nil }
        try await Task.sleep(for: .milliseconds(150))
        try expect(stale.generatedAt == summary.generatedAt && stale.overview == summary.overview && stale.items == summary.items,
            "Stale-flag fixture accidentally changed its overview identity")
        try await open(host)
        try await rejected(host)
        try await close(host)
        print("PASS: a sourceStale-only change closes the claim popover and fresh validation rejects reopening its old input")

        try store.write(summary, summaryURL); store.summary = summary
        var remapped = summary; remapped.overviewClaims[0].itemIndices = [1]
        try store.write(remapped, summaryURL); store.summary = remapped
        try await open(host)
        try await rejected(host)
        try await close(host)
        print("PASS: a claim-mapping-only change cannot reuse unchanged generation/prose/items to display stale sources")

        try store.write(summary, summaryURL); store.summary = summary
        try await open(host)
        try await verified(host, speaker: originalSpeaker)
        store.renameSpeaker("speaker_1", name: renamedSpeaker)
        try await verified(host, speaker: renamedSpeaker)
        try expect(closeButton(host) != nil && !hasWarning(host) && store.summary?.sourceStale == false
            && store.summary?.overviewClaims == summary.overviewClaims,
            "Renaming a speaker invalidated unchanged claim provenance or retained an unavailable-source warning")
        try await close(host)
        print("PASS: native source labels refresh after speaker metadata rename without rejecting unchanged quotes")
        print("4 native claim source checks passed")
    }

    private static func open(_ host: Host) async throws {
        try await wait(host) { openButton(host) != nil }
        guard let button = openButton(host), button.press() else { throw AppError.message("Native claim button rejected AX press") }
        try await wait(host) { closeButton(host) != nil }
    }
    private static func close(_ host: Host) async throws {
        guard let button = closeButton(host), button.press() else { throw AppError.message("Native claim popover Close missing") }
        try await wait(host) { closeButton(host) == nil }
        // Let the presentation finish its native dismissal before reusing the
        // actual button; the next click must open, rather than toggle a remnant.
        try await Task.sleep(for: .milliseconds(100))
    }
    private static func rejected(_ host: Host) async throws {
        try await wait(host) { hasWarning(host) }
        try expect(!hasText(host, quote) && !hasText(host, otherQuote),
            "A rejected obsolete claim still exposed source quote text")
    }
    private static func verified(_ host: Host, speaker: String) async throws {
        try await wait(host) { hasText(host, quote) && hasText(host, speaker) }
        // A cached first frame must not count as success if a late dismissal
        // callback cancels the new async request immediately after reopening.
        try await Task.sleep(for: .milliseconds(150))
        try expect(closeButton(host) != nil && hasText(host, quote) && hasText(host, speaker) && !hasWarning(host),
            "Native claim source content disappeared after its first accessible frame")
    }
    private static func hasWarning(_ host: Host) -> Bool {
        let values = texts(host)
        return [L("Источник недоступен. Обновите конспект."), L("Источник изменился. Откройте актуальный конспект."),
                L("Конспект изменился. Откройте актуальную версию.")].contains { warning in
            values.contains { $0.contains(warning) }
        }
    }
    private static func texts(_ host: Host) -> Set<String> { Set(popoverNodes(host).flatMap(\.text)) }
    private static func hasText(_ host: Host, _ text: String) -> Bool { texts(host).contains { $0.contains(text) } }
    private static func openButton(_ host: Host) -> Node? {
        let candidates = nodes([host.view]).filter { $0.identifier == "claim-sources.fixture.open" }
        return candidates.first { $0.role == NSAccessibility.Role.button.rawValue } ?? candidates.first
    }
    private static func closeButton(_ host: Host) -> Node? {
        popoverNodes(host).first { $0.role == NSAccessibility.Role.button.rawValue && $0.text.contains(L("Закрыть факты")) }
    }
    private static func popoverNodes(_ host: Host) -> [Node] {
        nodes(NSApp.windows.filter {
            $0 !== host.window && $0.isVisible && !host.existingWindows.contains(ObjectIdentifier($0))
        }.compactMap(\.contentView))
    }
    private static func wait(_ host: Host, _ ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !ready() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw AppError.message("Native claim source control timed out; visible text: \(texts(host).sorted())")
            }
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppError.message(message) }
    }

    @MainActor private final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        let existingWindows: Set<ObjectIdentifier>
        init<Button: View>(button: Button) {
            existingWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            view = NSHostingView(rootView: AnyView(VStack(alignment: .leading) {
                button.accessibilityIdentifier("claim-sources.fixture.open")
                Spacer()
            }.padding(32).frame(width: 680, height: 520, alignment: .topLeading)))
            view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: 680, height: 520)
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.center()
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
        func close() {
            window.orderOut(nil); window.contentView = nil
        }
    }
    @MainActor private struct Node {
        let object: NSObject
        private func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        var identifier: String? { attribute("accessibilityIdentifier") as? String }
        var role: String? { attribute("accessibilityRole") as? String }
        var text: [String] {
            [attribute("accessibilityValue"), attribute("accessibilityLabel"), attribute("accessibilityTitle")].compactMap { $0 as? String }
        }
        var children: [Any] {
            ["accessibilityChildren", "accessibilityVisibleChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { attribute($0) as? [Any] ?? [] }
        }
        func press() -> Bool {
            if let button = object as? NSButton, button.isEnabled { button.performClick(nil); return true }
            if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton,
               button.isEnabled { button.performClick(nil); return true }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Press.self)(object, selector)
        }
    }
    private static func nodes(_ roots: [NSView]) -> [Node] {
        var result: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.children { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        roots.forEach { visit($0, depth: 0) }; return result
    }
}
#endif
