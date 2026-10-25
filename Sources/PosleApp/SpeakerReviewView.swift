import AppKit
import PosleCore
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
                Text("Собеседники").font(AppTypography.modalTitle)
                Spacer()
                Text("Найдено: \(detected)").font(AppTypography.control).foregroundStyle(.secondary)
            }
            Picker("Количество участников", selection: $automatic) {
                Text("Указать число").tag(false)
                Text("Автоматически").tag(true)
            }.pickerStyle(.segmented).tint(Ink.actionFill).labelsHidden().accessibilityLabel("Способ определения числа участников")
            if !automatic {
                HStack {
                    Text("Участников в записи")
                    Spacer()
                    TextField("Количество", value: $count, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 60).accessibilityLabel("Точное количество участников")
                    Stepper("Участники", value: $count, in: 1...100).labelsHidden()
                }
                Text("Включая вас, если вы говорили.").font(AppTypography.caption).foregroundStyle(.secondary)
            }
            Text("Имена голосов потребуется задать заново. Текст, время и ссылки сохранятся.")
                .font(AppTypography.control).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Подробнее") {
                Text("Предыдущие метки и имена сохранятся в истории. Пересчёт не меняет границы реплик; проверьте длинные фрагменты и одновременную речь.")
                    .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if FileManager.default.fileExists(atPath: history.path) {
                    Button { NSWorkspace.shared.open(history) } label: { Label("История", systemImage: "clock.arrow.circlepath") }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(store.runtimeReady ? "Пересчитать" : "Подготовить распознавание") {
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
