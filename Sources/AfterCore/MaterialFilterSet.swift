import Foundation

/// Conditions are intersected across fields and unioned inside each field.
/// An empty field does not restrict the library.
public struct MaterialFilterSet: Codable, Equatable, Sendable {
    public var origins: Set<MaterialCreationOrigin> {
        didSet {
            let normalized = Self.normalizedOrigins(origins)
            if normalized != origins { origins = normalized }
        }
    }
    public var topicIDs: Set<String>
    public var kinds: Set<String>
    private enum CodingKeys: String, CodingKey { case origins, topicIDs, kinds }

    public init(origins: Set<MaterialCreationOrigin> = [], topicIDs: Set<String> = [], kinds: Set<String> = []) {
        self.origins = Self.normalizedOrigins(origins)
        self.topicIDs = topicIDs
        self.kinds = kinds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        origins = Self.normalizedOrigins(try values.decodeIfPresent(Set<MaterialCreationOrigin>.self, forKey: .origins) ?? [])
        topicIDs = try values.decodeIfPresent(Set<String>.self, forKey: .topicIDs) ?? []
        kinds = try values.decodeIfPresent(Set<String>.self, forKey: .kinds) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.normalizedOrigins(origins), forKey: .origins)
        try values.encode(topicIDs, forKey: .topicIDs)
        try values.encode(kinds, forKey: .kinds)
    }

    private static func normalizedOrigins(_ origins: Set<MaterialCreationOrigin>) -> Set<MaterialCreationOrigin> {
        Set(origins.compactMap { origin -> MaterialCreationOrigin? in
            switch origin {
            case .manual, .imported: MaterialCreationOrigin.manual
            case .ai: MaterialCreationOrigin.ai
            case .unknown: nil
            }
        })
    }

    public var activeCount: Int {
        (origins.isEmpty ? 0 : 1) + (topicIDs.isEmpty ? 0 : 1)
            + (kinds.isEmpty ? 0 : 1)
    }

    public func includesOrigin(_ origin: MaterialCreationOrigin) -> Bool {
        guard !origins.isEmpty else { return true }
        switch origin {
        case .manual, .imported: return origins.contains(.manual)
        case .ai: return origins.contains(.ai)
        case .unknown: return false
        }
    }

    public func includesKind(_ kind: String) -> Bool {
        kinds.isEmpty || kinds.contains(kind)
    }
}
