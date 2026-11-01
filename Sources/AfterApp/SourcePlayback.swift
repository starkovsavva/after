import AfterPlatform
import AfterLocalization
import AfterPlatformMacOS
import Combine
import Foundation
import AfterCore

/// Playback belongs to the open source popover, not the selected workspace.
/// Closing it invalidates pending asset loads and seeks as well as active audio.
@MainActor
final class SourcePlaybackState: ObservableObject {
    typealias SnapshotLoader = @Sendable (URL, String, [Int]) throws -> EvidenceSourceSnapshot
    @Published private(set) var playingID: Int?
    @Published private(set) var preparingID: Int?
    @Published private(set) var error: String?
    private var playback: ClipPlaybackSession?
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private var meetingID: String?
    private let loadSnapshot: SnapshotLoader
    var isActive: Bool { playback != nil || preparation != nil }

    init(loadSnapshot: @escaping SnapshotLoader = {
        try EvidenceSourceSnapshot.load(root: $0, meetingID: $1, ids: $2)
    }) {
        self.loadSnapshot = loadSnapshot
    }

    func toggle(store: AppStore, meetingID: String, expected: Segment,
                additionalValidation: @escaping @MainActor () async -> Bool = { true }) {
        if self.meetingID == meetingID && (playingID == expected.id || preparingID == expected.id) { stop(); return }
        stop()
        guard let url = audioURL(store: store, meetingID: meetingID) else {
            error = L("Аудиозапись недоступна. Исходный текст можно прочитать здесь.")
            return
        }
        begin(store: store, meetingID: meetingID, expected: expected, url: url, muted: false,
              additionalValidation: additionalValidation)
    }
    func stop() {
        generation = UUID(); error = nil
        preparation?.cancel(); preparation = nil
        playback?.stop(); playback = nil
        playingID = nil; preparingID = nil; meetingID = nil
    }
    private func current(_ store: AppStore, meetingID: String, expected: Segment) async -> Bool {
        let root = store.root, ids = [expected.id], load = loadSnapshot
        do {
            let fresh = try await Task.detached(priority: .userInitiated) {
                try load(root, meetingID, ids)
            }.value
            return fresh.meeting.id == meetingID && fresh.segments.count == 1 && fresh.segments.first == expected
        } catch { return false }
    }
    private func audioURL(store: AppStore, meetingID: String) -> URL? {
        let directory = store.meetingDirectory(meetingID)
        for name in ["recording.mp3", "playback.mp3"] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return url
        }
        return nil
    }
    private func begin(store: AppStore, meetingID: String, expected: Segment, url: URL, muted: Bool,
                       additionalValidation: @escaping @MainActor () async -> Bool) {
        guard expected.start.isFinite, expected.end.isFinite, expected.start >= 0, expected.end > expected.start else {
            error = L("Источник изменился. Откройте актуальный конспект.")
            return
        }
        let token = generation
        self.meetingID = meetingID; preparingID = expected.id
        preparation = Task { [weak self, weak store] in
            guard let self, let store else { return }
            do {
                let fresh = await self.current(store, meetingID: meetingID, expected: expected)
                guard self.generation == token, !Task.isCancelled else { return }
                guard fresh else { throw AppError.message(L("Источник изменился. Откройте актуальный конспект.")) }
                let valid = await additionalValidation()
                guard self.generation == token, !Task.isCancelled else { return }
                guard valid else { throw AppError.message(L("Источник изменился. Откройте актуальный конспект.")) }
                store.pause()
                let playback = ClipPlaybackSession(url: url, start: expected.start, end: expected.end, muted: muted)
                try await playback.load()
                guard self.generation == token, !Task.isCancelled else { return }
                let currentAfterLoad = await self.current(store, meetingID: meetingID, expected: expected)
                guard self.generation == token, !Task.isCancelled else { return }
                guard currentAfterLoad else {
                    throw AppError.message(L("Источник изменился. Откройте актуальный конспект."))
                }
                let validAfterLoad = await additionalValidation()
                guard self.generation == token, !Task.isCancelled else { return }
                guard validAfterLoad else {
                    throw AppError.message(L("Источник изменился. Откройте актуальный конспект."))
                }
                self.playback = playback
                let sought = await playback.seekToStart()
                guard self.generation == token, !Task.isCancelled else { playback.stop(); return }
                guard sought else { throw AppError.message(L("Источник изменился или фрагмент больше недоступен.")) }
                let currentAfterSeek = await self.current(store, meetingID: meetingID, expected: expected)
                guard self.generation == token, !Task.isCancelled else { playback.stop(); return }
                guard currentAfterSeek else {
                    throw AppError.message(L("Источник изменился или фрагмент больше недоступен."))
                }
                let validAfterSeek = await additionalValidation()
                guard self.generation == token, !Task.isCancelled else { playback.stop(); return }
                guard validAfterSeek else {
                    throw AppError.message(L("Источник изменился или фрагмент больше недоступен."))
                }
                self.preparingID = nil; self.playingID = expected.id; self.preparation = nil
                playback.play { [weak self] in
                    if self?.generation == token { self?.stop() }
                }
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.stop()
                self.error = error is ClipPlaybackFailure ? L("Этот фрагмент недоступен в аудиозаписи.") : error.localizedDescription
            }
        }
    }
    #if DEBUG
    /// A generated, muted audio fixture exercises the real player without using
    /// any existing recording or audio output. Never exposed in product UI.
    func playForChecks(store: AppStore, meetingID: String, expected: Segment, audioURL: URL,
                       additionalValidation: @escaping @MainActor () async -> Bool = { true }) {
        stop()
        begin(store: store, meetingID: meetingID, expected: expected, url: audioURL, muted: true,
              additionalValidation: additionalValidation)
    }
    var preparationForChecks: Task<Void, Never>? { preparation }
    #endif
}
