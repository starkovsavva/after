#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

/// Uses the real controller and popover with synthetic executors and a disposable
/// queue. Never starts models, accesses accounts or requests remote inference.
@MainActor
enum BackgroundJobsUINativeChecks {
    static func run(root: URL) async throws {
        let controller = BackgroundJobsController(root: root, activityChanged: { _ in })
        controller.connect { job, _, _ in
            if job.config.settings.cloudModel == "gpt-4.1-mini" {
                throw AppError.message("Модель недоступна. Выберите другую модель и повторите.")
            }
            return WorkerEvent(event: "done")
        }
        var settings = AppSettings(); settings.mode = "cloud"; settings.cloudProvider = "custom"; settings.cloudModel = "gpt-4.1-mini"
        var config = JobConfiguration(command: "summarize", meetingID: "english-lesson", extra: [], input: nil, settings: settings)
        do { _ = try await controller.submit(config, resource: "cloud", revision: "v1", title: "Конспект · Английский: первый урок", paid: false) } catch {}
        settings.cloudModel = "gpt-6-luna"; config.settings = settings
        _ = try await controller.submit(config, resource: "cloud", revision: "v2", title: "Конспект · Английский: первый урок", paid: false)
        config.meetingID = "delivery"; config.settings.cloudModel = "gpt-4.1-mini"
        do { _ = try await controller.submit(config, resource: "cloud", revision: "v1", title: "Конспект · Согласование поставки", paid: false) } catch {}
        for _ in 0..<100 {
            if controller.jobs.count == 3 && controller.activeCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard controller.jobs.count == 3, let historical = controller.jobs.first(where: { $0.objectID == "english-lesson" && $0.state == "failed" }),
              let unresolved = controller.jobs.first(where: { $0.objectID == "delivery" }) else { throw AppError.message("Native history fixture did not finish") }
        let screenshots = root.appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        let accessibilityMode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(accessibilityMode)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityMode)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: accessibilityMode) }
        for appearance in [ColorScheme.light, .dark] {
            let view = BackgroundJobsView(jobs: controller).frame(width: 410, height: 470, alignment: .topLeading)
                .background(Ink.paper).environment(\.colorScheme, appearance)
            let host = NSHostingView(rootView: view); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            for _ in 0..<12 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
            let ids = identifiers(host)
            guard !ids.contains("jobs.retry." + historical.id), ids.contains("jobs.retry." + unresolved.id) else {
                throw AppError.message("Native history must show Retry only for the unresolved latest generation: \(ids)")
            }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("History UI bitmap unavailable") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("History UI PNG unavailable") }
            try png.write(to: screenshots.appendingPathComponent(appearance == .dark ? "jobs-dark.png" : "jobs-light.png"))
        }
        await controller.shutdown()
        print("PASS: actual jobs popover preserves old model history and exposes Retry only for the current unresolved operation in light/dark")
        print("Job history screenshots: \(screenshots.path)")
    }
    private static func identifiers(_ root: NSView) -> Set<String> {
        var values = Set<String>(), seen = Set<ObjectIdentifier>()
        func read(_ object: NSObject, _ selectorName: String) -> Any? {
            let selector = NSSelectorFromString(selectorName)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let identifier = read(object, "accessibilityIdentifier") as? String { values.insert(identifier) }
            for child in read(object, "accessibilityChildren") as? [NSObject] ?? [] { visit(child) }
            if let view = object as? NSView { for child in view.subviews { visit(child) } }
        }
        visit(root); return values
    }
}
#endif
