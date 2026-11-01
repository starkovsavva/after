import Foundation

package struct ChatGPTProfile: Codable, Identifiable, Equatable, Sendable {
    package let id: String
    package let displayName: String
    package let email: String?
    package let planEnabled: Bool
    package init(id: String, displayName: String, email: String?, planEnabled: Bool) {
        self.id = id; self.displayName = displayName; self.email = email; self.planEnabled = planEnabled
    }
}
package struct ChatGPTModel: Identifiable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let supportedReasoning: [String]?
    package init(id: String, name: String, supportedReasoning: [String]?) {
        self.id = id; self.name = name; self.supportedReasoning = supportedReasoning
    }
    package var reasoningChoices: [String] {
        supportedReasoning ?? (id == "gpt-6-luna" ? ["none", "low", "medium", "high", "xhigh", "max"] : [])
    }
}

/// Application-owned presentation crosses as rendered data; the listener never
/// imports artwork, windows, application state or credentials into its HTML.
package struct BrowserCallbackPage: Sendable {
    package let render: @Sendable (Bool) -> Data
    package let contentSecurityPolicy: String
    package init(contentSecurityPolicy: String, render: @escaping @Sendable (Bool) -> Data) {
        self.contentSecurityPolicy = contentSecurityPolicy; self.render = render
    }
}
