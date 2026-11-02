import Foundation

/// Creation and source attachment are independent. Legacy/future values are
/// intentionally unknown; a transcript link never proves model authorship.
public enum MaterialCreationOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case manual, ai, imported, unknown

    /// Filter choices are narrower than canonical creation provenance.
    /// Imported material belongs to the user's choice; unknown stays unclassified.
    public static let selectableOrigins: [Self] = [.ai, .manual]

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
    public var titleKey: String {
        switch self {
        case .manual: "Создано мной"
        case .ai: "Создано ИИ"
        case .imported: "Импортировано"
        case .unknown: "Происхождение неизвестно"
        }
    }
}

public enum MaterialOriginFilter: String, Codable, CaseIterable, Hashable, Sendable {
    case all, manual, ai
    public var titleKey: String {
        switch self {
        case .all: "Все"
        case .manual: "Создано мной"
        case .ai: "Создано ИИ"
        }
    }
    public func includes(_ origin: MaterialCreationOrigin) -> Bool {
        self == .all || (self == .manual && (origin == .manual || origin == .imported)) || (self == .ai && origin == .ai)
    }
}
