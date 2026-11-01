import Foundation

/// Values shared by the worker, review UI, and transactional knowledge API.
/// References always identify either a persisted note or a proposed new note;
/// the backend validates the exclusive choice and the captured source versions.
public struct KnowledgeRebuildReference: Codable, Equatable, Hashable, Sendable {
    public var noteID: String?
    public var draftKey: String?
    public init(noteID: String? = nil, draftKey: String? = nil) { self.noteID = noteID; self.draftKey = draftKey }
}

public struct KnowledgeRebuildEdit: Codable, Equatable, Identifiable, Sendable {
    public var noteID: String
    public var title: String
    public var text: String
    public var id: String { noteID }
    public init(noteID: String, title: String, text: String) { self.noteID = noteID; self.title = title; self.text = text }
}

public struct KnowledgeRebuildNewNote: Codable, Equatable, Identifiable, Sendable {
    public var key: String
    public var title: String
    public var text: String
    public var sourceNoteIDs: [String]
    public var id: String { key }
    public init(key: String, title: String, text: String, sourceNoteIDs: [String]) {
        self.key = key; self.title = title; self.text = text; self.sourceNoteIDs = sourceNoteIDs
    }
}

public struct KnowledgeRebuildCollection: Codable, Equatable, Identifiable, Sendable {
    public var key: String
    public var name: String
    public var members: [KnowledgeRebuildReference]
    public var id: String { key }
    public init(key: String, name: String, members: [KnowledgeRebuildReference]) {
        self.key = key; self.name = name; self.members = members
    }
}

public struct KnowledgeRebuildLink: Codable, Equatable, Sendable {
    public var from: KnowledgeRebuildReference
    public var to: KnowledgeRebuildReference
    public init(from: KnowledgeRebuildReference, to: KnowledgeRebuildReference) { self.from = from; self.to = to }
}

public struct KnowledgeRebuildProposal: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var edits: [KnowledgeRebuildEdit]
    public var newNotes: [KnowledgeRebuildNewNote]
    public var collections: [KnowledgeRebuildCollection]
    public var links: [KnowledgeRebuildLink]
    public init(title: String, summary: String, edits: [KnowledgeRebuildEdit] = [],
                newNotes: [KnowledgeRebuildNewNote] = [], collections: [KnowledgeRebuildCollection] = [],
                links: [KnowledgeRebuildLink] = []) {
        self.title = title; self.summary = summary; self.edits = edits; self.newNotes = newNotes
        self.collections = collections; self.links = links
    }
    public var hasChanges: Bool { !edits.isEmpty || !newNotes.isEmpty || !collections.isEmpty || !links.isEmpty }
}

public struct KnowledgeRebuildBeforeEdit: Codable, Equatable, Identifiable, Sendable {
    public var noteID: String
    public var title: String
    public var text: String
    public var revision: UInt64
    public var id: String { noteID }
}

public struct KnowledgeRebuildPreview: Codable, Equatable, Sendable {
    public var draftID: String
    public var draftRevision: UInt64
    public var libraryID: String
    public var proposalHash: String
    public var proposal: KnowledgeRebuildProposal
    public var beforeEdits: [KnowledgeRebuildBeforeEdit]
}

public struct KnowledgeRebuildPrepared: Codable, Sendable {
    public struct Note: Codable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var text: String
        public var revision: UInt64
    }
    public var draftID: String
    public var draftRevision: UInt64
    public var libraryID: String
    public var instruction: String
    public var folderID: String?
    public var notes: [Note]
    public var createdAt: Double
}

public struct KnowledgeRebuildReceipt: Codable, Sendable {
    public struct CreatedNote: Codable, Sendable { public var key: String; public var noteID: String }
    public var operationID: String
    public var draftID: String
    public var workspaceRevision: UInt64
    public var kbRevision: UInt64
    public var editedNoteIDs: [String]
    public var createdNotes: [CreatedNote]
    public var collectionIDs: [String]
    public var linkIDs: [String]
    public var undone: Bool
}

public struct KnowledgeRebuildHistory: Codable, Sendable {
    public struct Operation: Codable, Identifiable, Sendable {
        public var operationID: String
        public var title: String
        public var summary: String
        public var appliedAt: Double
        public var undoneAt: Double?
        public var createdNoteIDs: [String]
        public var editedNoteIDs: [String]
        public var canUndo: Bool
        public var id: String { operationID }
    }
    public var operations: [Operation]
}
