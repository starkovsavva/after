import Foundation

/// A picker and its selected stream share one process-wide authorization session.
/// Keep ownership until capture stops; releasing the picker early revokes consent.
@MainActor
final class CaptureSelectionLease {
    private var owner: UUID?
    func acquire(_ candidate: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = candidate
        return true
    }
    func release(_ candidate: UUID) {
        if owner == candidate { owner = nil }
    }
}

enum CaptureSelectionFailure: Error { case busy }

/// Hardware-independent lifecycle used by the real system picker and synthetic checks.
@MainActor
final class CaptureSelectionRequest<Content> {
    private let lease: CaptureSelectionLease
    private let identity = UUID()
    private var continuation: CheckedContinuation<Content, Error>?
    private var pendingCancellation = false
    private var hasSelection = false
    private(set) var ownsLease = false
    var isSelecting: Bool { continuation != nil }
    var didRelease: (() -> Void)?

    init(lease: CaptureSelectionLease) { self.lease = lease }

    func select(present: () -> Void) async throws -> Content {
        try Task.checkCancellation()
        // Cancellation may arrive before this actor receives select(). Keep it
        // latched so a queued picker cannot appear after Cancel or app quit.
        guard !pendingCancellation else { throw CancellationError() }
        guard !ownsLease, lease.acquire(identity) else { throw CaptureSelectionFailure.busy }
        ownsLease = true
        hasSelection = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                present()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPending() }
        }
    }

    func resolve(_ result: Result<Content, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if case .success = result { hasSelection = true }
        else { release() }
        continuation.resume(with: result)
    }

    func cancelPending() {
        // A completed choice may already authorize a running stream. Its owner
        // must stop that stream before close() releases the picker session.
        guard !hasSelection else { return }
        pendingCancellation = true
        release()
    }

    func release() {
        let pending = continuation
        continuation = nil
        // Remove observer/deactivate before the next owner can present its picker.
        if ownsLease {
            didRelease?()
            ownsLease = false
            lease.release(identity)
        }
        pending?.resume(throwing: CancellationError())
    }
}
