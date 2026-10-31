import AfterLocalization
import AppKit
import AfterCore
import SwiftUI

/// Shared recording defaults. macOS asks for an explicit screen selection at
/// capture time, so saved monitor IDs cannot block a new recording after updates.
struct RecordingOptionsView: View {
    @Binding var audioQuality: RecordingAudioQuality
    @Binding var video: Bool
    @Binding var videoQuality: RecordingVideoQuality
    var systemAudio = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L("Качество аудио"), selection: $audioQuality) {
                ForEach(RecordingAudioQuality.allCases) { Text(L($0.title)).tag($0) }
            }.accessibilityIdentifier("record.audioQuality")
            Toggle(L("Сохранять видео экрана"), isOn: $video)
                .accessibilityIdentifier("record.video")
            if video {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L("Качество видео"), selection: $videoQuality) {
                        ForEach(RecordingVideoQuality.allCases) { Text(L($0.title)).tag($0) }
                    }.accessibilityIdentifier("record.videoQuality").help(L(videoQuality.detail))
                    Text(L("MP4 · H.264 · 30 кадров/с"))
                        .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                        .accessibilityIdentifier("record.format")
                }.padding(.leading, 20)
            }
            if systemAudio || video {
                Label(L("При запуске записи или проверки звука выберите экран в окне macOS. Доступ действует только на эту запись."), systemImage: "macwindow.on.rectangle")
                    .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("record.screenSelection")
                if systemAudio && !video {
                    Text(L("Видео не сохраняется. Экран нужен для доступа к звуку Mac."))
                        .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("record.audioSelection")
                }
            }
        }.font(AppTypography.control)
    }
}

/// A sparse per-meeting override; inheritance stays nil and follows folder changes.
struct CardGenerationPicker: View {
    @Binding var selection: String
    let inherited: Bool
    let inheritedTitle: String
    let identifier: String
    var body: some View {
        Picker(L("Автосоздание карточек"), selection: $selection) {
            Text(inheritedTitle + (inherited ? L(" · создавать") : L(" · не создавать"))).tag("inherit")
                .accessibilityIdentifier(identifier + ".inherit")
            Text(L("Создавать при обновлении конспекта")).tag("on")
                .accessibilityIdentifier(identifier + ".on")
            Text(L("Не создавать для этой встречи")).tag("off")
                .accessibilityIdentifier(identifier + ".off")
        }.pickerStyle(.radioGroup).accessibilityIdentifier(identifier)
    }
}
