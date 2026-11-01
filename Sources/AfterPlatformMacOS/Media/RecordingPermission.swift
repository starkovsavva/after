import Foundation

/// A system permission prompt can outlive a canceled recording or app shutdown.
/// Cancel the waiter immediately and ignore a later system reply. Each start
/// owns its own request so that an old reply cannot authorize the next start.
final class RecordingPermissionRequest: @unchecked Sendable {
    typealias Reply = @Sendable (Bool) -> Void
    typealias Request = @Sendable (@escaping Reply) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var result: Result<Bool, Error>?

    func wait(request: Request) async throws -> Bool {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                request { [weak self] allowed in self?.resolve(.success(allowed)) }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() { resolve(.failure(CancellationError())) }

    private func resolve(_ value: Result<Bool, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: value)
    }
}
