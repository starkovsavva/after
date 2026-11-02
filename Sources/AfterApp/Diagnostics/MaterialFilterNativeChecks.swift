#if DEBUG
import AfterCore
import AfterPlatform
import AfterPlatformMacOS
import Foundation

/// Topic controller boundaries use a controllable local transport over
/// explicit source memberships, without a model or external provider.
@MainActor
enum MaterialFilterNativeChecks {
    private actor TopicFixture {
        struct Call: Sendable { let command: String; let offset: Int; let folder: String? }
        private(set) var calls: [Call] = []
        private(set) var blocked = false
        private(set) var completedPages = 0
        private var blockNext = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var label = "base-"
        func setLabel(_ value: String) { label = value }
        func blockNextPage() { blockNext = true }
        func releaseBlocked() { continuation?.resume(); continuation = nil; blocked = false }
        func count(_ command: String) -> Int { calls.filter { $0.command == command }.count }
        func requested(folder: String) -> Bool { calls.contains { $0.command == "kb-topics" && $0.folder == folder } }

        func respond(_ root: URL, _ command: String, _ arguments: Data) async throws -> Data {
            let input = (try JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
            let offset = input["offset"] as? Int ?? 0
            calls.append(Call(command: command, offset: offset, folder: input["folderID"] as? String))
            if command == "kb-snapshot" { return Data("{\"workspaceRevision\":1,\"kbRevision\":1}".utf8) }
            if command.hasSuffix("-cancel") { return Data("{\"cancelled\":true}".utf8) }
            let payload: [String: Any]
            if command == "kb-topics" {
                payload = [
                    "topics": [["id": label + "page-\(offset)", "terms": ["Explicit notes \(offset)"],
                                "sources": [["noteID": "direct-note", "meetingID": "must-not-infer"]]]],
                    "collections": [["id": label + "collection", "name": "Saved collection", "nameRedacted": false,
                                     "hidden": false, "sources": [["noteID": "collection-note"]]]],
                    "nextOffset": offset < 250 ? offset + 50 : NSNull(), "partial": false,
                    "noteLimitReached": false, "topicLimitReached": false
                ]
            } else if command == "kb-mixed-topics" {
                payload = [
                    "topics": [["id": label + "mixed", "terms": ["Direct meeting source"], "method": "sharedTerms",
                                "sources": [
                                    ["kind": "note", "noteID": "mixed-note", "meetingID": "must-not-infer",
                                     "title": "Note", "fingerprint": "fixture-note"],
                                    ["kind": "meeting", "meetingID": "direct-meeting", "title": "Meeting",
                                     "fingerprint": "fixture-meeting"]]]],
                    "examined": 2, "total": 2, "semanticIndexed": 0, "offset": 0,
                    "nextOffset": NSNull(), "partial": false
                ]
            } else { throw AppError.message("Unexpected material-filter fixture request: " + command) }
            // Capture old bytes before suspending; cancellation intentionally
            // cannot stop this response, matching a blocking FFI boundary.
            let data = try JSONSerialization.data(withJSONObject: payload)
            if command == "kb-topics", blockNext {
                blockNext = false; blocked = true
                await withCheckedContinuation { continuation = $0 }
            }
            if command == "kb-topics" { completedPages += 1 }
            return data
        }
    }

    static func run(app: AppStore, root: URL) async throws {
        let resolved = root.resolvingSymlinksInPath()
        guard app.isPreview, app.root.resolvingSymlinksInPath() == resolved,
              ProcessInfo.processInfo.arguments.contains("--preview"),
              ["/private/tmp", "/tmp"].contains(resolved.deletingLastPathComponent().path),
              resolved.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Material-filter boundaries require a disposable preview root")
        }
        let originalFeatures = app.settings.features, originalFolder = app.folderSelection
        defer { app.settings.features = originalFeatures; app.folderSelection = originalFolder; _ = app.saveSettings() }
        app.folderSelection = nil
        app.settings.features.knowledgeBase = true; app.settings.features.cards = true
        guard app.saveSettings() else { throw AppError.message("Cannot save material-filter fixture feature settings") }
        try removedConditionPreferences(root: resolved)

        let fixture = TopicFixture()
        let controller = MaterialFilterController(request: { try await fixture.respond($0, $1, $2) })
        defer { controller.cancel(); Task { await fixture.releaseBlocked() } }
        let empty = MaterialFilterSet()
        try expect(controller.matchesNote(noteID: "anything", meetingID: nil, filters: empty) &&
                   controller.matchesCard(meetingID: "anything", cardID: "anything", filters: empty),
                   "No active topic field must admit every material without retrieval")
        let mixed = MaterialFilterSet(topicIDs: ["mixed:base-mixed"])
        controller.update(store: app, filters: mixed, target: .notes, revision: "initial")
        try await wait { !controller.topicsLoading && !controller.topics.isEmpty }
        try expect(controller.error == nil && controller.canLoadMoreTopics,
                   "The first bounded topic batch must retain an explicit next page")
        try expect(controller.matchesNote(noteID: "mixed-note", meetingID: nil, filters: mixed) &&
                   controller.matchesNote(noteID: "attached-note", meetingID: "direct-meeting", filters: mixed),
                   "A note must match an explicit note source or a direct meeting source")
        try expect(controller.matchesCard(meetingID: "direct-meeting", cardID: "any-card", filters: mixed),
                   "Every card in a directly selected topic source meeting must match")
        try expect(!controller.matchesCard(meetingID: "must-not-infer", cardID: "any-card", filters: mixed) &&
                   !controller.matchesNote(noteID: "outside-note", meetingID: "must-not-infer", filters: mixed),
                   "A note source's meetingID must never manufacture direct meeting membership")
        let collection = MaterialFilterSet(topicIDs: ["collection:base-collection"])
        try expect(controller.matchesNote(noteID: "collection-note", meetingID: nil, filters: collection) &&
                   !controller.matchesCard(meetingID: "must-not-infer", cardID: "card", filters: collection),
                   "Saved note collections must expose only their explicit note IDs")
        let either = MaterialFilterSet(topicIDs: ["collection:base-collection", "mixed:base-mixed"])
        try expect(controller.matchesNote(noteID: "collection-note", meetingID: nil, filters: either) &&
                   controller.matchesCard(meetingID: "direct-meeting", cardID: "card", filters: either),
                   "Selected topics combine with OR")
        let missing = MaterialFilterSet(topicIDs: ["mixed:missing"])
        try expect(!controller.matchesNote(noteID: "mixed-note", meetingID: "direct-meeting", filters: missing) &&
                   !controller.matchesCard(meetingID: "direct-meeting", cardID: "card", filters: missing),
                   "An unavailable selected topic must not silently become an unrestricted field")
        controller.loadMoreTopics(store: app)
        try await wait { !controller.topicsLoading }
        try expect(!controller.canLoadMoreTopics && controller.topics.contains { $0.id == "topic:base-page-250" },
                   "Loading more topics must append the next source page and finish pagination")
        let firstPageCount = await fixture.count("kb-topics")
        try expect(firstPageCount == 6,
                   "The initial bounded batch and explicit continuation must consume each page once")

        // AppStore clears a selected folder absent from the workspace on any
        // later note mutation. Use a real canonical scope for this boundary.
        guard let scopeFolder = app.notes.saveFolder(LibraryFolder(name: "Material filter scope fixture")) else {
            throw AppError.message(app.notes.error ?? "Cannot create material-filter scope fixture")
        }
        defer {
            app.folderSelection = nil
            if let current = app.notes.folders.first(where: { $0.id == scopeFolder.id }) { _ = app.notes.deleteFolder(current) }
        }
        app.folderSelection = scopeFolder.id
        try expect(!controller.matchesCard(meetingID: "direct-meeting", cardID: "card", filters: mixed),
                   "A changed folder must invalidate old memberships before another request completes")
        controller.update(store: app, filters: mixed, target: .cards, revision: "folder")
        try await wait(details: {
            "folder=\(app.folderSelection ?? "nil"), expected=\(scopeFolder.id), features=\(app.visibleFeatures), " +
                "loading=\(controller.topicsLoading), error=\(controller.error ?? "nil"), topics=\(controller.topics.map(\.id))"
        }) { !controller.topicsLoading && !controller.topics.isEmpty }
        let requestedFolder = await fixture.requested(folder: scopeFolder.id)
        try expect(requestedFolder, "Topic requests must carry the current folder scope")
        app.settings.features.knowledgeBase = false
        try expect(!controller.matchesCard(meetingID: "direct-meeting", cardID: "card", filters: mixed),
                   "Revoking the feature must invalidate already loaded topic memberships")
        controller.update(store: app, filters: mixed, target: .cards, revision: "feature-off")
        try expect(!controller.topicsLoading && controller.topics.isEmpty && controller.error != nil,
                   "Disabled topic filtering must explain the required feature and admit no stale sources")

        app.settings.features.knowledgeBase = true; app.folderSelection = nil
        await fixture.setLabel("old-"); await fixture.blockNextPage()
        controller.update(store: app, filters: mixed, target: .notes, revision: "old-load")
        try await wait { await fixture.blocked }
        await fixture.setLabel("new-")
        controller.update(store: app, filters: mixed, target: .notes, revision: "new-load")
        try await wait { !controller.topicsLoading && controller.topics.contains { $0.id == "mixed:new-mixed" } }
        await fixture.releaseBlocked()
        try await Task.sleep(for: .milliseconds(80))
        try expect(!controller.topics.contains { $0.id.contains("old-") } &&
                   controller.topics.contains { $0.id == "mixed:new-mixed" },
                   "A late response for an old revision must not replace the latest catalog")

        await fixture.blockNextPage()
        controller.update(store: app, filters: mixed, target: .notes, revision: "cancelled-load")
        try await wait { await fixture.blocked }
        controller.cancel(); await fixture.releaseBlocked()
        try await Task.sleep(for: .milliseconds(80))
        try expect(controller.topics.isEmpty && !controller.topicsLoading && !controller.canLoadMoreTopics,
                   "Cancellation must discard a late blocking response and reset busy state")
        let noteCancels = await fixture.count("kb-topics-cancel"), mixedCancels = await fixture.count("kb-mixed-topics-cancel")
        try expect(noteCancels > 0 && mixedCancels > 0,
                   "Cancellation must target both backend topic request lifetimes")

        print("PASS: Topic filters use direct source IDs, OR membership, explicit paging, current scope/revisions, and cancellation")
    }

    private static func removedConditionPreferences(root: URL) throws {
        let path = root.appendingPathComponent("material-filters.json")
        let original = try? Data(contentsOf: path)
        defer {
            if let original {
                try? original.write(to: path, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            } else { try? FileManager.default.removeItem(at: path) }
        }
        let bridge = try RustBridge.shared.get()
        let legacy: [String: Any] = [
            "version": 2, "futureRoot": ["keep": true],
            "notes": ["origins": ["manual"], "topicIDs": [], "kinds": [], "meaning": "removed notes phrase",
                      "futureSection": ["keep": 1]],
            "cards": ["origins": ["ai"], "topicIDs": [], "kinds": [], "meaning": "removed cards phrase",
                      "futureSection": ["keep": 2]]
        ]
        _ = try bridge.request(root: root, command: "write", arguments: ["path": "material-filters.json", "value": legacy])
        let preferences = OriginFilterPreferences(); preferences.configure(root: root)
        try expect(preferences.error == nil && preferences.notesFilters == MaterialFilterSet(origins: [.manual]) &&
                   preferences.cardsFilters == MaterialFilterSet(origins: [.ai]) &&
                   preferences.notesFilters.activeCount == 1 && preferences.cardsFilters.activeCount == 1,
                   "Removed phrase fields must not load as hidden active conditions")
        preferences.notesFilters.kinds = ["question"]
        try expect(preferences.error == nil, "Cannot persist the allowed filter conditions")
        let data = try bridge.request(root: root, command: "read", arguments: ["path": "material-filters.json"])
        guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notes = saved["notes"] as? [String: Any], let cards = saved["cards"] as? [String: Any] else {
            throw AppError.message("Cannot read migrated filter preference sections")
        }
        try expect(notes["meaning"] == nil && (notes["origins"] as? [String]) == ["manual"] &&
                   (notes["kinds"] as? [String]) == ["question"] && (cards["origins"] as? [String]) == ["ai"] &&
                   (cards["meaning"] as? String) == "removed cards phrase",
                   "Saving one pane must remove its obsolete field while preserving the other pane's preferences")
        try expect((notes["futureSection"] as? [String: Int])?["keep"] == 1 &&
                   (cards["futureSection"] as? [String: Int])?["keep"] == 2 &&
                   (saved["futureRoot"] as? [String: Bool])?["keep"] == true,
                   "Filter migration must retain compatible unknown section and root fields")
        let reopened = OriginFilterPreferences(); reopened.configure(root: root)
        try expect(reopened.notesFilters.activeCount == 2 && reopened.cardsFilters.activeCount == 1,
                   "Reopened preferences must count only origin, topic, and kind conditions")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message(message) }
    }
    private static func wait(line: UInt = #line, details: @MainActor () -> String = { "" },
                             _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Material-filter boundary fixture timed out at line \(line): \(details())")
    }
}
#endif
