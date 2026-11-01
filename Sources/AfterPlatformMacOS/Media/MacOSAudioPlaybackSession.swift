import AfterPlatform
import AVFoundation
import Foundation

@MainActor
package final class MacOSAudioPlaybackSession: AudioPlaybackSession {
    private let asset: AVURLAsset
    private let player: AVPlayer
    private var observer: Any?
    package init(url: URL) {
        asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }
    package var isReady: Bool { player.currentItem?.status == .readyToPlay }
    package var isMuted: Bool { get { player.isMuted } set { player.isMuted = newValue } }
    package func observeTime(_ callback: @escaping @Sendable (Double) -> Void) {
        if let observer { player.removeTimeObserver(observer) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) {
            callback($0.seconds)
        }
    }
    package func duration() async throws -> Double { try await asset.load(.duration).seconds }
    package func play() { player.play() }
    package func pause() { player.pause() }
    package func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    package func invalidate() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
    deinit {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
    }
}
