import AppKit
import PosleCore
import SwiftUI

struct TaskHistoryView: View {
    @EnvironmentObject private var app: AppStore
    let task: TaskWorkspace
    @State private var artifact: TaskArtifact?
    @State private var snapshot: TaskSnapshotPresentation?
    @State private var routeTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if task.history.isEmpty { Text(L("История появится после первого изменения задачи.")).font(AppTypography.control).foregroundStyle(.secondary) }
            ForEach(task.history) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: event.symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.text).font(AppTypography.body).lineSpacing(4).textSelection(.enabled)
                        HStack(spacing: 8) {
                            if !event.actor.isEmpty { Text(event.actor == "user" ? L("Вы") : event.actor) }
                            Text(Date(timeIntervalSince1970: event.createdAt).formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(UILocale())))
                        }.font(AppTypography.caption).foregroundStyle(.secondary)
                        if let value = event.snapshot {
                            Button { snapshot = TaskSnapshotPresentation(snapshot: value) } label: { Label(event.kind == "claimed" ? L("Контекст на момент принятия") : event.kind == "report" ? L("Контекст на момент отчёта") : L("Сохранённый контекст"), systemImage: "shippingbox") }
                                .buttonStyle(.bordered).font(AppTypography.control).accessibilityIdentifier("tasks.history.snapshot." + event.id)
                        }
                        ForEach(event.artifacts) { value in
                            Button { artifact = value } label: { Label(value.title, systemImage: value.symbol) }
                                .buttonStyle(.bordered).font(AppTypography.control).accessibilityIdentifier("tasks.history.artifact." + value.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("tasks.history.event." + event.id)
            }
            SnapshotShareHistoryView(root: app.root, taskID: task.id)
        }.onAppear { openRequestedArtifact() }
            .onChange(of: app.taskHistoryRoute) { _, _ in openRequestedArtifact() }
            .onDisappear { routeTask?.cancel() }
            .sheet(item: $artifact) { TaskArtifactSheet(artifact: $0) }
            .sheet(item: $snapshot) { TaskSnapshotSheet(snapshot: $0.snapshot) }
    }
    private func openRequestedArtifact() {
        guard let route = app.taskHistoryRoute, route.taskID == task.id else { return }
        routeTask?.cancel()
        let root = app.root
        routeTask = Task { @MainActor in
            do {
                let planData = try JSONEncoder().encode(route.plan)
                let targetData = try JSONEncoder().encode(route.target)
                let result = try await Task.detached(priority: .userInitiated) {
                    let bridge = try RustBridge.shared.get()
                    let plan = try JSONSerialization.jsonObject(with: planData)
                    let target = try JSONSerialization.jsonObject(with: targetData)
                    func valid() throws -> Bool {
                        let data = try bridge.request(root: root, command: "assistant-find-validate",
                            arguments: ["plan":plan, "target":target, "limit":20])
                        struct Validation: Decodable { let valid: Bool }
                        return try JSONDecoder().decode(Validation.self, from: data).valid
                    }
                    guard try valid() else { throw AppError.message(L("Отчёт изменился или стал недоступен. Повторите поиск.")) }
                    let data = try bridge.request(root: root, command: "task-get", arguments: ["taskID":route.target.taskID])
                    let fresh = try JSONDecoder().decode(TaskWorkspace.self, from: data)
                    guard fresh.revision >= 0, UInt64(fresh.revision) == route.target.revision,
                          fresh.sourceFingerprint == route.target.sourceFingerprint, try valid() else {
                        throw AppError.message(L("Отчёт изменился или стал недоступен. Повторите поиск."))
                    }
                    guard let event = fresh.history.first(where: { $0.id == route.eventID }),
                          let id = route.artifactID,
                          let found = event.artifacts.first(where: { $0.id == id }) else {
                        throw AppError.message(L("Артефакт изменился или стал недоступен. Повторите поиск."))
                    }
                    return found
                }.value
                guard !Task.isCancelled, app.taskHistoryRoute == route, app.notes.selectedTaskID == route.taskID else { return }
                app.taskHistoryRoute = nil
                artifact = result
            } catch {
                guard !Task.isCancelled, app.taskHistoryRoute == route else { return }
                app.taskHistoryRoute = nil
                app.error = error.localizedDescription
            }
        }
    }
}

struct TaskArtifactSheet: View {
    @Environment(\.dismiss) private var dismiss
    let artifact: TaskArtifact
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppPageHeader(title: artifact.title, modal: true)
            ScrollView { Text(artifact.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("tasks.artifact.contents." + artifact.id) }
            HStack {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(artifact.text, forType: .string) } label: { Label(L("Скопировать"), systemImage: "doc.on.doc") }
                if let url = artifact.url.flatMap(TaskWorkspaceURL.external) { Button(L("Открыть ссылку")) { NSWorkspace.shared.open(url) } }
                Spacer(); Button(L("Готово")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("tasks.artifact.close")
            }
        }.padding(24).frame(minWidth: 520, idealWidth: 620, minHeight: 380, idealHeight: 560).appControlDefaults()
    }
}

struct TaskSnapshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: TaskContextSnapshot
    var title = L("Контекст задачи")
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppPageHeader(title: title, modal: true)
            Text(Date(timeIntervalSince1970: snapshot.generatedAt).formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(UILocale())))
                .font(AppTypography.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(snapshot.task.title).font(AppTypography.heading)
                    Label(L(snapshot.task.status.title), systemImage: snapshot.task.status.symbol).font(AppTypography.control).foregroundStyle(.secondary)
                    if !snapshot.task.text.isEmpty { Text(snapshot.task.text).font(AppTypography.body).lineSpacing(4) }
                    ForEach(snapshot.materials) { material in
                        VStack(alignment: .leading, spacing: 7) {
                            Label(material.title, systemImage: material.symbol).font(AppTypography.controlStrong)
                            if let text = material.displayText, !text.isEmpty { Text(text).font(AppTypography.body).foregroundStyle(.secondary).lineSpacing(4) }
                            if let location = material.path ?? material.url { Text(location).font(AppTypography.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 8)
                    }
                    if snapshot.truncated { Text(L("Контекст сокращён до допустимого объёма.")).font(AppTypography.caption).foregroundStyle(Ink.warning) }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button {
                    guard let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                } label: { Label(L("Скопировать"), systemImage: "doc.on.doc") }
                Spacer(); Button(L("Готово")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(minWidth: 540, idealWidth: 660, minHeight: 420, idealHeight: 660).appControlDefaults()
    }
}
