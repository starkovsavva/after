import PosleCore
import SwiftUI

/// Quotes open before playback. An explicit meeting keeps global card sources
/// attached to their own recording, independent of the current app selection.
struct EvidenceButton: View {
    @EnvironmentObject private var store: AppStore
    let ids: [Int]
    var meetingID: String? = nil
    @State private var showing = false
    @State private var sourceSnapshot: [Segment] = []
    @State private var sourceMeetingID: String?
    @State private var sourceTitle = ""
    @StateObject private var playback = SourcePlaybackState()
    private var uniqueIDs: [Int] { var seen = Set<Int>(); return ids.filter { seen.insert($0).inserted } }
    private var visibleSegments: [Segment] {
        guard meetingID == nil || meetingID == store.selection else { return [] }
        return uniqueIDs.compactMap { id in store.transcript?.segments.first { $0.id == id } }
    }
    var body: some View {
        Button {
            sourceMeetingID = meetingID ?? store.selection
            if let id = sourceMeetingID {
                let transcript: Transcript? = store.read(store.meetingDirectory(id).appendingPathComponent("transcript.json"))
                let meeting: Meeting? = store.read(store.meetingDirectory(id).appendingPathComponent("meta.json"))
                sourceSnapshot = uniqueIDs.compactMap { reference in transcript?.segments.first { $0.id == reference } }
                sourceTitle = meeting?.title ?? ""
            } else { sourceSnapshot = []; sourceTitle = "" }
            showing = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "quote.bubble")
                if let first = visibleSegments.first {
                    Text(Exporter.timestamp(first.start)).monospacedDigit()
                    if uniqueIDs.count > 1 { Text("+\(uniqueIDs.count - 1)") }
                } else { Text("Источники: \(uniqueIDs.count)") }
            }.font(AppTypography.controlStrong).foregroundStyle(Ink.accent)
                .padding(.horizontal, 9).padding(.vertical, 7).background(Ink.accent.opacity(0.07), in: Capsule())
        }.buttonStyle(.plain).help("Показать исходные реплики")
            .accessibilityLabel("Исходные реплики: \(uniqueIDs.count)")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Источники").font(AppTypography.heading)
                        Spacer()
                        Button { showing = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Закрыть источники")
                    }
                    if !sourceTitle.isEmpty { Text(sourceTitle).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2) }
                    ScrollView {
                        SourceQuotes(ids: ids, snapshot: sourceSnapshot, meetingID: sourceMeetingID,
                                     playingID: playback.playingID, preparingID: playback.preparingID, open: openSource)
                    }.frame(maxHeight: 430)
                    if let error = playback.error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).textSelection(.enabled) }
                }.padding(20).frame(width: 470).background(Ink.paper).onDisappear { playback.stop() }
            }
            .onChange(of: showing) { _, shown in if !shown { playback.stop() } }
            .onChange(of: store.isPlaying) { _, playing in if playing { playback.stop() } }
            .onDisappear { playback.stop() }
    }
    private func openSource(_ id: Int, _ play: Bool) {
        guard let meeting = sourceMeetingID,
              let expected = sourceSnapshot.first(where: { $0.id == id }) else { return }
        let fresh: Transcript? = store.read(store.meetingDirectory(meeting).appendingPathComponent("transcript.json"))
        guard fresh?.segments.first(where: { $0.id == id }) == expected else {
            store.error = "Источник изменился. Откройте актуальный конспект."; showing = false; return
        }
        if play {
            playback.toggle(store: store, meetingID: meeting, expected: expected)
        } else {
            playback.stop(); showing = false
            store.openMeeting(meeting, tab: "transcript", segmentID: id)
            guard store.selection == meeting, store.transcript?.segments.first(where: { $0.id == id }) == expected else { return }
            store.openSegment(id, play: false)
        }
    }
}

struct SourceQuotes: View {
    @EnvironmentObject private var store: AppStore
    let ids: [Int]
    var snapshot: [Segment]? = nil
    var meetingID: String? = nil
    var playingID: Int? = nil
    var preparingID: Int? = nil
    let open: (Int, Bool) -> Void
    private var uniqueIDs: [Int] { var seen = Set<Int>(); return ids.filter { seen.insert($0).inserted } }
    private var sourceTranscript: Transcript? {
        guard let id = meetingID ?? store.selection else { return nil }
        if id == store.selection { return store.transcript }
        return store.read(store.meetingDirectory(id).appendingPathComponent("transcript.json"))
    }
    private var sourceMeeting: Meeting? {
        guard let id = meetingID ?? store.selection else { return nil }
        if id == store.selection { return store.selected }
        return store.read(store.meetingDirectory(id).appendingPathComponent("meta.json"))
    }
    var body: some View {
        let transcript = sourceTranscript
        let meeting = sourceMeeting
        let verified = uniqueIDs.compactMap { id -> Segment? in
            guard meeting != nil, let segment = transcript?.segments.first(where: { $0.id == id }),
                  snapshot == nil || snapshot?.first(where: { $0.id == id }) == segment else { return nil }
            return segment
        }
        VStack(alignment: .leading, spacing: 14) {
            if verified.count < uniqueIDs.count || uniqueIDs.isEmpty {
                Label(verified.isEmpty ? "Источник недоступен. Обновите конспект." : "Некоторые исходные реплики недоступны.", systemImage: "exclamationmark.circle")
                    .font(AppTypography.control).foregroundStyle(Ink.warning).padding(10)
            }
            ForEach(verified) { segment in
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 9) {
                        Text(meeting?.speakerName(segment.speaker) ?? segment.speaker)
                            .font(AppTypography.controlStrong).lineLimit(1)
                        Spacer()
                        Button { open(segment.id, true) } label: {
                            HStack(spacing: 6) {
                                if preparingID == segment.id { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
                                Label(Exporter.timestamp(segment.start), systemImage: playingID == segment.id ? "stop.circle" : "play.circle")
                            }
                        }
                        .font(AppTypography.control).monospacedDigit().buttonStyle(.borderless).foregroundStyle(Ink.accent)
                        .help(playingID == segment.id ? "Остановить реплику" : "Прослушать реплику здесь")
                        .accessibilityLabel(playingID == segment.id ? "Остановить реплику" : "Прослушать с \(Exporter.timestamp(segment.start))")
                    }
                    Text(segment.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                    Button { open(segment.id, false) } label: { Label("Открыть транскрипт", systemImage: "arrow.up.forward") }
                        .font(AppTypography.control).buttonStyle(.borderless).foregroundStyle(Ink.accent)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.soft, in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
}

struct ClaimReferenceButton: View {
    @EnvironmentObject private var store: AppStore
    let claim: OverviewClaim
    let number: Int
    let summary: Summary
    @State private var showing = false
    @State private var sourceMeetingID: String?
    @State private var sourceSnapshot: [Segment] = []
    @StateObject private var playback = SourcePlaybackState()
    var body: some View {
        Button("[\(number)]") {
            sourceMeetingID = store.selection
            sourceSnapshot = store.transcript?.segments ?? []
            showing = true
        }.font(AppTypography.controlStrong).buttonStyle(.borderless)
            .help("Факты и исходные реплики для этого утверждения")
            .accessibilityLabel("Показать факты для утверждения \(number)")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Источники").font(AppTypography.heading)
                        Spacer()
                        Button { showing = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Закрыть факты")
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if sourceMeetingID == store.selection, store.summary?.generatedAt == summary.generatedAt,
                               store.summary?.overview == summary.overview, store.summary?.items == summary.items,
                               summary.hasVerifiedOverviewClaims(transcript: store.transcript) {
                                ForEach(Array(claim.itemIndices.enumerated()), id: \.offset) { _, index in
                                    if summary.items.indices.contains(index) {
                                        let item = summary.items[index]
                                        VStack(alignment: .leading, spacing: 11) {
                                            Text(item.text).font(AppTypography.bodyStrong).lineSpacing(4).textSelection(.enabled)
                                            if !item.owner.isEmpty || !item.due.isEmpty {
                                                Text([item.owner, item.due].filter { !$0.isEmpty }.joined(separator: " · "))
                                                    .font(AppTypography.control).foregroundStyle(.secondary)
                                            }
                                            SourceQuotes(ids: item.segmentIDs, snapshot: sourceSnapshot, meetingID: sourceMeetingID,
                                                         playingID: playback.playingID, preparingID: playback.preparingID, open: openSource)
                                        }
                                    }
                                }
                            } else {
                                Label("Конспект изменился. Откройте актуальную версию.", systemImage: "exclamationmark.circle")
                                    .font(AppTypography.control).foregroundStyle(Ink.warning)
                            }
                        }
                    }.frame(maxHeight: 480)
                    if let error = playback.error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).textSelection(.enabled) }
                }.padding(20).frame(width: 530).background(Ink.paper).onDisappear { playback.stop() }
            }
            .onChange(of: showing) { _, shown in if !shown { playback.stop() } }
            .onChange(of: store.isPlaying) { _, playing in if playing { playback.stop() } }
            .onDisappear { playback.stop() }
    }
    private func openSource(_ id: Int, _ play: Bool) {
        guard let meeting = sourceMeetingID, let expected = sourceSnapshot.first(where: { $0.id == id }) else { return }
        let fresh: Transcript? = store.read(store.meetingDirectory(meeting).appendingPathComponent("transcript.json"))
        guard validSummary(meetingID: meeting), fresh?.segments.first(where: { $0.id == id }) == expected else {
            playback.stop(); store.error = "Источник изменился. Откройте актуальный конспект."; showing = false; return
        }
        if play {
            playback.toggle(store: store, meetingID: meeting, expected: expected) { validSummary(meetingID: meeting) }
        } else {
            playback.stop(); showing = false
            store.openMeeting(meeting, tab: "transcript", segmentID: id)
            store.openSegment(id, play: false)
        }
    }
    private func validSummary(meetingID: String) -> Bool {
        let fresh: Summary? = store.read(store.meetingDirectory(meetingID).appendingPathComponent("summary.json"))
        return fresh?.generatedAt == summary.generatedAt && fresh?.overview == summary.overview && fresh?.items == summary.items
    }
}
