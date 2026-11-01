import AVFoundation
import Foundation

package enum ClipPlaybackFailure: Error { case unavailable }

/// Owns only platform playback resources. Source identity, evidence validation,
/// navigation and user-facing error presentation belong to the caller.
@MainActor
package final class ClipPlaybackSession {
    private let asset: AVURLAsset
    private let start: Double
    private let end: Double
    private let muted: Bool
    private var preparedEnd: CMTime?
    private var player: AVPlayer?
    private var boundary: Any?
    private var ended: NSObjectProtocol?
    private var generation = UUID()

    package init(url: URL, start: Double, end: Double, muted: Bool = false) {
        asset = AVURLAsset(url: url)
        self.start = start; self.end = end; self.muted = muted
    }

    /// Does not create or start a player. Callers may revalidate their source
    /// after the asynchronous asset reads and before admitting playback.
    package func load() async throws {
        let token = generation
        let duration = try await asset.load(.duration)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let playable = try await asset.load(.isPlayable)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              playable, duration.seconds.isFinite, duration.seconds > start else {
            throw ClipPlaybackFailure.unavailable
        }
        preparedEnd = CMTime(seconds: min(duration.seconds, end), preferredTimescale: 600)
    }

    /// Creates the stopped player and seeks exactly. The caller revalidates
    /// again after this suspension, before calling play().
    package func seekToStart() async -> Bool {
        guard let preparedEnd, player == nil, !Task.isCancelled else { return false }
        let token = generation
        let item = AVPlayerItem(asset: asset)
        item.forwardPlaybackEndTime = preparedEnd
        let player = AVPlayer(playerItem: item); player.isMuted = muted
        self.player = player
        let sought = await withCheckedContinuation { continuation in
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                continuation.resume(returning: finished)
            }
        }
        return sought && generation == token && !Task.isCancelled
    }

    package func play(onFinished: @escaping @MainActor @Sendable () -> Void) {
        guard let player, let item = player.currentItem, let preparedEnd, boundary == nil, !Task.isCancelled else { return }
        let token = generation
        boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: preparedEnd)], queue: .main) { [weak self] in
            Task { @MainActor in if self?.generation == token { onFinished() } }
        }
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.generation == token { onFinished() } }
        }
        player.play()
    }

    package func stop() {
        generation = UUID()
        player?.pause()
        if let boundary { player?.removeTimeObserver(boundary) }
        if let ended { NotificationCenter.default.removeObserver(ended) }
        boundary = nil; ended = nil; player = nil; preparedEnd = nil
    }
}
