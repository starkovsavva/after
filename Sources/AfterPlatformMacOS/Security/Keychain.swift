import AfterLocalization
import AfterPlatform
import Foundation
import CryptoKit
import AfterCore
import Security

package enum Keychain {
    private static let service = "app.posle.meetings"
    package static func account(for settings: AppSettings) -> String {
        switch settings.cloudProvider {
        case "openai": return "openai" // Preserve the key from releases before provider selection.
        case "openrouter": return "cloud.openrouter"
        case "polza": return "cloud.polza"
        default: return scopedAccount(prefix: "cloud.custom", endpoint: settings.cloudEndpoint)
        }
    }
    package static func speechAccount(for settings: AppSettings) -> String {
        switch settings.speechCloudProvider {
        case "openai": return "speech.openai"
        default: return scopedAccount(prefix: "speech.custom", endpoint: settings.speechCloudEndpoint)
        }
    }
    private static func scopedAccount(prefix: String, endpoint: String) -> String {
        let raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: raw)
        let scheme = components?.scheme?.lowercased(), host = components?.host?.lowercased()
        components?.scheme = scheme; components?.host = host
        if (components?.scheme == "https" && components?.port == 443) || (components?.scheme == "http" && components?.port == 80) { components?.port = nil }
        if var path = components?.percentEncodedPath {
            while path.hasSuffix("/") { path.removeLast() }
            components?.percentEncodedPath = path
        }
        let normalized = components?.string ?? raw
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return prefix + "." + digest
    }
    package static func read(account: String = "openai") -> String {
        (try? readChecked(account: account)) ?? ""
    }

    /// A temporarily locked or inaccessible vault must not look like an empty
    /// account and allow a session manager to replace an existing registration.
    package static func readChecked(account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data,
              let result = String(data: data, encoding: .utf8) else {
            throw AppError.message(L("Не удалось прочитать сессию из Связки ключей macOS."))
        }
        return result
    }

    package static func save(_ key: String, account: String = "openai") throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppError.message(LF("Связка ключей не разрешила удалить ключ: {0}", arguments: [String(describing: status)]))
            }
            return
        }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        let status = update == errSecItemNotFound
            ? SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) : update
        guard status == errSecSuccess else { throw AppError.message(LF("Связка ключей не сохранила ключ: {0}", arguments: [String(describing: status)])) }
    }
}
