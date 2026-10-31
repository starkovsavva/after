import AfterPlatformMacOS
import AfterLocalization
import SwiftUI
import AfterCore

struct TrashEntry: Decodable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var detail: String
    var deletedAt: Double
    var expiresAt: Double
    var fingerprint: String
    var meetingID: String?
    var trashID: String?
    var key: String { kind + ":" + (meetingID ?? "") + ":" + id }
    var label: String {
        switch kind { case "meeting": L("Встреча"); case "task": L("Задача"); case "card": L("Карточка"); default: L("Заметка") }
    }
    var symbol: String {
        switch kind { case "meeting": "waveform"; case "task": "checklist"; case "card": "rectangle.on.rectangle"; default: "note.text" }
    }
}

struct TrashView: View {
    @EnvironmentObject private var app: AppStore
    @State private var entries: [TrashEntry] = []
    @State private var loading = true
    @State private var restoring: String?
    @State private var error: String?
    @State private var warning: String?
    @State private var query = ""
    private var matching: [TrashEntry] {
        entries.filter { query.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Корзина")).font(AppTypography.pageTitle)
                Spacer()
                TextField(L("Найти в Корзине"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }.padding(24)
            Divider()
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L("Удалённые объекты хранятся 30 дней.")).font(AppTypography.caption).foregroundStyle(.secondary)
                        if let error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).textSelection(.enabled) }
                        if let warning { Text(warning).font(AppTypography.caption).foregroundStyle(.secondary) }
                        if matching.isEmpty {
                            ContentUnavailableView(query.isEmpty ? L("Корзина пуста") : L("Ничего не найдено"), systemImage: "trash")
                                .frame(maxWidth: .infinity).padding(.top, 42)
                        }
                        ForEach(matching, id: \.key) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: entry.symbol).foregroundStyle(.secondary).frame(width: 22).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.title).font(AppTypography.controlStrong).lineLimit(2)
                                    if !entry.detail.isEmpty && entry.detail != entry.title { Text(entry.detail).font(AppTypography.control).foregroundStyle(.secondary).lineLimit(2) }
                                    Text(LF("{0} · Хранится до {1}", arguments: [String(describing: (entry.label)), String(describing: (Date(timeIntervalSince1970: entry.expiresAt).formatted(.dateTime.day().month(.abbreviated).locale(UILocale()))))]))
                                        .font(AppTypography.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                if restoring == entry.key { ProgressView().controlSize(.small) }
                                Button(L("Восстановить")) { Task { await restore(entry) } }
                                    .buttonStyle(.bordered).disabled(restoring != nil || app.busy)
                                    .accessibilityLabel(LF("Восстановить: {0}", arguments: [String(describing: (entry.title))]))
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }.appContentLayout()
                }
            }
        }.task { await reload(cleanup: true) }
        .onReceive(NotificationCenter.default.publisher(for: .posleJobsChanged)) { _ in Task { await reload() } }
        .accessibilityIdentifier("trash-workspace")
    }
    private func reload(cleanup: Bool = false) async {
        let root = app.root
        do {
            let mayCleanup = cleanup && !app.busy && !app.isRecording && !app.isPreview
            let data = try await Task.detached(priority: .utility) {
                let bridge = try RustBridge.shared.get()
                if mayCleanup { _ = try bridge.request(root: root, command: "trash-purge-expired") }
                return try bridge.request(root: root, command: "trash-list")
            }.value
            struct Response: Decodable { var entries: [TrashEntry]; var errors: [AnyTrashError] }
            let response = try JSONDecoder().decode(Response.self, from: data)
            entries = response.entries
            warning = response.errors.isEmpty ? nil : L("Не удалось прочитать часть Корзины. Исходные данные сохранены.")
            error = nil
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func restore(_ entry: TrashEntry) async {
        restoring = entry.key
        defer { restoring = nil }
        let root = app.root
        do {
            try await Task.detached(priority: .userInitiated) {
                let bridge = try RustBridge.shared.get()
                if entry.kind == "card" {
                    _ = try bridge.request(root: root, command: "card-restore", arguments: ["meetingID": entry.meetingID ?? "", "trashID": entry.trashID ?? entry.id, "expectedFingerprint": entry.fingerprint])
                } else {
                    _ = try bridge.request(root: root, command: "trash-change", arguments: ["kind": entry.kind, "id": entry.id, "restore": true, "expectedFingerprint": entry.fingerprint, "operationID": UUID().uuidString.lowercased()])
                }
            }.value
            app.notes.reload(); app.notes.loadTasks(); app.reloadLibrary()
            if let id = app.selection { app.refreshResults(id) }
            app.notice = LF("{0} восстановлена", arguments: [String(describing: (entry.label))])
            await reload()
        } catch { self.error = error.localizedDescription }
    }
}
private struct AnyTrashError: Decodable {
    init(from decoder: Decoder) throws { _ = try decoder.singleValueContainer() }
}

/// Retention is enforced only while the app is running, on an idle utility task.
@MainActor enum TrashMaintenance {
    static func run(app: AppStore) async {
        guard !app.isPreview else { return }
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        while !Task.isCancelled {
            if !app.busy && !app.isRecording && !app.startingRecording && !app.stoppingRecording && app.jobs.activeCount == 0 {
                let root = app.root
                _ = try? await Task.detached(priority: .utility) {
                    try RustBridge.shared.get().request(root: root, command: "trash-purge-expired")
                }.value
            }
            do { try await Task.sleep(for: .seconds(6 * 60 * 60)) } catch { return }
        }
    }
}
