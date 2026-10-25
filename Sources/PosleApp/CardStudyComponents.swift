import PosleCore
import SwiftUI

/// The same reading surface is used for a meeting and the whole library.
/// Source evidence and generated examples remain visibly separate.
struct StudyCardContent: View {
    @EnvironmentObject private var app: AppStore
    let card: Flashcard
    let flipped: Bool
    let example: CardExample?
    let makingExample: Bool
    var sourceMeetingID: String? = nil
    var meetingTitle: String? = nil
    var openMeeting: (() -> Void)? = nil
    var originIsDeck = false
    let makeExample: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(card.kind == "phrase" ? "Фраза" : "Понятие")
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if let meetingTitle, let openMeeting {
                    Button(action: openMeeting) {
                        Text(meetingTitle).lineLimit(1).truncationMode(.middle)
                    }.font(AppTypography.control).buttonStyle(.plain).foregroundStyle(Ink.accent)
                        .help((originIsDeck ? "Открыть колоду: " : "Открыть встречу: ") + meetingTitle)
                }
            }
            Text(card.front).font(AppTypography.cardFront).lineSpacing(4)
                .textSelection(.enabled).accessibilityLabel("Карточка: \(card.front)")
            if flipped {
                Divider()
                Text(card.back).font(AppTypography.cardAnswer).lineSpacing(5)
                    .textSelection(.enabled).accessibilityLabel("Ответ: \(card.back)")
                if !card.context.isEmpty || !card.segmentIDs.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        if !card.context.isEmpty {
                            Text(card.segmentIDs.isEmpty ? card.context : "«\(card.context)»")
                                .font(AppTypography.body).foregroundStyle(.secondary).lineSpacing(4)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } else { Spacer(minLength: 0) }
                        if !card.segmentIDs.isEmpty {
                            EvidenceButton(ids: card.segmentIDs, meetingID: sourceMeetingID)
                        }
                    }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Button {
                        guard !app.busy, !app.isRecording, !makingExample else { return }
                        makeExample()
                    } label: {
                        HStack(spacing: 7) {
                            Group {
                                if makingExample { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "sparkles") }
                            }.frame(width: 15, height: 15).accessibilityHidden(true)
                            Text(example == nil ? "Пример" : "Другой пример")
                        }
                    }.buttonStyle(.bordered).disabled(app.busy || app.isRecording || makingExample)
                        .accessibilityLabel(example == nil ? "Придумать пример с этой карточкой" : "Придумать другой пример с этой карточкой")
                        .help("Создать пример с этой карточкой; исходная цитата сохранится")
                    Spacer()
                }
                if app.settings.mode == "cloud" {
                    Text("Для примера \(app.settings.cloudProviderTitle) получит карточку и контекст. API оплачивается отдельно.")
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let example {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Пример ИИ").font(AppTypography.caption).foregroundStyle(Ink.accent)
                        Text(example.example).font(AppTypography.bodyStrong).lineSpacing(4).textSelection(.enabled)
                        if !example.translation.isEmpty {
                            Text(example.translation).font(AppTypography.body).foregroundStyle(.secondary)
                                .lineSpacing(4).textSelection(.enabled).accessibilityLabel("Перевод примера: \(example.translation)")
                        }
                        if !example.explanation.isEmpty {
                            DisclosureGroup("Пояснение") {
                                Text(example.explanation).font(AppTypography.body).foregroundStyle(.secondary)
                                    .lineSpacing(4).textSelection(.enabled).padding(.top, 4)
                            }.font(AppTypography.control).foregroundStyle(.secondary)
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Ink.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.padding(20).frame(maxWidth: .infinity, minHeight: flipped ? 0 : 155, alignment: .topLeading)
            .background(Ink.paper, in: RoundedRectangle(cornerRadius: AppLayout.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: AppLayout.cardRadius).strokeBorder(Ink.line))
            .accessibilityElement(children: .contain)
    }
}

/// Showing an answer and grading occupy the same slot. Hidden answers never
/// leave a row of disabled grades taking attention away from the question.
struct StudyReviewBar: View {
    @Binding var flipped: Bool
    let enabled: Bool
    let review: ReviewState?
    let rate: (Int) -> Void
    private let labels = ["Снова", "Трудно", "Хорошо", "Легко"]
    private let descriptions = ["Не удалось вспомнить", "Вспомнил с трудом", "Вспомнил правильно", "Вспомнил без усилий"]
    var body: some View {
        HStack(spacing: 10) {
            if flipped {
                ForEach(1...4, id: \.self) { value in
                    Button {
                        guard enabled, flipped else { return }
                        rate(value)
                    } label: {
                        HStack(spacing: 7) {
                            Text(String(value)).font(AppTypography.caption).foregroundStyle(.secondary).monospacedDigit()
                            Text(labels[value - 1]).font(AppTypography.controlStrong)
                        }.frame(maxWidth: .infinity, minHeight: 24)
                    }.buttonStyle(.bordered).disabled(!enabled)
                        .keyboardShortcut(KeyEquivalent(Character(String(value))), modifiers: [])
                        .help("\(descriptions[value - 1]) · \(value)\(reviewTooltip)")
                        .accessibilityLabel(labels[value - 1] + ": " + descriptions[value - 1])
                        .accessibilityHint("Запланировать следующее повторение. Клавиша \(value).")
                }
            } else {
                Spacer()
                Button("Показать ответ") {
                    guard enabled, !flipped else { return }
                    flipped = true
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .keyboardShortcut(.space, modifiers: []).disabled(!enabled)
                    .help("Показать ответ · Пробел").frame(minWidth: 180)
                Spacer()
            }
        }.padding(.horizontal, AppLayout.contentInset).frame(height: 56)
            .frame(maxWidth: .infinity).background(Ink.paper)
            .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
            .appLayoutAnchor("cards.review")
    }
    private var reviewTooltip: String {
        guard let review else { return "" }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: review.due) ?? ISO8601DateFormatter().date(from: review.due)
        let due = date?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ru_RU"))) ?? review.due
        return "\nПовторений: \(review.count). Следующий показ: \(due)"
    }
}
