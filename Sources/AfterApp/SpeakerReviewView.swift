import AfterLocalization
import AppKit
import AfterCore
import SwiftUI

struct SpeakerReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let meetingID: String
    @State private var automatic = false
    @State private var count = 1
    private var detected: Int {
        Set((store.transcript?.segments ?? []).map(\.speaker).filter { $0 != "unknown" }).count
    }
    private var history: URL { store.meetingDirectory(meetingID).appendingPathComponent("diarization-history") }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L("Собеседники")).font(AppTypography.modalTitle)
                Spacer()
                Text(LF("Найдено: {0}", arguments: [String(describing: (detected))])).font(AppTypography.control).foregroundStyle(.secondary)
            }
            Picker(L("Количество участников"), selection: $automatic) {
                Text(L("Указать число")).tag(false)
                Text(L("Автоматически")).tag(true)
            }.pickerStyle(.segmented).tint(Ink.actionFill).labelsHidden().accessibilityLabel(L("Способ определения числа участников"))
            if !automatic {
                HStack {
                    Text(L("Участников в записи"))
                    Spacer()
                    TextField(L("Количество"), value: $count, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 60).accessibilityLabel(L("Точное количество участников"))
                    Stepper(L("Участники"), value: $count, in: 1...100).labelsHidden()
                }
                Text(L("Включая вас, если вы говорили.")).font(AppTypography.caption).foregroundStyle(.secondary)
            }
            Text(L("Имена голосов потребуется задать заново. Текст, время и ссылки сохранятся."))
                .font(AppTypography.control).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L("Подробнее")) {
                Text(L("Предыдущие метки и имена сохранятся в истории. Пересчёт не меняет границы реплик; проверьте длинные фрагменты и одновременную речь."))
                    .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if FileManager.default.fileExists(atPath: history.path) {
                    Button { NSWorkspace.shared.open(history) } label: { Label(L("История"), systemImage: "clock.arrow.circlepath") }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(store.runtimeReady ? L("Пересчитать") : L("Подготовить распознавание")) {
                    if store.runtimeReady {
                        let requested = automatic ? 0 : count
                        dismiss(); Task { await store.rediarizeMeeting(meetingID, speakers: requested) }
                    } else { dismiss(); store.openSettings("speech") }
                }.buttonStyle(.borderedProminent).tint(Ink.actionFill).keyboardShortcut(.defaultAction)
                    .disabled((store.runtimeReady && !automatic && !(1...100).contains(count)) || store.busy || store.isRecording)
            }
        }.padding(AppLayout.contentInset).frame(width: 560).appControlDefaults()
            .onAppear { count = min(100, max(1, store.settings.speakerCount > 0 ? store.settings.speakerCount : detected)) }
    }
}
