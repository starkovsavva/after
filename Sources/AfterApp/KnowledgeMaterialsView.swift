import AfterLocalization
import Foundation
import AfterCore
import SwiftUI

/// Presentation shared by the library and suggested links. Identifiers remain
/// source identities; dates and provenance help people distinguish equal titles.
enum KnowledgeMaterialPresentation {
    static func date(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return Date(timeIntervalSince1970: value).formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(UILocale()))
    }
    static func metadata(_ note: CapturedNote) -> String {
        [L("Заметка"), date(note.createdAt), note.folder].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static func metadata(_ meeting: Meeting) -> String {
        var parts = [L("Встреча"), date(meeting.createdAt)]
        if meeting.duration.isFinite, meeting.duration > 0, meeting.duration < 1_000_000 {
            let seconds = Int(meeting.duration)
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        let filename = URL(fileURLWithPath: meeting.source).lastPathComponent
        if !filename.isEmpty, !["audio.mp3", "recording.mp3"].contains(filename) { parts.append(filename) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static func topicTitle(terms: [String], semantic: Bool, notesOnly: Bool = false) -> String {
        semantic && !terms.isEmpty ? terms.joined(separator: " · ") : L(notesOnly ? "Связанные заметки" : "Связанные материалы")
    }
}

struct KnowledgeMaterialRow: View {
    let title: String
    let metadata: String
    let meeting: Bool
    var snippet = ""
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: meeting ? "waveform" : "note.text").foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppTypography.controlStrong).lineLimit(2)
                Text(metadata).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2)
                if !snippet.isEmpty { Text(snippet).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.up.right").font(AppTypography.caption).foregroundStyle(.secondary).padding(.top, 3)
        }.contentShape(Rectangle())
    }
}

struct KnowledgeMaterialsView: View {
    @EnvironmentObject private var app: AppStore
    let query: String
    @State private var limit = 40
    @State private var error: String?
    private enum Material: Identifiable {
        case note(CapturedNote), meeting(Meeting)
        var id: String { switch self { case .note(let n): "note:" + n.id; case .meeting(let m): "meeting:" + m.id } }
        var date: Double { switch self { case .note(let n): n.updatedAt; case .meeting(let m): m.createdAt } }
    }
    private func allowed(_ note: CapturedNote) -> Bool {
        let folder = note.folderID ?? note.meetingID.flatMap { app.folderID(for: $0) }
        return note.kind == "note" && note.trashedAt == nil &&
            (app.folderSelection == nil || folder == app.folderSelection) &&
            app.effectiveSettings(for: note.folderID == nil ? note.meetingID : nil, folderID: note.folderID).features.knowledgeBase
    }
    private func allowed(_ meeting: Meeting) -> Bool {
        meeting.libraryKind != "cards" && ["ready", "transcribed"].contains(meeting.status) &&
            (app.folderSelection == nil || app.folderID(for: meeting.id) == app.folderSelection) &&
            app.effectiveSettings(for: meeting.id).features.knowledgeBase
    }
    private var materials: [Material] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = app.notes.workspace.notes.filter { allowed($0) && (needle.isEmpty ||
            $0.displayTitle.localizedCaseInsensitiveContains(needle) || $0.text.localizedCaseInsensitiveContains(needle)) }.map(Material.note)
        let meetings = app.meetings.filter { allowed($0) && (needle.isEmpty ||
            $0.title.localizedCaseInsensitiveContains(needle) || $0.source.localizedCaseInsensitiveContains(needle)) }.map(Material.meeting)
        return (notes + meetings).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    private var hasMaterials: Bool { app.notes.workspace.notes.contains(where: allowed) || app.meetings.contains(where: allowed) }
    private func createNote() {
        var note = CapturedNote()
        let folder = app.notes.folder(app.folderSelection)
        note.folderID = folder?.id; note.folder = folder?.name ?? ""
        guard let saved = app.notes.save(note) else { error = app.notes.error; return }
        app.openCapturedNote(saved)
    }
    private func open(_ material: Material) {
        switch material {
        case .note(let old):
            app.notes.reload()
            guard let current = app.notes.workspace.notes.first(where: { $0.id == old.id }), allowed(current) else {
                error = L("Заметка больше недоступна."); return
            }
            app.openCapturedNote(current)
        case .meeting(let old):
            app.reloadLibrary()
            guard let current = app.meetings.first(where: { $0.id == old.id }), allowed(current) else {
                error = L("Встреча больше недоступна."); return
            }
            app.openMeeting(current.id, tab: "transcript")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
            if materials.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(hasMaterials ? L("Ничего не найдено") : L("Начните с заметки или встречи"))
                        .font(AppTypography.heading).accessibilityIdentifier("knowledge.materials.empty")
                    Text(hasMaterials ? L("Попробуйте другое слово или поиск в содержимом встреч.") :
                        L("Сохранённые заметки и расшифрованные встречи появятся здесь. Откройте материал или соберите заметки в подборку."))
                        .font(AppTypography.control).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !hasMaterials {
                        HStack {
                            Button(L("Новая заметка")) { createNote() }.buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("knowledge.materials.new-note")
                            Button(L("Записать встречу")) { app.showingRecord = true }.buttonStyle(.bordered)
                                .disabled(app.isRecording || app.startingRecording || app.stoppingRecording)
                                .accessibilityIdentifier("knowledge.materials.record")
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Ink.soft, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text(LF("Материалов: {0}", arguments: [String(materials.count)]))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(materials.prefix(limit))) { material in
                        Button { open(material) } label: {
                            switch material {
                            case .note(let note):
                                KnowledgeMaterialRow(title: note.displayTitle, metadata: KnowledgeMaterialPresentation.metadata(note),
                                    meeting: false, snippet: note.text.replacingOccurrences(of: "\n", with: " "))
                                    .padding(.vertical, 12)
                            case .meeting(let meeting):
                                KnowledgeMaterialRow(title: meeting.title, metadata: KnowledgeMaterialPresentation.metadata(meeting), meeting: true)
                                    .padding(.vertical, 12)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("knowledge.material." + material.id)
                        Divider()
                    }
                }
                if materials.count > limit {
                    Button(L("Показать ещё")) { limit += 40 }.buttonStyle(.borderless)
                }
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(L("Искать в содержимом встреч…")) {
                    app.searchQuery = query; app.openGlobalSearch()
                }.buttonStyle(.borderless).font(AppTypography.caption)
                    .accessibilityIdentifier("knowledge.materials.search-meetings")
            }
        }.onChange(of: query) { _, _ in limit = 40; error = nil }
            .onChange(of: app.folderSelection) { _, _ in limit = 40; error = nil }
    }
}
