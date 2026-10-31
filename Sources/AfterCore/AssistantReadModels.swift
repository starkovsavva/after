import Foundation

public struct AssistantNoteQuery: Equatable, Sendable {
    public let query: String
    public let open: Bool
    public static func parse(_ command: String) -> Self? {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let lowered = value.lowercased()
        let prefixes = ["найди заметку ", "покажи заметку ", "открой заметку ",
                        "find note ", "find a note ", "show note ", "open note ", "open a note "]
        guard let prefix = prefixes.first(where: { lowered.hasPrefix($0) }) else { return nil }
        let remainder = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned: String
        if remainder.lowercased().hasPrefix("про ") { cleaned = String(remainder.dropFirst(4)) }
        else if remainder.lowercased().hasPrefix("about ") { cleaned = String(remainder.dropFirst(6)) }
        else { cleaned = remainder }
        let query = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 500 else { return nil }
        return Self(query: query, open: lowered.hasPrefix("открой ") || lowered.hasPrefix("open "))
    }
}

public struct AssistantNoteTarget: Codable, Equatable, Identifiable, Sendable {
    public var kind: String
    public var noteID: String
    public var title: String
    public var excerpt: String
    public var revision: UInt64
    public var sourceFingerprint: String
    public var id: String { noteID }
}
public struct AssistantNoteResponse: Codable, Equatable, Sendable {
    public var state: String
    public var targets: [AssistantNoteTarget]
    public var matching: Int
    public var truncated: Bool
}

/// Native, read-only task navigation. These types never authorize a mutation
/// or turn source text into an executable tool call.
public struct AssistantReadPlan: Codable, Equatable, Sendable {
    public enum FollowUp: Equatable, Sendable {
        case only
        case index(Int)
    }
    /// Only explicit, short references are resolved from the visible result
    /// list. Anything more complex returns to the normal assistant workflow.
    public static func parseFollowUp(_ command: String) -> FollowUp? {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if ["открой её", "открой ее", "открой его", "покажи её", "покажи ее", "открой эту задачу", "open it", "open that task"].contains(value) { return .only }
        let numbers = ["первую": 0, "первый": 0, "вторую": 1, "второй": 1,
                       "третью": 2, "третий": 2, "first": 0, "second": 1, "third": 2]
        if let index = numbers[value] { return .index(index) }
        for prefix in ["открой ", "покажи ", "open ", "show "] where value.hasPrefix(prefix) {
            if let index = numbers[String(value.dropFirst(prefix.count))] { return .index(index) }
        }
        return nil
    }
    public enum Intent: String, Codable, Sendable { case find, open, inspect }
    public enum EntityKind: String, Codable, Sendable { case task }
    public struct Selector: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case search, latestCreated, dueRange }
        public var type: Kind
        public var query: String?
        public var startDate: String?
        public var endDateExclusive: String?
    }
    public struct Scope: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable { case library, folder, project }
        public var mode: Mode
        public var folderID: String?
        public var projectID: String?
        public init(folderID: String? = nil, projectID: String? = nil) {
            mode = folderID != nil ? .folder : projectID != nil ? .project : .library
            self.folderID = folderID; self.projectID = projectID
        }
    }
    public struct Clock: Codable, Equatable, Sendable {
        public var queryNow: Double
        public var timeZoneID: String
    }
    public var intent: Intent
    public var entityKind: EntityKind = .task
    public var selector: Selector
    public var scope: Scope
    public var clock: Clock

    /// Recognize only unambiguous find/open commands. Questions about task
    /// contents, advice and edits stay with the existing assistant workflow.
    public static func parse(_ command: String, scope: Scope, now: Date = Date(),
                             timeZone: TimeZone = .current) -> Self? {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let latest = [
            "открой последнюю задачу", "покажи последнюю задачу", "найди последнюю задачу",
            "open the latest task", "open latest task", "find latest task",
            "show latest task", "open last task", "find last task"
        ]
        let latestDetails = ["что в последней задаче", "что там в последней задаче",
                             "что в последней таске", "что там в последней таске",
                             "что агент сделал в последней задаче", "что сделал агент в последней задаче",
                             "что агент сделал в последней таске", "что сделал агент в последней таске",
                             "what is in the latest task", "what is in the last task"]
        let isOpen = value.hasPrefix("открой ") || value.hasPrefix("open ")
        let clock = Clock(queryNow: now.timeIntervalSince1970, timeZoneID: timeZone.identifier)
        if latestDetails.contains(value) {
            return Self(intent: .inspect, selector: Selector(type: .latestCreated), scope: scope, clock: clock)
        }
        if latest.contains(value) {
            return Self(intent: isOpen ? .open : .find,
                        selector: Selector(type: .latestCreated), scope: scope, clock: clock)
        }
        let prefixes = ["найди задачи ", "найди задачу ", "покажи задачи ", "покажи задачу ",
                        "открой задачу ", "открой задачи ", "find tasks ", "find task ",
                        "show tasks ", "show task ", "open tasks ", "open task "]
        guard let prefix = prefixes.first(where: { value.hasPrefix($0) }) else { return nil }
        let query = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 500 else { return nil }
        if ["на сегодня", "сегодня", "due today", "for today", "today"].contains(query) {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            func day(_ date: Date) -> String {
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            }
            return Self(intent: isOpen ? .open : .find,
                        selector: Selector(type: .dueRange, startDate: day(start), endDateExclusive: day(end)),
                        scope: scope, clock: clock)
        }
        // A relative/latest phrase we did not parse must not become a title
        // search and silently open an unrelated task.
        let selectors = ["последн", "вчера", "завтра", "latest", "last ", "yesterday", "tomorrow"]
        guard !selectors.contains(where: { query.contains($0) }) else { return nil }
        return Self(intent: isOpen ? .open : .find,
                    selector: Selector(type: .search, query: query), scope: scope, clock: clock)
    }
}

public struct AssistantReadTarget: Codable, Equatable, Identifiable, Sendable {
    public struct Report: Codable, Equatable, Sendable {
        public struct Artifact: Codable, Equatable, Identifiable, Sendable {
            public var id: String
            public var title: String
        }
        public var eventID: String?
        public var actor: String?
        public var createdAt: Double
        public var text: String
        public var textTruncated: Bool
        public var artifacts: [Artifact]
        public var artifactsTruncated: Bool
    }
    public var kind: String
    public var taskID: String
    public var title: String
    public var detail: String
    public var revision: UInt64
    public var sourceFingerprint: String
    public var contextVersion: String
    public var createdAt: Double?
    public var creationProvenance: String?
    public var due: String?
    public var recentHistory: [String]?
    public var historyFingerprint: String?
    public var latestReport: Report?
    public var id: String { taskID }
}

public struct AssistantReadResponse: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case results, clarify, notFound, unavailable }
    public struct Coverage: Codable, Equatable, Sendable {
        public var matching: Int
        public var returned: Int
        public var unknownCreation: Int
        public var unknownDue: Int
    }
    public var state: State
    public var selectionExplanation: String
    public var targets: [AssistantReadTarget]
    public var coverage: Coverage
    public var warnings: [String]
    public var truncated: Bool
    public var asOf: Double
    public var plan: AssistantReadPlan
}
