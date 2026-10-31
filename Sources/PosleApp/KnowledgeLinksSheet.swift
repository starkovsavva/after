import Foundation
import PosleCore
import SwiftUI

private struct KnowledgeLink: Codable, Identifiable, Equatable {
    let id: String
    let fromID: String
    let toID: String
    let relation: String
    let revision: UInt64
}
private struct KnowledgeLinksSnapshot: Decodable {
    let libraryID: String
    let workspaceRevision: UInt64
    let kbRevision: UInt64
    let links: [KnowledgeLink]
}
private struct KnowledgeLinkMutation: Decodable {
    let operationID: String
}
private struct KnowledgeSuggestion: Decodable, Identifiable {
    let noteID: String
    let revision: UInt64
    let sharedTerms: [String]
    let method: String?
    var id: String { noteID }
}
private struct KnowledgeSuggestions: Decodable {
    let workspaceRevision: UInt64
    let kbRevision: UInt64
    let items: [KnowledgeSuggestion]
    let partial: Bool
}

/// A sheet owns one request generation. Late results cannot replace a newer
/// selection, and every write uses the canonical workspace and note revisions.
@MainActor
private final class KnowledgeLinksController: ObservableObject {
    @Published private(set) var snapshot: KnowledgeLinksSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var lastOperationID: String?
    @Published private(set) var suggestions: [KnowledgeSuggestion] = []
    @Published private(set) var findingSuggestions = false
    @Published private(set) var suggestionsPartial = false
    @Published private(set) var suggestionsUnavailable = false
    private let root: URL
    private let sourceID: String
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    init(root: URL, sourceID: String) { self.root = root; self.sourceID = sourceID }

    private static func request(root: URL, command: String, arguments: [String: Any]) async throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try await Task.detached(priority: .userInitiated) {
            guard let object = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
                throw AppError.message(L("Не удалось подготовить запрос."))
            }
            return try RustBridge.shared.get().request(root: root, command: command, arguments: object)
        }.value
    }
    func refresh() {
        guard !busy else { return }
        cancelSuggestions()
        generation = UUID(); let current = generation, root = root, id = sourceID
        busy = true; error = nil
        task = Task {
            do {
                let data = try await Self.request(root: root, command: "kb-snapshot", arguments: ["noteID":id])
                let value = try JSONDecoder().decode(KnowledgeLinksSnapshot.self, from: data)
                guard current == generation, !Task.isCancelled else { return }
                snapshot = value; busy = false; findSuggestions(for: value, generation: current)
            } catch {
                guard current == generation else { return }
                busy = false; self.error = error.localizedDescription
            }
        }
    }
    func change(from: CapturedNote, to: CapturedNote, action: String) {
        guard !busy, let snapshot else { return }
        let operation = UUID().uuidString.lowercased()
        let input: [String: Any] = ["operationID":operation, "expectedWorkspaceRevision":snapshot.workspaceRevision,
            "expectedKBRevision":snapshot.kbRevision, "expectedFromRevision":from.revision,
            "expectedToRevision":to.revision, "fromID":from.id, "toID":to.id, "action":action]
        perform("kb-link-change", input: input, keepUndo: true)
    }
    func undo() {
        guard !busy, let snapshot, let original = lastOperationID else { return }
        let input: [String: Any] = ["operationID":UUID().uuidString.lowercased(), "targetOperationID":original,
            "expectedWorkspaceRevision":snapshot.workspaceRevision, "expectedKBRevision":snapshot.kbRevision]
        perform("kb-undo", input: input, keepUndo: false)
    }
    func block(from: CapturedNote, to: CapturedNote) {
        guard !busy, let snapshot else { return }
        let input: [String: Any] = ["operationID":UUID().uuidString.lowercased(),
            "expectedWorkspaceRevision":snapshot.workspaceRevision, "expectedKBRevision":snapshot.kbRevision,
            "expectedFromRevision":from.revision, "expectedToRevision":to.revision,
            "fromID":from.id, "toID":to.id, "blocked":true]
        perform("kb-feedback-change", input: input, keepUndo: true)
    }
    private func perform(_ command: String, input: [String: Any], keepUndo: Bool) {
        cancelSuggestions()
        generation = UUID(); let current = generation, root = root, id = sourceID
        busy = true; error = nil
        task = Task {
            var committed = false
            do {
                let data = try await Self.request(root: root, command: command, arguments: input)
                let mutation = try JSONDecoder().decode(KnowledgeLinkMutation.self, from: data)
                guard current == generation, !Task.isCancelled else { return }
                committed = true
                lastOperationID = keepUndo ? mutation.operationID : nil
                let refreshed = try await Self.request(root: root, command: "kb-snapshot", arguments: ["noteID":id])
                let value = try JSONDecoder().decode(KnowledgeLinksSnapshot.self, from: refreshed)
                guard current == generation, !Task.isCancelled else { return }
                snapshot = value; busy = false; findSuggestions(for: value, generation: current)
            } catch {
                guard current == generation else { return }
                busy = false
                self.error = committed ? L("Действие сохранено, но список не обновился. Обновите его.") : error.localizedDescription
            }
        }
    }
    private func findSuggestions(for snapshot: KnowledgeLinksSnapshot, generation current: UUID) {
        let root = root, id = sourceID
        findingSuggestions = true
        suggestionTask = Task {
            do {
                let data = try await Self.request(root: root, command: "kb-suggestions",
                    arguments: ["noteID":id, "expectedWorkspaceRevision":snapshot.workspaceRevision,
                                "expectedKBRevision":snapshot.kbRevision])
                let value = try JSONDecoder().decode(KnowledgeSuggestions.self, from: data)
                guard current == generation, !Task.isCancelled else { return }
                guard value.workspaceRevision == snapshot.workspaceRevision, value.kbRevision == snapshot.kbRevision else {
                    findingSuggestions = false; suggestionsUnavailable = true; return
                }
                suggestions = value.items; suggestionsPartial = value.partial; findingSuggestions = false
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                // Manual links stay available if the library changed during the
                // optional analysis. A refresh starts from a fresh snapshot.
                suggestions = []; findingSuggestions = false; suggestionsUnavailable = true
            }
        }
    }
    private func cancelSuggestions() {
        suggestionTask?.cancel(); suggestionTask = nil
        suggestions = []; suggestionsPartial = false; findingSuggestions = false; suggestionsUnavailable = false
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; cancelSuggestions() }
}

struct KnowledgeLinksSheet: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var notes: NotesStore
    let source: CapturedNote
    @StateObject private var controller: KnowledgeLinksController
    @State private var query = ""
    init(notes: NotesStore, source: CapturedNote) {
        self.notes = notes; self.source = source
        _controller = StateObject(wrappedValue: KnowledgeLinksController(root: notes.root, sourceID: source.id))
    }
    private func available(_ note: CapturedNote) -> Bool {
        note.kind == "note" && note.trashedAt == nil &&
            app.effectiveSettings(for: note.folderID == nil ? note.meetingID : nil,
                                  folderID: note.folderID).features.knowledgeBase
    }
    private var current: CapturedNote? { notes.workspace.notes.first { $0.id == source.id && available($0) } }
    private var candidates: [CapturedNote] {
        let existing = Set((controller.snapshot?.links ?? []).filter { $0.fromID == source.id }.map(\.toID))
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.workspace.notes.filter {
            $0.id != source.id && available($0) && !existing.contains($0.id) &&
            (text.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(text) || $0.text.localizedCaseInsensitiveContains(text))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Связи заметки")).font(AppTypography.heading)
                    Text(source.displayTitle).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if controller.busy { ProgressView().controlSize(.small) }
                Button(L("Готово")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(controller.busy)
            }
            if let error = controller.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Ink.warning)
                    Spacer()
                    Button(L("Обновить")) { notes.reload(); controller.refresh() }.disabled(controller.busy)
                }.font(AppTypography.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Связанные заметки")).font(AppTypography.controlStrong)
                    if let snapshot = controller.snapshot, snapshot.links.isEmpty {
                        Text(L("Связей пока нет.")).font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                    ForEach(controller.snapshot?.links ?? []) { link in
                        let otherID = link.fromID == source.id ? link.toID : link.fromID
                        if let other = notes.workspace.notes.first(where: { $0.id == otherID && available($0) }) {
                            HStack {
                                Button {
                                    notes.selectedNoteID = other.id; dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(other.displayTitle).lineLimit(1)
                                        Text(link.fromID == source.id ? L("Ссылка из этой заметки") : L("Ссылается на эту заметку"))
                                            .font(AppTypography.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                    .accessibilityIdentifier("knowledge.links.navigate.\(other.id)")
                                Button {
                                    guard let source = current else { return }
                                    controller.change(from: link.fromID == source.id ? source : other,
                                                      to: link.toID == source.id ? source : other, action: "remove")
                                } label: { Image(systemName: "xmark") }
                                    .help(L("Удалить связь")).accessibilityLabel(L("Удалить связь"))
                                    .disabled(controller.busy)
                                    .accessibilityIdentifier("knowledge.links.remove.\(link.id)")
                            }.padding(8).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if controller.findingSuggestions {
                        HStack { ProgressView().controlSize(.small); Text(L("Ищу связанные заметки…")) }
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                    } else if controller.suggestionsUnavailable {
                        HStack {
                            Text(L("Не удалось обновить подсказки.")).font(AppTypography.caption).foregroundStyle(.secondary)
                            Button(L("Обновить")) { notes.reload(); controller.refresh() }.disabled(controller.busy)
                        }
                    } else if !controller.suggestions.isEmpty {
                        Divider()
                        Text(L("Возможно связаны")).font(AppTypography.controlStrong)
                        Text(L("Подсказки подобраны по общим словам и доступному смысловому индексу."))
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                        ForEach(controller.suggestions) { suggestion in
                            if let other = notes.workspace.notes.first(where: {
                                $0.id == suggestion.noteID && $0.revision == Int(suggestion.revision) && available($0)
                            }) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(other.displayTitle).font(AppTypography.controlStrong).lineLimit(2)
                                    if suggestion.method == "semantic" {
                                        Text(L("Возможная смысловая близость по индексу · экспериментально"))
                                            .font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2)
                                    } else {
                                        Text(LF("Общие слова: {0}", arguments: [suggestion.sharedTerms.joined(separator: ", ")]))
                                            .font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    HStack {
                                        Button(L("Связать")) {
                                            guard let source = current else { return }
                                            controller.change(from: source, to: other, action: "add")
                                        }.disabled(controller.busy)
                                            .accessibilityIdentifier("knowledge.suggestion.accept.\(other.id)")
                                        Button(L("Не связывать")) {
                                            guard let source = current else { return }
                                            controller.block(from: source, to: other)
                                        }.buttonStyle(.borderless).disabled(controller.busy)
                                            .accessibilityIdentifier("knowledge.suggestion.block.\(other.id)")
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    if controller.suggestionsPartial {
                        Text(L("Проверены не все заметки.")).font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                    KnowledgeMeetingSourcesView(source: source) { notes.reload(); controller.refresh() }
                    Divider()
                    Text(L("Связать с заметкой")).font(AppTypography.controlStrong)
                    TextField(L("Найти заметку"), text: $query).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("knowledge.links.search")
                    ForEach(Array(candidates.prefix(50))) { other in
                        HStack {
                            Text(other.displayTitle).lineLimit(1); Spacer()
                            Button(L("Связать")) {
                                guard let source = current else { return }
                                controller.change(from: source, to: other, action: "add")
                            }.disabled(controller.busy || controller.snapshot == nil)
                                .accessibilityIdentifier("knowledge.links.add.\(other.id)")
                        }.padding(.vertical, 5)
                    }
                    if candidates.isEmpty {
                        Text(L("Нет подходящих заметок.")).font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                    if candidates.count > 50 {
                        Text(L("Уточните поиск, чтобы увидеть остальные заметки."))
                            .font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if controller.lastOperationID != nil {
                Button(L("Отменить последнее действие")) { controller.undo() }
                    .buttonStyle(.borderless).disabled(controller.busy)
                    .accessibilityIdentifier("knowledge.links.undo")
            }
        }
        .padding(22).frame(width: 500, height: 620, alignment: .topLeading)
        .background(Ink.paper)
        .interactiveDismissDisabled(controller.busy)
        .onAppear { controller.refresh() }
        .onDisappear { controller.stop() }
    }
}
