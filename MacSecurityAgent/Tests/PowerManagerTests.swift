#if canImport(IOKit)
import XCTest
@testable import MacSecurityCore

/// macOS-only: verifies real IOKit power assertions (scenario 19).
@MainActor
final class PowerManagerTests: XCTestCase, @unchecked Sendable {
    func testIdleSystemSleepAssertionIsTakenAndReleased() async throws {
        let manager = PowerManager()
        try manager.beginMonitoring(keepDisplayAwake: false)
        XCTAssertTrue(manager.isPreventingSystemSleep)
        XCTAssertFalse(manager.isPreventingDisplaySleep)
        let held = PowerManager.assertionTypesHeldByCurrentProcess()
        XCTAssertTrue(held.contains("PreventUserIdleSystemSleep"), "Held: \(held)")
        XCTAssertFalse(held.contains("PreventUserIdleDisplaySleep"), "Display must be allowed to sleep")

        manager.endMonitoring()
        XCTAssertFalse(manager.isPreventingSystemSleep)
        XCTAssertFalse(PowerManager.assertionTypesHeldByCurrentProcess().contains("PreventUserIdleSystemSleep"))
    }

    func testDisplayFallbackAssertion() async throws {
        let manager = PowerManager()
        try manager.beginMonitoring(keepDisplayAwake: true)
        XCTAssertTrue(PowerManager.assertionTypesHeldByCurrentProcess().contains("PreventUserIdleDisplaySleep"))
        try manager.setKeepDisplayAwake(false)
        XCTAssertFalse(PowerManager.assertionTypesHeldByCurrentProcess().contains("PreventUserIdleDisplaySleep"))
        manager.endMonitoring()
        XCTAssertTrue(PowerManager.assertionTypesHeldByCurrentProcess().filter { $0.hasPrefix("PreventUserIdle") }.isEmpty)
    }

    func testEndMonitoringIsIdempotent() async {
        let manager = PowerManager()
        manager.endMonitoring()
        manager.endMonitoring()
        XCTAssertFalse(manager.isPreventingSystemSleep)
    }

    func testPowerSourceIsReported() async {
        // Battery or AC on a MacBook; unknown only on machines without IOPS.
        let source = PowerManager().currentPowerSource()
        XCTAssertFalse(source.title.isEmpty)
    }
}
#endif
