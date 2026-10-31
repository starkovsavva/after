import Foundation

/// Stable folders are independent of projects and exist even without content.
public struct LibraryFolder: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var revision: Int
    public var overrides: FolderOverrides
    public init(id: String = UUID().uuidString.lowercased(), name: String = "", revision: Int = 0, overrides: FolderOverrides = FolderOverrides()) {
        self.id = id; self.name = name; self.revision = revision; self.overrides = overrides
    }
}

/// Nil means inheritance; false is an explicit choice to disable a capability.
public struct FolderFeatureOverrides: Codable, Hashable, Sendable {
    public var cards: Bool?
    public var tasks: Bool?
    public var calendar: Bool?
    public var assistant: Bool?
    public var semanticSearch: Bool?
    public var knowledgeBase: Bool?
    public init() {}
    public subscript(feature: AppFeature) -> Bool? {
        get { switch feature {
        case .cards: cards; case .tasks: tasks; case .calendar: calendar
        case .assistant: assistant; case .semanticSearch: semanticSearch; case .knowledgeBase: knowledgeBase
        }}
        set { switch feature {
        case .cards: cards = newValue; case .tasks: tasks = newValue; case .calendar: calendar = newValue
        case .assistant: assistant = newValue; case .semanticSearch: semanticSearch = newValue; case .knowledgeBase: knowledgeBase = newValue
        }}
    }
    public func apply(to inherited: AppFeatures) -> AppFeatures {
        var value = inherited
        for feature in AppFeature.allCases { if let override = self[feature] { value[feature] = override } }
        return value
    }
}

/// Only non-secret preferences belong in a folder. Credentials remain scoped in Keychain.
public struct FolderOverrides: Codable, Hashable, Sendable {
    public var features: FolderFeatureOverrides?
    public var mode: String?
    public var localModel: String?
    public var localProvider: String?
    public var localEndpoint: String?
    public var cloudModel: String?
    public var cloudProvider: String?
    public var cloudEndpoint: String?
    public var cloudAPI: String?
    public var cloudOutput: String?
    public var cloudReasoning: String?
    public var chatGPTAccountID: String?
    public var language: String?
    public var focus: String?
    public var summaryUserContext: String?
    public var generateCards: Bool?
    public init() {}
    public func apply(to inherited: AppSettings) -> AppSettings {
        var value = inherited
        if let features { value.features = features.apply(to: inherited.features) }
        if let mode { value.mode = mode }
        if let localModel { value.localModel = localModel }
        if let localProvider { value.localProvider = localProvider }
        if let localEndpoint { value.localEndpoint = localEndpoint }
        if let cloudModel { value.cloudModel = cloudModel }
        if let cloudProvider { value.cloudProvider = cloudProvider }
        if let cloudEndpoint { value.cloudEndpoint = cloudEndpoint }
        if let cloudAPI { value.cloudAPI = cloudAPI }
        if let cloudOutput { value.cloudOutput = cloudOutput }
        if let cloudReasoning { value.cloudReasoning = cloudReasoning }
        if let chatGPTAccountID { value.chatGPTAccountID = chatGPTAccountID }
        if let language { value.language = language }
        if let focus { value.focus = focus }
        if let summaryUserContext { value.summaryUserContext = summaryUserContext }
        return value
    }
    public mutating func copyModel(from settings: AppSettings) {
        mode = settings.mode
        localModel = settings.localModel
        localProvider = settings.localProvider
        localEndpoint = settings.localEndpoint
        cloudModel = settings.cloudModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : settings.cloudModel
        cloudProvider = settings.cloudProvider
        cloudEndpoint = settings.cloudEndpoint
        cloudAPI = settings.cloudAPI
        cloudOutput = settings.cloudOutput
        cloudReasoning = settings.cloudReasoning
        chatGPTAccountID = settings.chatGPTAccountID
    }
    public mutating func inheritModel() {
        mode = nil
        localModel = nil
        localProvider = nil
        localEndpoint = nil
        cloudModel = nil
        cloudProvider = nil
        cloudEndpoint = nil
        cloudAPI = nil
        cloudOutput = nil
        cloudReasoning = nil
        chatGPTAccountID = nil
    }
    public var overridesModel: Bool {
        mode != nil || localModel != nil || localProvider != nil || localEndpoint != nil || cloudModel != nil || cloudProvider != nil || cloudEndpoint != nil || cloudAPI != nil || cloudOutput != nil || cloudReasoning != nil || chatGPTAccountID != nil
    }
}

public struct ResolvedFolderProfile: Decodable {
    public var folderID: String?
    public var folderName: String?
    public var fingerprint: String
    public var overrides: FolderOverrides
    public var generateCards: Bool
    public var features: AppFeatures? = nil
}
