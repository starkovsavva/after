import SwiftUI

struct VoiceCommandOverlay: View {
    @ObservedObject var controller: VoiceCommandController
    var body: some View {
        if controller.isPresented {
            VoiceCommandPanel(controller: controller)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct VoiceCommandPanel: View {
    @ObservedObject private var theme = ThemeController.shared
    @EnvironmentObject private var app: AppStore
    @ObservedObject var controller: VoiceCommandController
    @FocusState private var commandFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "mic").foregroundStyle(.secondary)
                Text("Помощник").font(AppTypography.control.weight(.semibold))
                Spacer()
                if controller.result == nil && controller.hasDraft && !controller.isWorking {
                    Button { controller.reset(); commandFocused = true } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Новое поручение").accessibilityLabel("Новое поручение")
                }
                Button { controller.dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Закрыть поручение").accessibilityLabel("Закрыть поручение")
                    .disabled(controller.phase == .applying)
            }
            Text(controller.knowledgeAnswer == nil ? controller.contextLabel : controller.text).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(2)
            if let answer = controller.knowledgeAnswer {
                KnowledgeAnswerView(answer: answer, openingID: controller.knowledgeOpeningID, open: controller.openKnowledgeSource)
                HStack {
                    Button { KnowledgeAnswerView.copy(answer) } label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Скопировать ответ").accessibilityLabel("Скопировать ответ")
                    Spacer()
                    Button("Уточнить") { controller.continueQuestion(); commandFocused = true }.buttonStyle(.borderless)
                    Button("Новый вопрос") { controller.reset(); commandFocused = true }.buttonStyle(.borderless)
                }
            } else if let result = controller.result {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.green)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.title).font(AppTypography.heading)
                        Text(result.detail).font(AppTypography.body).lineLimit(6).textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Открыть") { controller.openResult() }.buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(controller.isWorking)
                    if result.canUndo { Button("Отменить изменение") { controller.undo() }.buttonStyle(.borderless).disabled(controller.isWorking) }
                    if controller.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Продолжить") { controller.continueCommand(); commandFocused = true }.buttonStyle(.borderless).disabled(controller.isWorking)
                    Button { controller.reset(); commandFocused = true } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).disabled(controller.isWorking).help("Новое поручение").accessibilityLabel("Новое поручение")
                }
            } else if let plan = controller.plan, plan.reviewRequired == true, [.reviewing, .applying].contains(controller.phase) {
                Text(plan.title).font(AppTypography.heading)
                if ["appendTaskContext", "appendTaskContexts", "appendTask"].contains(plan.action ?? "") {
                    TextField("Что добавить к задачам", text: $controller.reviewText, axis: .vertical)
                        .font(AppTypography.body).lineLimit(3...6)
                        .textFieldStyle(.plain).padding(10)
                        .background(Ink.soft, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel("Текст дополнения")
                        .accessibilityIdentifier("voice-review-text").disabled(controller.isWorking)
                } else {
                    Text(plan.detail).font(AppTypography.control).foregroundStyle(.secondary)
                }
                HStack {
                    Text(reviewLabel(plan.action)).font(AppTypography.control.weight(.medium))
                    Spacer()
                    Text("Выбрано: \(controller.selectedTargetIDs.count)")
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(plan.candidates ?? []) { candidate in
                            Toggle(isOn: Binding(
                                get: { controller.selectedTargetIDs.contains(candidate.id) },
                                set: { controller.toggleReviewTarget(candidate, selected: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                                        Text(candidate.title).font(AppTypography.body).lineLimit(2)
                                        if candidate.completed == true {
                                            Text("Выполнена").font(AppTypography.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    if let reason = candidate.reason, !reason.isEmpty {
                                        Text(reason).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit((plan.action ?? "").contains("Cards") ? 8 : 3).textSelection(.enabled)
                                    } else if !candidate.detail.isEmpty {
                                        Text(candidate.detail).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit((plan.action ?? "").contains("Cards") ? 8 : 3)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox).padding(.vertical, 9)
                            .accessibilityIdentifier("voice-review-target-\(candidate.id)").disabled(controller.isWorking)
                            if candidate.id != plan.candidates?.last?.id { Divider() }
                        }
                    }
                }.frame(maxHeight: 240)
                HStack {
                    Button("Изменить поручение") { controller.editCommand(); commandFocused = true }
                        .buttonStyle(.borderless).disabled(controller.isWorking)
                    Spacer()
                    Button { controller.confirmReview() } label: {
                        HStack(spacing: 7) {
                            if controller.phase == .applying { ProgressView().controlSize(.small) }
                            Text(controller.phase == .applying ? "Сохраняю…" : "Применить")
                        }
                    }
                        .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                        .disabled(!controller.canConfirmReview || app.busy)
                        .accessibilityIdentifier("voice-review-confirm")
                }
            } else if controller.phase == .choosing, let plan = controller.plan {
                Text(plan.title).font(AppTypography.heading)
                Text(plan.detail).font(AppTypography.control).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(plan.candidates ?? []) { candidate in
                            Button { controller.choose(candidate) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.title).font(AppTypography.body).lineLimit(2)
                                        if !candidate.detail.isEmpty { Text(candidate.detail).font(AppTypography.caption).foregroundStyle(.secondary).lineLimit((plan.action ?? "").contains("Cards") ? 8 : 3) }
                                    }
                                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(.vertical, 10).padding(.horizontal, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 200)
                Button("Изменить поручение") { controller.editCommand(); commandFocused = true }.buttonStyle(.borderless)
            } else {
                TextField("Спросите о встречах или поручите добавить мысль к задаче", text: $controller.text, axis: .vertical)
                    .font(AppTypography.body).lineLimit(3...6).textFieldStyle(.plain)
                    .focused($commandFocused).disabled(controller.isWorking)
                    .accessibilityLabel("Текст поручения").accessibilityIdentifier("voice-command-text")
                HStack(spacing: 10) {
                    Button {
                        if controller.phase == .capturing { controller.finishDictation() }
                        else { controller.startDictation() }
                    } label: {
                        Image(systemName: controller.phase == .capturing ? "stop.fill" : "mic.fill")
                            .frame(width: 28, height: 28)
                            .foregroundStyle(controller.phase == .capturing ? Ink.recordFill : Ink.accent)
                    }.buttonStyle(.borderless)
                        .disabled(controller.isWorking && controller.phase != .capturing)
                        .help(controller.phase == .capturing ? "Завершить диктовку" : "Надиктовать поручение")
                        .accessibilityLabel(controller.phase == .capturing ? "Завершить диктовку" : "Надиктовать поручение")
                    if controller.isWorking {
                        if controller.phase != .capturing { ProgressView().controlSize(.small) }
                        Text(phaseLabel).font(AppTypography.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if controller.phase != .applying { Button("Остановить") { controller.cancelWork() }.buttonStyle(.borderless) }
                    } else {
                        Text(app.settings.speechMode == "local" ? "Диктовка на Mac" : app.settings.speechDestinationLabel)
                            .font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Выполнить") { commandFocused = false; controller.perform() }
                            .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                            .disabled(controller.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.busy)
                            .keyboardShortcut(.return, modifiers: [.command])
                    }
                }
            }
            if let message = controller.message {
                Text(message).font(AppTypography.caption).foregroundStyle(controller.phase == .reviewing ? Ink.warning : .secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice-command-message")
            }
        }
        .padding(18).frame(width: 430, alignment: .leading)
        .appSurface(.floatingPanel)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 5)
        .onAppear { commandFocused = true }
        .onExitCommand { controller.dismiss() }
        .accessibilityElement(children: .contain).accessibilityLabel("Помощник")
    }
    private func reviewLabel(_ action: String?) -> String {
        let value = action ?? ""
        if value.contains("Cards") { return "Карточки" }
        if value.hasSuffix("Meeting") { return "Встреча" }
        if value.hasSuffix("Note") { return "Заметка" }
        return "Задачи"
    }
    private var phaseLabel: String {
        switch controller.phase {
        case .authorizing: "Включаю микрофон…"
        case .capturing: "Слушаю…"
        case .transcribing: "Распознаю…"
        case .planning: "Разбираю…"
        case .applying: "Сохраняю…"
        default: ""
        }
    }
}
