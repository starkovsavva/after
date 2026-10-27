import Foundation

public enum AppFeature: String, CaseIterable, Codable, Sendable {
    case cards, tasks, calendar, assistant, semanticSearch
    public var title: String {
        switch self {
        case .cards: "Карточки"
        case .tasks: "Задачи и проекты"
        case .calendar: "Календарь"
        case .assistant: "Помощник"
        case .semanticSearch: "Смысловой поиск"
        }
    }
}

/// Optional tools are opt-in. Changing visibility never removes library data.
public struct AppFeatures: Codable, Equatable, Sendable {
    public var cards = false
    public var tasks = false
    public var calendar = false
    public var assistant = false
    public var semanticSearch = false
    public init() {}
    public static var allEnabled: AppFeatures {
        var value = AppFeatures()
        for feature in AppFeature.allCases { value[feature] = true }
        return value
    }
    public subscript(feature: AppFeature) -> Bool {
        get {
            switch feature {
            case .cards: cards; case .tasks: tasks; case .calendar: calendar
            case .assistant: assistant; case .semanticSearch: semanticSearch
            }
        }
        set {
            switch feature {
            case .cards: cards = newValue; case .tasks: tasks = newValue; case .calendar: calendar = newValue
            case .assistant: assistant = newValue; case .semanticSearch: semanticSearch = newValue
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case cards, tasks, calendar, assistant, semanticSearch }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cards = try values.decodeIfPresent(Bool.self, forKey: .cards) ?? false
        tasks = try values.decodeIfPresent(Bool.self, forKey: .tasks) ?? false
        calendar = try values.decodeIfPresent(Bool.self, forKey: .calendar) ?? false
        assistant = try values.decodeIfPresent(Bool.self, forKey: .assistant) ?? false
        semanticSearch = try values.decodeIfPresent(Bool.self, forKey: .semanticSearch) ?? false
    }
}

extension AppSettings {
    public func isEnabled(_ feature: AppFeature) -> Bool { features[feature] }
    public func allowsSection(_ section: String) -> Bool {
        switch section {
        case "cards": features.cards
        case "tasks", "contexts": features.tasks
        case "calendar": features.calendar
        default: true
        }
    }
}
