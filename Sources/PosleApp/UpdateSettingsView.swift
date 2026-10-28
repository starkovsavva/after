import AppKit
import Foundation
import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Обновления", systemImage: "arrow.triangle.2.circlepath")
                .font(AppTypography.heading).accessibilityAddTraits(.isHeader)
            LabeledContent("Версия", value: updates.currentVersion)
            if let version = updates.availableVersion {
                HStack {
                    Label("Доступна версия \(version)", systemImage: "arrow.down.circle")
                    Spacer()
                    Button("Обновить…") { updates.checkForUpdates() }.buttonStyle(.borderedProminent).tint(Ink.actionFill)
                        .disabled(!updates.canCheck).accessibilityIdentifier("updates.install")
                }
            }
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
            if updates.waitingForWork {
                Text("Проверка и установка обновлений доступны после завершения записи и обработки.")
                    .font(AppTypography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("updates.waiting")
            } else if let status = updates.status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(status).font(AppTypography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("updates.status")
            }
            if updates.settingsSaveFailed {
                Button("Повторить установку") { updates.retryInstallation() }
                    .buttonStyle(.bordered).disabled(updates.waitingForWork).accessibilityIdentifier("updates.retryInstall")
            }
            Link("История версий", destination: URL(string: "https://github.com/starkovsavva/posle/releases")!)
                .font(AppTypography.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 20).overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}

/// A quiet, optional affordance; no automatic modal or action on launch.
struct UpdateAvailabilityButton: View {
    @ObservedObject var updates: AppUpdateController
    @State private var presented = false
    var body: some View {
        if updates.showsUpdateAnnouncement, let version = updates.availableVersion {
            Button { presented.toggle() } label: {
                Label("Версия \(version)", systemImage: "arrow.down.circle")
                    .font(AppTypography.caption).lineLimit(1).padding(.horizontal, 9).frame(height: 28)
                    .background(Ink.soft, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help("Доступно обновление «После»")
                .accessibilityLabel("Доступна версия \(version)").accessibilityIdentifier("updates.announcement")
                .popover(isPresented: $presented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Доступна версия \(version)").font(AppTypography.heading)
                        HStack(spacing: 12) {
                            Button("Обновить…") { presented = false; updates.checkForUpdates() }
                                .buttonStyle(.borderedProminent).tint(Ink.actionFill).disabled(!updates.canCheck)
                            Button("Позже") { presented = false; updates.dismissUpdateAnnouncement() }.buttonStyle(.bordered)
                        }
                    }.padding(20).appControlDefaults().frame(minWidth: 280)
                }
        }
    }
}

/// Reads only this sheet's native window, rather than guessing from the key
/// window (which belongs to Sparkle as soon as its installer is shown).
struct UpdateSettingsWindowReader: NSViewRepresentable {
    let updates: AppUpdateController
    func makeNSView(context: Context) -> WindowReader { WindowReader(updates: updates) }
    func updateNSView(_ view: WindowReader, context: Context) { view.updates = updates }
    final class WindowReader: NSView {
        weak var updates: AppUpdateController?
        init(updates: AppUpdateController) { self.updates = updates; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { updates?.registerSettingsWindow(window) }
        }
    }
}

struct SettingsDraftWarning: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        if let message = updates.settingsDraftStatus {
            Text(message).font(AppTypography.caption).foregroundStyle(Ink.warning)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.unsaved.warning")
        }
    }
}
