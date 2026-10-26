import Foundation
import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Обновления", systemImage: "arrow.triangle.2.circlepath")
                .font(AppTypography.heading).accessibilityAddTraits(.isHeader)
            LabeledContent("Версия", value: updates.currentVersion)
            Toggle("Проверять автоматически", isOn: Binding(
                get: { updates.automaticallyChecks },
                set: { updates.setAutomaticChecks($0) }
            )).disabled(!updates.isAvailable).accessibilityIdentifier("updates.automatic")
            Button("Проверить обновления…") { updates.checkForUpdates() }
                .buttonStyle(.bordered).disabled(!updates.isAvailable || !updates.canCheck)
                .accessibilityIdentifier("updates.check")
            if let checked = updates.lastChecked {
                LabeledContent("Последняя проверка") {
                    Text(checked.formatted(.dateTime.day().month(.abbreviated).hour().minute()
                        .locale(Locale(identifier: "ru_RU"))))
                }.font(AppTypography.caption).foregroundStyle(.secondary)
            }
            if let status = updates.status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(status).font(AppTypography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("updates.status")
            }
            Link("История версий", destination: URL(string: "https://github.com/starkovsavva/posle/releases")!)
                .font(AppTypography.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 20).overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}
