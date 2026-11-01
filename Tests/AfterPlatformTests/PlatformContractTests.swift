import Foundation
import AfterPlatform
import AfterLocalization
#if SWIFT_PACKAGE
import XCTest
#endif

#if !SWIFT_PACKAGE
@main
#endif
struct PlatformContractChecks {
    static func workerEvents() throws {
        let strings = try JSONDecoder().decode(WorkerEvent.self, from: Data(#"{"event":"done","models":["local"]}"#.utf8))
        precondition(strings.models == ["local"] && strings.installedModels == nil)
        let objects = try JSONDecoder().decode(WorkerEvent.self, from: Data(#"{"event":"done","models":[{"id":"one","name":"One","provider":"local","endpoint":"http://localhost"}]}"#.utf8))
        precondition(objects.models == nil && objects.installedModels?.first?.id == "one")
    }
    static func leaseCancellation() async throws {
        let lease = LocalRuntimeLease()
        let first = try await lease.acquire()
        let cancelled = Task { try await lease.acquire() }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled waiter acquired the runtime") }
        catch is CancellationError {}
        await lease.release(first)
        let next = try await lease.acquire()
        await lease.release(first) // stale ownership must not release the new owner
        let probe = Task { try await lease.acquire(cancelled: { true }) }
        do { _ = try await probe.value; preconditionFailure("Cancelled probe acquired the runtime") }
        catch is CancellationError {}
        await lease.release(next)
        let final = try await lease.acquire()
        await lease.release(final)
    }
    static func catalog() {
        UILocalizationRuntime.shared.setLanguage("en")
        defer { UILocalizationRuntime.shared.setLanguage("ru") }
        precondition(L("База знаний") == "Knowledge base")
        precondition(LF("Снимок от {0}", arguments: ["{1} %s"]).contains("{1} %s"))
    }
    static func main() async throws {
        try workerEvents(); try await leaseCancellation(); catalog()
        print("PASS: portable worker events, runtime cancellation/ownership, module-owned localization")
    }
}
#if SWIFT_PACKAGE
final class PlatformContractTests: XCTestCase {
    func testWorkerEventCompatibility() throws { try PlatformContractChecks.workerEvents() }
    func testCancelledLeaseDoesNotRetainAdmission() async throws { try await PlatformContractChecks.leaseCancellation() }
    func testCatalogWithoutNativeApplication() { PlatformContractChecks.catalog() }
}
#endif
