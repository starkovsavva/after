import Foundation

/// A read-only answer references immutable source snapshots. Citation IDs are
/// opaque keys; navigation uses typed local IDs only after Rust validation.
public struct KnowledgeAnswer: Codable, Hashable {
    public var title: String
    public var paragraphs: [KnowledgeParagraph]
    public var sources: [KnowledgeSource]
    public var warnings: [String]
    public var truncated: Bool
    public init(title: String, paragraphs: [KnowledgeParagraph], sources: [KnowledgeSource], warnings: [String] = [], truncated: Bool = false) {
        self.title = title; self.paragraphs = paragraphs; self.sources = sources
        self.warnings = warnings; self.truncated = truncated
    }
}

public struct KnowledgeParagraph: Codable, Hashable {
    public var text: String
    public var sourceIDs: [String]
    public init(text: String, sourceIDs: [String] = []) { self.text = text; self.sourceIDs = sourceIDs }
}

public struct KnowledgeSource: Codable, Hashable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var excerpt: String
    public var taskID: String?
    public var noteID: String?
    public var meetingID: String?
    public var segmentID: Int?
    public var itemIndex: Int?
    public var cardID: String?
    public var eventID: String?
    public var sourceFingerprint: String
    public init(id: String, kind: String, title: String, excerpt: String, taskID: String? = nil,
                noteID: String? = nil, meetingID: String? = nil, segmentID: Int? = nil,
                itemIndex: Int? = nil, cardID: String? = nil, eventID: String? = nil,
                sourceFingerprint: String) {
        self.id = id; self.kind = kind; self.title = title; self.excerpt = excerpt
        self.taskID = taskID; self.noteID = noteID; self.meetingID = meetingID
        self.segmentID = segmentID; self.itemIndex = itemIndex; self.cardID = cardID
        self.eventID = eventID; self.sourceFingerprint = sourceFingerprint
    }
}

public struct KnowledgeCalendarEvent: Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var start: Double
    public var end: Double
    public var allDay: Bool
    public var calendarTitle: String
    public var startOffsetMinutes: Int?
    public var endOffsetMinutes: Int?
    public init(id: String, title: String, start: Double, end: Double, allDay: Bool, calendarTitle: String,
                startOffsetMinutes: Int? = nil, endOffsetMinutes: Int? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.allDay = allDay; self.calendarTitle = calendarTitle
        self.startOffsetMinutes = startOffsetMinutes; self.endOffsetMinutes = endOffsetMinutes
    }
}

public struct KnowledgeCalendarSnapshot: Codable, Hashable {
    public var connected: Bool
    public var coverageStart: Double
    public var coverageEnd: Double
    public var events: [KnowledgeCalendarEvent]
    public var truncated: Bool
    public var requestedStart: Double?
    public var requestedEnd: Double?
    public init(connected: Bool, coverageStart: Double, coverageEnd: Double, events: [KnowledgeCalendarEvent], truncated: Bool = false,
                requestedStart: Double? = nil, requestedEnd: Double? = nil) {
        self.connected = connected; self.coverageStart = coverageStart; self.coverageEnd = coverageEnd
        self.events = events; self.truncated = truncated
        self.requestedStart = requestedStart; self.requestedEnd = requestedEnd
    }
}
