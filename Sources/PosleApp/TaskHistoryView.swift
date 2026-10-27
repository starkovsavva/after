import AppKit
import PosleCore
import SwiftUI

struct TaskHistoryView: View {
    let task: TaskWorkspace
    @State private var artifact: TaskArtifact?
    @State private var snapshot: TaskSnapshotPresentation?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if task.history.isEmpty { Text("История появится после первого изменения задачи.").font(AppTypography.control).foregroundStyle(.secondary) }
            ForEach(task.history) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: event.symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.text).font(AppTypography.body).lineSpacing(4).textSelection(.enabled)
                        HStack(spacing: 8) {
                            if !event.actor.isEmpty { Text(event.actor == "user" ? "Вы" : event.actor) }
                            Text(Date(timeIntervalSince1970: event.createdAt).formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU"))))
                        }.font(AppTypography.caption).foregroundStyle(.secondary)
                        if let value = event.snapshot {
                            Button { snapshot = TaskSnapshotPresentation(snapshot: value) } label: { Label(event.kind == "claimed" ? "Контекст на момент принятия" : event.kind == "report" ? "Контекст на момент отчёта" : "Сохранённый контекст", systemImage: "shippingbox") }
                                .buttonStyle(.bordered).font(AppTypography.control).accessibilityIdentifier("tasks.history.snapshot." + event.id)
                        }
                        ForEach(event.artifacts) { value in
                            Button { artifact = value } label: { Label(value.title, systemImage: value.symbol) }
                                .buttonStyle(.bordered).font(AppTypography.control).accessibilityIdentifier("tasks.history.artifact." + value.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("tasks.history.event." + event.id)
            }
        }.sheet(item: $artifact) { TaskArtifactSheet(artifact: $0) }
            .sheet(item: $snapshot) { TaskSnapshotSheet(snapshot: $0.snapshot) }
    }
}

struct TaskArtifactSheet: View {
    @Environment(\.dismiss) private var dismiss
    let artifact: TaskArtifact
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppPageHeader(title: artifact.title, modal: true)
            ScrollView { Text(artifact.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(artifact.text, forType: .string) } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                if let url = artifact.url.flatMap(TaskWorkspaceURL.external) { Button("Открыть ссылку") { NSWorkspace.shared.open(url) } }
                Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(minWidth: 520, idealWidth: 620, minHeight: 380, idealHeight: 560).appControlDefaults()
    }
}

struct TaskSnapshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: TaskContextSnapshot
    var title = "Контекст задачи"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppPageHeader(title: title, modal: true)
            Text(Date(timeIntervalSince1970: snapshot.generatedAt).formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "ru_RU"))))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(snapshot.task.title).font(AppTypography.heading)
                    Label(snapshot.task.status.title, systemImage: snapshot.task.status.symbol).font(AppTypography.control).foregroundStyle(.secondary)
                    if !snapshot.task.text.isEmpty { Text(snapshot.task.text).font(AppTypography.body).lineSpacing(4) }
                    ForEach(snapshot.materials) { material in
                        VStack(alignment: .leading, spacing: 7) {
                            Label(material.title, systemImage: material.symbol).font(AppTypography.controlStrong)
                            if let text = material.displayText, !text.isEmpty { Text(text).font(AppTypography.body).foregroundStyle(.secondary).lineSpacing(4) }
                            if let location = material.path ?? material.url { Text(location).font(AppTypography.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 8)
                    }
                    if snapshot.truncated { Text("Контекст сокращён до допустимого объёма.").font(AppTypography.caption).foregroundStyle(Ink.warning) }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button {
                    guard let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(minWidth: 540, idealWidth: 660, minHeight: 420, idealHeight: 660).appControlDefaults()
    }
}
