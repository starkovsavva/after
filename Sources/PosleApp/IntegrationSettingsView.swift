import SwiftUI

/// Trackers and agent access have different setup flows. Keep each one visible
/// without pushing either connection form below an unrelated settings section.
struct IntegrationSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var section = "trackers"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            AppTabBar(label: L("Вид интеграции"), selection: $section, tabs: [
                AppTab(L("Трекеры"), value: "trackers"),
                AppTab(L("Агенты"), value: "agents")
            ], identifier: "integrations.section", fillsWidth: true)

            if section == "trackers" {
                TrackerSyncSettingsView(coordinator: store.trackerSync)
            } else {
                AgentIntegrationSettings()
            }
        }
    }
}
