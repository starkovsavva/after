#if DEBUG
import AppKit
import Foundation
import PosleCore

/// Actual native controls, a private pasteboard and a disposable export folder.
/// No real library, accounts, dialogs requesting access, network or Keychain.
@MainActor
enum BugReportNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Bug report checks require a disposable preview") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable report root required")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try installationMetadata(root: root)
        let canary = "AUTOMATIC-SECRET-CANARY-/Users/fixture/account@example.test/sk-secret"
        var settings = AppSettings(); settings.mode = "cloud"; settings.cloudProvider = "chatgpt"
        settings.chatGPTAccountID = canary; settings.cloudEndpoint = canary; settings.cloudModel = canary
        settings.localEndpoint = canary; settings.asrModelPath = canary; settings.focus = canary; settings.summaryUserContext = canary
        let config = JobConfiguration(command: "voice-plan", meetingID: canary, extra: [canary], input: Data(canary.utf8), settings: settings)
        let job = BackgroundJob(id: canary, kind: "voice-plan", objectID: canary, inputRevision: canary, dependencies: [canary], config: config,
                                resource: canary, state: "failed", progress: nil, message: "Настройки модели не совпадают с сохранённым профилем операции. " + canary,
                                title: canary, attempt: 3, paid: true, cancelRequested: false, createdAt: 1, updatedAt: 2)
        let diagnostics = BugReportDiagnostics(settings: settings, lastFailure: job, appVersion: "0.17.4", appBuild: "27")
        let technical = BugReportDocument(description: BugReportDraft(), diagnostics: diagnostics).text
        try expect(!technical.contains("AUTOMATIC-SECRET-CANARY") && !technical.contains("account@example") && !technical.contains("/Users/") && !technical.contains("sk-secret"), "Automatic diagnostics must exclude all user/account/path/model/error/input canaries")
        try expect(technical.contains("operation_profile_mismatch") && technical.contains("chatgpt") && technical.contains("0.17.4"), "Known route and failure classifications must remain useful")
        var unknown = settings; unknown.mode = canary; unknown.cloudProvider = canary; unknown.localProvider = canary; unknown.speechCloudProvider = canary; unknown.speechMode = canary
        let rejected = BugReportDocument(description: BugReportDraft(), diagnostics: BugReportDiagnostics(settings: unknown, appVersion: canary, appBuild: canary)).text
        try expect(!rejected.contains("AUTOMATIC-SECRET-CANARY") && rejected.contains("other") && rejected.contains("unknown"), "Unknown diagnostic fields must collapse to fixed enums and numeric metadata")
        print("PASS: allowlisted diagnostics exclude account, endpoint, model, error, job and input canaries; unknown values cannot escape")

        let pasteboard = NSPasteboard.withUniqueName(); pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        var copyWorks = false
        let controller = BugReportController { text in
            guard copyWorks else { return false }
            pasteboard.clearContents(); return pasteboard.setString(text, forType: .string)
        }
        controller.present(settings: settings, lastFailure: job)
        guard let window = controller.window, let session = controller.session else { throw AppError.message("Report window fixture failed") }
        defer { session.dispose(); window.delegate = nil; window.orderOut(nil); window.contentView = nil }
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"), previous = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: ax)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: ax) }
        try await wait(window) { ids(window).contains("bugReport.copy") }
        controller.copyReport()
        try expect(pasteboard.string(forType: .string) == nil && !session.hasUnsaved, "An empty report must not copy or create a protected draft")
        try edit(window, placeholder: "Например, поручение не выполняется", value: "Поручение не выполняется после проверки подключения.")
        try edit(window, placeholder: "Какой результат вы хотели получить", value: "Ожидал увидеть список моих задач.")
        try await wait(window) { session.draft.isValid && session.hasUnsaved && UnsavedEditorRegistry.hasUnsaved }
        let draft = session.draft
        let updateApp = AppStore(preview: true), updates = updateApp.updates
        updates.configureForChecks(store: updateApp)
        var installs = 0
        updates.postponeForChecks { installs += 1 }
        defer { updates.standardUserDriverWillFinishUpdateSession() }
        window.orderOut(nil)
        updates.resumeForChecks()
        try expect(!window.isVisible && updates.hasDeferredDraft && updates.canRevealDraft && !updates.canSafelyRelaunch && installs == 0,
                   "A hidden report must defer installation and offer recovery without dropping its draft")
        updates.revealPendingDraft()
        try await wait(window) { window.isVisible && window.isKeyWindow }
        try expect(session.draft == draft && session.hasUnsaved && !updates.canSafelyRelaunch && installs == 0,
                   "Open Draft must reveal the actual report window and preserve the restart guard")
        window.miniaturize(nil)
        try await wait(window) { window.isMiniaturized }
        updates.refreshForChecks(); updates.revealPendingDraft()
        try await wait(window) { !window.isMiniaturized && window.isVisible && window.isKeyWindow }
        try expect(session.draft == draft && session.hasUnsaved && !updates.canSafelyRelaunch && installs == 0,
                   "Open Draft must restore a minimized report, retaining its complete text and pending installation")
        print("PASS: updater Open Draft reveals hidden and minimized report windows without losing typed text or bypassing unsaved protection")
        try expect(!ids(window).contains("bugReport.steps") && !session.document.text.contains("Как повторить") && !String(decoding: session.document.json, as: UTF8.self).contains("\"steps\""), "The report must contain only the two requested fields and no reproduction form")
        controller.present(settings: unknown)
        try expect(controller.window === window && controller.session === session && session.draft == draft && session.diagnostics.currentRoute.provider == "chatgpt", "Reopening Help must preserve the same typed form and original metadata")
        try snapshot(window.contentView!, to: root.appendingPathComponent("bug-report-before-preview.png"))
        try press(window, "bugReport.previewDisclosure")
        try await Task.sleep(for: .milliseconds(100))
        if !session.previewExpanded {
            guard let content = window.contentView,
                  let nativeField = descendants(content, as: NSTextField.self).first(where: { $0.placeholderString == "Например, поручение не выполняется" }),
                  let disclosure = nodes(content).filter({ $0.identifier == "bugReport.previewDisclosure" }).compactMap(\.frame).first(where: { $0.width > 0 && $0.height > 0 }) else {
                throw AppError.message("Native disclosure calibration controls missing")
            }
            // SwiftUI's virtual group AX frame omits the scroll content's
            // horizontal inset on this macOS. Use the real field's screen bounds:
            // all form controls share its leading edge. Click the actual arrow,
            // without changing the DisclosureGroup binding or opening it in code.
            let nativeBounds = window.convertToScreen(nativeField.convert(nativeField.bounds, to: nil))
            let screen = NSPoint(x: nativeBounds.minX + 4, y: disclosure.midY)
            print("PREVIEW_NATIVE_CLICK fieldBounds=\(nativeBounds) point=\(screen)")
            postClick(window, screen: screen)
        }
        do { try await wait(window) { session.previewExpanded && hasNativePreview(window, text: session.document.text) } }
        catch {
            print("PREVIEW_DIAGNOSTICS expanded=\(session.previewExpanded) disclosureFrames=\(roots(window).flatMap(nodes).filter { $0.identifier == "bugReport.previewDisclosure" }.compactMap(\.frame)) windowFrame=\(window.frame)")
            print("PREVIEW_NATIVE_TEXT " + roots(window).flatMap(nodes).filter { !$0.textValues.isEmpty }.prefix(20).map { String(describing: type(of: $0.object)) + ":" + $0.textValues.map { String($0.prefix(100)) }.joined(separator: "|") }.joined(separator: "\n"))
            try snapshot(window.contentView!, to: root.appendingPathComponent("bug-report-preview-failure.png"))
            throw error
        }
        try expect(session.document.text.contains(draft.actual) && session.document.text.contains(draft.expected), "Preview must contain all explicitly written user text")
        try press(window, "bugReport.close")
        try await wait(window) { window.attachedSheet != nil }
        guard let keep = window.attachedSheet?.contentView.flatMap({ descendants($0, as: NSButton.self).first { $0.title == "Продолжить редактирование" } }) else { throw AppError.message("Report close guard missing") }
        keep.performClick(nil)
        try await wait(window) { window.attachedSheet == nil }
        try expect(controller.session === session && session.draft == draft && session.hasUnsaved && UnsavedEditorRegistry.hasUnsaved, "Cancelling close must keep complete native input and protect quit/update")
        print("PASS: native report fields and exact preview preserve typed text through repeated opening and Cancel; unsaved input participates in quit/update guards")

        try press(window, "bugReport.copy")
        try await wait(window) { session.failure != nil && ids(window).contains("bugReport.failure") }
        try expect(session.draft == draft && session.hasUnsaved && pasteboard.string(forType: .string) == nil, "Clipboard failure must preserve the draft and avoid false success")
        updates.resumeForChecks()
        try expect(installs == 0 && !updates.canSafelyRelaunch, "Copy failure cannot release the updater restart guard")
        let otherEditor = UUID()
        UnsavedEditorRegistry.set(id: otherEditor, title: "Другой редактор", dirty: true)
        defer { UnsavedEditorRegistry.remove(id: otherEditor) }
        copyWorks = true
        try press(window, "bugReport.copy")
        try await wait(window) { session.status != nil && !session.hasUnsaved && ids(window).contains("bugReport.status") }
        try expect(pasteboard.string(forType: .string) == session.document.text && session.failure == nil && UnsavedEditorRegistry.titles == ["Другой редактор"], "The private pasteboard must receive exactly the reviewed report; successful copy releases only this draft")
        updates.resumeForChecks()
        try expect(installs == 0 && !updates.canSafelyRelaunch, "Sharing a report cannot bypass another editor's unsaved guard")
        UnsavedEditorRegistry.remove(id: otherEditor)
        updates.resumeForChecks(); updates.resumeForChecks()
        try expect(installs == 1 && updates.relaunchRequested, "A successful copy must release the report's restart guard and resume installation exactly once")
        updates.standardUserDriverWillFinishUpdateSession()
        try edit(window, placeholder: "Какой результат вы хотели получить", value: "Ожидал список задач без повторной настройки.")
        try await wait(window) { session.hasUnsaved }
        let report = session.document
        controller.save(report, to: root.appendingPathComponent("missing/report.txt"))
        try expect(session.failure != nil && session.hasUnsaved && session.document == report, "Export failure must preserve all text and the dirty guard")
        let textURL = root.appendingPathComponent("report.txt"), jsonURL = root.appendingPathComponent("report.json")
        controller.save(report, to: textURL)
        try expect(try String(contentsOf: textURL, encoding: .utf8) == report.text, "Text export must exactly match preview")
        controller.save(report, to: jsonURL)
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        try expect((decoded?["description"] as? [String: String])?["actual"] == report.description.actual && decoded?["schemaVersion"] as? Int == 1, "JSON export must preserve explicit user fields and the report schema")
        let permissions = try FileManager.default.attributesOfItem(atPath: jsonURL.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600 && !session.hasUnsaved && !UnsavedEditorRegistry.hasUnsaved, "Export must restrict file permissions and release its own draft guard")
        try expect(!String(decoding: report.json, as: UTF8.self).contains("AUTOMATIC-SECRET-CANARY"), "Export cannot reintroduce automatic canaries")
        print("PASS: native Copy handles failure and exact private-pasteboard success; text/JSON exports match preview, retain drafts on failure and use private permissions")
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: dark ? 570 : 650, height: 580))
            try await wait(window) { ids(window).contains("bugReport.copy") }
            try snapshot(window.contentView!, to: root.appendingPathComponent(dark ? "bug-report-dark-narrow.png" : "bug-report-light.png"))
            func visibleFrame(_ id: String) -> NSRect? {
                nodes(window.contentView!).filter { $0.identifier == id }.compactMap(\.frame).filter { $0.width > 0 && $0.height > 0 }.max { $0.width * $0.height < $1.width * $1.height }
            }
            let copy = visibleFrame("bugReport.copy"), save = visibleFrame("bugReport.save"), close = visibleFrame("bugReport.close")
            try expect(copy != nil && save != nil && close != nil && abs(copy!.midY - save!.midY) <= 1 && abs(copy!.midY - close!.midY) <= 1, "Native footer actions must stay aligned in light/dark and at the minimum window width")
        }
        try press(window, "bugReport.close")
        try await wait(window) { controller.window == nil && controller.session == nil }
        try expect(!UnsavedEditorRegistry.hasUnsaved, "Closing a shared report must clean up its draft guard")
        print("5 native bug report checks passed")
    }
    private static func installationMetadata(root: URL) throws {
        let bundle = root.appendingPathComponent("private-account-canary.app")
        let revision = String(repeating: "a", count: 40)
        let info: [String: Any] = ["CFBundleShortVersionString": "0.17.6", "CFBundleVersion": "29", "PosleSourceRevision": revision]
        func save(_ object: [String: Any], _ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: url)
        }
        try save(info, bundle.appendingPathComponent("Contents/Info.plist"))
        let helpers = ["После Обработка", "После Распознавание"].map {
            bundle.appendingPathComponent("Contents/Helpers/" + $0 + ".app/Contents/Info.plist")
        }
        // Production build.sh helpers carry version/build, while provenance is
        // stamped on the outer app. Match that producer contract exactly.
        let helperInfo = info.filter { $0.key != "PosleSourceRevision" }
        for helper in helpers { try save(helperInfo, helper) }
        let matching = BugReportDiagnostics.Installation(bundleURL: bundle)
        try expect(matching.sourceRevision == revision && matching.helperVersions == "match"
                   && matching.location == "other" && matching.captureAuthorization == "system_picker",
                   "Installation diagnostics failed to identify an internally consistent capture build")
        var stale = helperInfo; stale["CFBundleVersion"] = "28"
        try save(stale, helpers[0])
        try expect(BugReportDiagnostics.Installation(bundleURL: bundle).helperVersions == "mismatch",
                   "A mixed helper update was hidden by installation diagnostics")
        try FileManager.default.removeItem(at: helpers[0])
        try expect(BugReportDiagnostics.Installation(bundleURL: bundle).helperVersions == "missing",
                   "A missing helper was hidden by installation diagnostics")
        var poisoned = info; poisoned["PosleSourceRevision"] = "private-account-canary/sk-secret"
        try save(poisoned, bundle.appendingPathComponent("Contents/Info.plist"))
        let unknown = BugReportDiagnostics.Installation(bundleURL: bundle)
        let encoded = String(decoding: try JSONEncoder().encode(unknown), as: UTF8.self)
        try expect(unknown.sourceRevision == "unknown" && !encoded.contains("private-account-canary")
                   && !encoded.contains("sk-secret") && !encoded.contains(root.path),
                   "Installation metadata leaked paths or unvalidated source values")
        print("PASS: static installation diagnostics detect mixed/missing helpers without exposing paths or arbitrary metadata")
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw AppError.message(message) } }
    private static func roots(_ window: NSWindow) -> [NSView] { [window.contentView, window.attachedSheet?.contentView].compactMap { $0 } }
    private static func ids(_ window: NSWindow) -> Set<String> { Set(roots(window).flatMap(nodes).compactMap(\.identifier)) }
    private static func wait(_ window: NSWindow, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw AppError.message("Report native timeout: " + ids(window).sorted().joined(separator: ", ")) }
            window.contentView?.layoutSubtreeIfNeeded(); window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80))
    }
    private static func descendants<T: NSView>(_ root: NSView, as type: T.Type) -> [T] { (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, as: type) } }
    private static func edit(_ window: NSWindow, placeholder: String, value: String) throws {
        guard let root = window.contentView, let field = descendants(root, as: NSTextField.self).first(where: { $0.placeholderString == placeholder }) else { throw AppError.message("Report native field missing: " + placeholder) }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Report field editor missing") }
        editor.selectAll(nil); editor.insertText(value, replacementRange: editor.selectedRange())
    }
    private static func press(_ window: NSWindow, _ id: String) throws {
        window.makeKeyAndOrderFront(nil)
        let matching = roots(window).flatMap(nodes).filter { $0.identifier == id }
        for node in matching { if node.press() { return } }
        if let frame = matching.compactMap(\.frame).first(where: { $0.width > 0 && $0.height > 0 }) {
            let target = window.attachedSheet ?? window
            // SwiftUI can expose a DisclosureGroup wrapper rather than a
            // pressable NSControl. The visible label uses the same toggle action.
            let screen = NSPoint(x: frame.midX, y: frame.midY)
            let point = target.convertPoint(fromScreen: screen)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: target.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            return
        }
        throw AppError.message("Report native action missing: " + id + " " + matching.map { String(describing: type(of: $0.object)) }.joined(separator: ", "))
    }
    private static func postClick(_ window: NSWindow, screen: NSPoint) {
        let point = window.convertPoint(fromScreen: screen)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
    private static func hasNativePreview(_ window: NSWindow, text: String) -> Bool {
        roots(window).contains { root in
            descendants(root, as: NSTextView.self).contains { $0.string == text }
                || nodes(root).contains { $0.textValues.contains(text) }
        }
    }
    private static func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Report snapshot failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let rendered = bitmap.cgImage,
              let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: opaque) else { throw AppError.message("Opaque report snapshot failed") }
        var background = NSColor.windowBackgroundColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor }
        let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        graphics.cgContext.setFillColor(background.cgColor); graphics.cgContext.fill(bounds)
        graphics.cgContext.draw(rendered, in: bounds)
        guard let data = opaque.representation(using: .png, properties: [:]) else { throw AppError.message("Report PNG failed") }
        try data.write(to: url)
    }
    @MainActor private struct Node {
        let object: NSObject
        var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
        private func get(_ name: String) -> Any? { let selector = NSSelectorFromString(name); return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil }
        var identifier: String? { modern?.accessibilityIdentifier() ?? get("accessibilityIdentifier") as? String }
        var children: [Any] { modern?.accessibilityChildren() ?? get("accessibilityChildren") as? [Any] ?? [] }
        var textValues: [String] {
            let values: [Any?] = [modern?.accessibilityValue(), modern?.accessibilityLabel(), get("accessibilityValue"), get("accessibilityLabel"), get("accessibilityTitle"), get("accessibilityAttributedValue")]
            return values.compactMap { value in
                if let string = value as? String { return string }
                return (value as? NSAttributedString)?.string
            }
        }
        var frame: NSRect? {
            if let modern { return modern.accessibilityFrame() }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(method, to: Frame.self)(object, selector)
        }
        func press() -> Bool {
            if let cell = object as? NSButtonCell, let control = cell.controlView as? NSButton, control.isEnabled { control.performClick(nil); return true }
            if let control = object as? NSControl, control.isEnabled { control.performClick(nil); return true }
            return modern?.accessibilityPerformPress() ?? false
        }
    }
    private static func nodes(_ root: NSView) -> [Node] {
        var result: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, _ depth: Int) {
            guard depth < 80, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.children { visit(child, depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth + 1) } }
        }
        visit(root, 0); return result
    }
}
#endif
