import AppKit
import PosleCore
import SwiftUI

/// Correct speaker grouping independently of speech recognition. The count is
/// per operation, so fixing one call does not change defaults for future calls.
struct SpeakerReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let meetingID: String
    @State private var automatic = false
    @State private var count = 4
    private var detected: Int {
        Set((store.transcript?.segments ?? []).map(\.speaker).filter { $0 != "unknown" }).count
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            AppPageHeader(title: "Собеседники", subtitle: "Найдено голосов: \(detected). Если один человек получил несколько меток, уточните число участников.", modal: true)
            Toggle("Определять количество автоматически", isOn: $automatic)
            HStack {
                Text("Всего участников, включая вас")
                Spacer()
                TextField("Количество", value: $count, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                    .accessibilityLabel("Точное количество участников")
                Stepper("Участники", value: $count, in: 1...100).labelsHidden()
            }.disabled(automatic)
            Text("Укажите тех, кто говорил в записи. На отдельных дорожках ваш микрофон уже входит в общее число.")
                .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Label("Текст, таймкоды и ссылки из конспекта сохранятся.", systemImage: "text.badge.checkmark")
                Label("Прежние метки и имена сохранятся в истории. Новые голоса можно назвать заново.", systemImage: "clock.arrow.circlepath")
                Text("ИИ может путать похожие голоса и одновременную речь. После пересчёта проверьте несколько реплик.")
                    .foregroundStyle(.secondary)
            }.font(AppTypography.control).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Показать историю") {
                    do {
                        let directory = store.meetingDirectory(meetingID)
                        let history = directory.appendingPathComponent("diarization-history")
                        if FileManager.default.fileExists(atPath: history.path) { NSWorkspace.shared.open(history) }
                        else { NSWorkspace.shared.open(directory) }
                    }
                }.buttonStyle(.borderless)
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Пересчитать собеседников") {
                    let requested = automatic ? 0 : count
                    dismiss()
                    Task { await store.rediarizeMeeting(meetingID, speakers: requested) }
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.defaultAction)
                    .disabled(!automatic && !(1...100).contains(count) || store.busy || store.isRecording || !store.runtimeReady)
            }
        }.padding(AppLayout.contentInset).frame(width: 620).appControlDefaults()
            .onAppear { count = store.settings.speakerCount > 0 ? store.settings.speakerCount : 4 }
    }
}
