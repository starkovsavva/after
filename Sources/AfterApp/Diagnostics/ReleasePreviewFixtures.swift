#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import Foundation
import AfterCore
import AppKit

/// Fictional release illustrations. These values are only read by --preview
/// own-view rendering and never create connections, credentials or model jobs.
@MainActor
enum ReleasePreviewFixtures {
    static let semanticSources = [
        KnowledgeSource(id: "phrase-circle-back", kind: "card", title: "circle back",
                        excerpt: "Вернуться к вопросу позже, чтобы продолжить обсуждение.\nLet's circle back to the onboarding flow on Friday.",
                        meetingID: "demo-product", cardID: "demo-circle-back", sourceFingerprint: "preview"),
        KnowledgeSource(id: "phrase-follow-up", kind: "card", title: "follow up with the team",
                        excerpt: "Связаться с командой повторно и уточнить результат.\nPlease follow up with the team before the pilot starts.",
                        meetingID: "demo-access", cardID: "demo-follow-up", sourceFingerprint: "preview"),
        KnowledgeSource(id: "source-friday", kind: "transcript", title: "Запуск пилота · Майкл · 03:10",
                        excerpt: "Let's circle back to the onboarding flow on Friday. I can put together a first draft before then.",
                        meetingID: "demo-product", segmentID: 1, sourceFingerprint: "preview")
    ]

    static var trackers: TrackerSyncState {
        var personal = TrackerSyncConfiguration()
        personal.id = "personal-google"; personal.account = "Личный"; personal.provider = "google"
        personal.enabled = true; personal.pushEnabled = true
        personal.scopes = ["personal", "english"]
        personal.scopeTitles = ["personal": "Личное", "english": "Английский"]
        personal.lastSync = Date().timeIntervalSince1970 - 120
        var project = TrackerSyncConfiguration()
        project.id = "product-yandex"; project.account = "Команда продукта"; project.provider = "yandex"
        project.enabled = true; project.pushEnabled = false
        project.scopes = ["PILOT"]
        project.scopeTitles = ["PILOT": "Запуск пилота"]
        project.lastSync = Date().timeIntervalSince1970 - 180
        var state = TrackerSyncState()
        state.configurations = [personal, project]
        state.linkedCount = 28
        return state
    }

    /// Runs before AppStore opens notes, jobs, or recovery state. Other launch
    /// modes keep their existing data-root behavior.
    static func preflightDataRoot() {
        if let error = dataRootValidationError(arguments: ProcessInfo.processInfo.arguments,
                                              environment: ProcessInfo.processInfo.environment) {
            fputs("Preview data-root preflight failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func dataRootValidationError(arguments: [String], environment: [String: String]) -> String? {
        let audit = arguments.contains("--check-search-fields")
        let screen = arguments.firstIndex(of: "--preview-screen").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let readme = screen?.hasPrefix("readme-") == true
        guard audit || readme else { return nil }
        guard !(audit && readme) else { return "Choose one disposable preview mode." }
        guard arguments.contains("--preview") else { return "Disposable screenshot modes require --preview." }
        guard let path = environment["POSLE_DATA_DIR"], (path as NSString).isAbsolutePath else {
            return "Disposable screenshot modes require an explicit absolute POSLE_DATA_DIR."
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = audit ? "posle-native-check-" : "posle-readme-"
        guard root.deletingLastPathComponent() == temporary, root.lastPathComponent.hasPrefix(prefix) else {
            return "Disposable screenshot root must be /private/tmp/" + prefix + "*."
        }
        return nil
    }

    static func prepare(_ store: AppStore, screen: String) {
        guard store.isPreview else { return }
        if screen == "assistant" { store.voice.seedPreview("voice-answer") }
        if screen == "tracker-sync" { store.trackerSync.seedPreview(trackers) }
        guard screen.hasPrefix("readme-") else { return }
        let root = URL(fileURLWithPath: store.root.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let parent = root.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let explicitRoot = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }
        guard explicitRoot == root, parent == temporaryDirectory, root.lastPathComponent.hasPrefix("posle-readme-") else {
            fputs("README previews require an explicit disposable fixture; parent=\(String(reflecting: parent.path)), name=\(String(reflecting: root.lastPathComponent)), explicit=\(explicitRoot == root), temporary=\(parent == temporaryDirectory)\n", stderr)
            exit(1)
        }
        struct Scene: Decodable { let noteID: String; let taskID: String }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("readme-fixture.json")),
              let scene = try? JSONDecoder().decode(Scene.self, from: data) else {
            fputs("README preview fixture is missing\n", stderr); exit(1)
        }
        switch screen {
        case "readme-summary": store.openMeeting("demo-product", tab: "summary")
        case "readme-notes": store.librarySection = "inbox"; store.notes.selectedNoteID = scene.noteID
        case "readme-knowledge": store.librarySection = "knowledge"
        case "readme-task-history": store.openTask(id: scene.taskID)
        case "readme-cards": store.librarySection = "cards"
        default: fputs("Unknown README preview scene\n", stderr); exit(1)
        }
    }

    /// Navigate the real mounted controls instead of duplicating production
    /// history or collection layouts in a screenshot-only widget.
    static func navigateReadme(_ store: AppStore, screen: String, in view: NSView) {
        guard store.isPreview else { return }
        let identifier: String
        switch screen {
        case "readme-task-history": identifier = "tasks.tab.history"
        case "readme-knowledge": identifier = "knowledge.section.collections"
        default: return
        }
        Task { @MainActor in
            for _ in 0..<40 {
                view.layoutSubtreeIfNeeded()
                if NativeTabNavigation.contains(identifier, in: view) {
                    do { try NativeTabNavigation.press(identifier, in: view) }
                    catch { fputs("README preview navigation failed: \(error)\n", stderr); exit(1) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            fputs("README preview control did not mount: \(identifier)\n", stderr); exit(1)
        }
    }
}
#endif
