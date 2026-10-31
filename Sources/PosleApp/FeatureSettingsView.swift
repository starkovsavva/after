import PosleCore
import SwiftUI

/// One place to choose which optional workflows appear in the app.
/// Turning a workflow off changes availability, never its stored content.
struct FeatureSettingsView: View {
    @EnvironmentObject private var store: AppStore
    var showsTitle = true
    private let features = AppFeature.allCases
    private var locked: Bool {
        store.isRecording || store.startingRecording || store.stoppingRecording || store.busy || store.jobs.activeCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showsTitle {
                Label(L("Возможности"), systemImage: "square.grid.2x2").font(AppTypography.heading)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(L("По умолчанию для всех папок. В каждой папке можно оставить «Как в приложении» или выбрать свои возможности."))
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
                Text(L("Изменить возможности можно после завершения записи и обработки."))
                    .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
            }
            Text(L("«Все папки» показывает разделы, включённые хотя бы в одной папке или здесь. При отключении данные сохраняются."))
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

/// Shared entry point from the sidebar and a clean folder editor.
struct FeatureDefaultsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Общие возможности")).font(AppTypography.modalTitle)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel(L("Закрыть общие возможности"))
            }.padding(22)
            Divider()
            ScrollView { FeatureSettingsView(showsTitle: false).padding(26) }
            Divider()
            HStack {
                if let error = store.error {
                    Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning).lineLimit(2).help(error)
                }
                Spacer()
                Button(L("Готово")) { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .tint(Ink.actionFill).accessibilityIdentifier("features.defaults.close")
            }.padding(18)
        }.frame(width: 620, height: 650).background(Ink.paper).tint(Ink.accent).appControlDefaults()
    }
}

/// Deep links and previously selected screens must not silently enable features.
struct OptionalFeatureGate: View {
    @EnvironmentObject private var store: AppStore
    let feature: AppFeature
    private var folder: LibraryFolder? {
        if store.librarySection == "meetings", let id = store.selection {
            return store.notes.folder(store.folderID(for: id))
        }
        return store.notes.folder(store.folderSelection)
    }
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: FeaturePresentation.icon(feature)).font(.system(size: 32, weight: .light))
                .foregroundStyle(Ink.secondaryText).accessibilityHidden(true)
            Text(FeaturePresentation.title(feature)).font(AppTypography.sectionTitle)
            Text(folder == nil ? L("Включите эту возможность в общих настройках. Сохранённые данные останутся на месте.") : L("Включите эту возможность в настройках папки. Сохранённые данные останутся на месте."))
                .font(AppTypography.control).foregroundStyle(Ink.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            Button(folder == nil ? L("Общие возможности…") : L("Возможности папки…")) {
                if let folder {
                    NotificationCenter.default.post(name: Notification.Name("PosleEditFolder"), object: folder.id, userInfo: ["section": "features"])
                } else { store.openSettings("features") }
            }
                .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                .accessibilityIdentifier("features.openSettings")
        }.padding(AppLayout.contentInset).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum FeaturePresentation {
    static func identifier(_ feature: AppFeature) -> String { feature.rawValue }
    static func title(_ feature: AppFeature) -> String { L(feature.title) }
    static func icon(_ feature: AppFeature) -> String {
        switch feature {
        case .cards: "rectangle.on.rectangle"
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .assistant: "mic"
        case .semanticSearch: "sparkle.magnifyingglass"
        case .knowledgeBase: "link"
        }
    }
    static func detail(_ feature: AppFeature) -> String {
        switch feature {
        case .cards: L("Создание, импорт и повторение карточек.")
        case .tasks: L("Задачи, материалы проектов, подключения трекеров и доступ агентов.")
        case .calendar: L("События и подключение календарей macOS.")
        case .assistant: L("Вопросы по библиотеке и поручения текстом или голосом.")
        case .semanticSearch: L("Поиск по смыслу с отдельной моделью. Поиск по словам доступен всегда.")
        case .knowledgeBase: L("Связи между заметками и переходы к связанным материалам.")
        }
    }
}
