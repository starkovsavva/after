import Foundation

/// One shared local runtime serves model preparation and queued inference.
/// Admission is cancellable; unrelated cloud text requests do not take this lease.
actor LocalRuntimeLease {
    private var owner: UUID?
    private var waiting: [UUID] = []

    func acquire(cancelled: @escaping @Sendable () async -> Bool = { false }) async throws -> UUID {
        let id = UUID()
        waiting.append(id)
        do {
            while owner != nil || waiting.first != id {
                try Task.checkCancellation()
                if await cancelled() { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            if await cancelled() { throw CancellationError() }
            waiting.removeFirst(); owner = id
            return id
        } catch {
            waiting.removeAll { $0 == id }
            throw error
        }
    }

    func release(_ id: UUID) {
        if owner == id { owner = nil }
    }
}
