import Foundation
import PosleCore
import SwiftUI

/// Project/person labels belong to a meeting context, not a second folder tree.
struct ContextLibraryIndex {
    let meetings: [Meeting]
    let contexts: [MeetingContext]
    let mode: String
    static func label(_ context: MeetingContext, mode: String) -> String {
        (mode == "project" ? context.project : context.person).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var labels: [String] {
        let ids = Set(meetings.map(\.id))
        var unique: [String: String] = [:]
        for context in contexts where ids.contains(context.meetingID) {
            let label = Self.label(context, mode: mode)
            let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            if !label.isEmpty && unique[key] == nil { unique[key] = label }
        }
        return unique.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func meetings(for label: String) -> [Meeting] {
        guard !label.isEmpty else { return [] }
        let ids = Set(contexts.filter {
            Self.label($0, mode: mode).compare(label, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }.map(\.meetingID))
        return meetings.filter { ids.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }
}

struct ContextLinkDraft {
    let baseline: MeetingContext
    let mode: String
    var label: String
    var normalizedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    var dirty: Bool { normalizedLabel != ContextLibraryIndex.label(baseline, mode: mode) }
    var updated: MeetingContext {
        var value = baseline
        if mode == "project" { value.project = normalizedLabel } else { value.person = normalizedLabel }
        return value
    }
}

/// The whole workflow is available where the user discovers the feature.
struct ContextAssignmentSheet: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var notes: NotesStore
    let mode: String
    let suggestedLabel: String
    let onSaved: (String) -> Void
    @State private var meetingID = ""
    @State private var draft: ContextLinkDraft?
    @State private var label = ""
    @State private var failure = ""
    @State private var editorID = UUID()
    @State private var finished = false
    @FocusState private var labelFocused: Bool
    private var candidates: [Meeting] { app.noteMeetings }
    private var dirty: Bool { currentDraft?.dirty == true }
    private var currentDraft: ContextLinkDraft? {
        guard var value = draft else { return nil }; value.label = label; return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(mode == "project" ? "Связать встречу с проектом" : "Добавить человека к встрече").font(AppTypography.modalTitle)
            Picker("Встреча", selection: $meetingID) {
                if candidates.isEmpty { Text("Нет встреч").tag("") }
                if !meetingID.isEmpty && !candidates.contains(where: { $0.id == meetingID }) { Text("Встреча недоступна").tag(meetingID) }
                ForEach(candidates) { Text($0.title).tag($0.id) }
            }.accessibilityIdentifier("contexts.link.meeting")
            TextField(mode == "project" ? "Название проекта" : "Имя человека", text: $label)
                .textFieldStyle(.roundedBorder).focused($labelFocused).accessibilityIdentifier("contexts.link.label")
                .onSubmit { save() }
            if let original = draft.map({ ContextLibraryIndex.label($0.baseline, mode: mode) }), !original.isEmpty, dirty {
                Text("Заменит связь с «\(original)».").font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
            }
            Text("Заметки и договорённости встречи появятся здесь. Папка и её настройки сохранятся.")
                .font(AppTypography.caption).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
            if !failure.isEmpty { Text(failure).font(AppTypography.caption).foregroundStyle(Ink.warning).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Отмена") { finish() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("contexts.link.cancel")
                Button("Связать") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .disabled(app.isTerminating || currentDraft?.normalizedLabel.isEmpty != false || !candidates.contains(where: { $0.id == meetingID }))
                    .accessibilityIdentifier("contexts.link.save")
            }
        }.padding(24).frame(width: 510).background(Ink.paper).appControlDefaults()
            .interactiveDismissDisabled(dirty)
            .onAppear {
                label = suggestedLabel
                meetingID = candidates.first(where: { $0.id == app.selection })?.id ?? candidates.first?.id ?? ""
                selectMeeting(); labelFocused = true
            }
            .onChange(of: meetingID) { _, _ in selectMeeting() }
            .onChange(of: dirty) { _, _ in registerDraft() }
            .onDisappear { finished = true; UnsavedEditorRegistry.remove(id: editorID) }
    }
    private func selectMeeting() {
        draft = meetingID.isEmpty ? nil : ContextLinkDraft(baseline: notes.context(for: meetingID), mode: mode, label: label)
        registerDraft()
    }
    private func registerDraft() {
        guard !finished else { return }
        UnsavedEditorRegistry.set(id: editorID, title: "Связь встречи", dirty: dirty)
    }
    private func finish() { finished = true; UnsavedEditorRegistry.remove(id: editorID); dismiss() }
    private func save() {
        guard !finished, !app.isTerminating, let value = currentDraft, !value.normalizedLabel.isEmpty,
              candidates.contains(where: { $0.id == meetingID }) else { return }
        if value.dirty, !notes.saveContext(value.updated) { failure = notes.error ?? "Не удалось связать встречу. Ваш текст сохранён в этом окне."; return }
        finish(); onSaved(value.normalizedLabel)
    }
}

struct ContextBriefRequest: Equatable {
    let folderID: String?
    let mode: String
    let label: String
    let meetings: [Meeting]
}

/// Decoding all related summaries during a SwiftUI body pass blocks navigation.
/// Scope and generation checks ensure a late result cannot refill another folder.
@MainActor
final class ContextBriefStore: ObservableObject {
    @Published private(set) var summaries: [String: Summary] = [:]
    @Published private(set) var loading = false
    private var generation = 0
    private var worker: Task<[String: Summary], Never>?
    func load(root: URL, request: ContextBriefRequest) async {
        worker?.cancel(); generation += 1; let current = generation
        summaries = [:]; loading = !request.meetings.isEmpty
        guard !request.meetings.isEmpty else { return }
        let ids = request.meetings.map(\.id)
        let work = Task.detached(priority: .userInitiated) {
            var summaries: [String: Summary] = [:]
            guard let bridge = try? RustBridge.shared.get() else { return summaries }
            for id in ids {
                guard !Task.isCancelled else { break }
                let url = root.appendingPathComponent("meetings/\(id)/summary.json")
                if let data = try? bridge.read(root: root, url: url), let summary = try? JSONDecoder().decode(Summary.self, from: data) { summaries[id] = summary }
            }
            return summaries
        }
        worker = work
        let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        guard !Task.isCancelled, current == generation else { return }
        worker = nil; summaries = result; loading = false
    }
    func cancel() { worker?.cancel(); worker = nil; generation += 1; summaries = [:]; loading = false }
}
