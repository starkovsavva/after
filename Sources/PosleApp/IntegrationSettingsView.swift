import SwiftUI

/// Trackers and agent access have different setup flows. Keep each one visible
/// without pushing either connection form below an unrelated settings section.
struct IntegrationSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var section = "trackers"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker(L("Вид интеграции"), selection: $section) {
                Text(L("Трекеры")).tag("trackers")
                Text(L("Агенты")).tag("agents")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .tint(Ink.actionFill)
            .accessibilityIdentifier("integrations.section")

            if section == "trackers" {
                TrackerSyncSettingsView(coordinator: store.trackerSync)
            } else {
                AgentIntegrationSettings()
            }
        }
    }
}
