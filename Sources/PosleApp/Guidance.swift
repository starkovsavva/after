import Combine
import Foundation
import SwiftUI

enum GuidancePresentation: String, Identifiable {
    case gettingStarted, whatsNew
    var id: String { rawValue }
}
enum GuidanceAction { case record, importFile, speechSettings, cards, aiSettings, tasks, integrations, semantic, trash, features }

private struct GuidancePreferences: Codable {
    var introSeen = false
    var knownVersion = ""
    var knownFeatureRelease = ""
    var hintsEnabled = true
    var dismissedHints: Set<String> = []
    init() {}
    private enum CodingKeys: String, CodingKey { case introSeen, knownVersion, knownFeatureRelease, hintsEnabled, dismissedHints }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        introSeen = try values.decodeIfPresent(Bool.self, forKey: .introSeen) ?? false
        knownVersion = try values.decodeIfPresent(String.self, forKey: .knownVersion) ?? ""
        knownFeatureRelease = try values.decodeIfPresent(String.self, forKey: .knownFeatureRelease) ?? ""
        hintsEnabled = try values.decodeIfPresent(Bool.self, forKey: .hintsEnabled) ?? true
        dismissedHints = try values.decodeIfPresent(Set<String>.self, forKey: .dismissedHints) ?? []
    }
}

/// A separate, inert preference file. Guidance never records, imports, opens
/// an account or requests permissions until the user chooses that action.
@MainActor
final class GuidanceController: ObservableObject {
    static let shared = GuidanceController()
    @Published var presentation: GuidancePresentation?
    @Published private(set) var hintsEnabled = true
    @Published private(set) var dismissedHints: Set<String> = []
    @Published private(set) var error: String?
    private var preferences = GuidancePreferences()
    private var root: URL?
    private var preview = false
    private var active: GuidancePresentation?
    private var pendingAction: GuidanceAction?
    private var consideredStartup = false
    // Bump only when a release introduces something worth teaching.
    private let featureRelease = "0.16"
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }

    func configure(root: URL, preview: Bool) {
        guard self.root != root else { return }
        self.root = root; self.preview = preview; consideredStartup = false
        preferences = GuidancePreferences(); presentation = nil; active = nil; pendingAction = nil; error = nil
        do {
            let url = root.appendingPathComponent("guidance.json")
            if FileManager.default.fileExists(atPath: url.path) {
                try validateFile(url)
                preferences = try JSONDecoder().decode(GuidancePreferences.self, from: Data(contentsOf: url))
            }
        } catch {
            // Damaged preferences must not interrupt opening a working library.
            preferences.introSeen = true; preferences.knownVersion = currentVersion; preferences.knownFeatureRelease = featureRelease
            self.error = "Не удалось открыть настройки подсказок."
        }
        hintsEnabled = preferences.hintsEnabled; dismissedHints = preferences.dismissedHints
    }
    func considerStartup(hasMeetings: Bool) {
        guard root != nil, !preview, !consideredStartup else { return }
        consideredStartup = true
        if !preferences.introSeen && !hasMeetings { presentGettingStarted() }
        else if preferences.knownFeatureRelease != featureRelease { presentWhatsNew() }
    }
    func presentGettingStarted() { active = .gettingStarted; presentation = .gettingStarted }
    func presentWhatsNew() { active = .whatsNew; presentation = .whatsNew }
    func complete(with action: GuidanceAction? = nil) {
        pendingAction = action
        finishPresentation()
    }
    /// Call from the sheet's onDismiss too, so Escape/window-close stays final.
    func finishPresentation() {
        guard let active else { return }
        if active == .gettingStarted { preferences.introSeen = true }
        preferences.knownVersion = currentVersion
        preferences.knownFeatureRelease = featureRelease
        self.active = nil; presentation = nil
        persist()
    }
    /// Root routes this only after the sheet has closed, avoiding stacked sheets.
    func takeAction() -> GuidanceAction? { defer { pendingAction = nil }; return pendingAction }
    func setHintsEnabled(_ enabled: Bool) {
        preferences.hintsEnabled = enabled; hintsEnabled = enabled; persist()
    }
    func shouldShowHint(_ id: String) -> Bool { hintsEnabled && !dismissedHints.contains(id) }
    func dismissHint(_ id: String) {
        preferences.dismissedHints.insert(id); dismissedHints = preferences.dismissedHints; persist()
    }
    private func validateFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 65_536 else {
            throw AppError.message("Неверный файл настроек подсказок.")
        }
    }
    private func persist() {
        guard let root, !preview else { return }
        do {
            let url = root.appendingPathComponent("guidance.json")
            if FileManager.default.fileExists(atPath: url.path) { try validateFile(url) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preferences).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            error = nil
        } catch { self.error = "Не удалось сохранить настройки подсказок." }
    }
}

struct GuidanceSheet: View {
    @ObservedObject var controller: GuidanceController
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                AppPageHeader(title: controller.presentation == .gettingStarted ? "Начните со встречи" : "Что нового в «После»", modal: true)
                Button { controller.complete() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Закрыть")
            }
            if controller.presentation == .gettingStarted {
                Text("Запишите звонок или добавьте готовое аудио. После соберёт транскрипт и конспект со ссылками на реплики. Дополнительные возможности можно включить в настройках.")
                    .font(AppTypography.body).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button { controller.complete(with: .record) } label: { Label("Записать встречу", systemImage: "record.circle") }
                        .buttonStyle(.borderedProminent).tint(Ink.actionFill)
                    Button { controller.complete(with: .importFile) } label: { Label("Добавить файл…", systemImage: "arrow.down.doc") }.buttonStyle(.bordered)
                }
                Button("Выбрать локальную или облачную модель") { controller.complete(with: .speechSettings) }.buttonStyle(.borderless)
            } else {
                HStack {
                    feature("Только нужные возможности", "Встречи, заметки, конспекты и транскрипты доступны сразу. Карточки, задачи, календарь, помощник и смысловой поиск включаются отдельно.", "square.grid.2x2")
                    Button("Выбрать") { controller.complete(with: .features) }.buttonStyle(.bordered)
                }
                HStack {
                    feature("Корзина на 30 дней", "Встречи, заметки, задачи и карточки можно восстановить после удаления.", "trash")
                    Button("Открыть") { controller.complete(with: .trash) }.buttonStyle(.bordered)
                }
                HStack {
                    feature("Контекст конспекта", "Укажите свою роль и цель встречи, чтобы конспект точнее выделял главное.", "text.bubble")
                    Button("Настроить") { controller.complete(with: .aiSettings) }.buttonStyle(.bordered)
                }
            }
            Divider()
            HStack(spacing: 14) {
                Toggle("Подсказки по ходу работы", isOn: Binding(get: { controller.hintsEnabled }, set: { controller.setHintsEnabled($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button(controller.presentation == .gettingStarted ? "Позже" : "Понятно") { controller.complete() }
                    .buttonStyle(.bordered).keyboardShortcut(controller.presentation == .gettingStarted ? .cancelAction : .defaultAction)
            }
            if let error = controller.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning) }
        }.padding(28).frame(width: 580).appControlDefaults().tint(Ink.accent).background(Ink.paper)
    }
    private func feature(_ title: String, _ text: String, _ image: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: image).font(.system(size: 20)).foregroundStyle(Ink.accent).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(AppTypography.controlStrong)
                Text(text).font(AppTypography.body).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct GuidanceHint: View {
    @ObservedObject var controller: GuidanceController
    let id: String
    let text: String
    var body: some View {
        if controller.shouldShowHint(id) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lightbulb").foregroundStyle(Ink.secondaryText)
                Text(text).font(AppTypography.control).foregroundStyle(Ink.secondaryText).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { controller.dismissHint(id) } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).foregroundStyle(Ink.secondaryText).accessibilityLabel("Скрыть подсказку")
            }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
