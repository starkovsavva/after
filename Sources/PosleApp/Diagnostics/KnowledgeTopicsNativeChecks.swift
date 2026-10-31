#if DEBUG
import AppKit
import Darwin
import Foundation
import PosleCore
import SwiftUI

@MainActor
enum KnowledgeTopicsNativeChecks {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = env["POSLE_DATA_DIR"],
              let library = env["POSLE_RUST_LIBRARY"], FileManager.default.fileExists(atPath: library) else {
            throw AppError.message("Disposable preview and Rust library required")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("posle-native-check-") else { throw AppError.message("Disposable root required") }
        let store = AppStore(preview: true)
        store.settings.features.knowledgeBase = true
        guard store.saveSettings() else { throw AppError.message("Could not save feature settings") }
        for name in ["a","b","c","d"] {
            guard store.notes.save(CapturedNote(id:"topic-\(name)",
                text:"Пилотный бюджет, условия договора и закупки", title:"Пилот \(name)")) != nil else {
                throw AppError.message("Could not create fixture notes")
            }
        }
        guard store.notes.save(CapturedNote(id:"orphan-note",text:"Маяк у моря",title:"Одинокая запись")) != nil else {
            throw AppError.message("Could not create ungrouped fixture note")
        }
        store.notes.reload(); store.librarySection = "knowledge"
        let host = NSHostingView(rootView: KnowledgeBaseView().environmentObject(store))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let mode = NSAccessibility.Attribute(rawValue:"AXEnhancedUserInterface")
        let prior = NSApp.accessibilityAttributeValue(mode)
        NSApp.accessibilitySetValue(true, forAttribute: mode)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; NSApp.accessibilitySetValue(prior, forAttribute: mode) }
        let id = "knowledge.topic.note.topic-a"
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(id, in: host) != nil }
        guard let settings = find("knowledge.topics.semantic-settings", in: host), press(settings),
              store.showingSettings,
              store.settingsSection == (store.isFeatureEnabled(.semanticSearch) ? "semantic" : "features") else {
            throw AppError.message("Semantic setup did not open the appropriate settings")
        }
        store.showingSettings = false
        store.isRecording = true
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find("knowledge.topics.paused", in: host) != nil }
        store.isRecording = false
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(id, in: host) != nil }
        let bridge=try RustBridge.shared.get()
        func dictionary(_ data: Data) throws -> [String:Any] {
            guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
                throw AppError.message("Expected object")
            }
            return object
        }
        let snapshot=try dictionary(bridge.request(root:root, command:"kb-snapshot"))
        let topicData=try dictionary(bridge.request(root:root, command:"kb-topics",arguments:[
            "expectedWorkspaceRevision":snapshot["workspaceRevision"]!,"expectedKBRevision":snapshot["kbRevision"]!]))
        guard let rows=topicData["topics"] as? [[String:Any]], let topicID=rows.first?["id"] as? String else {
            throw AppError.message("Missing suggested topic")
        }
        let saveID="knowledge.topic.save.\(topicID)"
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(saveID,in:host) != nil }
        guard let save=find(saveID,in:host),press(save) else {throw AppError.message("Cannot save a topic")}
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find("knowledge.collections.heading",in:host) != nil }
        guard find("knowledge.collection.note.topic-a",in:host) != nil else {throw AppError.message("Saved collection did not show its note")}
        let after=try dictionary(bridge.request(root:root,command:"kb-snapshot"))
        let collected=try dictionary(bridge.request(root:root,command:"kb-topics",arguments:[
            "expectedWorkspaceRevision":after["workspaceRevision"]!,"expectedKBRevision":after["kbRevision"]!]))
        guard let collections=collected["collections"] as? [[String:Any]],let collectionID=collections.first?["id"] as? String else {
            throw AppError.message("Missing saved collection")
        }
        let addID="knowledge.collection.add.\(collectionID)"
        guard let add=find(addID,in:host),press(add) else {throw AppError.message("Cannot add notes to collection")}
        try await wait {
            window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
            guard let root=window.attachedSheet?.contentView else {return false}
            return find("knowledge.collection.pick.orphan-note",in:root) != nil
        }
        guard let sheet=window.attachedSheet?.contentView,
              let choice=find("knowledge.collection.pick.orphan-note",in:sheet),press(choice) else {
            throw AppError.message("Cannot select the note")
        }
        try await Task.sleep(for:.milliseconds(150))
        sheet.layoutSubtreeIfNeeded(); window.attachedSheet?.displayIfNeeded()
        guard let confirm=find("knowledge.collection.pick.confirm",in:sheet),press(confirm) else {
            throw AppError.message("Cannot select and add the note")
        }
        try await wait {host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find("knowledge.collection.note.orphan-note",in:host) != nil}
        let removeID="knowledge.collection.remove.\(collectionID).orphan-note"
        guard let remove=find(removeID,in:host),press(remove) else {throw AppError.message("Cannot remove note from collection")}
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return find("knowledge.collections.heading",in:host) != nil && find("knowledge.collection.note.orphan-note",in:host) == nil
        }
        try edit(window,placeholder:L("Поиск по заметкам и темам"),text:"маяк")
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find("knowledge.search.note.orphan-note",in:host) != nil }
        guard let orphan=find("knowledge.search.note.orphan-note",in:host),press(orphan),store.notes.selectedNoteID=="orphan-note" else {
            throw AppError.message("Search did not open the ungrouped note")
        }
        try edit(window,placeholder:L("Поиск по заметкам и темам"),text:"")
        try await wait { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return find(id,in:host) != nil }
        guard let control = find(id, in: host), press(control) else { throw AppError.message("Topic source cannot be opened") }
        guard store.librarySection == "inbox", store.notes.selectedNoteID == "topic-a" else {
            throw AppError.message("Topic did not open its exact note")
        }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: root.appendingPathComponent("knowledge-topics.png"))
            }
        }
        let meetingDirectory=root.appendingPathComponent("meetings/topic-meeting")
        try FileManager.default.createDirectory(at:meetingDirectory,withIntermediateDirectories:true)
        var topicMeeting=Meeting(title:"Пилот встречи",source:"audio.mp3",status:"ready")
        topicMeeting.id="topic-meeting"
        try store.write(topicMeeting,meetingDirectory.appendingPathComponent("meta.json"))
        try store.write(Transcript(duration:2,segments:[Segment(id:1,start:0,end:2,speaker:"speaker_1",
            text:"Пилотный бюджет, условия договора и закупки")],warnings:[],model:"fixture"),
            meetingDirectory.appendingPathComponent("transcript.json"))
        store.reloadLibrary()
        // This component is a section of the scrolling knowledge page. Use
        // the same outer scrolling container in its isolated navigation check.
        let mixed=NSHostingView(rootView:ScrollView {
            KnowledgeMixedTopicsView(query:"").environmentObject(store).padding(20)
        }.background(Ink.paper))
        mixed.sizingOptions=[];mixed.frame=NSRect(x:0,y:0,width:720,height:600)
        window.makeFirstResponder(nil); window.setContentSize(mixed.frame.size); window.contentView=mixed
        let mixedSource="knowledge.mixed.source.meeting:topic-meeting"
        do {
            try await wait {mixed.layoutSubtreeIfNeeded();window.displayIfNeeded();return find(mixedSource,in:mixed) != nil}
        } catch {
            try? captureFrame(mixed,to:root.appendingPathComponent("knowledge-mixed-failure.png"))
            let identifiers=NativeTabNavigation.nodes(in:mixed).compactMap(\.identifier).sorted().joined(separator:", ")
            throw AppError.message("Mixed topic row unavailable: " + identifiers)
        }
        guard let meetingButton=find(mixedSource,in:mixed),press(meetingButton) else {throw AppError.message("Mixed topic meeting button missing")}
        try await wait {store.selection=="topic-meeting" && store.tab=="transcript"}
        guard store.librarySection=="meetings" else {throw AppError.message("Mixed topic did not open its exact meeting")}
        // Populate enough independent themes and long titles to exceed the
        // supported main window height. The page must have one scroll owner.
        for (group, text) in [("music", "Оркестр репетиция симфония скрипка дирижёр"),
                              ("space", "Телескоп орбита спутник галактика космонавт")] {
            for number in 1...4 {
                guard store.notes.save(CapturedNote(id:"layout-\(group)-\(number)", text:text,
                    title:"\(text) — \(text) — \(number)")) != nil else {
                    throw AppError.message("Could not create layout fixture")
                }
            }
        }
        store.notes.reload(); store.librarySection = "knowledge"
        let originalLanguage = UILocalization.shared.language
        let originalLanguageOverride = ProcessInfo.processInfo.environment["POSLE_UI_LANGUAGE"]
        defer {
            if let originalLanguageOverride { setenv("POSLE_UI_LANGUAGE", originalLanguageOverride, 1) }
            else { unsetenv("POSLE_UI_LANGUAGE") }
            _ = UILocalization.shared.setLanguage(originalLanguage)
        }
        for language in [UILanguage.ru, .en] {
            // Normal --check-* runs pin Russian. Override that diagnostic
            // default explicitly so the English screenshot really is English.
            setenv("POSLE_UI_LANGUAGE", language.rawValue, 1)
            guard UILocalization.shared.setLanguage(language), UILocalization.shared.resolvedLanguage == language.rawValue,
                  L("База знаний") == (language == .ru ? "База знаний" : "Knowledge base") else {
                throw AppError.message("Could not resolve fixture language")
            }
            let main = NSHostingView(rootView: LocalizedInterfaceRoot(content: MainView().environmentObject(store).background(Ink.paper)))
            main.sizingOptions = []; main.frame = NSRect(x:0,y:0,width:1040,height:700)
            window.makeFirstResponder(nil); window.setContentSize(main.frame.size); window.contentView = main
            try await wait {
                main.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let controls=NativeTabNavigation.nodes(in:main)
                let loaded=["knowledge.topics.refresh", "knowledge.mixed.refresh"].allSatisfy { id in
                    controls.contains { $0.identifier == id && $0.enabled }
                }
                return loaded && descendants(main, as:NSScrollView.self).contains {
                    $0.frame.width > 400 && ($0.documentView?.frame.height ?? 0) > $0.contentSize.height + 100
                }
            }
            let scrolls = descendants(main, as:NSScrollView.self).filter { $0.frame.width > 400 }
            guard scrolls.count == 1, let scroll = scrolls.first, let document = scroll.documentView else {
                throw AppError.message("Knowledge sections must share one vertically scrollable page at 1040×700")
            }
            let suffix = language == .ru ? "" : "-en"
            try captureFrame(main, to:root.appendingPathComponent("knowledge-full\(suffix).png"))
            let expected:Set<String> = ["knowledge.collection.note.topic-a", "knowledge.topic.note.topic-a",
                "knowledge.topic.note.layout-space-4", "knowledge.topic.note.layout-music-4", mixedSource]
            var reached=Set<String>()
            let bottom=max(0,document.bounds.height-scroll.contentSize.height)
            let step=max(1,scroll.contentSize.height/2)
            for offset in stride(from:CGFloat.zero, through:bottom+step, by:step) {
                document.scroll(NSPoint(x:0,y:min(offset,bottom)))
                try await Task.sleep(for:.milliseconds(80))
                main.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let visible=window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds,to:nil))
                for node in NativeTabNavigation.nodes(in:main) {
                    if let id=node.identifier, expected.contains(id), let frame=node.frame, !frame.isEmpty,
                       frame.intersects(visible) {reached.insert(id)}
                }
            }
            try captureFrame(main, to:root.appendingPathComponent("knowledge-full-bottom\(suffix).png"))
            guard scroll.contentView.bounds.minY > 0, reached == expected else {
                throw AppError.message("Knowledge rows could not be reached by scrolling: " + expected.subtracting(reached).sorted().joined(separator:", "))
            }
        }
        print("PASS: one scrolling knowledge page reaches its lower sections at 1040×700 in Russian and English")
        print("PASS: mixed topics include published meetings and open their validated transcript")
        print("PASS: topics save a collection, add and remove notes without deleting them, and search ungrouped notes")
    }
    private static func descendants<T:NSView>(_ root:NSView, as type:T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, as:type) }
    }
    private static func captureFrame(_ view:NSView, to url:URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {throw AppError.message("Knowledge snapshot failed")}
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let rendered=bitmap.cgImage,
              let opaque=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:bitmap.pixelsWide,pixelsHigh:bitmap.pixelsHigh,
                                          bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                                          colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let graphics=NSGraphicsContext(bitmapImageRep:opaque) else {throw AppError.message("Opaque knowledge snapshot failed")}
        let bounds=CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh)
        graphics.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor);graphics.cgContext.fill(bounds)
        graphics.cgContext.draw(rendered,in:bounds)
        guard let png=opaque.representation(using:.png,properties:[:]) else {throw AppError.message("Knowledge PNG failed")}
        try png.write(to:url)
    }
    private static func edit(_ window:NSWindow,placeholder:String,text:String) throws {
        func fields(_ root:NSView)->[NSTextField] {
            (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(fields)
        }
        guard let root=window.contentView,
              let field=fields(root).first(where:{$0.placeholderString==placeholder}) else {
            throw AppError.message("Search field not found")
        }
        window.makeFirstResponder(field)
        guard let editor=field.currentEditor() as? NSTextView else {throw AppError.message("Search editor not available")}
        editor.selectAll(nil); editor.insertText(text,replacementRange:editor.selectedRange())
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Knowledge topics UI timed out at line \(line)")
    }
    private static func find(_ id: String, in root: NSView) -> NSObject? {
        // SwiftUI sections expose some rows through accessibilityContents,
        // especially after removing a nested NSScrollView. Use the shared
        // public traversal rather than assuming every row is an AX child.
        NativeTabNavigation.nodes(in:root).first { $0.identifier == id }?.object
    }
    private static func press(_ object: NSObject) -> Bool {
        if let button = object as? NSButton, button.isEnabled { button.performClick(nil); return true }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Press.self)(object, selector)
    }
}
#endif
