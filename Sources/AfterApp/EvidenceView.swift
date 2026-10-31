import AfterLocalization
import AfterCore
import SwiftUI

private func uniqueSourceIDs(_ ids: [Int]) -> [Int] {
    var seen = Set<Int>()
    return ids.filter { seen.insert($0).inserted }
}

private struct SourcePopoverRequest: Hashable {
    let meetingID: String?
    let ids: [Int]
    let metadata: Meeting?
    var presentation: UUID? = nil
}

private func validateSource(root: URL, meetingID: String, expected: Segment, summary: Summary? = nil) async -> Bool {
    let ids = uniqueSourceIDs((summary?.items.flatMap(\.segmentIDs) ?? []) + [expected.id])
    let result = try? await Task.detached(priority: .userInitiated) {
        try EvidenceSourceSnapshot.load(root: root, meetingID: meetingID, ids: ids, includeSummary: summary != nil)
    }.value
    guard !Task.isCancelled, let result, result.meeting.id == meetingID,
          result.segments.first(where: { $0.id == expected.id }) == expected else { return false }
    return summary.map { result.matches($0) } ?? true
}

@MainActor
private func navigateToSource(store: AppStore, meetingID: String, expected: Segment) {
    // Current-meeting sources already have a loaded transcript. Do not decode
    // it again just to change the tab and scroll to a known, freshly checked ID.
    if store.transcriptSegment(expected.id, meetingID: meetingID) != expected {
        store.openMeeting(meetingID, tab: "transcript")
    }
    guard store.selection == meetingID,
          store.transcriptSegment(expected.id, meetingID: meetingID) == expected else {
        store.error = L("Источник изменился. Откройте актуальный конспект."); return
    }
    store.openSegment(expected.id, play: false)
}

/// The click presents a shell immediately. A worker reads only referenced
/// segments through the validated bridge; neither labels nor quote bodies do I/O.
struct EvidenceButton: View {
    @EnvironmentObject private var store: AppStore
    let ids: [Int]
    var meetingID: String? = nil
    @State private var showing = false
    @State private var sourceMeetingID: String?
    @State private var sourceTitle = ""
    @State private var presentation = UUID()
    @State private var openedTranscriptRevision: UInt64 = 0
    @State private var openedIDs: [Int] = []
    @State private var action = UUID()
    @State private var actionTask: Task<Void, Never>?
    @StateObject private var sources = EvidenceSourceState()
    @StateObject private var playback = SourcePlaybackState()

    var body: some View {
        let currentPresentation = presentation
        let references = uniqueSourceIDs(ids)
        let first = (meetingID == nil || meetingID == store.selection)
            ? references.lazy.compactMap { store.transcriptSegment($0) }.first : nil
        Button {
            GuidanceController.shared.recordUsage("sources", root: store.root)
            sourceMeetingID = meetingID ?? store.selection
            sourceTitle = store.meetings.first(where: { $0.id == sourceMeetingID })?.title ?? ""
            openedTranscriptRevision = store.transcriptRevision; openedIDs = ids
            presentation = UUID(); sources.prepare(); showing = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "quote.bubble")
                if let first {
                    Text(Exporter.timestamp(first.start)).monospacedDigit()
                    if references.count > 1 { Text("+\(references.count - 1)") }
                } else { Text(LF("Источники: {0}", arguments: [String(references.count)])) }
            }.font(AppTypography.controlStrong).foregroundStyle(Ink.accent)
                .padding(.horizontal, 9).padding(.vertical, 7).background(Ink.accent.opacity(0.07), in: Capsule())
        }.buttonStyle(.plain).help(L("Показать исходные реплики"))
            .accessibilityLabel(LF("Исходные реплики: {0}", arguments: [String(references.count)]))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L("Источники")).font(AppTypography.heading)
                        Spacer()
                        Button { showing = false } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel(L("Закрыть источники"))
                    }
                    let title = sources.snapshot?.meeting.title ?? sourceTitle
                    if !title.isEmpty { Text(title).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2) }
                    ScrollView {
                        if sources.loading {
                            ProgressView(L("Загружаю источники…")).frame(maxWidth: .infinity, minHeight: 120)
                        } else if let source = sources.snapshot {
                            SourceQuotes(ids: references, meetingID: sourceMeetingID, resolved: source,
                                         playingID: playback.playingID, preparingID: playback.preparingID, open: openSource)
                        } else { sourceUnavailable(sources.error) }
                    }.frame(maxHeight: 430)
                    if let error = playback.error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).textSelection(.enabled) }
                }.padding(20).frame(width: 470).background(Ink.paper)
                    .task(id: SourcePopoverRequest(meetingID: sourceMeetingID, ids: references,
                        metadata: store.meetings.first(where: { $0.id == sourceMeetingID }), presentation: presentation)) {
                        guard let sourceMeetingID else { sources.cancel(); return }
                        await sources.load(root: store.root, meetingID: sourceMeetingID, ids: references)
                    }
            }
            .onChange(of: showing) { _, shown in if !shown, !showing { cancel() } }
            .onChange(of: ids) { _, _ in if showing, ids != openedIDs { showing = false; cancel() } }
            .onChange(of: store.selection) { _, _ in
                if showing, meetingID == nil, store.selection != sourceMeetingID { showing = false; cancel() }
            }
            .onChange(of: store.transcriptRevision) { _, _ in
                if showing, sourceMeetingID == store.selection,
                   store.transcriptRevision != openedTranscriptRevision { showing = false; cancel() }
            }
            .onChange(of: store.isPlaying) { _, playing in if playing { playback.stop() } }
            .onDisappear { if presentation == currentPresentation { cancel() } }
    }

    private func cancel() {
        action = UUID(); actionTask?.cancel(); actionTask = nil
        sources.cancel(); playback.stop()
    }
    private func openSource(_ id: Int, _ play: Bool) {
        guard let meeting = sourceMeetingID,
              let expected = sources.snapshot?.segments.first(where: { $0.id == id }) else { return }
        if play { playback.toggle(store: store, meetingID: meeting, expected: expected); return }
        actionTask?.cancel(); action = UUID()
        let token = action, root = store.root
        actionTask = Task { @MainActor in
            let valid = await validateSource(root: root, meetingID: meeting, expected: expected)
            guard !Task.isCancelled, action == token, showing else { return }
            guard valid else {
                store.error = L("Источник изменился. Откройте актуальный конспект."); showing = false; return
            }
            playback.stop(); showing = false
            navigateToSource(store: store, meetingID: meeting, expected: expected)
        }
    }
}

@MainActor private func sourceUnavailable(_ error: String?) -> some View {
    Label(error ?? L("Источник недоступен. Обновите конспект."), systemImage: "exclamationmark.circle")
        .font(AppTypography.control).foregroundStyle(Ink.warning).padding(10)
}

struct SourceQuotes: View {
    @EnvironmentObject private var store: AppStore
    let ids: [Int]
    var snapshot: [Segment]? = nil
    var meetingID: String? = nil
    var resolved: EvidenceSourceSnapshot? = nil
    var playingID: Int? = nil
    var preparingID: Int? = nil
    let open: (Int, Bool) -> Void
    @StateObject private var sources = EvidenceSourceState()

    var body: some View {
        let references = uniqueSourceIDs(ids)
        let candidate = resolved ?? sources.snapshot
        let source = candidate?.meeting.id == (meetingID ?? store.selection) ? candidate : nil
        let byID = Dictionary((source?.segments ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let expected = snapshot.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        let verified = references.compactMap { id -> Segment? in
            guard let segment = byID[id], expected == nil || expected?[id] == segment else { return nil }
            return segment
        }
        LazyVStack(alignment: .leading, spacing: 14) {
            if resolved == nil, sources.loading {
                ProgressView(L("Загружаю источники…")).frame(maxWidth: .infinity, minHeight: 120)
            } else if verified.count < references.count || references.isEmpty {
                Label(verified.isEmpty ? L("Источник недоступен. Обновите конспект.") : L("Некоторые исходные реплики недоступны."), systemImage: "exclamationmark.circle")
                    .font(AppTypography.control).foregroundStyle(Ink.warning).padding(10)
            }
            ForEach(verified) { segment in
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 9) {
                        Text(source?.meeting.speakerName(segment.speaker) ?? segment.speaker)
                            .font(AppTypography.controlStrong).lineLimit(1)
                        Spacer()
                        Button { open(segment.id, true) } label: {
                            HStack(spacing: 6) {
                                if preparingID == segment.id { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
                                Label(Exporter.timestamp(segment.start), systemImage: playingID == segment.id ? "stop.circle" : "play.circle")
                            }
                        }.font(AppTypography.control).monospacedDigit().buttonStyle(.borderless).foregroundStyle(Ink.accent)
                            .help(playingID == segment.id ? L("Остановить реплику") : L("Прослушать реплику здесь"))
                            .accessibilityLabel(playingID == segment.id ? L("Остановить реплику") : LF("Прослушать с {0}", arguments: [Exporter.timestamp(segment.start)]))
                    }
                    Text(segment.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                    Button { open(segment.id, false) } label: { Label(L("Открыть транскрипт"), systemImage: "arrow.up.forward") }
                        .font(AppTypography.control).buttonStyle(.borderless).foregroundStyle(Ink.accent)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.soft, in: RoundedRectangle(cornerRadius: 9))
            }
        }.task(id: SourcePopoverRequest(meetingID: meetingID ?? store.selection, ids: references,
            metadata: store.meetings.first(where: { $0.id == (meetingID ?? store.selection) }))) {
            guard resolved == nil, let id = meetingID ?? store.selection else { return }
            await sources.load(root: store.root, meetingID: id, ids: references)
        }.onDisappear { sources.cancel() }
    }
}

struct ClaimReferenceButton: View {
    @EnvironmentObject private var store: AppStore
    let claim: OverviewClaim
    let number: Int
    let summary: Summary
    @State private var showing = false
    @State private var sourceMeetingID: String?
    @State private var presentation = UUID()
    @State private var openedTranscriptRevision: UInt64 = 0
    @State private var openedSummaryRevision: UInt64 = 0
    @State private var action = UUID()
    @State private var actionTask: Task<Void, Never>?
    @StateObject private var sources = EvidenceSourceState()
    @StateObject private var playback = SourcePlaybackState()
    private var references: [Int] { uniqueSourceIDs(summary.items.flatMap(\.segmentIDs)) }
    var body: some View {
        let currentPresentation = presentation
        Button("[\(number)]") {
            GuidanceController.shared.recordUsage("sources", root: store.root)
            sourceMeetingID = store.selection
            openedTranscriptRevision = store.transcriptRevision; openedSummaryRevision = store.summaryRevision
            presentation = UUID(); sources.prepare(); showing = true
        }.font(AppTypography.controlStrong).buttonStyle(.borderless)
            .help(L("Факты и исходные реплики для этого утверждения"))
            .accessibilityLabel(LF("Показать факты для утверждения {0}", arguments: [String(number)]))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L("Источники")).font(AppTypography.heading)
                        Spacer()
                        Button { showing = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L("Закрыть факты"))
                    }
                    ScrollView {
                        if sources.loading {
                            ProgressView(L("Загружаю источники…")).frame(maxWidth: .infinity, minHeight: 120)
                        } else if let source = sources.snapshot {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(Array(claim.itemIndices.enumerated()), id: \.offset) { _, index in
                                    if summary.items.indices.contains(index) {
                                        let item = summary.items[index]
                                        VStack(alignment: .leading, spacing: 11) {
                                            Text(item.text).font(AppTypography.bodyStrong).lineSpacing(4).textSelection(.enabled)
                                            if !item.owner.isEmpty || !item.due.isEmpty {
                                                Text([item.owner, item.due].filter { !$0.isEmpty }.joined(separator: " · "))
                                                    .font(AppTypography.control).foregroundStyle(.secondary)
                                            }
                                            SourceQuotes(ids: item.segmentIDs, meetingID: sourceMeetingID, resolved: source,
                                                playingID: playback.playingID, preparingID: playback.preparingID, open: openSource)
                                        }
                                    }
                                }
                            }
                        } else { sourceUnavailable(sources.error) }
                    }.frame(maxHeight: 480)
                    if let error = playback.error { Text(error).font(AppTypography.control).foregroundStyle(Ink.warning).textSelection(.enabled) }
                }.padding(20).frame(width: 530).background(Ink.paper)
                    .task(id: SourcePopoverRequest(meetingID: sourceMeetingID, ids: references,
                        metadata: store.meetings.first(where: { $0.id == sourceMeetingID }), presentation: presentation)) {
                        guard let sourceMeetingID else { sources.cancel(); return }
                        await sources.load(root: store.root, meetingID: sourceMeetingID, ids: references, expectedSummary: summary)
                    }
            }
            .onChange(of: showing) { _, shown in if !shown, !showing { cancel() } }
            .onChange(of: store.selection) { _, _ in
                if showing, store.selection != sourceMeetingID { showing = false; cancel() }
            }
            .onChange(of: store.transcriptRevision) { _, _ in
                if showing, store.transcriptRevision != openedTranscriptRevision { showing = false; cancel() }
            }
            .onChange(of: store.summaryRevision) { _, _ in
                if showing, store.summaryRevision != openedSummaryRevision { showing = false; cancel() }
            }
            .onChange(of: store.isPlaying) { _, playing in if playing { playback.stop() } }
            .onDisappear { if presentation == currentPresentation { cancel() } }
    }
    private func cancel() {
        action = UUID(); actionTask?.cancel(); actionTask = nil
        sources.cancel(); playback.stop()
    }
    private func openSource(_ id: Int, _ play: Bool) {
        guard let meeting = sourceMeetingID, let expected = sources.snapshot?.segments.first(where: { $0.id == id }) else { return }
        if play {
            let root = store.root
            playback.toggle(store: store, meetingID: meeting, expected: expected) {
                await validateSource(root: root, meetingID: meeting, expected: expected, summary: summary)
            }
            return
        }
        actionTask?.cancel(); action = UUID()
        let token = action, root = store.root
        actionTask = Task { @MainActor in
            let valid = await validateSource(root: root, meetingID: meeting, expected: expected, summary: summary)
            guard !Task.isCancelled, action == token, showing else { return }
            guard valid else { store.error = L("Источник изменился. Откройте актуальный конспект."); showing = false; return }
            playback.stop(); showing = false
            navigateToSource(store: store, meetingID: meeting, expected: expected)
        }
    }
}
