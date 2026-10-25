import PosleCore
import SwiftUI

struct CardsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var mode = "study"
    @State private var flipped = false
    @State private var picked: String?
    @State private var exampleCardID: String?
    @State private var ratingPending = false
    private var cards: [Flashcard] { store.summary?.cards ?? [] }
    private var current: Flashcard? {
        if mode == "all", let picked { return cards.first { $0.id == picked } }
        return mode == "study" ? store.dueCards.first : cards.first
    }
    var body: some View {
        // A due date can pass without any published store change. Re-evaluate
        // the count, current card, empty state and review controls together.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("Режим карточек", selection: $mode) {
                    Text("Повторение").tag("study"); Text("Все карточки").tag("all")
                }.pickerStyle(.segmented).tint(Ink.actionFill).labelsHidden().frame(width: 225)
                Text(mode == "study" ? "\(store.dueCards.count) к повторению" : "Всего: \(cards.count)")
                    .font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button("Экспорт…") { store.export(true) }.buttonStyle(.bordered).disabled(cards.isEmpty)
                    .help("Сохранить карточки как TSV, совместимый с Anki")
            }.padding(.horizontal, AppLayout.contentInset).frame(height: 54)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if mode == "all", !cards.isEmpty {
                        Picker("Карточка", selection: Binding(get: { current?.id ?? "" }, set: { picked = $0; flipped = false })) {
                            ForEach(cards) { Text($0.front).tag($0.id) }
                        }.labelsHidden()
                    }
                    if let card = current {
                        StudyCardContent(card: card, flipped: flipped, example: store.examples[card.id],
                                         makingExample: exampleCardID == card.id,
                                         sourceMeetingID: store.selection) {
                            guard exampleCardID == nil, !store.busy, !store.isRecording else { return }
                            exampleCardID = card.id; store.progressText = "Придумываю пример…"; store.makeExample(card)
                        }
                    } else { empty }
                }.appContentLayout()
            }
            if let card = current {
                StudyReviewBar(flipped: $flipped, enabled: !store.busy && !store.isRecording && !ratingPending,
                               review: store.reviews[card.id]) { value in
                    guard flipped, !ratingPending, !store.busy, !store.isRecording,
                          store.selection != nil, current?.id == card.id else { return }
                    // Set synchronously: AppStore starts its async task on the
                    // next turn, so a second key press must already be blocked.
                    ratingPending = true; store.progressText = "Сохраняю повторение…"; store.rate(card, value)
                }
            }
        }.onChange(of: mode) { _, _ in
            flipped = previewAnswer
            if let target = store.navigationTarget, target.meetingID == store.selection, target.kind == "card", mode == "all" { picked = target.cardID }
            else { picked = nil }
        }.onChange(of: current?.id) { _, _ in flipped = previewAnswer; ratingPending = false }
            .onChange(of: store.busy) { _, busy in if !busy { exampleCardID = nil; ratingPending = false } }
            .onChange(of: store.navigationTarget?.id) { _, _ in navigateToCard() }
            .onAppear {
                navigateToCard()
                if ProcessInfo.processInfo.arguments.contains("--preview-all") { mode = "all" }
                if ProcessInfo.processInfo.arguments.contains("--preview"), ProcessInfo.processInfo.arguments.contains("--preview-answer") { flipped = true }
            }
        }
    }
    @ViewBuilder private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.busy && store.processingID == store.selection {
                Text("Карточки готовятся").font(AppTypography.heading)
            } else if cards.isEmpty {
                Text(store.summary == nil ? "Сначала создайте конспект" : "Карточек пока нет").font(AppTypography.heading)
                Button("Открыть конспект") { store.tab = "summary" }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
            } else {
                Text("На сегодня всё").font(AppTypography.heading)
                Button("Все карточки") { mode = "all" }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading).padding(.vertical, 16)
    }
    private var previewAnswer: Bool {
        ProcessInfo.processInfo.arguments.contains("--preview") && ProcessInfo.processInfo.arguments.contains("--preview-answer")
    }
    private func navigateToCard() {
        guard let target = store.navigationTarget, target.meetingID == store.selection, target.kind == "card",
              let id = target.cardID, cards.contains(where: { $0.id == id }) else { return }
        mode = "all"; picked = id; flipped = false
    }
}
