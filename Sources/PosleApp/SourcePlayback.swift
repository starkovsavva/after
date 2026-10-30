import AVFoundation
import Combine
import Foundation
import PosleCore

/// Playback belongs to the open source popover, not the selected workspace.
/// Closing it invalidates pending asset loads and seeks as well as active audio.
@MainActor
final class SourcePlaybackState: ObservableObject {
    @Published private(set) var playingID: Int?
    @Published private(set) var preparingID: Int?
    @Published private(set) var error: String?
    private var player: AVPlayer?
    private var boundary: Any?
    private var ended: NSObjectProtocol?
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private var meetingID: String?
    var isActive: Bool { player != nil || preparation != nil }

    func toggle(store: AppStore, meetingID: String, expected: Segment,
                additionalValidation: @escaping @MainActor () -> Bool = { true }) {
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
        player?.pause()
        if let boundary { player?.removeTimeObserver(boundary) }
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = nil; boundary = nil; player = nil; playingID = nil; preparingID = nil; meetingID = nil
    }
    private func current(_ store: AppStore, meetingID: String, expected: Segment) -> Bool {
        let fresh: Transcript? = store.read(store.meetingDirectory(meetingID).appendingPathComponent("transcript.json"))
        return fresh?.segments.first(where: { $0.id == expected.id }) == expected
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
                       additionalValidation: @escaping @MainActor () -> Bool) {
        guard expected.start.isFinite, expected.end.isFinite, expected.start >= 0, expected.end > expected.start,
              current(store, meetingID: meetingID, expected: expected), additionalValidation() else {
            error = L("Источник изменился. Откройте актуальный конспект.")
            return
        }
        store.pause()
        let token = generation
        self.meetingID = meetingID; preparingID = expected.id
        preparation = Task { [weak self, weak store] in
            guard let self, let store else { return }
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let playable = try await asset.load(.isPlayable)
                guard self.generation == token, !Task.isCancelled else { return }
                guard playable, duration.seconds.isFinite, duration.seconds > expected.start else {
                    throw AppError.message(L("Этот фрагмент недоступен в аудиозаписи."))
                }
                guard self.current(store, meetingID: meetingID, expected: expected), additionalValidation() else {
                    throw AppError.message(L("Источник изменился. Откройте актуальный конспект."))
                }
                let item = AVPlayerItem(asset: asset)
                let end = CMTime(seconds: min(duration.seconds, expected.end), preferredTimescale: 600)
                item.forwardPlaybackEndTime = end
                let player = AVPlayer(playerItem: item); player.isMuted = muted
                self.player = player
                let sought = await withCheckedContinuation { continuation in
                    player.seek(to: CMTime(seconds: expected.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                        continuation.resume(returning: finished)
                    }
                }
                guard self.generation == token, !Task.isCancelled else { player.pause(); return }
                guard sought, self.current(store, meetingID: meetingID, expected: expected), additionalValidation() else {
                    throw AppError.message(L("Источник изменился или фрагмент больше недоступен."))
                }
                self.boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self] in
                    Task { @MainActor in if self?.generation == token { self?.stop() } }
                }
                self.ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in if self?.generation == token { self?.stop() } }
                }
                self.preparingID = nil; self.playingID = expected.id; self.preparation = nil
                player.play()
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.stop(); self.error = error.localizedDescription
            }
        }
    }
    #if DEBUG
    /// A generated, muted audio fixture exercises the real player without using
    /// any existing recording or audio output. Never exposed in product UI.
    func playForChecks(store: AppStore, meetingID: String, expected: Segment, audioURL: URL) {
        stop()
        begin(store: store, meetingID: meetingID, expected: expected, url: audioURL, muted: true, additionalValidation: { true })
    }
    #endif
}
