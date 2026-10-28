#if DEBUG
import Foundation

/// Exercises the exact state behind the system picker. No SCStream, displays,
/// microphone, TCC request, real file, account, or user data is touched.
@MainActor
enum CaptureSelectionNativeChecks {
    static func run() async throws {
        let lease = CaptureSelectionLease()
        let recording = CaptureSelectionRequest<String>(lease: lease)
        let audioCheck = CaptureSelectionRequest<String>(lease: lease)
        var presented = 0, released = 0
        recording.didRelease = { released += 1 }
        let selected = Task { try await recording.select { presented += 1 } }
        try await wait { recording.isSelecting }
        do {
            _ = try await audioCheck.select { presented += 100 }
            throw CheckFailure("A concurrent audio probe opened another picker")
        } catch CaptureSelectionFailure.busy {}
        recording.resolve(.success("authorized-display-filter"))
        try expect(try await selected.value == "authorized-display-filter", "Selected filter was replaced or lost")
        try expect(recording.ownsLease && !recording.isSelecting && presented == 1 && released == 0,
                   "Selection must retain ownership through the running stream")
        recording.cancelPending()
        try expect(recording.ownsLease && !recording.isSelecting && released == 0,
                   "Canceling pending startup must not revoke an already selected active stream")
        do {
            _ = try await audioCheck.select { presented += 100 }
            throw CheckFailure("Active recording allowed an overlapping probe")
        } catch CaptureSelectionFailure.busy {}
        recording.resolve(.success("late-filter"))
        recording.release(); recording.release()
        try expect(released == 1 && !recording.ownsLease, "Stop did not clean up the observer exactly once")
        let next = Task { try await audioCheck.select { presented += 1 } }
        try await wait { audioCheck.isSelecting }
        // Releasing a stale recorder cannot deactivate a newer owner's picker.
        recording.release()
        try expect(audioCheck.ownsLease && presented == 2, "Stale cleanup released another session")
        audioCheck.resolve(.success("probe-filter"))
        try expect(try await next.value == "probe-filter", "Next probe did not receive its own selection")
        audioCheck.release()
        print("PASS: the exact selected filter survives into one capture; concurrent probes and stale callbacks cannot replace it")

        // Reproduce the actor-hop race: cancel arrives before queued select()
        // has installed its continuation or acquired the process-wide lease.
        let cancelledBeforeSelect = CaptureSelectionRequest<String>(lease: lease)
        var prematurePresentations = 0, prematureCleanup = 0
        cancelledBeforeSelect.didRelease = { prematureCleanup += 1 }
        let queuedSelection = Task {
            try await cancelledBeforeSelect.select { prematurePresentations += 1 }
        }
        cancelledBeforeSelect.cancelPending()
        cancelledBeforeSelect.release() // Ordinary cleanup cannot undo cancellation.
        do { _ = try await queuedSelection.value; throw CheckFailure("Canceled queued picker appeared during quit") }
        catch is CancellationError {}
        try expect(!cancelledBeforeSelect.ownsLease && !cancelledBeforeSelect.isSelecting &&
                   prematurePresentations == 0 && prematureCleanup == 0,
                   "Cancellation before actor-hop selection presented UI or released another owner's resources")
        let afterEarlyCancel = CaptureSelectionRequest<String>(lease: lease)
        let afterEarlyCancelValue = try await afterEarlyCancel.select { afterEarlyCancel.resolve(.success("next-start")) }
        try expect(afterEarlyCancelValue == "next-start", "Early cancellation left the global lease occupied")
        afterEarlyCancel.release()
        print("PASS: cancellation before queued selection is latched without presenting UI; active selection remains authorized until stop")

        let cancelled = CaptureSelectionRequest<String>(lease: lease)
        var cancelledCleanup = 0
        cancelled.didRelease = { cancelledCleanup += 1 }
        let cancelTask = Task { try await cancelled.select {} }
        try await wait { cancelled.isSelecting }
        cancelTask.cancel()
        do { _ = try await cancelTask.value; throw CheckFailure("Canceled picker reported success") }
        catch is CancellationError {}
        cancelled.resolve(.success("late-after-cancel"))
        cancelled.release()
        try expect(!cancelled.ownsLease && !cancelled.isSelecting && cancelledCleanup == 1,
                   "Task cancellation leaked or double-released picker ownership")
        let alreadyCancelled = Task { try await cancelled.select { presented += 100 } }
        alreadyCancelled.cancel()
        do { _ = try await alreadyCancelled.value; throw CheckFailure("Pre-canceled task opened picker") }
        catch is CancellationError {}
        try expect(presented == 2 && !cancelled.ownsLease, "Pre-canceled request presented UI or kept a lease")
        print("PASS: cancellation before or during selection resumes the waiter and removes the observer exactly once")

        for failure in [CancellationError() as Error, NSError(domain: "synthetic.picker", code: 17)] {
            let request = CaptureSelectionRequest<String>(lease: lease)
            var cleanup = 0
            request.didRelease = { cleanup += 1 }
            let pending = Task { try await request.select {} }
            try await wait { request.isSelecting }
            request.resolve(.failure(failure))
            request.resolve(.success("late-result"))
            do { _ = try await pending.value; throw CheckFailure("Picker failure reported success") }
            catch {
                try expect((error as NSError).domain == (failure as NSError).domain &&
                           (error as NSError).code == (failure as NSError).code,
                           "Picker failure was misclassified")
            }
            request.release()
            try expect(!request.ownsLease && !request.isSelecting && cleanup == 1,
                       "Picker cancellation/failure leaked observer or process lease")
        }
        let reusable = CaptureSelectionRequest<String>(lease: lease)
        let success = try await reusable.select { reusable.resolve(.success("after-errors")) }
        try expect(success == "after-errors", "Failed/canceled requests blocked the next recording")
        reusable.release()
        print("PASS: macOS cancel and picker failures release consent ownership; late results cannot start recording")
    }

    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw CheckFailure(message) }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CheckFailure("Synthetic picker did not reach the expected state")
    }
}
#endif
