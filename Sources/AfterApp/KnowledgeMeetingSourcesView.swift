import AfterPlatform
import AfterPlatformMacOS
import AfterLocalization
import Foundation
import AfterCore
import SwiftUI

private struct RelatedMeetingSource: Codable {
    let kind: String
    let meetingID: String
    let segmentID: Int?
    let itemIndex: Int?
    let title: String
    let text: String
    let contentFingerprint: String
    let policyFingerprint: String
}
private struct RelatedMeetingItem: Decodable, Identifiable {
    let source: RelatedMeetingSource
    let sharedTerms: [String]
    var id: String { "\(source.meetingID):\(source.kind):\(source.segmentID ?? source.itemIndex ?? -1)" }
}
private struct RelatedMeetingResults: Decodable {
    let items: [RelatedMeetingItem]
    let partial: Bool
}
private struct RelatedMeetingValidation: Decodable { let valid: Bool }
private struct SavedMeetingLink: Decodable, Identifiable {
    let id: String
    let revision: UInt64
    let source: RelatedMeetingSource?
    let available: Bool
}
private struct SavedMeetingLinks: Decodable { let items: [SavedMeetingLink] }
private struct KnowledgeLinkRevision: Decodable { let workspaceRevision: UInt64; let kbRevision: UInt64 }
private struct MeetingLinkOperation: Decodable { let operationID: String }

/// Suggestions remain separate from explicit saved links. Every meeting source
/// is checked again before navigating or saving it.
struct KnowledgeMeetingSourcesView: View {
    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss
    let source: CapturedNote
    var didChange: () -> Void = {}
    @State private var results: RelatedMeetingResults?
    @State private var saved: SavedMeetingLinks?
    @State private var loading = false
    @State private var opening: String?
    @State private var mutating = false
    @State private var error: String?
    @State private var active = false
    @State private var undoOperation: String?

    private func isSaved(_ source:RelatedMeetingSource)->Bool {
        (saved?.items ?? []).contains { link in
            guard let other=link.source, link.available else {return false}
            return other.meetingID==source.meetingID && other.kind==source.kind &&
                other.segmentID==source.segmentID && other.itemIndex==source.itemIndex
        }
    }

    private func request(_ command: String, arguments: [String: Any]) async throws -> Data {
        let root = app.root
        let input = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try await Task.detached(priority: .userInitiated) {
            guard let object = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
                throw AppError.message(L("Не удалось подготовить запрос."))
            }
            return try RustBridge.shared.get().request(root: root, command: command, arguments: object)
        }.value
    }
    @MainActor private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let savedData = try await request("kb-meeting-links", arguments:["noteID":source.id,"noteRevision":source.revision])
            let current = try JSONDecoder().decode(SavedMeetingLinks.self, from:savedData)
            let data = try await request("knowledge-meeting-suggestions", arguments: ["noteID":source.id,"noteRevision":source.revision])
            guard !Task.isCancelled else { return }
            saved = current
            results = try JSONDecoder().decode(RelatedMeetingResults.self, from: data)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = L("Не удалось проверить материалы встреч.")
        }
    }
    @MainActor private func change(_ action:String, item:RelatedMeetingItem? = nil, link:SavedMeetingLink? = nil) async {
        guard !mutating else { return }; mutating=true; error=nil
        defer { mutating=false }
        do {
            let snapshot=try await request("kb-snapshot", arguments:["noteID":source.id])
            let revision=try JSONDecoder().decode(KnowledgeLinkRevision.self,from:snapshot)
            var arguments:[String:Any]=["action":action,"noteID":source.id,"noteRevision":source.revision,
                "expectedWorkspaceRevision":revision.workspaceRevision,"expectedKBRevision":revision.kbRevision,
                "operationID":UUID().uuidString.lowercased()]
            if let item {arguments["source"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(item.source))}
            if let link {arguments["linkID"]=link.id}
            let changed = try await request("kb-meeting-link-change",arguments:arguments)
            let operation = try JSONDecoder().decode(MeetingLinkOperation.self,from:changed).operationID
            undoOperation = operation
            guard active else {return}
            didChange()
            await load()
        } catch {
            guard active else {return}
            self.error = L("Материал изменился или стал недоступен. Обновите подсказки.")
        }
    }
    @MainActor private func undo() async {
        guard let original=undoOperation, !mutating else { return }
        mutating=true; error=nil
        defer { mutating=false }
        do {
            let snapshot=try await request("kb-snapshot", arguments:["noteID":source.id])
            let revision=try JSONDecoder().decode(KnowledgeLinkRevision.self,from:snapshot)
            _ = try await request("kb-undo", arguments:["operationID":UUID().uuidString.lowercased(),
                "targetOperationID":original,"expectedWorkspaceRevision":revision.workspaceRevision,"expectedKBRevision":revision.kbRevision])
            guard active else {return}
            undoOperation=nil; didChange(); await load()
        } catch {
            guard active else {return}
            self.error=L("Материал изменился или стал недоступен. Обновите подсказки.")
            undoOperation=nil
        }
    }
    @MainActor private func open(_ item: RelatedMeetingItem) async {
        guard opening == nil else { return }
        opening = item.id; error = nil
        defer { opening = nil }
        do {
            let encoded = try JSONEncoder().encode(item.source)
            let raw = try JSONSerialization.jsonObject(with: encoded)
            let data = try await request("knowledge-meeting-validate", arguments: ["noteID":source.id,"noteRevision":source.revision,"source":raw])
            let valid = try JSONDecoder().decode(RelatedMeetingValidation.self, from:data).valid
            guard active else { return }
            guard valid else {
                error = L("Материал изменился или стал недоступен. Обновите подсказки."); return
            }
            dismiss()
            app.openMeeting(item.source.meetingID, tab:item.source.kind == "transcript" ? "transcript" : "summary", segmentID:item.source.segmentID)
        } catch { self.error = L("Материал изменился или стал недоступен. Обновите подсказки.") }
    }
    var body: some View {
        Group {
        if loading || error != nil || !(results?.items.isEmpty ?? true) || !(saved?.items.isEmpty ?? true) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Материалы встреч по теме")).font(AppTypography.controlStrong)
                Text(L("Связь ведёт к сохранённой версии материала. При изменении содержания её нужно проверить заново."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                if loading { HStack { ProgressView().controlSize(.small); Text(L("Ищу материалы встреч…")) }.font(AppTypography.caption).foregroundStyle(.secondary) }
                if undoOperation != nil {
                    Button(L("Отменить")) { Task { await undo() } }.buttonStyle(.borderless).disabled(mutating)
                        .accessibilityIdentifier("knowledge.meeting.undo")
                }
                if let error {
                    HStack { Text(error); Button(L("Обновить")) { Task { await load() } } }
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                }
                if let links=saved?.items, !links.isEmpty {
                    Text(L("Сохранённые материалы встреч")).font(AppTypography.caption.weight(.semibold))
                    ForEach(links) { link in
                        HStack(alignment:.top) {
                            if let meeting=link.source, link.available {
                                Button { Task { await open(RelatedMeetingItem(source:meeting,sharedTerms:[])) } } label: {
                                    VStack(alignment:.leading,spacing:4) {
                                        Text(meeting.title).font(AppTypography.controlStrong).lineLimit(1)
                                        Text(meeting.text).font(AppTypography.caption).lineLimit(2)
                                    }.frame(maxWidth:.infinity,alignment:.leading)
                                }.buttonStyle(.plain).disabled(opening != nil || mutating)
                            } else {
                                Text(L("Материал больше недоступен")).font(AppTypography.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth:.infinity,alignment:.leading)
                            }
                            Button { Task { await change("remove",link:link) } } label: { Image(systemName:"xmark") }
                                .buttonStyle(.plain).disabled(mutating)
                                .help(L("Удалить связь"))
                                .accessibilityLabel(L("Удалить связь"))
                                .accessibilityIdentifier("knowledge.meeting.unlink.\(link.id)")
                        }.padding(10).background(Ink.soft,in:RoundedRectangle(cornerRadius:8))
                    }
                }
                ForEach(results?.items ?? []) { item in
                    VStack(alignment:.leading,spacing:4) {
                    Button { Task { await open(item) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.source.title).font(AppTypography.controlStrong).lineLimit(1)
                            Text(item.source.text).font(AppTypography.caption).lineLimit(3)
                            Text(LF("Общие слова: {0}", arguments:[item.sharedTerms.joined(separator:", ")]))
                                .font(AppTypography.caption).foregroundStyle(.secondary)
                            Text(item.source.kind == "transcript" ? L("Открыть реплику") : L("Открыть конспект"))
                                .font(AppTypography.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity, alignment:.leading).padding(10)
                            .background(Ink.soft, in:RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain).disabled(opening != nil)
                        .accessibilityIdentifier("knowledge.meeting.open.\(item.source.meetingID)")
                    if isSaved(item.source) {
                        Text(L("Связано")).font(AppTypography.caption).foregroundStyle(.secondary)
                    } else {
                        Button(L("Связать с заметкой")) { Task { await change("add",item:item) } }
                            .buttonStyle(.borderless).font(AppTypography.caption).disabled(mutating)
                            .accessibilityIdentifier("knowledge.meeting.link.\(item.source.meetingID)")
                    }
                    }.padding(.bottom,4)
                }
                if results?.partial == true { Text(L("Проверены не все материалы встреч.")).font(AppTypography.caption).foregroundStyle(.secondary) }
            }
        }
        }.onAppear { active = true }.onDisappear { active = false }
            .task(id: "\(source.id):\(source.revision)") { await load() }
    }
}

private struct MeetingBacklink: Decodable, Identifiable {
    let id: String
    let noteID: String
    let noteRevision: Int
}
private struct MeetingBacklinks: Decodable { let items: [MeetingBacklink]; let partial: Bool }

/// Open from a meeting only after the core rechecks both ends of the link.
struct MeetingKnowledgeBacklinks: View {
    @EnvironmentObject private var app: AppStore
    let meetingID: String
    @State private var shown = false
    @State private var links: MeetingBacklinks?
    @State private var loading = false
    @State private var error = false

    private func read() async throws -> MeetingBacklinks {
        let root=app.root, id=meetingID
        let data=try await Task.detached(priority:.utility) {
            try RustBridge.shared.get().request(root:root,command:"kb-meeting-backlinks",arguments:["meetingID":id])
        }.value
        return try JSONDecoder().decode(MeetingBacklinks.self,from:data)
    }
    @MainActor private func reload() async {
        loading=true; error=false
        defer {loading=false}
        do {links=try await read(); app.notes.reload()} catch {links=nil; self.error=true}
    }
    @MainActor private func open(_ item:MeetingBacklink) async {
        do {
            let current=try await read()
            guard current.items.contains(where:{$0.id==item.id && $0.noteID==item.noteID && $0.noteRevision==item.noteRevision}) else {throw AppError.message(L("Заметка больше недоступна."))}
            app.notes.reload()
            guard let note=app.notes.notes.first(where:{$0.id==item.noteID && $0.revision==item.noteRevision && $0.trashedAt==nil}) else {throw AppError.message(L("Заметка больше недоступна."))}
            shown=false; app.openCapturedNote(note)
        } catch {self.error=true; await reload()}
    }
    var body: some View {
        Button {shown.toggle()} label: {Label(L("Связанные заметки"),systemImage:"link")}
            .buttonStyle(.plain).accessibilityIdentifier("meeting.knowledge.backlinks")
            .popover(isPresented:$shown) {
                VStack(alignment:.leading,spacing:10) {
                    Text(L("Связанные заметки")).font(AppTypography.controlStrong)
                    if loading {ProgressView().controlSize(.small)}
                    if error {Text(L("Не удалось проверить связанные заметки.")).foregroundStyle(.secondary)}
                    if let links {
                        if links.items.isEmpty {Text(L("Связанных заметок пока нет.")).foregroundStyle(.secondary)}
                        ForEach(links.items) { item in
                            if let note=app.notes.notes.first(where:{$0.id==item.noteID && $0.revision==item.noteRevision && $0.trashedAt==nil}) {
                                Button(note.displayTitle) {Task {await open(item)}}.buttonStyle(.plain).lineLimit(2)
                                    .accessibilityIdentifier("meeting.knowledge.backlink.\(item.noteID)")
                            }
                        }
                        if links.partial {Text(L("Показаны не все связи.")).foregroundStyle(.secondary)}
                    }
                    Button(L("Обновить")) {Task {await reload()}}.buttonStyle(.borderless)
                }.font(AppTypography.caption).frame(width:260,alignment:.leading).padding(16)
                    .task {await reload()}
            }
    }
}
