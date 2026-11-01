import Foundation

/// Each workflow owns its own lease. The adapter must release on final disposal.
package protocol IdleSleepPreventing: AnyObject {
    var isActive: Bool { get }
    func setActive(_ active: Bool, reason: String)
}

package enum GlobalShortcutAction: UInt32, Hashable, Sendable {
    case quickCapture = 1, bookmark = 2, voice = 3
}

package enum GlobalShortcutKey: Sendable {
    case controlOptionN, controlShiftSpace, controlOptionB, controlOptionM
}

package struct GlobalShortcutBinding: Sendable {
    package let action: GlobalShortcutAction
    package let key: GlobalShortcutKey
    package init(action: GlobalShortcutAction, key: GlobalShortcutKey) {
        self.action = action; self.key = key
    }
}

@MainActor
package protocol GlobalShortcutRegistering: AnyObject {
    func start(handler: @escaping @MainActor (GlobalShortcutAction) -> Void) -> Bool
    /// Failed actions are explicit; a collision must never appear registered.
    func configure(_ bindings: [GlobalShortcutBinding]) -> Set<GlobalShortcutAction>
    func stop()
}

/// Times cross the boundary in seconds, never as framework-owned media objects.
@MainActor
package protocol AudioPlaybackSession: AnyObject {
    var isReady: Bool { get }
    var isMuted: Bool { get set }
    func observeTime(_ callback: @escaping @Sendable (Double) -> Void)
    func duration() async throws -> Double
    func play()
    func pause()
    func seek(to seconds: Double)
    func invalidate()
}

/// Native factories are selected once by the application composition root.
/// Feature coordinators receive these contracts instead of choosing an OS.
@MainActor
package struct ApplicationMediaServices {
    package let makeRecorder: () -> any MeetingRecordingBackend
    package let makePlayback: (URL) -> any AudioPlaybackSession
    package let makeSleepLease: () -> any IdleSleepPreventing
    package init(makeRecorder: @escaping () -> any MeetingRecordingBackend,
                 makePlayback: @escaping (URL) -> any AudioPlaybackSession,
                 makeSleepLease: @escaping () -> any IdleSleepPreventing) {
        self.makeRecorder = makeRecorder; self.makePlayback = makePlayback; self.makeSleepLease = makeSleepLease
    }
}
