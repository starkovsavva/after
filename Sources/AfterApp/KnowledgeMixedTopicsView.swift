import AfterLocalization
import Foundation
import AfterCore
import SwiftUI

/// Mixed-source groups are suggestions. The core checks each content version
/// and current scope before publication and again before navigation.
struct KnowledgeMixedTopicsView: View {
    @EnvironmentObject private var app: AppStore
    let query: String
    var refreshToken = UUID()
    @StateObject private var controller = KnowledgeMixedTopicsController()
    @State private var offset = 0
    private var paused: Bool { app.isRecording || app.startingRecording || app.stoppingRecording }
    private var visible: [MixedTopic] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (controller.result?.topics ?? []).filter {
            needle.isEmpty || $0.terms.joined(separator: " ").localizedCaseInsensitiveContains(needle) ||
                $0.sources.contains { $0.title.localizedCaseInsensitiveContains(needle) }
        }
    }
    private func load(reset: Bool = false) {
        if reset { offset = 0 }
        controller.load(store: app, offset: offset)
    }
    private func metadata(_ source: MixedTopicSource) -> String {
        if let id = source.meetingID, let meeting = app.meetings.first(where: { $0.id == id }) {
            return KnowledgeMaterialPresentation.metadata(meeting)
        }
        if let id = source.noteID, let note = app.notes.workspace.notes.first(where: { $0.id == id }) {
            return KnowledgeMaterialPresentation.metadata(note)
        }
        return source.kind == "meeting" ? L("Встреча") : L("Заметка")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !paused && controller.busy {
                HStack { ProgressView().controlSize(.small); Text(L("Ищу связанные встречи…")) }
                    .font(AppTypography.caption).foregroundStyle(.secondary)
            }
            if let error = controller.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
            if let result = controller.result {
                ForEach(visible) { topic in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(KnowledgeMaterialPresentation.topicTitle(terms: topic.terms,
                                semantic: topic.method == "semantic" || topic.method == "hybrid"))
                                .font(AppTypography.controlStrong)
                            Spacer()
                            Text(String(topic.sources.count)).font(AppTypography.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup(L("Почему связаны")) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(topic.method == "semantic" ? L("Предложено по смыслу") :
                                     (topic.method == "hybrid" ? L("Предложено по смыслу и общим словам") : L("Предложено по общим словам")))
                                if !topic.terms.isEmpty {
                                    Text(LF("Общие слова: {0}", arguments: [topic.terms.joined(separator: ", ")]))
                                }
                                if result.partial {
                                    Text(LF("Рассмотрено материалов: {0} из {1}. Предложения могут быть неполными.",
                                            arguments: [String(result.examined), String(result.total)]))
                                }
                            }
                        }.font(AppTypography.caption).foregroundStyle(.secondary)
                        ForEach(topic.sources) { source in
                            Button { controller.open(source, store: app) } label: {
                                KnowledgeMaterialRow(title: source.title, metadata: metadata(source), meeting: source.kind == "meeting")
                            }.buttonStyle(.plain).disabled(controller.opening)
                                .accessibilityIdentifier("knowledge.mixed.source.\(source.id)")
                        }
                    }.padding(14).background(Ink.soft, in: RoundedRectangle(cornerRadius: 10))
                }
                if result.offset > 0 || result.nextOffset != nil {
                    HStack {
                        if result.offset > 0 { Button(L("Назад")) { offset = max(0,result.offset-40); load() } }
                        if let next = result.nextOffset { Button(L("Следующая страница")) { offset=next; load() } }
                    }.buttonStyle(.borderless).font(AppTypography.caption)
                }
            }
        }
        .onAppear { load() }.onDisappear { controller.stop(root: app.root) }
        .onChange(of: query) { _, _ in controller.cancelOpening() }
        .onChange(of: refreshToken) { _, _ in load(reset: true) }
        .onChange(of: paused) { _, _ in load() }
        .onChange(of: app.folderSelection) { _, _ in load(reset: true) }
        .onChange(of: app.notes.workspace.notes) { _, _ in load(reset: true) }
        .onChange(of: app.notes.workspace.folders) { _, _ in load(reset: true) }
        .onChange(of: app.notes.workspace.contexts) { _, _ in load(reset: true) }
        .onChange(of: app.meetings) { _, _ in load(reset: true) }
        .onChange(of: app.settings.features) { _, _ in load(reset: true) }
    }
}
