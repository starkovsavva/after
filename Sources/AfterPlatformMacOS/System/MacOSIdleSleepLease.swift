import AfterPlatform
import Foundation
import IOKit.pwr_mgt

/// Owns one transient assertion; never changes persistent power preferences.
package final class MacOSIdleSleepLease: IdleSleepPreventing {
    struct Driver {
        var acquire: (String) -> IOPMAssertionID
        var release: (IOPMAssertionID) -> Void
        static let live = Driver(acquire: { reason in
            var value: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &value)
            return value
        }, release: { IOPMAssertionRelease($0) })
    }
    private let lock = NSLock()
    private let driver: Driver
    private var assertion: IOPMAssertionID = 0
    package convenience init() { self.init(driver: .live) }
    init(driver: Driver) { self.driver = driver }
    package var isActive: Bool { lock.lock(); defer { lock.unlock() }; return assertion != 0 }
    package func setActive(_ active: Bool, reason: String) {
        lock.lock(); defer { lock.unlock() }
        if active, assertion == 0 { assertion = driver.acquire(reason) }
        else if !active, assertion != 0 { driver.release(assertion); assertion = 0 }
    }
    deinit { if assertion != 0 { driver.release(assertion) } }
}
