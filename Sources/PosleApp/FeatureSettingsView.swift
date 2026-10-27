import PosleCore
import SwiftUI

/// One place to choose which optional workflows appear in the app.
/// Turning a workflow off changes availability, never its stored content.
struct FeatureSettingsView: View {
    @EnvironmentObject private var store: AppStore
    private let features = AppFeature.allCases
    private var locked: Bool {
        store.isRecording || store.startingRecording || store.stoppingRecording || store.busy || store.jobs.activeCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Возможности", systemImage: "square.grid.2x2").font(AppTypography.heading)
                .accessibilityAddTraits(.isHeader)
            Text("Это настройки по умолчанию. У папок могут быть свои возможности.")
                .font(AppTypography.control).foregroundStyle(Ink.secondaryText)
            VStack(spacing: 0) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    Toggle(isOn: binding(for: feature)) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: FeaturePresentation.icon(feature))
                                .foregroundStyle(Ink.secondaryText).frame(width: 22).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(FeaturePresentation.title(feature)).font(AppTypography.controlStrong)
                                Text(FeaturePresentation.detail(feature)).font(AppTypography.caption)
                                    .foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).padding(.vertical, 14)
                        .accessibilityIdentifier("features." + FeaturePresentation.identifier(feature))
                    if index < features.count - 1 { Divider() }
                }
            }.disabled(locked)
            if locked {
                Text("Изменить возможности можно после завершения записи и обработки.")
                    .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
            }
            Text("При отключении данные сохраняются. Их можно снова открыть, включив возможность здесь.")
                .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func binding(for feature: AppFeature) -> Binding<Bool> {
        Binding(get: { store.settings.isEnabled(feature) }, set: { enabled in
            guard !locked else { return }
            store.setFeature(feature, enabled: enabled)
        })
    }
}

/// Deep links and previously selected screens must not silently enable features.
struct OptionalFeatureGate: View {
    @EnvironmentObject private var store: AppStore
    let feature: AppFeature
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: FeaturePresentation.icon(feature)).font(.system(size: 32, weight: .light))
                .foregroundStyle(Ink.secondaryText).accessibilityHidden(true)
            Text(FeaturePresentation.title(feature)).font(AppTypography.sectionTitle)
            Text("Включите эту возможность в настройках. Сохранённые данные останутся на месте.")
                .font(AppTypography.control).foregroundStyle(Ink.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            Button("Выбрать возможности…") { store.openSettings("features") }
                .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                .accessibilityIdentifier("features.openSettings")
        }.padding(AppLayout.contentInset).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum FeaturePresentation {
    static func identifier(_ feature: AppFeature) -> String { feature.rawValue }
    static func title(_ feature: AppFeature) -> String { feature.title }
    static func icon(_ feature: AppFeature) -> String {
        switch feature {
        case .cards: "rectangle.on.rectangle"
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .assistant: "mic"
        case .semanticSearch: "sparkle.magnifyingglass"
        }
    }
    static func detail(_ feature: AppFeature) -> String {
        switch feature {
        case .cards: "Создание, импорт и повторение карточек."
        case .tasks: "Задачи, материалы проектов, подключения трекеров и доступ агентов."
        case .calendar: "События и подключение календарей macOS."
        case .assistant: "Вопросы по библиотеке и поручения текстом или голосом."
        case .semanticSearch: "Поиск по смыслу с отдельной моделью. Поиск по словам доступен всегда."
        }
    }
}
