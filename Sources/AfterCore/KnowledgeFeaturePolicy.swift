import Foundation

extension AppFeatures {
    /// UI visibility and retrieval use the same known source types. Factual
    /// action notes remain part of the base summary, independent of the tracker.
    public func allowsKnowledgeKind(_ kind: String) -> Bool {
        switch kind {
        case "card": cards
        case "task", "code": tasks
        case "calendar": calendar
        case "meeting", "transcript", "summary", "note", "title", "overview", "item", "manual": true
        default: false
        }
    }

    public var knowledgeSearchKinds: [String] {
        ["meeting", "transcript", "summary", "note", "card", "task", "code", "calendar"].filter(allowsKnowledgeKind)
    }

    public func normalizedSearchScope(_ scope: String, byMeaning: Bool) -> String {
        switch scope {
        case "all", "notes", "transcript", "meetings": scope
        case "cards": cards ? scope : "all"
        case "tasks", "code": byMeaning && semanticSearch && tasks ? scope : "all"
        default: "all"
        }
    }
}
