import XCTest
@testable import MacWake

final class NativePowerUIChargeLimitTests: XCTestCase {
    func testOnlyDocumentedNativeLimitsAreAllowed() {
        for limit in [80, 85, 90, 95, 100] {
            #if !APPSTORE
            XCTAssertTrue(NativePowerUIChargeLimit.supports(limit))
            #else
            XCTAssertFalse(NativePowerUIChargeLimit.supports(limit))
            #endif
        }
        for limit in [5, 20, 30, 45, 50, 55, 70, 75, 79, 81, 86, 96, 101] {
            XCTAssertFalse(NativePowerUIChargeLimit.supports(limit),
                "Native PowerUI must not silently accept unsupported limit \(limit)")
        }
    }

    func testReportedNativeStatusTracksEnabledAndLimitSeparately() {
        let disabled = NativePowerUIChargeLimit.Status(
            supported: true, enabled: false, limit: 100
        )
        let enabled = NativePowerUIChargeLimit.Status(
            supported: true, enabled: true, limit: 85
        )
        XCTAssertNotEqual(disabled, enabled)
        XCTAssertFalse(disabled.enabled)
        XCTAssertEqual(enabled.limit, 85)
    }
}
