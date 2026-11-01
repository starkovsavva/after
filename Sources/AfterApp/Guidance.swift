import AfterPlatform
import AfterLocalization
import Combine
import Foundation
import AfterCore
import SwiftUI

enum GuidancePresentation: String, Identifiable {
    case gettingStarted, whatsNew
    var id: String { rawValue }
}
enum GuidanceAction: Equatable {
    case record, importFile, speechSettings, cards, aiSettings, tasks, integrations, semantic, trash, features, support
    case settings(String)
}

private struct GuidancePreferences: Codable {
    var introSeen = false
    var knownVersion = ""
    var knownFeatureRelease = ""
    var lastLaunchedVersion: String?
    var pendingReleaseVersion: String?
    var pendingReleaseFromVersion: String?
    var pendingReleaseFromIsExact = false
    var usedFeatureIDs: Set<String> = []
    var usageSeeded = false
    var readFeatures: [String: Set<String>] = [:]
    var hintsEnabled = true
    var dismissedHints: Set<String> = []
    init() {}
    private enum CodingKeys: String, CodingKey {
        case introSeen, knownVersion, knownFeatureRelease, lastLaunchedVersion
        case pendingReleaseVersion, pendingReleaseFromVersion, pendingReleaseFromIsExact
        case usedFeatureIDs, usageSeeded, readFeatures, hintsEnabled, dismissedHints
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        introSeen = try values.decodeIfPresent(Bool.self, forKey: .introSeen) ?? false
        knownVersion = try values.decodeIfPresent(String.self, forKey: .knownVersion) ?? ""
        knownFeatureRelease = try values.decodeIfPresent(String.self, forKey: .knownFeatureRelease) ?? ""
        lastLaunchedVersion = try values.decodeIfPresent(String.self, forKey: .lastLaunchedVersion)
        pendingReleaseVersion = try values.decodeIfPresent(String.self, forKey: .pendingReleaseVersion)
        pendingReleaseFromVersion = try values.decodeIfPresent(String.self, forKey: .pendingReleaseFromVersion)
        pendingReleaseFromIsExact = try values.decodeIfPresent(Bool.self, forKey: .pendingReleaseFromIsExact) ?? false
        usedFeatureIDs = try values.decodeIfPresent(Set<String>.self, forKey: .usedFeatureIDs) ?? []
        usageSeeded = try values.decodeIfPresent(Bool.self, forKey: .usageSeeded) ?? false
        readFeatures = try values.decodeIfPresent([String: Set<String>].self, forKey: .readFeatures) ?? [:]
        hintsEnabled = try values.decodeIfPresent(Bool.self, forKey: .hintsEnabled) ?? true
        dismissedHints = try values.decodeIfPresent(Set<String>.self, forKey: .dismissedHints) ?? []
    }
}

/// Guidance stores only version markers and local feature IDs. It never reads
/// meeting content, enables a feature, requests access, or starts work itself.
@MainActor
final class GuidanceController: ObservableObject {
    static let shared = GuidanceController()
    @Published var presentation: GuidancePresentation?
    @Published private(set) var hintsEnabled = true
    @Published private(set) var dismissedHints: Set<String> = []
    @Published private(set) var error: String?
    @Published private(set) var featureGroups: [ReleaseFeatureSection] = []
    @Published var selectedFeatureID: String?
    private(set) var previousVersion: String?
    private(set) var previousVersionIsExact = false
    private var preferences = GuidancePreferences()
    private var root: URL?
    private var preview = false
    private var active: GuidancePresentation?
    private var pendingAction: GuidanceAction?
    private var consideredStartup = false
    private let versionOverride: String?
    private var features = AppFeatures()
    private var updates: [ReleaseFeatureUpdate] = []
    var currentVersion: String { versionOverride ?? AppVersion.current ?? "development" }
    var releaseVersion: String { currentVersion }
    var selectedFeature: ReleaseFeatureUpdate? { updates.first { $0.id == selectedFeatureID } }
    var changeCounts: (added: Int, changed: Int, fixed: Int) {
        let changes = updates.flatMap(\.changes)
        return (changes.filter { $0.kind == .added }.count, changes.filter { $0.kind == .changed }.count,
                changes.filter { $0.kind == .fixed }.count)
    }
    init(version: String? = nil) { versionOverride = version }

    func configure(root: URL, preview: Bool) {
        guard self.root != root || self.preview != preview else { return }
        self.root = root; self.preview = preview; consideredStartup = false
        preferences = GuidancePreferences(); presentation = nil; active = nil; pendingAction = nil; error = nil
        selectedFeatureID = nil; previousVersion = nil; previousVersionIsExact = false
        var loaded = true
        do {
            let url = root.appendingPathComponent("guidance.json")
            if FileManager.default.fileExists(atPath: url.path) {
                try validateFile(url)
                preferences = try JSONDecoder().decode(GuidancePreferences.self, from: Data(contentsOf: url))
            }
        } catch {
            loaded = false
            preferences.introSeen = true; preferences.knownVersion = currentVersion
            self.error = L("Не удалось открыть настройки подсказок.")
        }
        hintsEnabled = preferences.hintsEnabled; dismissedHints = preferences.dismissedHints
        prepareVersionHistory()
        rebuildFeatures()
        if loaded { persist() }
    }

    private func prepareVersionHistory() {
        guard let current = ReleaseVersion(currentVersion) else { return }
        if preferences.pendingReleaseVersion == currentVersion {
            previousVersion = preferences.pendingReleaseFromVersion
            previousVersionIsExact = preferences.pendingReleaseFromIsExact
        } else {
            let last = preferences.lastLaunchedVersion.flatMap(ReleaseVersion.init)
            if let last, last < current {
                previousVersion = preferences.lastLaunchedVersion; previousVersionIsExact = true
            } else if last == nil {
                previousVersion = [preferences.knownVersion, preferences.knownFeatureRelease].first {
                    ReleaseVersion($0).map { $0 < current } == true
                }
            }
            if last == nil || last! < current {
                preferences.pendingReleaseVersion = currentVersion
                preferences.pendingReleaseFromVersion = previousVersion
                preferences.pendingReleaseFromIsExact = previousVersionIsExact
            }
        }
        preferences.lastLaunchedVersion = currentVersion
    }

    func considerStartup(hasMeetings: Bool, canPresent: Bool = true) {
        guard root != nil, !preview, !consideredStartup, canPresent, presentation == nil else { return }
        consideredStartup = true
        if !preferences.introSeen && !hasMeetings && preferences.knownVersion.isEmpty
            && preferences.knownFeatureRelease.isEmpty && previousVersion == nil {
            presentGettingStarted(); return
        }
        guard let current = ReleaseVersion(currentVersion),
              preferences.knownVersion.isEmpty || ReleaseVersion(preferences.knownVersion).map({ $0 < current }) != false,
              preferences.pendingReleaseVersion == currentVersion, !updates.isEmpty else { return }
        presentWhatsNew()
    }
    func presentGettingStarted() { active = .gettingStarted; presentation = .gettingStarted }
    func presentWhatsNew() {
        rebuildFeatures()
        if selectedFeature == nil { selectedFeatureID = featureGroups.first?.updates.first?.id }
        active = .whatsNew; presentation = .whatsNew
    }
    func complete(with action: GuidanceAction? = nil) {
        pendingAction = action
        finishPresentation()
    }
    /// Escape and window-close accept this presentation, but do not mark hidden
    /// feature details as read. The exact upgrade baseline survives a relaunch
    /// while presentation is deferred or the app quits before dismissal.
    func finishPresentation() {
        guard let active else { return }
        if active == .gettingStarted { preferences.introSeen = true }
        if let current = ReleaseVersion(currentVersion),
           ReleaseVersion(preferences.knownVersion).map({ $0 <= current }) != false {
            preferences.knownVersion = currentVersion
        }
        if preferences.pendingReleaseVersion == currentVersion {
            preferences.pendingReleaseVersion = nil
            preferences.pendingReleaseFromVersion = nil
            preferences.pendingReleaseFromIsExact = false
        }
        self.active = nil; presentation = nil
        persist()
    }
    func takeAction() -> GuidanceAction? { defer { pendingAction = nil }; return pendingAction }

    func updateFeatures(_ features: AppFeatures) {
        guard self.features != features else { return }
        self.features = features; rebuildFeatures()
    }
    /// Existing objects seed prior usage once. Merely enabling a workflow does
    /// not establish that the user has used it.
    func seedUsage(_ ids: Set<String>) {
        guard !preferences.usageSeeded else { return }
        preferences.usageSeeded = true
        if preferences.usedFeatureIDs.isEmpty {
            preferences.usedFeatureIDs.formUnion(ids.intersection(ReleaseNotesCatalog.featureIDs))
        }
        rebuildFeatures(); persist()
    }
    func recordUsage(_ id: String, root: URL? = nil) {
        let id = id == "inbox" ? "notes" : id
        guard self.root != nil, root == nil || root == self.root,
              ReleaseNotesCatalog.featureIDs.contains(id), !preferences.usedFeatureIDs.contains(id) else { return }
        preferences.usedFeatureIDs.insert(id); rebuildFeatures(); persist()
    }
    private func rebuildFeatures() {
        updates = ReleaseNotesCatalog.updates(from: previousVersion, through: currentVersion)
        featureGroups = ReleaseFeatureGroup.allCases.compactMap { group in
            let values = updates.filter { update in
                let actual: ReleaseFeatureGroup
                if let required = update.requiredFeature, !features[required] { actual = .disabled }
                else if update.isNewFeature { actual = .new }
                else if preferences.usedFeatureIDs.contains(update.id) { actual = .used }
                else { actual = .other }
                return actual == group
            }
            return values.isEmpty ? nil : ReleaseFeatureSection(group: group, updates: values)
        }
        if let selectedFeatureID, !updates.contains(where: { $0.id == selectedFeatureID }) { self.selectedFeatureID = nil }
    }
    func selectFeature(_ id: String) {
        guard updates.contains(where: { $0.id == id }) else { return }
        selectedFeatureID = id; markSelectedRead()
    }
    func isUnread(_ id: String) -> Bool {
        updates.contains { $0.id == id } && !(preferences.readFeatures[currentVersion]?.contains(id) ?? false)
    }
    func markSelectedRead() {
        guard let selectedFeature, isUnread(selectedFeature.id) else { return }
        preferences.readFeatures[currentVersion, default: []].insert(selectedFeature.id)
        objectWillChange.send(); persist()
    }
    func openFeatureSettings(_ id: String) {
        guard let feature = updates.first(where: { $0.id == id }) else { return }
        let section = feature.requiredFeature.map { features[$0] ? feature.settingsSection : "features" } ?? feature.settingsSection
        complete(with: .settings(section))
    }
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
            throw AppError.message(L("Неверный файл настроек подсказок."))
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
        } catch { self.error = L("Не удалось сохранить настройки подсказок.") }
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
                    .buttonStyle(.plain).foregroundStyle(Ink.secondaryText).accessibilityLabel(L("Скрыть подсказку"))
            }.padding(12).background(Ink.soft, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
