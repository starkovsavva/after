import Foundation

public enum TaskWorkspaceStatus: String, Codable, CaseIterable, Identifiable {
    case todo, doing, blocked, done
    public var id: String { rawValue }
    public var title: String {
        switch self { case .todo: return "К выполнению"; case .doing: return "В работе"; case .blocked: return "Заблокировано"; case .done: return "Готово" }
    }
    public var symbol: String {
        switch self { case .todo: return "circle"; case .doing: return "circle.lefthalf.filled"; case .blocked: return "pause.circle"; case .done: return "checkmark.circle.fill" }
    }
}

public enum TaskWorkspaceSource: String, Codable, CaseIterable, Identifiable {
    case local, manual, yandex, google
    public var id: String { rawValue }
    public var title: String {
        switch self { case .local: return "После"; case .manual: return "По внешней ссылке"; case .yandex: return "Яндекс Трекер"; case .google: return "Google Tasks" }
    }
    public var symbol: String { self == .local ? "checklist" : "link" }
}

public struct TaskAgentAccess: Codable, Hashable {
    public var enabled: Bool
    public init(enabled: Bool = false) { self.enabled = enabled }
}

/// A reference to an explicitly selected item. Folder/repository paths never
/// imply access to their files and are not enumerated by the workspace UI.
public struct TaskMaterial: Codable, Identifiable, Hashable {
    public var id: String?
    public var kind: String
    public var title: String
    public var noteID: String?
    public var meetingID: String?
    public var segmentIDs: [Int]
    public var attachmentID: String?
    public var path: String?
    public var url: String?
    public var text: String?
    public var shared: Bool
    public var available: Bool?
    public var createdAt: Double?
    public init(id: String? = nil, kind: String, title: String, noteID: String? = nil,
                meetingID: String? = nil, segmentIDs: [Int] = [], attachmentID: String? = nil,
                path: String? = nil, url: String? = nil, text: String? = nil, shared: Bool = false,
                available: Bool? = nil, createdAt: Double? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.noteID = noteID
        self.meetingID = meetingID; self.segmentIDs = segmentIDs; self.attachmentID = attachmentID
        self.path = path; self.url = url; self.text = text; self.shared = shared
        self.available = available; self.createdAt = createdAt
    }
    public var displayText: String? {
        guard kind == "meeting", let text, let data = text.data(using: .utf8),
              let segments = try? JSONDecoder().decode([TaskExcerptSegment].self, from: data) else { return self.text }
        return segments.map { segment in
            let seconds = max(0, Int(segment.start ?? 0))
            return String(format: "%02d:%02d  %@", seconds / 60, seconds % 60, segment.text)
        }.joined(separator: "\n")
    }
    public var isWorkspace: Bool { kind == "folder" || kind == "repository" }
    public var symbol: String {
        switch kind { case "meeting": return "waveform"; case "file": return "doc"; case "folder": return "folder"; case "repository": return "folder.badge.gearshape"; case "link": return "link"; default: return "note.text" }
    }
}

private struct TaskExcerptSegment: Decodable { let start: Double?; let text: String }

public struct TaskArtifact: Codable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var kind: String
    public var text: String
    public var url: String?
    public var symbol: String { kind == "changes" ? "arrow.triangle.branch" : kind == "snapshot" ? "shippingbox" : "doc.text" }
}

/// Snapshot fields are intentionally optional for older entries. The frozen
/// context is presented as recorded; it is never silently regenerated.
public struct TaskSnapshotDetails: Codable, Hashable {
    public var id: String
    public var title: String
    public var text: String
    public var status: TaskWorkspaceStatus
    public var owner: String
    public var due: String
    public var project: String
    public var revision: Int
}
public struct TaskContextSnapshot: Codable, Hashable {
    public var task: TaskSnapshotDetails
    public var materials: [TaskMaterial]
    public var contextVersion: String
    public var generatedAt: Double
    public var truncated: Bool
}

public struct TaskWorkspaceEvent: Codable, Identifiable, Hashable {
    public var id: String
    public var kind: String
    public var text: String
    public var actor: String
    public var createdAt: Double
    public var artifacts: [TaskArtifact]
    public var snapshot: TaskContextSnapshot?
    public var symbol: String {
        switch kind { case "claimed", "claim": return "person.crop.circle.badge.checkmark"; case "report", "result": return "doc.badge.checkmark"; case "status": return "checkmark.circle"; case "material", "material-linked": return "paperclip"; default: return "clock" }
    }
}

public struct TaskWorkspace: Codable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var text: String
    public var status: TaskWorkspaceStatus
    public var completed: Bool
    public var owner: String
    public var due: String
    public var source: TaskWorkspaceSource
    public var externalURL: String
    public var project: String
    public var revision: Int
    public var createdAt: Double
    public var updatedAt: Double
    public var virtual: Bool
    public var sourceFingerprint: String
    public var meetingID: String?
    public var materials: [TaskMaterial]
    public var materialCount: Int?
    public var historyCount: Int?
    public var history: [TaskWorkspaceEvent]
    public var agentAccess: TaskAgentAccess
    public init(id: String, title: String, text: String = "", status: TaskWorkspaceStatus = .todo,
                completed: Bool = false, owner: String = "", due: String = "", source: TaskWorkspaceSource = .local,
                externalURL: String = "", project: String = "", revision: Int = 0, createdAt: Double = 0,
                updatedAt: Double = 0, virtual: Bool = false, sourceFingerprint: String = "", meetingID: String? = nil,
                materials: [TaskMaterial] = [], materialCount: Int? = nil, historyCount: Int? = nil, history: [TaskWorkspaceEvent] = [], agentAccess: TaskAgentAccess = .init()) {
        self.id = id; self.title = title; self.text = text; self.status = status; self.completed = completed
        self.owner = owner; self.due = due; self.source = source; self.externalURL = externalURL
        self.project = project; self.revision = revision; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.virtual = virtual; self.sourceFingerprint = sourceFingerprint; self.meetingID = meetingID; self.materials = materials; self.materialCount = materialCount; self.historyCount = historyCount; self.history = history
        self.agentAccess = agentAccess
    }
}
public struct TaskWorkspacesResponse: Decodable {
    public var tasks: [TaskWorkspace]
    public var warnings: [String]
}
