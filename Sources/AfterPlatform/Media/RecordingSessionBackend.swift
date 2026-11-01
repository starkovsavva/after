import Foundation
import AfterCore

package struct RecordingFailure: Sendable {
    package let sessionID: String
    package let message: String
    package let userInitiated: Bool

    package init(sessionID: String, message: String, userInitiated: Bool = false) {
        self.sessionID = sessionID
        self.message = message
        self.userInitiated = userInitiated
    }
}

package enum RecordingMicrophoneState: Equatable, Sendable {
    case switching
    case unavailable
    case active(name: String)
}

package struct RecordingMicrophoneUpdate: Sendable {
    package let sessionID: String
    package let state: RecordingMicrophoneState

    package init(sessionID: String, state: RecordingMicrophoneState) {
        self.sessionID = sessionID; self.state = state
    }
}

/// Capture is injectable independently of post-processing, so lifecycle races
/// can be exercised without requesting microphone or screen permissions.
package protocol MeetingRecordingBackend: AnyObject, Sendable {
    var failed: (@Sendable (RecordingFailure) -> Void)? { get set }
    var levels: (@Sendable (Double?, Double?) -> Void)? { get set }
    var microphoneStatus: (@Sendable (RecordingMicrophoneUpdate) -> Void)? { get set }
    func start(url: URL, systemAudio: Bool, video: Bool,
               videoQuality: RecordingVideoQuality, audioQuality: RecordingAudioQuality,
               displayID: UInt32?, expectedDisplayUUID: String?) async throws
    func stop() async throws
    func cancelPendingStart() async
}

package extension MeetingRecordingBackend {
    var microphoneStatus: (@Sendable (RecordingMicrophoneUpdate) -> Void)? {
        get { nil }
        set {}
    }
    /// Synthetic backends that do not present consent UI have nothing to cancel.
    func cancelPendingStart() async {}
}
