import SwiftUI

/// Trackers and agent access have different setup flows. Keep each one visible
/// without pushing either connection form below an unrelated settings section.
struct IntegrationSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            AppTabBar(label: L("Вид интеграции"), selection: $store.integrationSettingsSection, tabs: [
                AppTab(L("Трекеры"), value: "trackers"),
                AppTab(L("Агенты"), value: "agents")
            ], identifier: "integrations.section", fillsWidth: true)

            if store.integrationSettingsSection == "trackers" {
                TrackerSyncSettingsView(coordinator: store.trackerSync)
            } else {
                AgentIntegrationSettings()
            }
        }
    }
}
