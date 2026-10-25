import PosleCore
import SwiftUI

struct CardsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode = "study"
    @State private var flipped = false
    @State private var picked: String?
    @State private var exampleCardID: String?
    private var cards: [Flashcard] { store.summary?.cards ?? [] }
    private var current: Flashcard? {
        if mode == "all", let picked { return cards.first { $0.id == picked } }
        return mode == "study" ? store.dueCards.first : cards.first
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Карточки").font(.system(size: 20, weight: .medium, design: .rounded)).tracking(-0.3)
                            .accessibilityAddTraits(.isHeader)
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text("К повторению: \(store.dueCards.count) · Всего во встрече: \(cards.count)")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { store.export(true) } label: { Label("Экспорт в Anki", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered).disabled(cards.isEmpty)
                        .accessibilityLabel("Экспортировать карточки в Anki")
                        .help("Сохранить файл карточек для импорта в Anki")
                }
                Picker("Режим карточек", selection: $mode) {
                    Text("Повторение").tag("study")
                    Text("Все карточки").tag("all")
                }.pickerStyle(.segmented).tint(Ink.actionFill).labelsHidden().frame(width: 250)
                    .accessibilityLabel("Режим карточек")
                    .onChange(of: mode) { _, _ in
                        flipped = false
                        if let target = store.navigationTarget, target.meetingID == store.selection, target.kind == "card", mode == "all" { picked = target.cardID }
                        else { picked = nil }
                    }

                if cards.isEmpty {
                    if store.busy {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.regular).accessibilityHidden(true)
                            Text("Встреча обрабатывается").font(.system(size: 17, weight: .medium))
                            Text(store.progressText.isEmpty ? "После конспекта здесь появятся карточки из встречи." : store.progressText)
                                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, minHeight: 220).accessibilityElement(children: .combine)
                    } else {
                        VStack(spacing: 15) {
                            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 36, weight: .light))
                                .foregroundStyle(Ink.accent).accessibilityHidden(true)
                            Text(store.summary == nil ? "Сначала создайте конспект" : "В конспекте пока нет карточек")
                                .font(.system(size: 20, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
                            Text(store.summary == nil
                                 ? "ИИ выберет из транскрипта полезные фразы и понятия. Каждая карточка будет связана с исходной цитатой."
                                 : "Для карточек нужны полезные фразы или важные понятия с цитатами. Уточните фокус встречи и создайте конспект заново.")
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                                .multilineTextAlignment(.center).frame(maxWidth: 460)
                            Button("Открыть конспект") { store.tab = "summary" }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                        }.padding(26).frame(maxWidth: .infinity, minHeight: 230)
                            .background(Ink.soft, in: RoundedRectangle(cornerRadius: 16))
                    }
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        if mode == "all" {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(cards) { card in
                                    Button { picked = card.id; flipped = false } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(card.front).font(.system(size: 12, weight: .medium)).lineLimit(3)
                                            Text(card.kind == "phrase" ? "Английская фраза" : "Понятие").font(.system(size: 11)).foregroundStyle(.secondary)
                                        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(current?.id == card.id ? Ink.accent.opacity(0.08) : Ink.soft,
                                                        in: RoundedRectangle(cornerRadius: 8))
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel("\(card.kind == "phrase" ? "Английская фраза" : "Понятие"): \(card.front)")
                                        .accessibilityAddTraits(current?.id == card.id ? .isSelected : [])
                                        .accessibilityHint("Открыть карточку")
                                }
                            }.frame(width: 210)
                        }
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            if let card = current { study(card) }
                            else {
                                VStack(spacing: 15) {
                                    Image(systemName: "checkmark.seal").font(.system(size: 36, weight: .light)).foregroundStyle(Ink.green).accessibilityHidden(true)
                                    Text("Сейчас нет карточек к повторению").font(.system(size: 20, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
                                    Text("Следующее повторение запланировано по вашим ответам. Вернитесь позже или откройте все карточки.")
                                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
                                    Button("Открыть все карточки") { mode = "all" }.buttonStyle(.bordered)
                                }.padding(28).frame(maxWidth: .infinity, minHeight: 260)
                                    .background(Ink.soft, in: RoundedRectangle(cornerRadius: 16))
                            }
                        }.frame(maxWidth: .infinity)
                    }
                }
                if !cards.isEmpty {
                    Label("После ответа оцените, насколько легко удалось его вспомнить.", systemImage: "calendar.badge.clock")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("Следующее повторение рассчитывается по алгоритму FSRS")
                }
            }.padding(20)
        }
        if flipped, let card = current {
            VStack(spacing: 7) {
                HStack(spacing: 9) {
                    rating(card, 1, "Снова", .red)
                    rating(card, 2, "Трудно", .orange)
                    rating(card, 3, "Хорошо", Ink.green)
                    rating(card, 4, "Легко", Ink.accent)
                }
                if let state = store.reviews[card.id] {
                    Text("Повторений: \(state.count) · Следующий показ: \(dueDate(state.due))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 32).padding(.vertical, 12).background(Ink.paper)
                .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
        }
        }.onChange(of: current?.id) { _, _ in flipped = false }
            .onChange(of: store.busy) { _, busy in if !busy { exampleCardID = nil } }
            .onChange(of: store.navigationTarget?.id) { _, _ in navigateToCard() }
            .onAppear {
                navigateToCard()
                if ProcessInfo.processInfo.arguments.contains("--preview-all") { mode = "all" }
                if ProcessInfo.processInfo.arguments.contains("--preview"), ProcessInfo.processInfo.arguments.contains("--preview-answer") { flipped = true }
            }
    }

    private func navigateToCard() {
        guard let target = store.navigationTarget, target.meetingID == store.selection, target.kind == "card",
              let id = target.cardID, cards.contains(where: { $0.id == id }) else { return }
        mode = "all"; picked = id; flipped = false
    }
    private func study(_ card: Flashcard) -> some View {
        let makingExample = store.busy && exampleCardID == card.id
        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(card.kind == "phrase" ? "Английская фраза" : "Важное понятие", systemImage: card.kind == "phrase" ? "quote.bubble" : "lightbulb")
                    Spacer()
                    Text(flipped ? "Ответ" : "Вспомните ответ")
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.accent)
                Text(card.front).font(.system(size: 24, weight: .medium, design: .rounded)).tracking(-0.3)
                    .lineSpacing(4).textSelection(.enabled).padding(.vertical, 6)
                    .accessibilityLabel("Карточка: \(card.front)")
                if flipped {
                    Rectangle().fill(Ink.line).frame(height: 1)
                    Text(card.back).font(.system(size: 15)).lineSpacing(7).textSelection(.enabled)
                        .accessibilityLabel("Ответ: \(card.back)")
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Цитата из транскрипта").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            EvidenceButton(ids: card.segmentIDs).accessibilityLabel("Открыть цитату в транскрипте")
                        }
                        Text("«\(card.context)»").font(.system(size: 12)).lineSpacing(5).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(14).background(Ink.soft, in: RoundedRectangle(cornerRadius: 9))
                    Button { exampleCardID = card.id; store.makeExample(card) } label: {
                        HStack(spacing: 7) {
                            if makingExample { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                            Label(makingExample ? "Создаю пример…" : (store.examples[card.id] == nil ? "Придумать пример" : "Придумать другой пример"),
                                  systemImage: "sparkles")
                        }
                    }.buttonStyle(.bordered).disabled(store.busy || store.isRecording)
                        .accessibilityHint("Создать новый пример с этой карточкой. Исходная цитата сохранится.")
                    if let example = store.examples[card.id] {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Пример от ИИ", systemImage: "sparkles").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.accent)
                            Text(example.example).font(.system(size: 14, weight: .medium)).lineSpacing(4).textSelection(.enabled)
                            Text(example.translation).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                                .accessibilityLabel("Перевод примера: \(example.translation)")
                            Text(example.explanation).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).textSelection(.enabled)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Ink.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if store.settings.mode == "cloud" {
                        Text("OpenAI получит эту карточку и её контекст. Создание примера оплачивается через API.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(card.kind == "phrase" ? "Как бы вы перевели и использовали эту фразу?" : "Сформулируйте ответ своими словами.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Показать ответ") { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { flipped = true } }
                        .buttonStyle(.borderedProminent).tint(Ink.actionFill).controlSize(.large).keyboardShortcut(.space, modifiers: [])
                        .help("Показать ответ · Пробел")
                        .accessibilityHint("Открыть ответ и исходную цитату. Можно нажать пробел.")
                        .padding(.top, 8)
                    Text("Пробел — показать ответ").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: 720, alignment: .leading)
                .padding(22).frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
                .background(Ink.paper, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Ink.accent.opacity(0.13)))
                .accessibilityElement(children: .contain)
        }
    }
    private func rating(_ card: Flashcard, _ value: Int, _ label: String, _ color: Color) -> some View {
        Button { store.rate(card, value) } label: {
            HStack(spacing: 7) {
                Text("\(value)").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.25)))
        }.buttonStyle(.plain).disabled(store.busy || store.isRecording).keyboardShortcut(KeyEquivalent(Character(String(value))), modifiers: [])
            .accessibilityLabel("\(label): \(ratingDescription(value))")
            .accessibilityHint("Запланировать следующее повторение. Клавиша \(value).")
            .help("\(ratingDescription(value)) · \(value)")
    }
    private func ratingDescription(_ value: Int) -> String {
        switch value {
        case 1: return "Не удалось вспомнить ответ"
        case 2: return "Вспомнил с трудом"
        case 3: return "Вспомнил правильно"
        default: return "Вспомнил без усилий"
        }
    }
    private func dueDate(_ string: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string) else { return "позже" }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ru_RU")))
    }
}
