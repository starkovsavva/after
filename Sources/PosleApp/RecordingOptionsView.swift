import AppKit
import PosleCore
import SwiftUI

extension RecordingDisplay {
    /// Preview and native checks use invented monitors and never enumerate user devices.
    @MainActor static func choices(preview: Bool) -> [RecordingDisplay] {
        if preview {
            return [.init(id: 1, title: "Встроенный дисплей", pixelWidth: 2560, pixelHeight: 1664,
                          isMain: true, persistentID: "preview-built-in"),
                    .init(id: 2, title: "Внешний дисплей", pixelWidth: 3840, pixelHeight: 2160,
                          isMain: false, persistentID: "preview-external")]
        }
        return MeetingRecorder.availableDisplays()
    }

    static func selectionIsAvailable(_ uuid: String, in displays: [RecordingDisplay]) -> Bool {
        uuid.isEmpty ? displays.contains(where: \.isMain) : displays.contains { $0.persistentID == uuid }
    }
}

/// The same controls before a meeting and in Settings, with no separate set of defaults.
struct RecordingOptionsView: View {
    @Binding var audioQuality: RecordingAudioQuality
    @Binding var video: Bool
    @Binding var videoQuality: RecordingVideoQuality
    @Binding var displayUUID: String
    let displays: [RecordingDisplay]

    private var displayIsAvailable: Bool { RecordingDisplay.selectionIsAvailable(displayUUID, in: displays) }
    private var selectedDisplay: RecordingDisplay? {
        displayUUID.isEmpty ? displays.first(where: \.isMain) : displays.first { $0.persistentID == displayUUID }
    }
    private var videoDescription: String {
        guard let display = selectedDisplay,
              let size = videoQuality.dimensions(width: Double(display.pixelWidth), height: Double(display.pixelHeight)) else {
            return "MP4 · H.264 · 30 кадров/с"
        }
        return "MP4 · \(size.width) × \(size.height) · 30 кадров/с"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Качество аудио", selection: $audioQuality) {
                ForEach(RecordingAudioQuality.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("record.audioQuality")
            Toggle("Сохранять видео экрана", isOn: $video)
                .accessibilityIdentifier("record.video")
            if video {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Экран целиком", selection: $displayUUID) {
                        Text("Основной экран · автоматически").tag("")
                        ForEach(displays) { display in
                            Text("\(display.title) · \(display.pixelWidth) × \(display.pixelHeight)").tag(display.persistentID)
                        }
                        if !displayUUID.isEmpty && !displayIsAvailable {
                            Text("Экран недоступен").tag(displayUUID)
                        }
                    }.accessibilityIdentifier("record.display")
                    Picker("Качество видео", selection: $videoQuality) {
                        ForEach(RecordingVideoQuality.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("record.videoQuality").help(videoQuality.detail)
                    if displayIsAvailable {
                        Text(videoDescription).font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                            .accessibilityIdentifier("record.dimensions")
                        Text("Весь экран, включая меню, Dock и другие окна.")
                            .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                    } else {
                        Label("Экран отключён. Выберите доступный.", systemImage: "exclamationmark.triangle")
                            .font(AppTypography.caption).foregroundStyle(Ink.warning)
                            .accessibilityIdentifier("record.displayUnavailable")
                    }
                }.padding(.leading, 20)
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
        Picker("Автосоздание карточек", selection: $selection) {
            Text(inheritedTitle + (inherited ? " · создавать" : " · не создавать")).tag("inherit")
                .accessibilityIdentifier(identifier + ".inherit")
            Text("Создавать при обновлении конспекта").tag("on")
                .accessibilityIdentifier(identifier + ".on")
            Text("Не создавать для этой встречи").tag("off")
                .accessibilityIdentifier(identifier + ".off")
        }.pickerStyle(.radioGroup).accessibilityIdentifier(identifier)
    }
}
