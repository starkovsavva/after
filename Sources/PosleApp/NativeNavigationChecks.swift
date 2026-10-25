#if DEBUG
import Foundation
import PosleCore

/// Integration checks run only with an explicit, empty disposable directory.
/// They never initialize models, microphone access, cloud requests or Keychain.
@MainActor
enum NativeNavigationChecks {
    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"),
              let path = environment["POSLE_DATA_DIR"],
              isDisposableRoot(path) else {
            throw AppError.message("Navigation checks require --preview and an explicit /private/tmp/posle-native-check-* directory")
        }
        let store = AppStore(preview: true)
        try expect(store.meetings.isEmpty, "Navigation checks require an empty fixture library")
        let bridge = try RustBridge.shared.get()
        let first = Meeting(title: "Демо: первая встреча", source: "source.mp3")
        let second = Meeting(title: "Демо: доступы", source: "source.mp3")
        for meeting in [first, second] {
            let directory = store.meetingDirectory(meeting.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let metadataURL = directory.appendingPathComponent("meta.json")
            try store.write(meeting, metadataURL)
            let transcript: [String: Any] = ["duration": 80, "warnings": [], "model": "demo", "segments": [
                ["id": 0, "start": 0, "end": 10, "speaker": "speaker_1", "text": "Выдадим доступ к стенду до пятницы.", "overlap": false],
                ["id": 1, "start": 20, "end": 35, "speaker": "speaker_2", "text": "Please follow up before Friday.", "overlap": false]
            ]]
            let summary: [String: Any] = ["overview": "Выдадут доступ к стенду.", "items": [
                ["kind": "action", "text": "Выдать доступ к стенду.", "owner": "", "due": "до пятницы", "segmentIDs": [0]]
            ], "cards": [["id": "demo-follow", "kind": "phrase", "front": "follow up", "back": "Уточнить результат", "context": "Please follow up before Friday.", "segmentIDs": [1]]],
                "provider": "local", "model": "demo", "generatedAt": 1, "warnings": [],
                "overviewClaims": [["text": "Выдадут доступ к стенду.", "itemIndices": [0]]]]
            _ = try bridge.request(root: store.root, command: "write", arguments: ["path": "meetings/\(meeting.id)/transcript.json", "value": transcript])
            _ = try bridge.request(root: store.root, command: "write", arguments: ["path": "meetings/\(meeting.id)/summary.json", "value": summary])
        }
        // Alias spellings must work for new files without resolving child links.
        let shortRoot = URL(fileURLWithPath: "/tmp/" + store.root.lastPathComponent)
        try bridge.write(root: shortRoot, url: store.root.appendingPathComponent("settings.json"), value: ["focus": "Unicode и пробелы"])
        let aliasData = try bridge.read(root: store.root, url: shortRoot.appendingPathComponent("settings.json"))
        let aliasValue = try JSONSerialization.jsonObject(with: aliasData) as? [String: String]
        try expect(aliasValue?["focus"] == "Unicode и пробелы", "/tmp and /private/tmp library aliases round-trip")
        try expectThrows("Outside path must be rejected") {
            _ = try bridge.read(root: store.root, url: store.root.deletingLastPathComponent().appendingPathComponent("outside-posle.json"))
        }
        let linkedMeeting = store.root.appendingPathComponent("meetings/demo-linked")
        try FileManager.default.createSymbolicLink(at: linkedMeeting, withDestinationURL: store.meetingDirectory(second.id))
        try expectThrows("Meeting directory symlink must be rejected") {
            _ = try bridge.read(root: store.root, url: linkedMeeting.appendingPathComponent("meta.json"))
        }
        let targetURL = store.meetingDirectory(second.id).appendingPathComponent("meta.json")
        let originalTarget = try Data(contentsOf: targetURL)
        let linkedFile = store.meetingDirectory(first.id).appendingPathComponent("examples.json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: targetURL)
        try expectThrows("JSON file symlink must not be read") { _ = try bridge.read(root: store.root, url: linkedFile) }
        // Atomic replacement can replace the link, but must never follow it to another meeting.
        try bridge.write(root: store.root, url: linkedFile, value: ["demo": "replacement"])
        try expect(try Data(contentsOf: targetURL) == originalTarget, "Writing a linked filename never redirects into a different meeting")
        print("PASS: root aliases, Unicode paths, outside rejection and child symlink safety")
        store.reloadLibrary(); store.selection = first.id; store.loadSelection()
        store.libraryFilter = "Не существующее название"; store.transcriptSearch = "скрыть всё"
        store.showingSearch = true
        let response = try await search(store: store, query: "доступ")
        guard let hit = response.hits.first(where: { $0.meetingID == second.id && $0.kind == "item" }) else {
            throw AppError.message("Missing indexed fixture fact")
        }
        store.openSearchHit(hit)
        try await waitUntil { store.searchOpeningID == nil }
        try expect(store.selection == second.id && store.tab == "summary", "Cross meeting search opens correct meeting and kind")
        try expect(store.navigationTarget?.itemIndex == 0 && store.navigationTarget?.kind == "item", "Search preserves precise fact target")
        try expect(!store.isPlaying && store.libraryFilter.isEmpty && store.transcriptSearch.isEmpty, "Search opens silently and clears hidden filters")
        let targetID = store.navigationTarget?.id
        store.selectionDidChange()
        try expect(store.navigationTarget?.id == targetID, "Selection observer does not erase an explicit navigation request")
        print("PASS: native cross-meeting search, precise target and silent playback")

        store.transcriptSearch = "строка, скрывающая источник"
        store.openSegment(0)
        try expect(store.tab == "transcript" && store.transcriptSearch.isEmpty && store.playbackTime == 0, "Zero-second source clears transcript filter")
        try expect(store.navigationTarget?.segmentID == 0 && !store.isPlaying, "Zero-second source creates an explicit scroll target without audio")
        let firstCitationID = store.navigationTarget?.id
        store.openSegment(0)
        try expect(store.navigationTarget?.id != firstCitationID, "Repeated same-source citation creates a new scroll request")
        print("PASS: zero-second source, cleared transcript filter and repeat citation UUID")

        guard let oldSummary = store.summary else { throw AppError.message("Missing fixture summary") }
        try expect(oldSummary.hasVerifiedOverviewClaims(transcript: store.transcript), "Fixture claims initially verified")
        try expect(store.saveOverview("Изменённый вручную конспект.", meetingID: second.id,
                                     expectedOverview: oldSummary.overview, expectedGeneratedAt: oldSummary.generatedAt), "Manual edit saved")
        try expect(store.summary?.overviewClaims.isEmpty == true && store.summary?.items == oldSummary.items && store.summary?.cards == oldSummary.cards,
                   "Manual prose edit clears claim mapping and retains facts and cards")
        print("PASS: manual overview edit clears citations and preserves facts and cards")

        store.selection = first.id; store.loadSelection(); store.showingSearch = true
        store.searchQuery = "доступ"; store.openSearchHit(hit)
        try await waitUntil { store.searchOpeningID == nil }
        try expect(store.selection == first.id && store.showingSearch && store.searchError != nil,
                   "Stale indexed source is refused before switching meeting")
        store.cancelSearch()
        print("PASS: stale search result is refused and refreshed")
        store.showingSearch = true; store.searchQuery = "доступ"; store.updateSearch(immediate: true)
        store.searchQuery = "нет-такого-слова-987654"; store.updateSearch(immediate: true)
        try await waitUntil { !store.searching }
        try expect(store.searchHits.isEmpty, "Earlier asynchronous query cannot replace the latest result")
        store.searchQuery = "доступ"; store.updateSearch(immediate: true); store.showingSearch = false; store.cancelSearch()
        try await Task.sleep(for: .milliseconds(80))
        try expect(!store.searching && store.searchHits.isEmpty, "Closed search does not accept an in-flight result")
        print("PASS: asynchronous query generation and closed-search lifetime guards")
        print("6 native navigation checks passed")
    }
    private static func isDisposableRoot(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return ["/private/tmp", "/tmp"].contains(url.deletingLastPathComponent().path) && url.lastPathComponent.hasPrefix("posle-native-check-")
    }
    private static func search(store: AppStore, query: String) async throws -> SearchResponse {
        let root = store.root
        return try await Task.detached(priority: .userInitiated) {
            let data = try RustBridge.shared.get().request(root: root, command: "search", arguments: ["query": query, "scope": "all", "limit": 60])
            return try JSONDecoder().decode(SearchResponse.self, from: data)
        }.value
    }
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw AppError.message("Native check timed out")
    }
    private static func expectThrows(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw AppError.message(message)
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AppError.message(message) }
    }
}
#endif
