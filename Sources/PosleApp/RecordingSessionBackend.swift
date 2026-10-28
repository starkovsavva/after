import Foundation
import PosleCore

struct RecordingFailure: Sendable {
    let sessionID: String
    let message: String
    let userInitiated: Bool

    init(sessionID: String, message: String, userInitiated: Bool = false) {
        self.sessionID = sessionID
        self.message = message
        self.userInitiated = userInitiated
    }
}

/// Capture is injectable independently of post-processing, so lifecycle races
/// can be exercised without requesting microphone or screen permissions.
protocol MeetingRecordingBackend: AnyObject, Sendable {
    var failed: (@Sendable (RecordingFailure) -> Void)? { get set }
    var levels: (@Sendable (Double?, Double?) -> Void)? { get set }
    func start(url: URL, systemAudio: Bool, video: Bool,
               videoQuality: RecordingVideoQuality, audioQuality: RecordingAudioQuality,
               displayID: UInt32?, expectedDisplayUUID: String?) async throws
    func stop() async throws
    func cancelPendingStart() async
}

extension MeetingRecordingBackend {
    /// Synthetic backends that do not present consent UI have nothing to cancel.
    func cancelPendingStart() async {}
}
