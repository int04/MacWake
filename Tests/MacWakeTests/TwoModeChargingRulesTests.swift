import XCTest
@testable import MacWake

final class TwoModeChargingRulesTests: XCTestCase {
    private func decision(_ level: Int, _ phase: TwoModeChargingRules.Phase = .normal,
                          limit: Int = 50, target: Int = 20) -> TwoModeChargingRules.Decision {
        TwoModeChargingRules.decide(phase: phase, batteryLevel: level,
                                   maxLimit: limit, cycleTarget: target)
    }

    func testNormalModeDrainsAboveLimitAndHoldsExactlyAtLimit() {
        XCTAssertEqual(decision(51).action, .discharge)
        XCTAssertEqual(decision(50).action, .holdOnAC)
        XCTAssertEqual(decision(49).action, .charge)
    }

    func testSpecialCycleHasExclusiveDischargeAndRechargePhases() {
        XCTAssertEqual(decision(70, .cycleDischarging).action, .discharge)
        XCTAssertEqual(decision(21, .cycleDischarging).phase, .cycleDischarging)
        let bottom = decision(20, .cycleDischarging)
        XCTAssertEqual(bottom.phase, .cycleRecharging)
        XCTAssertEqual(bottom.action, .charge)
        XCTAssertEqual(decision(49, .cycleRecharging).action, .charge)
        let finished = decision(50, .cycleRecharging)
        XCTAssertEqual(finished.phase, .normal)
        XCTAssertEqual(finished.action, .holdOnAC)
    }

    func testUnsupportedBackendNeverCutsAdapterOrPretendsToHoldAC() {
        for level in [5, 20, 49, 50, 51, 85, 90, 99, 100] {
            for phase: TwoModeChargingRules.Phase in
                [.normal, .cycleDischarging, .cycleRecharging] {
                let decision = TwoModeChargingRules.decide(
                    phase: phase, batteryLevel: level, maxLimit: 50,
                    cycleTarget: 20, supportsChargeInhibit: false
                )
                XCTAssertEqual(decision, .init(phase: .normal, action: .unavailable),
                               "unsupported backend must not force discharge at \(level)%")
            }
        }
    }

    func testSupportedBackendStopsAtExactMaxOnAC() {
        XCTAssertEqual(
            TwoModeChargingRules.decide(
                phase: .normal, batteryLevel: 51, maxLimit: 50,
                cycleTarget: 20, supportsChargeInhibit: true
            ).action, .discharge
        )
        XCTAssertEqual(
            TwoModeChargingRules.decide(
                phase: .normal, batteryLevel: 50, maxLimit: 50,
                cycleTarget: 20, supportsChargeInhibit: true
            ).action, .holdOnAC
        )
        XCTAssertEqual(
            TwoModeChargingRules.decide(
                phase: .normal, batteryLevel: 49, maxLimit: 50,
                cycleTarget: 20, supportsChargeInhibit: true
            ).action, .charge
        )
    }

    func testNativeNormalAndSpecialDischargeHaveDifferentPhysicalActions() {
        XCTAssertFalse(TwoModeChargingRules.needsAdapterCut(
            action: .discharge, phase: .normal, nativePowerUI: true
        ), "Native MCL preserves AC while firmware drains toward Max")
        XCTAssertTrue(TwoModeChargingRules.needsAdapterCut(
            action: .discharge, phase: .cycleDischarging, nativePowerUI: true
        ), "Special cycle must actively cut CHIE to reach Target")
        XCTAssertTrue(TwoModeChargingRules.needsAdapterCut(
            action: .discharge, phase: .normal, nativePowerUI: false
        ), "Legacy SMC discharge still cuts adapter")
        XCTAssertFalse(TwoModeChargingRules.needsAdapterCut(
            action: .holdOnAC, phase: .normal, nativePowerUI: true
        ))
        XCTAssertFalse(TwoModeChargingRules.needsAdapterCut(
            action: .charge, phase: .cycleRecharging, nativePowerUI: true
        ))
    }

    func testCancelReturnsToNormalDecision() {
        XCTAssertEqual(decision(25, .normal).action, .charge)
        XCTAssertEqual(decision(55, .normal).action, .discharge)
    }

    func testTargetAlwaysStaysBelowMaximum() {
        XCTAssertEqual(TwoModeChargingRules.target(95, maxLimit: 50), 45)
        XCTAssertEqual(TwoModeChargingRules.target(5, maxLimit: 20), 5)
        XCTAssertEqual(TwoModeChargingRules.target(30, maxLimit: 20), 15)
    }
}
