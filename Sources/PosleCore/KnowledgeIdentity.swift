import Foundation

/// Stable, typed references for the future knowledge graph. A reference alone
/// is not permission to read the referenced material.
public enum KnowledgeSourceKind: String, Codable, Sendable {
    case note, meeting, transcript, summary, card, task, taskEvent, taskArtifact, calendar, code
}

public struct SourceRef: Codable, Hashable, Sendable {
    public var libraryID: String
    public var kind: KnowledgeSourceKind
    public var objectID: String
    public var subID: String?
    public init(libraryID: String, kind: KnowledgeSourceKind, objectID: String, subID: String? = nil) {
        self.libraryID = libraryID; self.kind = kind; self.objectID = objectID; self.subID = subID
    }
    public var isValid: Bool {
        guard UUID(uuidString: libraryID) != nil, Self.validIdentifier(objectID),
              subID.map(Self.validIdentifier) ?? true else { return false }
        if kind == .note {
            return subID == nil && objectID.utf8.count <= 128 &&
                objectID.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
                    (97...122).contains($0) || $0 == 45 || $0 == 95 }
        }
        return true
    }
    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        })
    }
}

public struct SourceVersion: Codable, Hashable, Sendable {
    public var source: SourceRef
    public var entityRevision: UInt64?
    public var contentFingerprint: String
    public var policyRevision: UInt64
    enum CodingKeys: String, CodingKey { case source = "ref", entityRevision, contentFingerprint, policyRevision }
}

public struct EvidenceAnchor: Codable, Hashable, Sendable {
    public var source: SourceRef
    public var contentFingerprint: String
    public var spanID: String
    public var quoteHash: String
    public var startUTF8: UInt64?
    public var endUTF8: UInt64?
    public var prefixHash: String?
    public var suffixHash: String?
    enum CodingKeys: String, CodingKey {
        case source = "ref", contentFingerprint, spanID, quoteHash, startUTF8, endUTF8, prefixHash, suffixHash
    }
}
