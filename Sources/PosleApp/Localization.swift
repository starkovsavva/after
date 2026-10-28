import AppKit
import Combine
import Foundation
import PosleCore
import SwiftUI

/// Interface preferences never enter a model profile or change saved content.
enum UILanguage: String, Codable, CaseIterable, Identifiable {
    case system, ru, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("Как в системе")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

/// Immutable catalog plus a small synchronized language snapshot for non-UI errors.
/// Callers translate UI text explicitly; documents, transcripts, model output and
/// user names must never be passed through a global string replacement hook.
private final class UILocalizationRuntime: @unchecked Sendable {
    static let shared = UILocalizationRuntime()
    private let lock = NSLock()
    private var language = "ru"
    private let english: [String: String]
    private init() {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Localization/en.json"))
        }
        #if DEBUG
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Localization/en.json"))
        #endif
        english = candidates.lazy.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        }.first ?? [:]
    }
    func setLanguage(_ value: String) { lock.lock(); language = value; lock.unlock() }
    var locale: Locale {
        lock.lock(); let selected = language; lock.unlock()
        return Locale(identifier: selected == "ru" ? "ru_RU" : "en_US")
    }
    func translate(_ source: String) -> String {
        lock.lock(); let selected = language; lock.unlock()
        return selected == "en" ? english[source] ?? source : source
    }
}

/// Translate a known application string, not arbitrary user content.
func L(_ source: String) -> String { UILocalizationRuntime.shared.translate(source) }
func UILocale() -> Locale { UILocalizationRuntime.shared.locale }

/// Interpolate explicit catalog placeholders without interpreting arguments as
/// format specifiers, translation keys, Markdown, or additional placeholders.
func LF(_ source: String, arguments: [String]) -> String {
    var result = L(source)
    guard let expression = try? NSRegularExpression(pattern: #"\{([0-9]+)\}"#) else { return result }
    let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result))
    for match in matches.reversed() {
        guard let numberRange = Range(match.range(at: 1), in: result),
              let index = Int(result[numberRange]), arguments.indices.contains(index),
              let range = Range(match.range, in: result) else { continue }
        result.replaceSubrange(range, with: arguments[index])
    }
    return result
}

@MainActor
final class UILocalization: ObservableObject {
    static let shared = UILocalization()
    private struct Preferences: Codable { var language: UILanguage = .system }
    @Published private(set) var language: UILanguage = .system
    @Published private(set) var resolvedLanguage = "ru"
    @Published private(set) var error: String?
    private var root: URL?
    private var localeObserver: NSObjectProtocol?
    var locale: Locale { Locale(identifier: resolvedLanguage == "ru" ? "ru_RU" : "en_US") }
    private init() {
        apply(.system)
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.language == .system else { return }
                self.apply(.system)
            }
        }
    }
    /// First supported preference wins. Unsupported languages fall back to English.
    static func systemLanguage(preferredLanguages: [String]) -> String {
        for preference in preferredLanguages {
            let base = preference.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased()
            if base == "ru" || base == "en" { return base! }
        }
        return "en"
    }
    func configure(root: URL) {
        guard self.root != root else { return }
        self.root = root
        let url = root.appendingPathComponent("language-state.json")
        do {
            var preferences = Preferences()
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try RustBridge.shared.get().read(root: root, url: url)
                guard data.count <= 4096 else { throw AppError.message("Файл языка интерфейса слишком большой.") }
                preferences = try JSONDecoder().decode(Preferences.self, from: data)
            }
            error = nil; apply(preferences.language)
        } catch {
            apply(.system)
            self.error = "Не удалось прочитать язык интерфейса. Используется язык системы."
        }
    }
    @discardableResult func setLanguage(fromString value: String) -> Bool {
        guard let language = UILanguage(rawValue: value) else {
            error = "Неизвестный язык интерфейса."; return false
        }
        return setLanguage(language)
    }
    /// Persist before publishing so failed writes leave the current UI intact.
    @discardableResult func setLanguage(_ value: UILanguage) -> Bool {
        guard value != language || error != nil else { return true }
        guard let root else { error = "Папка настроек ещё не открыта."; return false }
        do {
            try RustBridge.shared.get().write(root: root, url: root.appendingPathComponent("language-state.json"), value: Preferences(language: value))
            error = nil; apply(value); return true
        } catch {
            self.error = "Не удалось сохранить язык интерфейса. Повторите попытку."
            return false
        }
    }
    private func apply(_ value: UILanguage) {
        var resolved = value == .system ? Self.systemLanguage(preferredLanguages: Locale.preferredLanguages) : value.rawValue
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let option = args.firstIndex(of: "--ui-language").flatMap { index in args.indices.contains(index + 1) ? args[index + 1] : nil }
        if let explicit = option ?? ProcessInfo.processInfo.environment["POSLE_UI_LANGUAGE"], ["ru", "en"].contains(explicit) {
            resolved = explicit
        } else if args.contains(where: { $0.hasPrefix("--check-") && $0 != "--check-localization" }) { resolved = "ru" }
        #endif
        let changed = language != value || resolvedLanguage != resolved
        UILocalizationRuntime.shared.setLanguage(resolved)
        language = value; resolvedLanguage = resolved
        if changed { NotificationCenter.default.post(name: .posleUILanguageChanged, object: nil) }
    }
}

extension Notification.Name {
    static let posleUILanguageChanged = Notification.Name("PosleUILanguageChanged")
}

/// Panels keep their identity and editor state when the app language changes.
struct LocalizedInterfaceRoot<Content: View>: View {
    @ObservedObject private var localization = UILocalization.shared
    let content: Content
    var body: some View { content.environment(\.locale, localization.locale) }
}

/// Update app-owned menu labels through public AppKit APIs. System dialogs and
/// platform-managed editing descriptions continue to follow macOS localization.
@MainActor
func refreshLocalizedApplicationMenu() {
    guard let menu = NSApp.mainMenu else { return }
    let topLevelKeys = ["File": "Файл", "Файл": "Файл", "Edit": "Правка", "Правка": "Правка", "View": "Вид", "Вид": "Вид", "Window": "Окно", "Окно": "Окно", "Help": "Справка", "Справка": "Справка"]
    for item in menu.items {
        if let key = topLevelKeys[item.title] { item.title = L(key); item.submenu?.title = L(key) }
    }
    guard let application = menu.items.first, let submenu = application.submenu else { return }
    application.title = L("После"); submenu.title = L("После")
    for item in submenu.items {
        switch item.action.map(NSStringFromSelector) {
        case "orderFrontStandardAboutPanel:": item.title = LF("О программе {0}", arguments: [L("После")])
        case "hide:": item.title = LF("Скрыть {0}", arguments: [L("После")])
        case "hideOtherApplications:": item.title = L("Скрыть остальные")
        case "unhideAllApplications:": item.title = L("Показать все")
        case "terminate:": item.title = LF("Завершить {0}", arguments: [L("После")])
        default:
            if ["Службы", "Services"].contains(item.title) { item.title = L("Службы"); item.submenu?.title = L("Службы") }
        }
    }
}
