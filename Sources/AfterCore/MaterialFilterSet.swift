import Foundation

/// Conditions are intersected across fields and unioned inside each field.
/// An empty field does not restrict the library.
public struct MaterialFilterSet: Codable, Equatable, Sendable {
    public var origins: Set<MaterialCreationOrigin>
    public var topicIDs: Set<String>
    public var kinds: Set<String>

    public init(origins: Set<MaterialCreationOrigin> = [], topicIDs: Set<String> = [], kinds: Set<String> = []) {
        self.origins = origins
        self.topicIDs = topicIDs
        self.kinds = kinds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        origins = try values.decodeIfPresent(Set<MaterialCreationOrigin>.self, forKey: .origins) ?? []
        topicIDs = try values.decodeIfPresent(Set<String>.self, forKey: .topicIDs) ?? []
        kinds = try values.decodeIfPresent(Set<String>.self, forKey: .kinds) ?? []
    }

    public var activeCount: Int {
        (origins.isEmpty ? 0 : 1) + (topicIDs.isEmpty ? 0 : 1)
            + (kinds.isEmpty ? 0 : 1)
    }

    public func includesOrigin(_ origin: MaterialCreationOrigin) -> Bool {
        origins.isEmpty || origins.contains(origin)
    }

    public func includesKind(_ kind: String) -> Bool {
        kinds.isEmpty || kinds.contains(kind)
    }
}
