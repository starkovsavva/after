import AfterLocalization
import AfterPlatform
import AfterPlatformMacOS
import Combine
import Foundation
import AfterCore

extension Notification.Name {
    static let knowledgeRebuildChanged = Notification.Name("AfterKnowledgeRebuildChanged")
}

@MainActor
final class KnowledgeRebuildController: ObservableObject {
    typealias Progress = @MainActor @Sendable (String) -> Void
    typealias Generate = @MainActor ([String], String?, String, @escaping Progress) async throws -> Data
    typealias Request = @Sendable (URL, String, Data) async throws -> Data
    enum Phase: Equatable { case select, review, finished }
    enum Activity: Equatable { case generate, preview, apply, undo }
    @Published var selectedNoteIDs = Set<String>()
    @Published var instruction = ""
    @Published var proposal: KnowledgeRebuildProposal?
    @Published private(set) var preview: KnowledgeRebuildPreview?
    @Published private(set) var phase = Phase.select
    @Published private(set) var activity: Activity?
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var receipt: KnowledgeRebuildReceipt?
    @Published private(set) var history: [KnowledgeRebuildHistory.Operation] = []
    @Published private(set) var historyLoading = false
    @Published private(set) var historyError: String?
    private(set) var sourceNotes: [String: CapturedNote] = [:]
    private(set) var selectionFolderID: String?
    private(set) var providerDescription = ""
    private let root: URL
    private let generator: Generate
    private let request: Request
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var historyReloadRequested = false
    // Retain this after an uncertain response so retry cannot apply twice.
    private var applyOperationID: String?
    var busy: Bool { activity != nil }
    var mutating: Bool { activity == .apply || activity == .undo }
    var reviewChanged: Bool { proposal != nil && proposal != preview?.proposal }

    init(root: URL, generate: @escaping Generate, request: @escaping Request = KnowledgeRebuildController.liveRequest) {
        self.root = root; self.generator = generate; self.request = request
    }
    nonisolated static func liveRequest(root: URL, command: String, arguments: Data) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard let input = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
                throw AppError.message(L("Не удалось подготовить запрос."))
            }
            return try RustBridge.shared.get().request(root: root, command: command, arguments: input)
        }.value
    }
    private func call(_ command: String, _ arguments: [String: Any] = [:]) async throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try await request(root, command, bytes)
    }
    func generate(notes: [CapturedNote], folderID: String?, provider: String) {
        guard !busy else { return }
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = notes.filter { selectedNoteIDs.contains($0.id) }
        guard (1...30).contains(selected.count), selected.count == selectedNoteIDs.count,
              !instruction.isEmpty, instruction.utf8.count <= 4_000,
              selected.reduce(0, { $0 + $1.title.utf8.count + $1.text.utf8.count }) <= 60_000 else {
            error = L("Выберите от 1 до 30 доступных заметок и сократите поручение или выбранные тексты."); return
        }
        sourceNotes = Dictionary(selected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        selectionFolderID = folderID; providerDescription = provider
        let current = UUID(); generation = current
        activity = .generate; error = nil; receipt = nil; status = L("Готовлю предложение…")
        task = Task { [self] in
            defer { if generation == current { activity = nil; task = nil } }
            do {
                let data = try await generator(selected.map(\.id).sorted(), folderID, instruction) { [weak self] message in
                    guard let self, self.generation == current else { return }; self.status = message
                }
                try Task.checkCancellation()
                guard generation == current else { return }
                let value = try JSONDecoder().decode(KnowledgeRebuildPreview.self, from: data)
                preview = value; proposal = value.proposal; phase = .review; applyOperationID = nil
                status = L("Предложение готово. Проверьте изменения перед применением.")
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                status = ""; self.error = error.localizedDescription
            }
        }
    }
    func validateEdits() {
        guard !busy, let preview, let proposal else { return }
        activity = .preview; error = nil; status = L("Проверяю изменённое предложение…")
        let current = UUID(); generation = current
        task = Task { [self] in
            defer { if generation == current { activity = nil; task = nil } }
            do {
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal))
                let data = try await call("kb-rebuild-preview", ["draftID": preview.draftID,
                    "expectedDraftRevision": preview.draftRevision, "proposal": object])
                try Task.checkCancellation()
                guard generation == current else { return }
                let value = try JSONDecoder().decode(KnowledgeRebuildPreview.self, from: data)
                self.preview = value; self.proposal = value.proposal; applyOperationID = nil
                status = L("Изменения проверены. Теперь их можно применить.")
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                status = ""; self.error = error.localizedDescription
            }
        }
    }
    func apply() {
        guard !busy, !reviewChanged, let preview, preview.proposal.hasChanges else { return }
        let operationID = applyOperationID ?? UUID().uuidString.lowercased(); applyOperationID = operationID
        activity = .apply; error = nil; status = L("Применяю изменения…")
        task = Task { [self] in
            defer { activity = nil; task = nil }
            do {
                let data = try await call("kb-rebuild-apply", ["draftID": preview.draftID,
                    "expectedDraftRevision": preview.draftRevision, "operationID": operationID])
                receipt = try JSONDecoder().decode(KnowledgeRebuildReceipt.self, from: data)
                self.preview = nil; proposal = nil; phase = .finished; selectedNoteIDs.removeAll()
                status = L("Изменения применены. Их можно отменить в истории.")
                NotificationCenter.default.post(name: .knowledgeRebuildChanged, object: root)
                await loadHistory()
            } catch { status = ""; self.error = error.localizedDescription }
        }
    }
    func undo(_ operation: KnowledgeRebuildHistory.Operation) {
        guard !busy, operation.canUndo, operation.undoneAt == nil else { return }
        activity = .undo; error = nil; status = L("Отменяю применение…")
        task = Task { [self] in
            defer { activity = nil; task = nil }
            do {
                let data = try await call("kb-rebuild-undo", ["operationID": operation.operationID])
                receipt = try JSONDecoder().decode(KnowledgeRebuildReceipt.self, from: data)
                status = L("Применение отменено.")
                NotificationCenter.default.post(name: .knowledgeRebuildChanged, object: root)
                await loadHistory()
            } catch { status = ""; self.error = error.localizedDescription; await loadHistory() }
        }
    }
    func loadHistory() async {
        historyReloadRequested = true
        guard !historyLoading else { return }
        historyLoading = true; historyError = nil
        defer { historyLoading = false }
        repeat {
            historyReloadRequested = false
            do {
                let value = try JSONDecoder().decode(KnowledgeRebuildHistory.self,
                    from: await call("kb-rebuild-history")).operations
                // Apply/Undo may have completed during this read. Discard
                // that older snapshot and replay its requested refresh.
                if !historyReloadRequested { history = value; historyError = nil }
            } catch {
                if !historyReloadRequested { historyError = error.localizedDescription }
            }
        } while historyReloadRequested
    }
    func startOver() {
        guard !busy else { return }
        phase = .select; preview = nil; proposal = nil; receipt = nil; error = nil; status = ""; applyOperationID = nil
    }
    func removeEdit(_ noteID: String) {
        guard !busy, var proposal else { return }
        proposal.edits.removeAll { $0.noteID == noteID }; self.proposal = proposal
    }
    func removeNewNote(_ key: String) {
        guard !busy, var proposal else { return }
        proposal.newNotes.removeAll { $0.key == key }
        for index in proposal.collections.indices {
            proposal.collections[index].members.removeAll { $0.draftKey == key }
        }
        proposal.collections.removeAll { $0.members.isEmpty }
        proposal.links.removeAll { $0.from.draftKey == key || $0.to.draftKey == key }
        self.proposal = proposal
    }
    func removeCollection(_ key: String) {
        guard !busy, var proposal else { return }
        proposal.collections.removeAll { $0.key == key }; self.proposal = proposal
    }
    func removeLink(_ index: Int) {
        guard !busy, var proposal, proposal.links.indices.contains(index) else { return }
        proposal.links.remove(at: index); self.proposal = proposal
    }
    func cancel() {
        guard !mutating else { return }
        generation = UUID(); task?.cancel(); task = nil; activity = nil
    }
}
