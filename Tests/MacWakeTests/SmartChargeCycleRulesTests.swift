import XCTest
@testable import MacWake

final class SmartChargeCycleRulesTests: XCTestCase {
    private func allowed(
        enabled: Bool = true, armed: Bool = true,
        batteryLevel: Int = 90, chargeLimit: Int = 80,
        physicallyPlugged: Bool = true, batteryTemperatureC: Double = 28,
        lidClosedWithExternalDisplay: Bool = false, conflictingMode: Bool = false
    ) -> Bool {
        SmartChargeCycleRules.canStartDischarge(
            enabled: enabled, armed: armed, chargeLimit: chargeLimit,
            batteryLevel: batteryLevel, helperReady: true,
            physicallyPlugged: physicallyPlugged,
            batteryTemperatureC: batteryTemperatureC,
            lidClosedWithExternalDisplay: lidClosedWithExternalDisplay,
            conflictingMode: conflictingMode
        )
    }

    func testStartsOnlyFivePointsOverLimit() {
        XCTAssertTrue(allowed(batteryLevel: 85))
        XCTAssertFalse(allowed(batteryLevel: 84))
        XCTAssertFalse(allowed(batteryLevel: 80))
        XCTAssertFalse(allowed(enabled: false))
        XCTAssertFalse(allowed(armed: false))
    }

    func testRequiresRealAdapterAndValidSensor() {
        XCTAssertFalse(allowed(physicallyPlugged: false))
        XCTAssertFalse(allowed(batteryTemperatureC: 0))
        XCTAssertFalse(allowed(batteryTemperatureC: 40))
        XCTAssertFalse(allowed(batteryTemperatureC: 42))
        XCTAssertTrue(allowed(batteryTemperatureC: 39))
    }

    func testNeverOverridesClamshellOrOtherChargeModes() {
        XCTAssertFalse(allowed(lidClosedWithExternalDisplay: true))
        XCTAssertFalse(allowed(conflictingMode: true))
    }

    func testCancelsIfSafetyConditionChanges() {
        XCTAssertTrue(SmartChargeCycleRules.mustStopDischarge(
            helperReady: true, batteryTemperatureC: 40,
            lidClosedWithExternalDisplay: false, conflictingMode: false
        ))
        XCTAssertTrue(SmartChargeCycleRules.mustStopDischarge(
            helperReady: true, batteryTemperatureC: 28,
            lidClosedWithExternalDisplay: true, conflictingMode: false
        ))
        XCTAssertFalse(SmartChargeCycleRules.mustStopDischarge(
            helperReady: true, batteryTemperatureC: 28,
            lidClosedWithExternalDisplay: false, conflictingMode: false
        ))
    }
}

extension SmartChargeCycleRulesTests {
    func testCalibrationReminderBecomesDueAfterThirtyDays() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(SmartChargeCycleRules.calibrationIsDue(
            lastHandled: start, now: start.addingTimeInterval(29 * 24 * 3600)
        ))
        XCTAssertTrue(SmartChargeCycleRules.calibrationIsDue(
            lastHandled: start, now: start.addingTimeInterval(30 * 24 * 3600)
        ))
    }

    func testAutomaticCalibrationRequiresSafeConditions() {
        func allowed(temp: Double = 28, plugged: Bool = true, clamshell: Bool = false,
                     busy: Bool = false) -> Bool {
            SmartChargeCycleRules.canStartScheduledCalibration(
                batteryTemperatureC: temp,
                physicallyPlugged: plugged,
                helperReady: true,
                lidClosedWithExternalDisplay: clamshell,
                conflictingMode: busy
            )
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(temp: 35))
        XCTAssertFalse(allowed(temp: 0))
        XCTAssertFalse(allowed(plugged: false))
        XCTAssertFalse(allowed(clamshell: true))
        XCTAssertFalse(allowed(busy: true))
    }
}
