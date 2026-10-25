import PosleCore
import SwiftUI

/// A source opens as readable text first; playback is always a separate, explicit action.
struct EvidenceButton: View {
    @EnvironmentObject private var store: AppStore
    let ids: [Int]
    @State private var showing = false
    @State private var sourceSnapshot: [Segment] = []
    @State private var sourceMeetingID: String?
    private var segments: [Segment] { ids.compactMap { id in store.transcript?.segments.first { $0.id == id } } }
    var body: some View {
        Button {
            sourceSnapshot = segments; sourceMeetingID = store.selection; showing = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "quote.bubble")
                if let first = segments.first {
                    Text(Exporter.timestamp(first.start)).monospacedDigit()
                    if ids.count > 1 { Text("+\(ids.count - 1)") }
                } else { Text("Источник") }
            }.font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.accent)
                .padding(.horizontal, 9).padding(.vertical, 7).background(Ink.accent.opacity(0.07), in: Capsule())
        }.buttonStyle(.plain).help("Показать все исходные реплики")
            .accessibilityLabel("Исходные реплики: \(ids.count)")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Исходные реплики").font(AppTypography.heading)
                        Spacer()
                        Button { showing = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Закрыть источники")
                    }
                    ScrollView {
                        SourceQuotes(ids: ids, snapshot: sourceSnapshot, meetingID: sourceMeetingID) { id, play in showing = false; store.openSegment(id, play: play) }
                    }.frame(maxHeight: 430)
                }.padding(20).frame(width: 490).background(Ink.paper)
            }
    }
}

struct SourceQuotes: View {
    @EnvironmentObject private var store: AppStore
    let ids: [Int]
    var snapshot: [Segment]? = nil
    var meetingID: String? = nil
    let open: (Int, Bool) -> Void
    private var uniqueIDs: [Int] { var seen = Set<Int>(); return ids.filter { seen.insert($0).inserted } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if uniqueIDs.isEmpty { unavailable }
            ForEach(uniqueIDs, id: \.self) { id in
                if let segment = store.transcript?.segments.first(where: { $0.id == id }),
                   meetingID == nil || meetingID == store.selection,
                   snapshot == nil || snapshot?.first(where: { $0.id == id }) == segment {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack(spacing: 9) {
                            Text(store.selected?.speakerName(segment.speaker) ?? segment.speaker)
                                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Button { open(id, true) } label: { Label(Exporter.timestamp(segment.start), systemImage: "play.circle") }
                                .font(AppTypography.control).monospacedDigit().buttonStyle(.borderless)
                                .help("Прослушать исходную реплику").accessibilityLabel("Прослушать с \(Exporter.timestamp(segment.start))")
                        }
                        Text(segment.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                        Button { open(id, false) } label: { Label("Открыть в транскрипте", systemImage: "arrow.up.forward") }
                            .font(AppTypography.control).buttonStyle(.borderless)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Ink.soft, in: RoundedRectangle(cornerRadius: 9))
                } else { unavailable }
            }
        }
    }
    private var unavailable: some View {
        Label("Исходная реплика недоступна. Обновите конспект по текущей транскрипции.", systemImage: "exclamationmark.circle")
            .font(AppTypography.control).foregroundStyle(Ink.warning).padding(10)
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
    var body: some View {
        Button("[\(number)]") {
            sourceMeetingID = store.selection
            sourceSnapshot = store.transcript?.segments ?? []
            showing = true
        }.font(.system(size: 13, weight: .semibold)).buttonStyle(.borderless)
            .help("Факты и исходные реплики для этого утверждения")
            .accessibilityLabel("Показать факты для утверждения \(number)")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("На чём основан конспект").font(AppTypography.heading)
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
                                            Text(item.text).font(.system(size: 14, weight: .semibold)).lineSpacing(4).textSelection(.enabled)
                                            if !item.owner.isEmpty || !item.due.isEmpty {
                                                Text([item.owner, item.due].filter { !$0.isEmpty }.joined(separator: " · "))
                                                    .font(AppTypography.control).foregroundStyle(.secondary)
                                            }
                                            SourceQuotes(ids: item.segmentIDs, snapshot: sourceSnapshot, meetingID: sourceMeetingID) { id, play in showing = false; store.openSegment(id, play: play) }
                                        }
                                    }
                                }
                            } else {
                                Label("Конспект изменился. Откройте факты актуальной версии.", systemImage: "exclamationmark.circle")
                                    .font(AppTypography.control).foregroundStyle(Ink.warning)
                            }
                        }
                    }.frame(maxHeight: 480)
                }.padding(20).frame(width: 530).background(Ink.paper)
            }
    }
}
