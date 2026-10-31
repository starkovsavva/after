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

/// Benchmarks the real button/popover with explicitly generated transcripts.
/// No existing meeting, recording, account or clipboard content is accessed.
@MainActor
enum SourcePopoverNativeChecks {
    private struct Fixture {
        let meeting: Meeting
        let segmentCount: Int
        let bytes: Int
        let ids: [Int]
    }
    private struct Measurement: Codable {
        let segments: Int
        let transcriptBytes: Int
        let selectedMeeting: Bool
        let attempt: Int
        let pressReturnMilliseconds: Double
        let shellMilliseconds: Double?
        let contentReadyMilliseconds: Double?
        let firstQuoteMilliseconds: Double?
        let fullScrollMilliseconds: Double?
        let heartbeatMaximumStallMilliseconds: Double
        let heartbeatTicks: Int
        let displayedCitationCount: Int
        let displayedMeetingTitle: Bool
        let scrollSteps: Int
        let reachedBottom: Bool
        let failure: String?
    }
    private struct Report: Encodable {
        let schemaVersion = 2
        let expectedCitations = 5
        let sourceTextCharacters = 1000
        let contentReadyMeaning = "All five full citations verified across native scrolling; this includes the scroll phase."
        let firstQuoteMeaning = "First complete citation and source title exposed before scrolling."
        let heartbeatMeaning = "Opening through first quote plus one settling turn; excludes scrolling and its AX probes."
        let measurements: [Measurement]
    }

    static func run(root: URL) async throws {
        let owned = root.standardizedFileURL.resolvingSymlinksInPath()
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              ["/private/tmp", "/tmp"].contains(owned.deletingLastPathComponent().path),
              owned.lastPathComponent.hasPrefix("posle-native-check-"),
              let configured = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"],
              URL(fileURLWithPath: configured).resolvingSymlinksInPath() == owned else {
            throw AppError.message("Source popover checks require the explicitly configured disposable preview root")
        }
        let fixtures = try [32, 10_000, 20_000].map { try fixture(root: owned, count: $0) }
        let otherMeeting = try fixture(root: owned, count: 8).meeting
        let store = AppStore(preview: true)
        store.reloadLibrary()
        let mode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(mode)
        NSApp.accessibilitySetValue(true, forAttribute: mode)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: mode) }
        var measurements: [Measurement] = []
        let metrics = owned.appendingPathComponent("source-popover-metrics.json")
        for fixture in fixtures {
            for selected in [true, false] {
                // Selected citations use the normal meeting button. The global
                // card-style button points at a different meeting explicitly.
                store.selection = selected ? fixture.meeting.id : otherMeeting.id
                store.loadSelection()
                let host = Host(button: EvidenceButton(ids: fixture.ids,
                    meetingID: selected ? nil : fixture.meeting.id).environmentObject(store))
                defer { host.close() }
                try await wait { openButton(in: host) != nil }
                for attempt in 1...2 {
                    let result = try await measure(host: host, fixture: fixture, selected: selected, attempt: attempt)
                    measurements.append(result)
                    try write(measurements, to: metrics)
                    print(String(format: "SOURCE POPOVER: segments=%d bytes=%d selected=%@ attempt=%d press=%.2fms shell=%@ ready=%@ maxStall=%.2fms citations=%d title=%@ firstQuote=%@ fullScroll=%@ scrollSteps=%d bottom=%@",
                        result.segments, result.transcriptBytes, String(result.selectedMeeting), result.attempt,
                        result.pressReturnMilliseconds, display(result.shellMilliseconds), display(result.contentReadyMilliseconds),
                        result.heartbeatMaximumStallMilliseconds, result.displayedCitationCount, String(result.displayedMeetingTitle),
                        display(result.firstQuoteMilliseconds), display(result.fullScrollMilliseconds), result.scrollSteps, String(result.reachedBottom)))
                }
                host.close()
            }
        }
        // Functional completeness is required; timing is emitted independently
        // so the identical harness can measure the unfixed and fixed builds.
        guard measurements.allSatisfy({ $0.failure == nil }) else {
            throw AppError.message("Source popover did not expose complete generated citations; inspect source-popover-metrics.json")
        }
        print("PASS: real source popover opens/closes twice for selected/global citations across 32/10k/20k segments; timing and heartbeat metrics saved")
    }

    private static func measure(host: Host, fixture: Fixture, selected: Bool, attempt: Int) async throws -> Measurement {
        let heartbeat = Heartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }
        try await Task.sleep(for: .milliseconds(30))
        heartbeat.reset()
        let button = try required(openButton(in: host), "Actual EvidenceButton missing")
        let tap = ProcessInfo.processInfo.systemUptime
        guard button.press() else { throw AppError.message("Actual EvidenceButton rejected native AX press") }
        let returned = ProcessInfo.processInfo.systemUptime
        var shell: Double?
        var ready: Double?
        var firstQuote: Double?
        var fullScroll: Double?
        var seen = Set<Int>()
        var title = false
        var scrollSteps = 0
        var reachedBottom = false
        var failure: String?
        let deadline = returned + 15
        while ProcessInfo.processInfo.systemUptime < deadline {
            host.view.layoutSubtreeIfNeeded()
            let values = popoverNodes(excluding: host).flatMap(\.text)
            let time = ProcessInfo.processInfo.systemUptime
            if shell == nil, closeButton(excluding: host) != nil { shell = (time - tap) * 1000 }
            seen.formUnion(citations(in: values, fixture: fixture))
            title = values.contains { $0.contains(fixture.meeting.title) }
            if shell != nil, let first = fixture.ids.first, seen.contains(first), title {
                firstQuote = (time - tap) * 1000; break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Let a heartbeat already delayed by the synchronous action/first
        // layout run before collecting its maximum stall.
        try await Task.sleep(for: .milliseconds(40))
        heartbeat.stop()
        if firstQuote != nil {
            let scrollStart = ProcessInfo.processInfo.systemUptime
            do {
                let result = try await verifyByScrolling(host: host, fixture: fixture, seen: seen)
                seen = result.seen; scrollSteps = result.steps; reachedBottom = true
                ready = (ProcessInfo.processInfo.systemUptime - tap) * 1000
            } catch { failure = error.localizedDescription }
            fullScroll = (ProcessInfo.processInfo.systemUptime - scrollStart) * 1000
        } else { failure = "The first complete citation and source title did not become accessible within 15 seconds" }
        guard let close = closeButton(excluding: host), close.press() else {
            throw AppError.message("Actual source-popover Close control missing")
        }
        try await wait { closeButton(excluding: host) == nil }
        try await Task.sleep(for: .milliseconds(100))
        return Measurement(segments: fixture.segmentCount, transcriptBytes: fixture.bytes,
            selectedMeeting: selected, attempt: attempt, pressReturnMilliseconds: (returned - tap) * 1000,
            shellMilliseconds: shell, contentReadyMilliseconds: ready,
            firstQuoteMilliseconds: firstQuote, fullScrollMilliseconds: fullScroll,
            heartbeatMaximumStallMilliseconds: heartbeat.maximumStall * 1000, heartbeatTicks: heartbeat.ticks,
            displayedCitationCount: seen.count, displayedMeetingTitle: title, scrollSteps: scrollSteps,
            reachedBottom: reachedBottom, failure: failure)
    }

    private static func citations(in values: [String], fixture: Fixture) -> Set<Int> {
        Set(fixture.ids.filter { id in
            values.contains { $0.contains(marker(id, end: false)) } &&
            values.contains { $0.contains(marker(id, end: true)) }
        })
    }

    private static func verifyByScrolling(host: Host, fixture: Fixture, seen initial: Set<Int>) async throws -> (seen: Set<Int>, steps: Int) {
        var seen = initial
        var steps = 0
        var stableBottom = 0
        for _ in 0..<250 {
            let roots = popoverRoots(excluding: host)
            seen.formUnion(citations(in: nodes(roots).flatMap(\.text), fixture: fixture))
            let candidates = roots.flatMap(scrollViews).filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 300 && $0.bounds.height > 100 }
            guard let scroll = candidates
                .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
                  let document = scroll.documentView else {
                throw AppError.message("Native source quote scroll view missing")
            }
            scroll.layoutSubtreeIfNeeded()
            let clip = scroll.contentView
            let bottom = document.isFlipped
                ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height) : document.bounds.minY
            let difference = bottom - clip.bounds.origin.y
            if abs(difference) <= 1 {
                stableBottom += 1
                if stableBottom >= 2, seen.count == fixture.ids.count {
                    // The long quotes must require actual viewport movement,
                    // even if a non-lazy baseline exposes their AX text early.
                    guard steps > 0 else { throw AppError.message("Source quote fixture did not actually scroll") }
                    return (seen, steps)
                }
            } else {
                stableBottom = 0
                let step = min(abs(difference), max(40, clip.bounds.height * 0.6))
                let point = NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + (difference > 0 ? step : -step))
                // Public native scrolling changes the real viewport and lets
                // LazyVStack mount each quote; no SwiftUI state is assigned.
                clip.scroll(to: point)
                scroll.reflectScrolledClipView(clip)
                steps += 1
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw AppError.message("Native scrolling did not expose all five full source quotes at the bottom (seen \(seen.count))")
    }

    private static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private static func fixture(root: URL, count: Int) throws -> Fixture {
        var meeting = Meeting(title: "Synthetic source popover — \(count) segments", source: "synthetic-no-recording.wav", status: "ready")
        meeting.id = String(format: "00000000-0000-4000-8000-%012d", count)
        meeting.createdAt = 1_800_000_000; meeting.duration = Double(count)
        meeting.speakerNames = ["speaker_1": "Synthetic speaker"]
        let directory = root.appendingPathComponent("meetings/\(meeting.id)")
        if FileManager.default.fileExists(atPath: directory.path) {
            let meta = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
            guard let existing = try? JSONDecoder().decode(Meeting.self, from: meta), existing.title == meeting.title else {
                throw AppError.message("Refusing to replace a non-popover fixture meeting")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sentence = "Synthetic source evidence keeps every quoted word available for verification. "
        let padding = String(repeating: sentence, count: 20)
        let segments = (0..<count).map { index -> Segment in
            let prefix = marker(index, end: false) + " "
            let suffix = " " + marker(index, end: true)
            let text = prefix + String(padding.prefix(1000 - prefix.count - suffix.count)) + suffix
            return Segment(id: index, start: Double(index), end: Double(index + 1), speaker: "speaker_1", text: text)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Transcript(duration: Double(count), segments: segments, warnings: [], model: "synthetic-popover"))
        guard data.count > count * 1000, data.count < count * 1400 else { throw AppError.message("Generated transcript size is outside the intended full-length bounds") }
        let transcript = directory.appendingPathComponent("transcript.json")
        try data.write(to: transcript, options: .atomic)
        let meta = directory.appendingPathComponent("meta.json")
        try encoder.encode(meeting).write(to: meta, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: meta.path)
        return Fixture(meeting: meeting, segmentCount: count, bytes: data.count,
                       ids: [0, count / 4, count / 2, count * 3 / 4, count - 1])
    }
    private static func marker(_ id: Int, end: Bool) -> String { "POSLE-QUOTE-\(id)-" + (end ? "END" : "BEGIN") }
    private static func write(_ measurements: [Measurement], to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Report(measurements: measurements)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func display(_ value: Double?) -> String { value.map { String(format: "%.2fms", $0) } ?? "not-ready" }

    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?
        private var last = ProcessInfo.processInfo.systemUptime
        private(set) var maximumStall = 0.0
        private(set) var ticks = 0
        func start() {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                    self?.tick()
                }
            }
        }
        func reset() { maximumStall = 0; ticks = 0; last = ProcessInfo.processInfo.systemUptime }
        func stop() { if task != nil { tick(); task?.cancel(); task = nil } }
        private func tick() {
            let now = ProcessInfo.processInfo.systemUptime
            maximumStall = max(maximumStall, max(0, now - last - 0.005)); last = now; ticks += 1
        }
    }
    @MainActor private final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        init<Button: View>(button: Button) {
            view = NSHostingView(rootView: AnyView(VStack(alignment: .leading) {
                button.accessibilityIdentifier("source-popover.fixture.open")
                Spacer()
            }.padding(32).frame(width: 740, height: 520, alignment: .topLeading)))
            view.sizingOptions = []; view.frame = NSRect(x: 0, y: 0, width: 740, height: 520)
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.center()
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
        func close() { window.orderOut(nil); window.contentView = nil }
    }
    private static func openButton(in host: Host) -> Node? {
        let candidates = nodes([host.view]).filter { $0.identifier == "source-popover.fixture.open" }
        return candidates.first { $0.role == NSAccessibility.Role.button.rawValue } ?? candidates.first
    }
    private static func closeButton(excluding host: Host) -> Node? {
        popoverNodes(excluding: host).first { $0.role == NSAccessibility.Role.button.rawValue && $0.text.contains(L("Закрыть источники")) }
    }
    private static func popoverNodes(excluding host: Host) -> [Node] {
        nodes(popoverRoots(excluding: host))
    }
    private static func popoverRoots(excluding host: Host) -> [NSView] {
        NSApp.windows.filter { $0 !== host.window && $0.isVisible }.compactMap(\.contentView)
    }
    @MainActor private struct Node {
        let object: NSObject
        private func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        var identifier: String? { attribute("accessibilityIdentifier") as? String }
        var role: String? { attribute("accessibilityRole") as? String }
        var text: [String] { [attribute("accessibilityValue"), attribute("accessibilityLabel"), attribute("accessibilityTitle")].compactMap { $0 as? String } }
        var children: [Any] {
            ["accessibilityChildren", "accessibilityVisibleChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { attribute($0) as? [Any] ?? [] }
        }
        func press() -> Bool {
            if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton, button.isEnabled { button.performClick(nil); return true }
            if let button = object as? NSButton, button.isEnabled { button.performClick(nil); return true }
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
        roots.forEach { visit($0, depth: 0) }
        return result
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Source popover native control timed out")
    }
    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw AppError.message(message) }; return value
    }
}
#endif
