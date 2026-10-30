import Foundation

/// Public hotfix labels are independent of Apple's bundle version and the
/// monotonic build used by the installer and Sparkle.
enum AppVersion {
    static var current: String? { display(info: Bundle.main.infoDictionary ?? [:]) }

    static func display(info: [String: Any]) -> String? {
        guard let base = info["CFBundleShortVersionString"] as? String,
              valid(base, pattern: #"^[0-9]{1,4}(\.[0-9]{1,4}){1,2}$"#) else { return nil }
        guard let product = info["PosleProductVersion"] as? String else { return base }
        if product == base { return base }
        let parts = product.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.prefix(3).joined(separator: ".") == base,
              valid(String(parts[3]), pattern: #"^[1-9][0-9]{0,3}$"#) else { return base }
        return product
    }

    private static func valid(_ value: String, pattern: String) -> Bool {
        guard value.utf8.count <= 24,
              let match = value.range(of: pattern, options: .regularExpression) else { return false }
        return match == value.startIndex..<value.endIndex
    }
}
