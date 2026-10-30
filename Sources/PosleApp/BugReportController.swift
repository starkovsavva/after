import AppKit
import PosleCore
import SwiftUI
import UniformTypeIdentifiers

/// Local-only report UI. Nothing is uploaded and no SDK/account client is used.
@MainActor
final class BugReportController: NSObject, NSWindowDelegate {
    static let shared = BugReportController()
    private(set) var window: NSWindow?
    private(set) var session: BugReportSession?
    private let copyText: (String) -> Bool
    private var languageObserver: NSObjectProtocol?
    init(copyText: @escaping (String) -> Bool = { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); return pasteboard.setString(text, forType: .string)
    }) { self.copyText = copyText; super.init() }

    func present(settings: AppSettings, lastFailure: BackgroundJob? = nil) {
        if let window { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let session = BugReportSession(diagnostics: BugReportDiagnostics(settings: settings, lastFailure: lastFailure))
        self.session = session
        let view = BugReportView(session: session, copy: { [weak self] in self?.copyReport() }, save: { [weak self] in self?.save() }, close: { [weak self] in self?.window?.performClose(nil) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("Сообщить об ошибке"); window.minSize = NSSize(width: 570, height: 520)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: LocalizedInterfaceRoot(content: view))
        languageObserver = NotificationCenter.default.addObserver(forName: .posleUILanguageChanged, object: nil, queue: .main) { [weak window] _ in
            Task { @MainActor in window?.title = L("Сообщить об ошибке") }
        }
        session.setReveal { [weak window] in
            guard let window else { return }
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        self.window = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func copyReport() {
        guard let session, session.draft.isValid else { return }
        let document = session.document
        if copyText(document.text) { session.didShare(document.description, status: L("Отчёт скопирован. Отправьте его разработчику.")) }
        else { session.failure = L("Не удалось скопировать отчёт. Повторите или сохраните файл.") }
    }
    private func save() {
        guard let window, window.attachedSheet == nil, let session, session.draft.isValid else { return }
        let document = session.document
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText, .json]; panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = "Posle-Bug-Report.txt"; panel.title = L("Сохранить отчёт об ошибке")
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.save(document, to: url) }
        }
    }
    // The save-panel adapter and native checks share exactly the same writer.
    func save(_ document: BugReportDocument, to url: URL) {
        guard let session else { return }
        do { try document.write(to: url); session.didShare(document.description, status: L("Отчёт сохранён. Прикрепите файл к сообщению разработчику.")) }
        catch { session.failure = L("Не удалось сохранить отчёт. Выберите другую папку или скопируйте текст.") }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        guard sender.attachedSheet == nil else { return false }
        guard session?.hasUnsaved == true else { return true }
        let alert = NSAlert(); alert.messageText = L("Закрыть отчёт без сохранения?")
        alert.informativeText = L("Описание ошибки останется только в этом окне. Скопируйте отчёт или сохраните файл перед закрытием.")
        alert.addButton(withTitle: L("Продолжить редактирование")); alert.addButton(withTitle: L("Закрыть отчёт"))
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            if response == .alertSecondButtonReturn { self?.session?.dispose(); sender?.close() }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }; languageObserver = nil
        session?.dispose(); session = nil; window = nil
    }
}
