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
import SwiftUI

@MainActor
enum KnowledgeLinksNativeChecks {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = env["POSLE_DATA_DIR"],
              let library = env["POSLE_RUST_LIBRARY"], FileManager.default.fileExists(atPath: library) else {
            throw AppError.message("Disposable preview and Rust library required")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Disposable root required")
        }
        let store = AppStore(preview: true)
        store.settings.features.knowledgeBase = true
        guard store.saveSettings() else { throw AppError.message("Could not save feature settings") }
        guard let first = store.notes.save(CapturedNote(id: "note-a", text: "Пилотный бюджет и условия договора с закупками", title: "Бюджет пилота")),
              let second = store.notes.save(CapturedNote(id: "note-b", text: "Условия договора, бюджет пилотного проекта и закупки", title: "Условия пилота")) else {
            throw AppError.message("Could not create fixture notes")
        }
        let meeting = Meeting(title:"Встреча о бюджете", source:"fixture.wav", status:"ready")
        let meetingDirectory = store.meetingDirectory(meeting.id)
        try FileManager.default.createDirectory(at:meetingDirectory, withIntermediateDirectories:true)
        try store.write(meeting, meetingDirectory.appendingPathComponent("meta.json"))
        try store.write(Transcript(duration:5, segments:[Segment(id:7, start:0, end:5, speaker:"speaker_1",
            text:"Пилотный бюджет и условия договора")], warnings:[], model:"fixture"), meetingDirectory.appendingPathComponent("transcript.json"))
        store.notes.reload()
        let host = NSHostingView(rootView: KnowledgeLinksSheet(notes: store.notes, source: first).environmentObject(store))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 500, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let mode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(mode)
        NSApp.accessibilitySetValue(true, forAttribute: mode)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; NSApp.accessibilitySetValue(previous, forAttribute: mode) }
        func show() { host.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func links(_ id: String) throws -> [[String: Any]] {
            let data = try RustBridge.shared.get().request(root: root, command: "kb-snapshot", arguments: ["noteID":id])
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let links = result["links"] as? [[String: Any]] else { throw AppError.message("No link snapshot") }
            return links
        }
        let add = "knowledge.links.add.\(second.id)"
        let block = "knowledge.suggestion.block.\(second.id)"
        let accept = "knowledge.suggestion.accept.\(second.id)"
        try await wait { show(); return find(block, in: host) != nil }
        try await click(block, host)
        try await wait { show(); return find(block, in: host) == nil && find("knowledge.links.undo", in: host) != nil }
        try await click("knowledge.links.undo", host)
        try await wait { show(); return find(accept, in: host) != nil }
        try await click(accept, host)
        try await wait { show(); return (try? links(first.id).count) == 1 && find("knowledge.links.undo", in: host) != nil }
        guard try links(second.id).count == 1 else { throw AppError.message("Backlink missing") }
        try await click("knowledge.links.undo", host)
        try await wait { show(); return find(add, in: host) != nil }
        try await click(add, host)
        try await wait { show(); return (try? links(first.id).count) == 1 && find("knowledge.links.undo", in: host) != nil }
        guard try links(second.id).count == 1 else { throw AppError.message("Backlink missing") }
        try await click("knowledge.links.undo", host)
        try await wait { show(); return (try? links(first.id).isEmpty) == true && find(add, in: host) != nil }
        try await click(add, host)
        try await wait { show(); return (try? links(first.id).count) == 1 && find("knowledge.links.undo", in: host) != nil }
        guard let id = try links(first.id).first?["id"] as? String else { throw AppError.message("Link ID missing") }
        let remove = "knowledge.links.remove.\(id)"
        try await wait { show(); return find(remove, in: host) != nil }
        try await click(remove, host)
        try await wait { show(); return (try? links(first.id).isEmpty) == true && find("knowledge.links.undo", in: host) != nil }
        try await click("knowledge.links.undo", host)
        let navigate = "knowledge.links.navigate.\(second.id)"
        try await wait { show(); return (try? links(first.id).count) == 1 && find(navigate, in: host) != nil }
        try await click(navigate, host)
        guard store.notes.selectedNoteID == second.id else { throw AppError.message("Linked note did not open") }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: root.appendingPathComponent("knowledge-links.png"))
            }
        }
        let meetingHost = NSHostingView(rootView: KnowledgeMeetingSourcesView(source:first).environmentObject(store))
        meetingHost.sizingOptions = []; meetingHost.frame = NSRect(x:0,y:0,width:500,height:350)
        window.contentView = meetingHost
        let meetingLink = "knowledge.meeting.open.\(meeting.id)"
        try await wait { meetingHost.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(meetingLink, in:meetingHost) != nil }
        func meetingLinks() throws -> [[String:Any]] {
            let data=try RustBridge.shared.get().request(root:root,command:"kb-meeting-links",arguments:["noteID":first.id,"noteRevision":first.revision])
            guard let result=try JSONSerialization.jsonObject(with:data) as? [String:Any], let items=result["items"] as? [[String:Any]] else {
                throw AppError.message("Missing meeting link snapshot")
            }
            return items
        }
        let saveMeeting = "knowledge.meeting.link.\(meeting.id)"
        try await click(saveMeeting, meetingHost)
        try await wait { (try? meetingLinks().count)==1 }
        guard let savedID=try meetingLinks().first?["id"] as? String else {throw AppError.message("Meeting link missing")}
        let unlink="knowledge.meeting.unlink.\(savedID)"
        try await wait { meetingHost.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(unlink,in:meetingHost) != nil }
        try await click(unlink,meetingHost)
        try await wait { (try? meetingLinks().isEmpty)==true }
        try await wait { meetingHost.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find("knowledge.meeting.undo",in:meetingHost) != nil }
        try await click("knowledge.meeting.undo",meetingHost)
        try await wait { (try? meetingLinks().count)==1 }
        try await wait { meetingHost.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(unlink,in:meetingHost) != nil }
        try await click(unlink,meetingHost)
        try await wait { (try? meetingLinks().isEmpty)==true }
        try await wait { meetingHost.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(saveMeeting,in:meetingHost) != nil }
        try await click(saveMeeting,meetingHost)
        try await wait { (try? meetingLinks().count)==1 }
        try await click(meetingLink, meetingHost)
        try await wait { store.selection == meeting.id && store.tab == "transcript" && store.navigationTarget?.segmentID == 7 }
        print("PASS: manual note links, backlinks, saved meeting links, undo, removal and exact navigation")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Knowledge links UI timed out")
    }
    private static func find(_ id: String, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func attribute(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func visit(_ object: NSObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if attribute(object,"accessibilityIdentifier") as? String == id { return object }
            let children = (attribute(object,"accessibilityChildren") as? [NSObject] ?? []) +
                ((object as? NSView)?.subviews.map { $0 as NSObject } ?? [])
            for child in children { if let found = visit(child) { return found } }
            return nil
        }
        return visit(root)
    }
    private static func click(_ id: String, _ root: NSView) async throws {
        for _ in 0..<1500 {
            if let object = find(id, in: root), press(object) { return }
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("UI control unavailable: \(id)")
    }
    private static func press(_ object: NSObject) -> Bool {
        if let button = object as? NSButton, button.isEnabled { button.performClick(nil); return true }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector), let method = object.method(for: selector) else {
            return false
        }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Press.self)(object, selector)
    }
}
#endif
