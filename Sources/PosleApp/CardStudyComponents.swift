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
    var exampleIsStale = false
    var sourceStale = false
    var showSourceHint = false
    var actions: CardActionsView? = nil
    let makeExample: () -> Void
    private var profileSettings: AppSettings { app.effectiveSettings(for: sourceMeetingID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(card.kind == "phrase" ? "Фраза" : "Понятие")
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                if actions?.paused == true {
                    Image(systemName: "pause.circle").font(AppTypography.caption).foregroundStyle(.secondary)
                        .help("Не повторяется").accessibilityLabel("Не повторяется")
                }
                Spacer(minLength: 12)
                if let meetingTitle, let openMeeting {
                    Button(action: openMeeting) {
                        Text(meetingTitle).lineLimit(1).truncationMode(.middle)
                    }.font(AppTypography.control).buttonStyle(.plain).foregroundStyle(Ink.accent)
                        .help((originIsDeck ? "Открыть колоду: " : "Открыть встречу: ") + meetingTitle)
                }
                if let actions { actions }
            }
            if sourceStale {
                Text("Транскрипт исправлен. Проверьте карточку по источнику.")
                    .font(AppTypography.caption).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true)
            }
            Text(card.front).font(AppTypography.cardFront).lineSpacing(4)
                .textSelection(.enabled).accessibilityLabel("Карточка: \(card.front)").accessibilityIdentifier("cards.detail.front")
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
                if showSourceHint && !card.segmentIDs.isEmpty {
                    GuidanceHint(controller: .shared, id: "cards.source-playback", text: "По таймкоду можно прослушать исходную реплику.")
                }
                HStack {
                    Button {
                        guard !makingExample else { return }
                        makeExample()
                    } label: {
                        HStack(spacing: 7) {
                            Group {
                                if makingExample { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "sparkles") }
                            }.frame(width: 15, height: 15).accessibilityHidden(true)
                            Text(example == nil ? "Пример" : "Другой пример")
                        }
                    }.buttonStyle(.bordered).disabled(makingExample)
                        .accessibilityLabel(example == nil ? "Придумать пример с этой карточкой" : "Придумать другой пример с этой карточкой")
                        .help("Создать пример с этой карточкой; исходная цитата сохранится")
                    Spacer()
                }
                if profileSettings.mode == "cloud" {
                    Text(profileSettings.cloudProvider == "chatgpt"
                         ? "ChatGPT получит карточку и контекст. Используются лимиты вашей подписки."
                         : "Для примера \(profileSettings.cloudProviderTitle) получит карточку и контекст. API оплачивается отдельно.")
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let example {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(exampleIsStale ? "Пример до правки карточки" : "Пример ИИ").font(AppTypography.caption).foregroundStyle(Ink.accent)
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
            .appLayoutAnchor("cards.detail")
    }
}

struct CardActionsView: View {
    let paused: Bool
    let disabled: Bool
    let edit: () -> Void
    let togglePause: () -> Void
    let delete: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: edit) { Image(systemName: "pencil").frame(width: 22, height: 22) }
                .buttonStyle(.plain).help("Изменить карточку").accessibilityLabel("Изменить карточку")
            Menu {
                Button(paused ? "Вернуть в повторение" : "Не повторять", action: togglePause)
                Button("Удалить карточку…", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                .menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Действия с карточкой")
        }.disabled(disabled).foregroundStyle(.secondary)
    }
}

/// Showing an answer and grading occupy the same slot. Hidden answers never
/// leave a row of disabled grades taking attention away from the question.
struct StudyReviewBar: View {
    @Binding var flipped: Bool
    let enabled: Bool
    let review: ReviewState?
    let rate: (Int) -> Void
    var intervals: [Int: String] = [:]
    private let labels = ["Снова", "Трудно", "Хорошо", "Легко"]
    private let descriptions = ["Не удалось вспомнить", "Вспомнил с трудом", "Вспомнил правильно", "Вспомнил без усилий"]
    var body: some View {
        HStack(spacing: 10) {
            if flipped {
                ForEach(1...4, id: \.self) { value in gradeButton(value) }
            } else {
                Spacer()
                answerButton
                Spacer()
            }
        }.padding(.horizontal, AppLayout.contentInset).frame(height: 56)
            .frame(maxWidth: .infinity).background(Ink.paper)
            .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
            .appLayoutAnchor("cards.review")
    }
    private var answerButton: some View {
        Button("Показать ответ") {
            guard enabled, !flipped else { return }
            flipped = true
        }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
            .keyboardShortcut(.space, modifiers: []).disabled(!enabled)
            .help("Показать ответ · Пробел").frame(minWidth: 180)
    }
    private func gradeButton(_ value: Int) -> some View {
        Button {
            guard enabled, flipped else { return }
            rate(value)
        } label: { gradeLabel(value) }
            .buttonStyle(.bordered).disabled(!enabled)
            .keyboardShortcut(KeyEquivalent(Character(String(value))), modifiers: [])
            .help(gradeHelp(value))
            .accessibilityLabel(labels[value - 1] + ": " + descriptions[value - 1])
            .accessibilityHint("Запланировать следующее повторение. Клавиша \(value).")
    }
    private func gradeLabel(_ value: Int) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 7) {
                Text(String(value)).font(AppTypography.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(labels[value - 1]).font(AppTypography.controlStrong)
            }
            if let interval = intervals[value] {
                Text(interval).font(AppTypography.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 24)
    }
    private func gradeHelp(_ value: Int) -> String {
        var text = descriptions[value - 1] + " · \(value)"
        if let interval = intervals[value] { text += " · Следующее повторение через " + interval }
        return text
    }
}
