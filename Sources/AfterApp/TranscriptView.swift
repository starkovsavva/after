import AfterLocalization
import AppKit
import AfterCore
import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject private var store: AppStore
    @State private var speaker: String?
    @State private var name = ""
    @State private var showingSpeakers = false
    @State private var editingSegment: SegmentEditTarget?
    @State private var transcriptCopied = ProcessInfo.processInfo.arguments.contains("--preview") && ProcessInfo.processInfo.arguments.contains("--preview-copied")
    private var segments: [Segment] {
        (store.transcript?.segments ?? []).filter { store.transcriptSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(store.transcriptSearch) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Поиск по словам встречи"), text: $store.transcriptSearch).textFieldStyle(.plain)
                    Text(LF("Реплик: {0}", arguments: [String(describing: (segments.count))])).foregroundStyle(.secondary).monospacedDigit()
                }.padding(10).background(Ink.soft, in: RoundedRectangle(cornerRadius: AppLayout.controlRadius))
                Button { showingSpeakers = true } label: {
                    Label(LF("Собеседники: {0}", arguments: [String(describing: (Set((store.transcript?.segments ?? []).map(\.speaker).filter { $0 != "unknown" }).count))]), systemImage: "person.2")
                }.buttonStyle(.bordered).disabled(store.busy || store.isRecording)
                    .help(L("Указать точное число участников и пересчитать голоса без повторного распознавания"))
                Button {
                    if store.copyTranscriptMarkdown() { transcriptCopied = true }
                } label: {
                    Image(systemName: transcriptCopied ? "checkmark" : "doc.on.doc")
                        .frame(width: 20, height: 20)
                        .foregroundStyle(transcriptCopied ? Ink.green : .secondary)
                }.buttonStyle(.bordered)
                    .disabled(store.transcript?.segments.isEmpty ?? true)
                    .help(transcriptCopied ? L("Транскрипт скопирован") : L("Скопировать весь транскрипт в Markdown"))
                    .accessibilityLabel(L("Скопировать транскрипт в Markdown"))
                    .accessibilityValue(transcriptCopied ? L("Скопировано") : "")
                    .accessibilityIdentifier("transcript.copy-markdown")
            }.font(AppTypography.control)
                .padding(.horizontal, AppLayout.contentInset).padding(.top, 16).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.transcript?.warnings ?? [], id: \.self) { Text($0).font(AppTypography.caption).foregroundStyle(Ink.warning).padding(.bottom, 10) }
                        ForEach(segments) { segment in
                            HStack(alignment: .top, spacing: 18) {
                                Button { store.seek(segment.start, play: true) } label: {
                                    Text(Exporter.timestamp(segment.start)).font(AppTypography.control).monospacedDigit()
                                        .foregroundStyle(Ink.accent).frame(width: 60, alignment: .leading)
                                }.buttonStyle(.plain).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Button {
                                            speaker = segment.speaker; name = store.selected?.speakerName(segment.speaker) ?? ""
                                        } label: {
                                            HStack(spacing: 7) {
                                                Circle().fill(speakerColor(segment.speaker)).frame(width: 7, height: 7)
                                                Text(store.selected?.speakerName(segment.speaker) ?? segment.speaker).font(AppTypography.controlStrong)
                                                Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(.secondary)
                                            }
                                        }.buttonStyle(.plain).help(L("Переименовать собеседника")).disabled(store.busy || store.isRecording)
                                        if segment.overlap { Text(L("Голоса пересекаются")).font(AppTypography.caption).foregroundStyle(Ink.warning) }
                                    }
                                    Text(segment.text).font(AppTypography.body).lineSpacing(6).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    if let id = store.selection { editingSegment = SegmentEditTarget(meetingID: id, segmentID: segment.id) }
                                } label: { Image(systemName: "pencil").frame(width: 24, height: 24) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Изменить текст и собеседника")).accessibilityLabel(L("Изменить реплику"))
                            }.padding(14).background(active(segment) ? Ink.accent.opacity(0.06) : .clear,
                                                     in: RoundedRectangle(cornerRadius: 9)).id(segment.id)
                        }
                        if segments.isEmpty { Text(L("Ничего не найдено")).foregroundStyle(.secondary).padding(30) }
                    }.padding(.horizontal, 18).padding(.vertical, 10)
                }.onAppear { scrollToTarget(proxy) }
                .onChange(of: store.navigationTarget?.id) { _, _ in scrollToTarget(proxy) }
                .onChange(of: store.playbackTime) { old, new in
                    if abs(new - old) > 1.5, let target = store.transcript?.segments.first(where: { new >= $0.start && new < $0.end }) {
                        withAnimation { proxy.scrollTo(target.id, anchor: .center) }
                    }
                }
            }
        }.task(id: transcriptCopied) {
            guard transcriptCopied, !(ProcessInfo.processInfo.arguments.contains("--preview") && ProcessInfo.processInfo.arguments.contains("--preview-copied")) else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            transcriptCopied = false
        }.onChange(of: store.selection) { _, _ in transcriptCopied = false }
        .sheet(item: $editingSegment) { target in
            TranscriptSegmentEditor(meetingID: target.meetingID, segmentID: target.segmentID).environmentObject(store)
        }
        .sheet(isPresented: $showingSpeakers) {
            if let id = store.selection { SpeakerReviewView(meetingID: id).environmentObject(store) }
        }.alert(L("Имя собеседника"), isPresented: Binding(get: { speaker != nil }, set: { if !$0 { speaker = nil } })) {
            TextField(L("Имя"), text: $name)
            Button(L("Сохранить")) { if let speaker { store.renameSpeaker(speaker, name: name) }; speaker = nil }
            Button(L("Отмена"), role: .cancel) { speaker = nil }
        } message: { Text(L("Имя изменится во всех репликах этого собеседника. Метки голосов определены автоматически и могут ошибаться.")) }
    }
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = store.navigationTarget, target.meetingID == store.selection, target.kind == "transcript", let id = target.segmentID else { return }
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
    }
    private func active(_ s: Segment) -> Bool {
        (store.navigationTarget?.meetingID == store.selection && store.navigationTarget?.kind == "transcript" && store.navigationTarget?.segmentID == s.id) ||
        (store.playbackTime >= s.start && store.playbackTime < s.end)
    }
    private func speakerColor(_ key: String) -> Color {
        if key == "self" { return Ink.green }
        if key == "unknown" { return .gray }
        let value = Int(key.replacingOccurrences(of: "speaker_", with: "")) ?? 0
        return [Ink.accent, Ink.green, .orange, .pink, .cyan][abs(value % 5)]
    }
}

private struct SegmentEditTarget: Identifiable { let id = UUID(); let meetingID: String; let segmentID: Int }
