#if DEBUG
import AfterCore
import AfterLocalization
import AfterPlatform
import AppKit
import Foundation
import SwiftUI

@MainActor
enum KnowledgeCollectionPickerNativeChecks {
    private final class Session: ObservableObject {
        @Published var showing = false
        @Published var name = "Материалы исследования"
        var excluded: Set<String> = []
        var calls: [[String]] = []
        var continuation: CheckedContinuation<Void, Error>?
        func save(_ notes: [CapturedNote]) async throws {
            calls.append(notes.map(\.id))
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish(_ result: Result<Void, Error>) {
            let current = continuation; continuation = nil; current?.resume(with: result)
        }
    }
    private struct Harness: View {
        @ObservedObject var session: Session
        let store: AppStore
        var body: some View {
            Color.clear.frame(width: 1040, height: 700)
                .sheet(isPresented: $session.showing) {
                    KnowledgeCollectionPicker(excluded: session.excluded, capacity: 200, scopeFolderID: nil,
                        title: L("Новая подборка"), name: $session.name, onAdd: session.save)
                        .environmentObject(store)
                }
        }
    }
    static func run(store: AppStore) async throws {
        let root = store.root.resolvingSymlinksInPath()
        guard store.isPreview, ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("posle-native-check-") else { throw AppError.message("Disposable collection fixture required") }
        try await draftChecks()
        let previousFolder = store.folderSelection
        let language = UILocalization.shared.language
        let languageOverride = ProcessInfo.processInfo.environment["POSLE_UI_LANGUAGE"]
        defer {
            store.folderSelection = previousFolder
            if let languageOverride { setenv("POSLE_UI_LANGUAGE", languageOverride, 1) } else { unsetenv("POSLE_UI_LANGUAGE") }
            _ = UILocalization.shared.setLanguage(language)
        }
        store.folderSelection = nil
        let before = Set(store.notes.workspace.notes.map(\.id))
        guard let research = store.notes.saveFolder(LibraryFolder(name: "Исследование продукта")),
              let english = store.notes.saveFolder(LibraryFolder(name: "Английский")) else { throw AppError.message("Cannot create collection folders") }
        let fullText = (1...45).map { "Строка \($0). Полный текст заметки для чтения без сокращения." }.joined(separator: "\n") + "\nEND OF FULL NOTE"
        for index in (0..<6).reversed() {
            guard store.notes.save(CapturedNote(id: "picker-\(index)", text: index == 0 ? fullText : "Фрагмент заметки \(index): решения, вопросы и следующие шаги.",
                updatedAt: Double(2_000_000_000 - index), title: index == 1 ? "Длинное название заметки для проверки одинаковой высоты карточек в строке" : "Заметка \(index)",
                folderID: index < 3 ? research.id : english.id)) != nil else { throw AppError.message("Cannot create picker note") }
        }
        let session = Session(); session.excluded = before
        let host = NSHostingView(rootView: Harness(session: session, store: store))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 1040, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { session.finish(.failure(CancellationError())); session.showing = false; window.orderOut(nil); window.contentView = nil }
        func sheet() throws -> NSView {
            guard let content = window.attachedSheet?.contentView else { throw AppError.message("Collection sheet missing") }
            content.layoutSubtreeIfNeeded(); window.attachedSheet?.displayIfNeeded(); return content
        }
        for locale in [UILanguage.ru, .en] {
            setenv("POSLE_UI_LANGUAGE", locale.rawValue, 1); _ = UILocalization.shared.setLanguage(locale)
            session.showing = true
            try await wait { (try? sheet()).map { NativeTabNavigation.contains("knowledge.collection.pick.picker-0", in: $0) } == true }
            try await Task.sleep(for: .milliseconds(250))
            let content = try sheet()
            try assertFooter(content, window: window.attachedSheet!)
            guard !NativeTabNavigation.nodes(in: content).contains(where: { $0.identifier?.contains("selected-toggle") == true }) else {
                throw AppError.message("Collection picker must not expose a Selected filter")
            }
            let nodes = NativeTabNavigation.nodes(in: content)
            guard let first = nodes.first(where: { $0.identifier == "knowledge.collection.pick.read.picker-0" })?.frame,
                  let second = nodes.first(where: { $0.identifier == "knowledge.collection.pick.read.picker-1" })?.frame,
                  abs(first.minY - second.minY) < 1 else { throw AppError.message("Collection card actions must align within a row") }
            try capture(content, to: root.appendingPathComponent("knowledge-picker-" + locale.rawValue + ".png"))
            try NativeTabNavigation.press("knowledge.collection.pick.cancel", in: content)
            try await wait { window.attachedSheet == nil }
        }
        session.showing = true
        try await wait { (try? sheet()).map { NativeTabNavigation.contains("knowledge.collection.pick.picker-0", in: $0) } == true }
        try await Task.sleep(for: .milliseconds(250))
        try NativeTabNavigation.press("knowledge.collection.pick.read.picker-0", in: sheet())
        try await wait { window.attachedSheet?.attachedSheet?.contentView != nil }
        guard let readWindow = window.attachedSheet?.attachedSheet, let read = readWindow.contentView else { throw AppError.message("Full note sheet missing") }
        read.layoutSubtreeIfNeeded()
        guard NativeTabNavigation.nodes(in: read).contains(where: { $0.identifier == "knowledge.collection.pick.full-text" && $0.value?.hasSuffix("END OF FULL NOTE") == true }) else {
            throw AppError.message("Read must expose the full note, including its last line")
        }
        try capture(read, to: root.appendingPathComponent("knowledge-picker-read.png"))
        try NativeTabNavigation.press("knowledge.collection.pick.read.close", in: read)
        try await wait { window.attachedSheet?.attachedSheet == nil }
        try NativeTabNavigation.press("knowledge.collection.pick.picker-0", in: sheet())
        try edit(window.attachedSheet!, placeholder: L("Найти по названию или тексту"), text: "Заметка 3")
        try await wait { (try? sheet()).map { NativeTabNavigation.contains("knowledge.collection.pick.picker-3", in: $0) } == true }
        try NativeTabNavigation.press("knowledge.collection.pick.picker-3", in: sheet())
        try edit(window.attachedSheet!, placeholder: L("Найти по названию или тексту"), text: "")
        try NativeTabNavigation.press("knowledge.collection.pick.folder." + research.id, in: sheet())
        try await wait { (try? sheet()).map { !NativeTabNavigation.contains("knowledge.collection.pick.picker-3", in: $0) } == true }
        try NativeTabNavigation.press("knowledge.collection.pick.confirm", in: sheet())
        try await wait { session.continuation != nil }
        guard session.calls == [["picker-0", "picker-3"]], session.showing,
              !NativeTabNavigation.nodes(in: try sheet()).contains(where: { $0.identifier == "knowledge.collection.pick.cancel" && $0.enabled }) else {
            throw AppError.message("Hidden selections must survive filters; busy sheet must remain open")
        }
        session.finish(.failure(AppError.message("Controlled save failure")))
        try await wait { (try? sheet()).map { NativeTabNavigation.contains("knowledge.collection.pick.error", in: $0) } == true }
        guard session.showing, session.name == "Материалы исследования" else { throw AppError.message("Failed collection save lost its draft") }
        try assertFooter(try sheet(), window: window.attachedSheet!)
        try capture(sheet(), to: root.appendingPathComponent("knowledge-picker-error.png"))
        try NativeTabNavigation.press("knowledge.collection.pick.confirm", in: sheet())
        try await wait { session.continuation != nil }
        guard session.calls == [["picker-0", "picker-3"], ["picker-0", "picker-3"]] else { throw AppError.message("Retry lost selections") }
        session.finish(.success(()))
        try await wait { window.attachedSheet == nil && !session.showing }
        session.excluded.formUnion((1..<6).map { "picker-\($0)" }); session.showing = true
        try await wait { (try? sheet()).map { NativeTabNavigation.contains("knowledge.collection.pick.picker-0", in: $0) } == true }
        try await Task.sleep(for: .milliseconds(250))
        guard let singleWindow = window.attachedSheet, singleWindow.frame.height < 520 else { throw AppError.message("One-note picker should fit its content") }
        try capture(sheet(), to: root.appendingPathComponent("knowledge-picker-one.png"))
        try NativeTabNavigation.press("knowledge.collection.pick.cancel", in: sheet())
        try await wait { window.attachedSheet == nil }
        print("PASS: collection cards align, full text is readable, RU/EN footer stays visible, one note uses a compact sheet")
        print("PASS: selection survives search/folder filters; pending and failed saves keep the draft; only success closes the sheet")
    }
    private static func draftChecks() async throws {
        let note = CapturedNote(id: "draft-a", revision: 4)
        let draft = KnowledgeCollectionPickerDraft(); draft.select(note, checked: true, capacity: 200)
        var called = false
        var stale = note; stale.revision += 1
        for (notes, allowed) in [([stale], true), ([note], false), ([], true)] {
            let saved = await draft.save(notes: notes, name: "Название", capacity: 200, permitted: { _ in allowed }) { _ in called = true }
            guard !saved, !called, draft.selected == [note.id: 4], draft.error != nil else { throw AppError.message("Stale/missing/ineligible picker sources reached save") }
        }
        guard KnowledgeCollectionPickerDraft.nameError(String(repeating: "я", count: 251)) != nil,
              KnowledgeCollectionPickerDraft.nameError(String(repeating: "я", count: 250)) == nil,
              KnowledgeCollectionPickerDraft.nameError("Строка\nдва") != nil else { throw AppError.message("Collection name preview must respect UTF-8/control limits") }
        draft.clear()
        for index in 0...200 { draft.select(CapturedNote(id: "capacity-\(index)"), checked: true, capacity: 200) }
        guard draft.selected.count == 200, draft.selected["capacity-200"] == nil else { throw AppError.message("Picker exceeded 200 selected notes") }
        print("PASS: picker retains stale selections for correction and blocks missing/ineligible sources, 201st selection, and invalid UTF-8 name length")
    }
    private static func assertFooter(_ view: NSView, window: NSWindow) throws {
        let bounds = window.convertToScreen(view.convert(view.bounds, to: nil))
        for id in ["knowledge.collection.pick.count", "knowledge.collection.pick.cancel", "knowledge.collection.pick.confirm"] {
            guard let frame = NativeTabNavigation.nodes(in: view).first(where: { $0.identifier == id })?.frame,
                  !frame.isEmpty, bounds.contains(frame) else { throw AppError.message("Collection footer clipped: " + id) }
        }
    }
    private static func edit(_ window: NSWindow, placeholder: String, text: String) throws {
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let root = window.contentView, let field = fields(root).first(where: { $0.placeholderString == placeholder }) else { throw AppError.message("Collection search missing") }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Collection search editor missing") }
        editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw AppError.message("Collection picker native timeout at line \(line)")
    }
    private static func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Collection screenshot unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage,
              let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: opaque) else { throw AppError.message("Collection screenshot failed") }
        let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        graphics.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor); graphics.cgContext.fill(bounds)
        graphics.cgContext.draw(image, in: bounds)
        guard let png = opaque.representation(using: .png, properties: [:]) else { throw AppError.message("Collection PNG failed") }
        try png.write(to: url)
    }
}
#endif
