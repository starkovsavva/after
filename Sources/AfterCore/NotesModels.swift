import Foundation

public struct NoteAttachment: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var relativePath: String
    public var contentType: String
    public var extractedText: String
    public init(id: String, name: String, relativePath: String, contentType: String, extractedText: String = "") {
        self.id = id; self.name = name; self.relativePath = relativePath
        self.contentType = contentType; self.extractedText = extractedText
    }
}
public struct NoteExpansionStatement: Codable, Hashable {
    public var text: String
    public var segmentIDs: [Int]
    public init(text: String, segmentIDs: [Int]) { self.text = text; self.segmentIDs = segmentIDs }
}
public struct NoteExpansion: Codable, Hashable {
    public var statements: [NoteExpansionStatement]
    public var openQuestions: [String]
    public var generatedAt: Double
    public var provider: String
    public var model: String
    public var warnings: [String]
    public var sourceFingerprint: String
    public init(statements: [NoteExpansionStatement], openQuestions: [String] = [], generatedAt: Double,
                provider: String, model: String, warnings: [String] = [], sourceFingerprint: String) {
        self.statements = statements; self.openQuestions = openQuestions; self.generatedAt = generatedAt
        self.provider = provider; self.model = model; self.warnings = warnings; self.sourceFingerprint = sourceFingerprint
    }
}
public struct TaskOrigin: Codable, Hashable {
    public var meetingID: String
    public var itemSignature: String
    public var sourceText: String
    public var segmentIDs: [Int]
    public var summaryTaskID: String
}
public struct TaskHistory: Codable, Identifiable, Hashable {
    public var id: String
    public var operationID: String
    public var text: String
    public var createdAt: Double
}
public struct TaskSubtask: Codable, Identifiable, Hashable {
    public var id: String
    public var text: String
    public var completed: Bool
    public init(id: String = UUID().uuidString.lowercased(), text: String, completed: Bool = false) {
        self.id = id; self.text = text; self.completed = completed
    }
}
public struct CapturedNote: Codable, Identifiable, Hashable {
    public var id: String
    public var text: String
    public var kind: String
    public var meetingID: String?
    public var timestamp: Double?
    public var createdAt: Double
    public var updatedAt: Double
    public var revision: Int
    public var sourceURL: String
    public var owner: String
    public var due: String
    public var completed: Bool
    public var attachments: [NoteAttachment]
    public var expansion: NoteExpansion?
    public var title: String
    public var contentRTF: String
    public var folder: String
    public var folderID: String?
    public var tags: [String]
    public var pinned: Bool
    public var trashedAt: Double?
    public var taskOrigin: TaskOrigin?
    public var history: [TaskHistory]
    public var subtasks: [TaskSubtask]
    public init(id: String = UUID().uuidString.lowercased(), text: String = "", kind: String = "note",
                meetingID: String? = nil, timestamp: Double? = nil, createdAt: Double = Date().timeIntervalSince1970,
                updatedAt: Double = Date().timeIntervalSince1970, revision: Int = 0, sourceURL: String = "",
                owner: String = "", due: String = "", completed: Bool = false,
                attachments: [NoteAttachment] = [], expansion: NoteExpansion? = nil, title: String = "", contentRTF: String = "", folder: String = "", folderID: String? = nil, tags: [String] = [], pinned: Bool = false, trashedAt: Double? = nil, taskOrigin: TaskOrigin? = nil, history: [TaskHistory] = [], subtasks: [TaskSubtask] = []) {
        self.id = id; self.text = text; self.kind = kind; self.meetingID = meetingID; self.timestamp = timestamp
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.revision = revision; self.sourceURL = sourceURL
        self.owner = owner; self.due = due; self.completed = completed; self.attachments = attachments; self.expansion = expansion
        self.title = title; self.contentRTF = contentRTF; self.folder = folder; self.folderID = folderID; self.tags = tags; self.pinned = pinned; self.trashedAt = trashedAt; self.taskOrigin = taskOrigin; self.history = history; self.subtasks = subtasks
    }
    public var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (text.split(separator: "\n").first.map(String.init) ?? "Новая заметка") : title }
    private enum CodingKeys: String, CodingKey {
        case id, text, kind, meetingID, timestamp, createdAt, updatedAt, revision, sourceURL, owner, due, completed, attachments, expansion
        case title, contentRTF, folder, folderID, tags, pinned, trashedAt, taskOrigin, history, subtasks
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "note"
        meetingID = try c.decodeIfPresent(String.self, forKey: .meetingID)
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp)
        createdAt = try c.decode(Double.self, forKey: .createdAt); updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""; due = try c.decodeIfPresent(String.self, forKey: .due) ?? ""
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        attachments = try c.decodeIfPresent([NoteAttachment].self, forKey: .attachments) ?? []
        expansion = try c.decodeIfPresent(NoteExpansion.self, forKey: .expansion)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        contentRTF = try c.decodeIfPresent(String.self, forKey: .contentRTF) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        folderID = try c.decodeIfPresent(String.self, forKey: .folderID)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        trashedAt = try c.decodeIfPresent(Double.self, forKey: .trashedAt)
        taskOrigin = try c.decodeIfPresent(TaskOrigin.self, forKey: .taskOrigin)
        history = try c.decodeIfPresent([TaskHistory].self, forKey: .history) ?? []
        subtasks = try c.decodeIfPresent([TaskSubtask].self, forKey: .subtasks) ?? []
    }
}
public struct NoteTemplate: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var body: String
    public var focus: String
    public var revision: Int
    public init(id: String = UUID().uuidString.lowercased(), name: String, body: String = "", focus: String = "", revision: Int = 0) {
        self.id = id; self.name = name; self.body = body; self.focus = focus; self.revision = revision
    }
}
public struct MeetingContext: Codable, Identifiable, Hashable {
    public var meetingID: String
    public var project: String
    public var folderID: String?
    public var person: String
    public var templateID: String?
    public var revision: Int
    public var id: String { meetingID }
    public init(meetingID: String, folderID: String? = nil, project: String = "", person: String = "", templateID: String? = nil, revision: Int = 0) {
        self.meetingID = meetingID; self.folderID = folderID; self.project = project; self.person = person; self.templateID = templateID; self.revision = revision
    }
}
public struct NotesWorkspace: Codable, Equatable {
    public var notes: [CapturedNote]
    public var templates: [NoteTemplate]
    public var contexts: [MeetingContext]
    public var folders: [LibraryFolder]
    public init(notes: [CapturedNote] = [], templates: [NoteTemplate] = [], contexts: [MeetingContext] = [], folders: [LibraryFolder] = []) {
        self.notes = notes; self.templates = templates; self.contexts = contexts; self.folders = folders
    }
    private enum CodingKeys: String, CodingKey { case notes, templates, contexts, folders }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = try c.decodeIfPresent([CapturedNote].self, forKey: .notes) ?? []
        templates = try c.decodeIfPresent([NoteTemplate].self, forKey: .templates) ?? []
        contexts = try c.decodeIfPresent([MeetingContext].self, forKey: .contexts) ?? []
        folders = try c.decodeIfPresent([LibraryFolder].self, forKey: .folders) ?? []
    }
}

public struct LibraryTask: Codable, Identifiable, Hashable {
    public var id: String
    public var meetingID: String?
    public var title: String
    public var text: String
    public var owner: String
    public var due: String
    public var completed: Bool
    public var segmentIDs: [Int]
    public var itemIndex: Int?
    public var noteID: String?
    public var noteRevision: Int?
    public var taskTitle: String?
    public var taskOrigin: TaskOrigin?
    public var history: [TaskHistory]?
    public var subtasks: [TaskSubtask]?
    public var timestamp: Double?
}
public struct LibraryTasksResponse: Decodable { public var tasks: [LibraryTask] }
