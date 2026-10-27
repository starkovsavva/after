import AppKit
import PosleCore
import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var overviewMeetingID: String?
    @State private var overviewDraft = ""
    @State private var originalOverview = ""
    @State private var originalGeneratedAt = 0.0
    @FocusState private var overviewFocused: Bool
    @State private var showingFocus = false
    @State private var editingInsight: InsightEditTarget?

    private var overviewEditing: Bool { overviewMeetingID != nil && overviewMeetingID == store.selection }
    private var overviewLocked: Bool { false }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Menu {
                        Picker("Где создавать конспект", selection: $store.settings.mode) {
                            Text("На Mac").tag("local"); Text("Облако").tag("cloud")
                        }
                    } label: { Label(store.settings.mode == "cloud" ? "Облако" : "На Mac", systemImage: store.settings.mode == "cloud" ? "cloud" : "laptopcomputer") }
                        .menuStyle(.borderlessButton).frame(width: 110).disabled(overviewLocked || overviewEditing)
                        .onChange(of: store.settings.mode) { _, _ in store.saveSettings() }
                    Button { showingFocus = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(overviewLocked || overviewEditing).accessibilityLabel("Контекст встречи")
                        .help("Цель встречи и что важно выписать")
                        .popover(isPresented: $showingFocus) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Контекст встречи").font(AppTypography.heading)
                                Text("Цель встречи").font(AppTypography.control)
                                TextField("Например: синк с руководителем о прогрессе и следующих шагах", text: Binding(get: { store.selected?.meetingPurpose ?? "" }, set: { value in
                                    if let id = store.selection {
                                        store.updateMeeting(id) { $0.meetingPurpose = String(value.prefix(300)) }
                                    }
                                }), axis: .vertical)
                                    .font(AppTypography.control).lineLimit(2...4).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Цель встречи")
                                Text("На что обратить внимание").font(AppTypography.control)
                                TextEditor(text: Binding(get: { store.selected?.focus ?? "" }, set: { value in
                                    if let id = store.selection { store.updateMeeting(id) { $0.focus = value } }
                                })).font(AppTypography.body).frame(height: 110).padding(8).background(Ink.field, in: RoundedRectangle(cornerRadius: 6))
                                Text("Факты берутся из транскрипта. После изменения контекста обновите конспект.")
                                    .font(AppTypography.caption).foregroundStyle(.secondary)
                                HStack { Spacer(); Button("Готово") { showingFocus = false } }
                            }.padding(20).frame(width: 420)
                        }
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .help("Создано ИИ. Проверяйте цифры и договорённости по исходным репликам.")
                        .accessibilityLabel("Создано ИИ. Проверяйте цифры и договорённости по исходным репликам.")
                    Spacer()
                    Button { store.summarizeSelected() } label: {
                        Label(store.summary == nil ? "Создать конспект" : "Обновить", systemImage: "sparkles").frame(minWidth: 120)
                    }.buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(overviewLocked || overviewEditing)
                }
                if store.settings.mode == "cloud" {
                    Text(cloudContextDisclosure)
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                }

                if store.summary == nil && overviewEditing {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Черновик конспекта").font(AppTypography.heading)
                        overviewEditor
                    }
                }
                if let summary = store.summary {
                    if summary.sourceStale || summary.overviewStale {
                        Label(summary.sourceStale ? "Транскрипт исправлен. Проверьте конспект или обновите его." : "Пункты исправлены. Краткий конспект может требовать обновления.", systemImage: "arrow.triangle.2.circlepath")
                            .font(AppTypography.control).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Text("Кратко").font(AppTypography.heading)
                            Spacer()
                            if !overviewEditing {
                                Button("Изменить") { beginOverviewEdit(summary) }
                                    .buttonStyle(.borderless).disabled(overviewLocked)
                            }
                        }
                        if overviewEditing {
                            overviewEditor
                        } else {
                            if summary.hasVerifiedOverviewClaims(transcript: store.transcript) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(summary.overviewClaims.enumerated()), id: \.offset) { index, claim in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(claim.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                                            ClaimReferenceButton(claim: claim, number: index + 1, summary: summary)
                                        }
                                    }
                                }.frame(maxWidth: 700, alignment: .leading)
                            } else {
                                Text(summary.overview).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                                    .frame(maxWidth: 700, alignment: .leading)
                                if !summary.items.isEmpty {
                                    DisclosureGroup("Факты этой встречи") {
                                        VStack(alignment: .leading, spacing: 14) {
                                            Text("Проверяйте конспект по фактам и исходным репликам ниже. Новый конспект добавит ссылки к отдельным утверждениям.")
                                                .font(AppTypography.caption).foregroundStyle(.secondary)
                                            ForEach(summary.items) { item in
                                                HStack(alignment: .top, spacing: 12) {
                                                    Text(item.text).font(AppTypography.body).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                                                    EvidenceButton(ids: item.segmentIDs)
                                                }
                                            }
                                        }.padding(.top, 12)
                                    }.font(AppTypography.control).padding(.top, 4)
                                }
                            }
                        }
                    }.padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(overviewTargeted ? Ink.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
                        .id("summary-overview")
                    ForEach(["decision", "action", "detail", "question"], id: \.self) { kind in
                        let items = summary.items.filter { $0.kind == kind }
                        if !items.isEmpty { section(kind, items) }
                    }
                    ForEach(summary.warnings, id: \.self) { Text($0).font(AppTypography.caption).foregroundStyle(Ink.warning) }
                } else if !overviewEditing {
                    VStack(alignment: .leading, spacing: 15) {
                        Image(systemName: "text.badge.star").font(.system(size: 35)).foregroundStyle(Ink.accent)
                        Text("Конспект не создан").font(AppTypography.emptyTitle)
                        Button("Настройки ИИ") { store.openSettings("ai") }.buttonStyle(.bordered)
                    }.padding(.vertical, 45).frame(maxWidth: 540, alignment: .leading)
                }
            }.appContentLayout()
        }
        .onAppear { scrollToTarget(proxy) }
        .onChange(of: store.navigationTarget?.id) { _, _ in scrollToTarget(proxy) }
        .onAppear { restoreOverviewDraft() }
        .onChange(of: store.selection) { _, _ in restoreOverviewDraft() }
        .onChange(of: store.summary?.generatedAt) { _, _ in
            if !overviewEditing { restoreOverviewDraft() }
        }
        .onDisappear { endOverviewEdit() }
        .sheet(item: $editingInsight) { target in
            SummaryInsightEditor(meetingID: target.meetingID, itemIndex: target.index).environmentObject(store)
        }
        }
    }
    private var cloudContextDisclosure: String {
        let hasContext = !store.settings.summaryUserContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(store.selected?.meetingPurpose ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let content = hasContext ? "текст встречи и указанный контекст" : "текст встречи"
        return store.settings.cloudProvider == "chatgpt"
            ? "ChatGPT получит \(content). Используются лимиты вашей подписки."
            : "\(store.settings.cloudProviderTitle) получит \(content). Запрос оплачивается через API."
    }

    private var overviewEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: Binding(get: { overviewDraft }, set: { text in
                overviewDraft = text
                if let id = overviewMeetingID {
                    store.rememberOverviewDraft(text, meetingID: id, original: originalOverview, generatedAt: originalGeneratedAt)
                }
            }))
                .font(AppTypography.body).lineSpacing(7)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150, maxHeight: 280).padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
                .accessibilityLabel("Редактирование краткого конспекта")
                .focused($overviewFocused)
                .disabled(overviewLocked)
            if overviewConflict {
                HStack {
                    Text("Исходный конспект изменился. Правку можно сохранить в заметки.")
                        .font(AppTypography.control).foregroundStyle(Ink.warning)
                    Spacer()
                    Button("В заметки") {
                        guard let id = overviewMeetingID,
                              store.notes.capture(text: overviewDraft, meetingID: id) != nil else { return }
                        cancelOverviewEdit()
                        store.notice = "Правка сохранена в заметки встречи"
                    }.buttonStyle(.bordered)
                }
            }
            HStack(spacing: 10) {
                if overviewDraft != originalOverview {
                    Text("Есть несохранённые изменения").font(AppTypography.control).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отмена") { cancelOverviewEdit() }
                    .buttonStyle(.bordered).disabled(overviewLocked)
                Button("Сохранить") {
                    guard let id = overviewMeetingID else { return }
                    if store.saveOverview(overviewDraft, meetingID: id, expectedOverview: originalOverview,
                                          expectedGeneratedAt: originalGeneratedAt) {
                        cancelOverviewEdit()
                    }
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    .disabled(overviewLocked || overviewConflict || overviewDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || overviewDraft == originalOverview)
            }
        }
    }
    private var overviewTargeted: Bool {
        guard let target = store.navigationTarget, target.meetingID == store.selection else { return false }
        return ["overview", "title"].contains(target.kind)
    }
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = store.navigationTarget, target.meetingID == store.selection else { return }
        let id = target.kind == "item" ? "summary-item-\(target.itemIndex ?? -1)" : "summary-overview"
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
    }
    private var overviewConflict: Bool {
        guard overviewEditing else { return false }
        guard let summary = store.summary else { return true }
        return summary.generatedAt != originalGeneratedAt || summary.overview != originalOverview
    }
    private func restoreOverviewDraft() {
        endOverviewEdit()
        guard let id = store.selection, let draft = store.overviewDrafts[id] else { return }
        overviewMeetingID = id; overviewDraft = draft.text
        originalOverview = draft.original; originalGeneratedAt = draft.generatedAt
        store.editingOverview = true
    }
    private func beginOverviewEdit(_ summary: Summary) {
        guard let id = store.selection, !overviewLocked else { return }
        overviewMeetingID = id; store.editingOverview = true
        overviewDraft = summary.overview
        originalOverview = summary.overview
        originalGeneratedAt = summary.generatedAt
        DispatchQueue.main.async { overviewFocused = true }
    }
    private func cancelOverviewEdit() {
        if let id = overviewMeetingID { store.discardOverviewDraft(id) }
        endOverviewEdit()
    }
    private func endOverviewEdit() {
        overviewMeetingID = nil; store.editingOverview = false
        overviewDraft = ""
        originalOverview = ""
        originalGeneratedAt = 0
    }
    private func section(_ kind: String, _ items: [Insight]) -> some View {
        let title = ["decision": "Решения", "action": "Задачи", "detail": "Детали", "question": "Вопросы"][kind]!
        let icon = ["decision": "checkmark.seal", "action": "checklist", "detail": "pin", "question": "questionmark.bubble"][kind]!
        return VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(AppTypography.heading)
            ForEach(items) { item in
                let index = store.summary?.items.firstIndex(where: { $0.id == item.id }) ?? -1
                let targeted = store.navigationTarget?.meetingID == store.selection && store.navigationTarget?.kind == "item" && store.navigationTarget?.itemIndex == index
                HStack(alignment: .top, spacing: 12) {
                    if kind == "action" {
                        Button { store.toggleTask(item) } label: {
                            Image(systemName: store.taskCompleted(item) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(Ink.accent).font(.system(size: 18)).frame(width: 30, height: 30).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.busy || store.isRecording).accessibilityLabel("Выполнение задачи")
                            .accessibilityValue(store.taskCompleted(item) ? "Выполнена" : "Не выполнена")
                    } else { Circle().fill(Ink.accent.opacity(0.45)).frame(width: 5, height: 5).padding(.top, 6) }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                            .strikethrough(kind == "action" && store.taskCompleted(item))
                        if !item.owner.isEmpty || !item.due.isEmpty {
                            HStack(spacing: 12) {
                                if !item.owner.isEmpty { Label(item.owner, systemImage: "person") }
                                if !item.due.isEmpty { Label(item.due, systemImage: "calendar") }
                            }.font(AppTypography.control).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    EvidenceButton(ids: item.segmentIDs)
                    Button {
                        if let id = store.selection, index >= 0 { editingInsight = InsightEditTarget(meetingID: id, index: index) }
                    } label: { Image(systemName: "pencil").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Изменить пункт").accessibilityLabel("Изменить пункт конспекта")
                }.padding(.vertical, 9).padding(.horizontal, 10)
                    .background(targeted ? Ink.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    .id("summary-item-\(index)")
            }
        }.padding(.bottom, 4)
    }
}

private struct InsightEditTarget: Identifiable { let id = UUID(); let meetingID: String; let index: Int }
