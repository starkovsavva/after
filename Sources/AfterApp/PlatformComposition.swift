import AfterPlatform
import AfterPlatformMacOS

/// The macOS application selects native implementations here. A second client
/// can assemble the same contracts without importing this application target.
extension ApplicationMediaServices {
    @MainActor static var macOS: Self {
        Self(makeRecorder: { MeetingRecorder() },
             makePlayback: { MacOSAudioPlaybackSession(url: $0) },
             makeSleepLease: { MacOSIdleSleepLease() })
    }
}
