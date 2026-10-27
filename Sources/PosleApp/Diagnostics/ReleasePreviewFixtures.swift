#if DEBUG
import Foundation
import PosleCore

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

    static func prepare(_ store: AppStore, screen: String) {
        guard store.isPreview else { return }
        if screen == "assistant" { store.voice.seedPreview("voice-answer") }
        if screen == "tracker-sync" { store.trackerSync.seedPreview(trackers) }
    }
}
#endif
