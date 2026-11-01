import Foundation
import Observation

/// Observable reads in L()/UILocale() invalidate each SwiftUI body that uses
/// localized copy, including cached list rows. Identity and editor state stay intact.
/// The synchronized snapshot also supports non-UI errors.
/// Callers translate UI text explicitly; documents, transcripts, model output and
/// user names must never be passed through a global string replacement hook.
@Observable
package final class UILocalizationRuntime: @unchecked Sendable {
    package static let shared = UILocalizationRuntime()
    private let lock = NSLock()
    @ObservationIgnored private var storedLanguage = "ru"
    private var language: String {
        access(keyPath: \.language)
        lock.lock(); defer { lock.unlock() }
        return storedLanguage
    }
    private let english: [String: String]
    private init() {
        // SwiftPM's generated accessor looks beside the executable, while a
        // native app owns bundles in Contents/Resources. Resolve that shipped
        // location first, without consulting a developer's absolute build path.
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("After_AfterLocalization.bundle/en.json"))
            candidates.append(resources.appendingPathComponent("Localization/en.json"))
        }
        let shipped = candidates.lazy.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        }.first
        if let shipped { english = shipped }
        else if Bundle.main.bundleURL.pathExtension != "app",
                let owned = Bundle.module.url(forResource: "en", withExtension: "json"),
                let data = try? Data(contentsOf: owned),
                let catalog = try? JSONDecoder().decode([String: String].self, from: data) {
            // SwiftPM CLI/unit clients use the generated module resource path.
            english = catalog
        } else {
            // A damaged application catalog must not crash the UI at startup.
            english = [:]
        }
    }
    package func setLanguage(_ value: String) {
        guard language != value else { return }
        withMutation(keyPath: \.language) {
            lock.lock(); storedLanguage = value; lock.unlock()
        }
    }
    package var locale: Locale {
        let selected = language
        return Locale(identifier: selected == "ru" ? "ru_RU" : "en_US")
    }
    package func translate(_ source: String) -> String {
        let selected = language
        return selected == "en" ? english[source] ?? source : source
    }
}

/// Translate a known application string, not arbitrary user content.
package func L(_ source: String) -> String { UILocalizationRuntime.shared.translate(source) }
package func UILocale() -> Locale { UILocalizationRuntime.shared.locale }

/// Interpolate explicit catalog placeholders without interpreting arguments as
/// format specifiers, translation keys, Markdown, or additional placeholders.
package func LF(_ source: String, arguments: [String]) -> String {
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
