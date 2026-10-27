import SwiftUI

/// Trackers and agent access have different setup flows. Keep each one visible
/// without pushing either connection form below an unrelated settings section.
struct IntegrationSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var section = "trackers"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("Вид интеграции", selection: $section) {
                Text("Трекеры").tag("trackers")
                Text("Агенты").tag("agents")
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
