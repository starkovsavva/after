import Foundation
import PosleCore
import SwiftUI

private struct MixedMeetingAnchor: Codable {
    let kind: String
    let meetingID: String
    let segmentID: Int?
    let itemIndex: Int?
    let title: String
    let text: String
    let contentFingerprint: String
    let policyFingerprint: String
}
private struct MixedTopicSource: Codable, Identifiable {
    let kind: String
    let noteID: String?
    let meetingID: String?
    let revision: UInt64?
    let title: String
    let fingerprint: String
    let source: MixedMeetingAnchor?
    let partial: Bool?
    var id: String {kind + ":" + (noteID ?? meetingID ?? "")}
}
private struct MixedTopic: Decodable, Identifiable {
    let id: String
    let terms: [String]
    let sources: [MixedTopicSource]
    let method: String
}
private struct MixedTopicResult: Decodable {
    let topics: [MixedTopic]
    let examined: Int
    let total: Int
    let partial: Bool
    let semanticIndexed: Int
    let nextOffset: Int?
    let offset: Int
}

/// Mixed-source groups are suggestions. The core checks each content version
/// and current scope before publication and again before navigation.
struct KnowledgeMixedTopicsView: View {
    @EnvironmentObject private var app: AppStore
    let query: String
    @State private var result: MixedTopicResult?
    @State private var busy = false
    @State private var error: String?
    @State private var expanded = true
    @State private var requestID: String?
    @State private var work: Task<Void,Never>?
    @State private var offset = 0
    @State private var opening = false
    private var paused: Bool {app.isRecording || app.startingRecording || app.stoppingRecording}
    private var visible: [MixedTopic] {
        let needle=query.trimmingCharacters(in:.whitespacesAndNewlines)
        return (result?.topics ?? []).filter {needle.isEmpty || $0.terms.joined(separator:" ").localizedCaseInsensitiveContains(needle) ||
            $0.sources.contains(where:{$0.title.localizedCaseInsensitiveContains(needle)})}
    }
    private func cancel() {
        let id=requestID; requestID=nil; work?.cancel(); work=nil; busy=false
        if let id {let root=app.root; Task.detached(priority:.utility){_ = try? RustBridge.shared.get().request(root:root,command:"kb-mixed-topics-cancel",arguments:["requestID":id])}}
    }
    private func load(reset: Bool = false) {
        cancel(); error=nil; result=nil
        if reset {offset=0}
        guard !paused else {return}
        let id=UUID().uuidString.lowercased(); requestID=id; busy=true
        let root=app.root, folder=app.folderSelection, currentOffset=offset
        work=Task {
            do {
                try await Task.sleep(for:.milliseconds(250))
                let data=try await Task.detached(priority:.utility){
                    var input:[String:Any]=["requestID":id,"offset":currentOffset]
                    if let folder {input["folderID"]=folder}
                    return try RustBridge.shared.get().request(root:root,command:"kb-mixed-topics",arguments:input)
                }.value
                let value=try JSONDecoder().decode(MixedTopicResult.self,from:data)
                guard requestID==id, !Task.isCancelled else {return}
                result=value;busy=false;work=nil
            } catch {
                guard requestID==id,!Task.isCancelled else{return}
                self.error=error.localizedDescription;busy=false;work=nil
            }
        }
    }
    private func open(_ source:MixedTopicSource) async {
        guard !opening else{return};opening=true;defer{opening=false}
        do {
            let bytes=try JSONEncoder().encode(source)
            let root=app.root,folder=app.folderSelection
            let data=try await Task.detached(priority:.userInitiated){
                var args:[String:Any]=["source":try JSONSerialization.jsonObject(with:bytes)]
                if let folder {args["folderID"]=folder}
                return try RustBridge.shared.get().request(root:root,command:"kb-topic-source-validate",arguments:args)
            }.value
            let value=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            guard value?["valid"] as? Bool == true else {throw AppError.message(L("Материал изменился или стал недоступен. Обновите подсказки."))}
            if let id=source.noteID {
                app.notes.reload()
                guard let note=app.notes.notes.first(where:{$0.id==id && $0.trashedAt==nil && UInt64(max(0,$0.revision))==source.revision}) else {throw AppError.message(L("Заметка больше недоступна."))}
                app.openCapturedNote(note)
            }else if let id=source.meetingID,let anchor=source.source {
                app.openMeeting(id,tab:anchor.kind=="transcript" ? "transcript":"summary",segmentID:anchor.segmentID)
            }
        } catch {self.error=error.localizedDescription}
    }
    var body: some View {
        DisclosureGroup(isExpanded:$expanded){
            VStack(alignment:.leading,spacing:8){
                Text(L("Предложения связывают опубликованные материалы. Исходные заметки и встречи не изменяются."))
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                if paused {Text(L("Построение тем приостановлено на время записи.")).font(AppTypography.caption).foregroundStyle(.secondary)}
                else if busy {HStack{ProgressView().controlSize(.small);Text(L("Собираю темы…"))}.font(AppTypography.caption)}
                if let error {Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning)}
                if let result {
                    if result.semanticIndexed==0 {Text(L("Пока используются общие слова. Для смысловых связей включите локальный смысловой поиск."))
                        .font(AppTypography.caption).foregroundStyle(.secondary)}
                    if result.partial {Text(LF("Рассмотрено материалов: {0} из {1}. Часть возможных связей может отсутствовать.",arguments:[String(result.examined),String(result.total)]))
                        .font(AppTypography.caption).foregroundStyle(.secondary)}
                    if visible.isEmpty {Text(L("Подходящих связей встреч пока нет.")).font(AppTypography.caption).foregroundStyle(.secondary)}
                    if !visible.isEmpty {
                        VStack(alignment:.leading,spacing:10){
                            ForEach(visible){topic in
                                VStack(alignment:.leading,spacing:6){
                                    Text(topic.terms.isEmpty ? L("Связанные материалы"):topic.terms.joined(separator:" · "))
                                        .font(AppTypography.controlStrong)
                                    Text(topic.method=="semantic" ? L("Предложено по смыслу"):(topic.method=="hybrid" ? L("Предложено по смыслу и общим словам"):L("Предложено по общим словам")))
                                        .font(AppTypography.caption).foregroundStyle(.secondary)
                                    ForEach(topic.sources){source in
                                        Button{Task{await open(source)}}label:{
                                            HStack{Image(systemName:source.kind=="meeting" ? "waveform":"note.text");Text(source.title).lineLimit(1);Spacer();Image(systemName:"arrow.up.right")}
                                        }.buttonStyle(.plain).font(AppTypography.caption).disabled(opening)
                                            .accessibilityIdentifier("knowledge.mixed.source.\(source.id)")
                                    }
                                }.padding(10).background(Ink.soft,in:RoundedRectangle(cornerRadius:8))
                            }
                        }
                    }
                    HStack{
                        if result.offset>0 {Button(L("Назад")){offset=max(0,result.offset-40);load()}}
                        if let next=result.nextOffset {Button(L("Следующая страница")){offset=next;load()}}
                    }.buttonStyle(.borderless).font(AppTypography.caption)
                }
                Button(L("Обновить")){load(reset:true)}.buttonStyle(.borderless).font(AppTypography.caption).disabled(busy || paused)
                    .accessibilityIdentifier("knowledge.mixed.refresh")
            }.padding(.top,8)
        }label:{
            // Scope this ID to the heading. Applying it to DisclosureGroup
            // propagates it to its rows and replaces their source identifiers.
            Text(L("Встречи и заметки по темам")).font(AppTypography.controlStrong)
                .accessibilityIdentifier("knowledge.mixed.topics")
        }
        .onAppear{load()}.onDisappear{cancel()}
        .onChange(of:paused){_,_ in load()}
        .onChange(of:app.folderSelection){_,_ in load(reset:true)}
        .onChange(of:app.notes.workspace.notes){_,_ in load(reset:true)}
        .onChange(of:app.notes.workspace.folders){_,_ in load(reset:true)}
        .onChange(of:app.notes.workspace.contexts){_,_ in load(reset:true)}
        .onChange(of:app.meetings){_,_ in load(reset:true)}
        .onChange(of:app.settings.features){_,_ in load(reset:true)}
    }
}
