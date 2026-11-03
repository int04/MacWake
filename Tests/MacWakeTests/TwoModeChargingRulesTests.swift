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

    func testAdapterCutOnlyDischargesFrom99To90ThenRestoresAC() {
        let above = TwoModeChargingRules.decideAdapterCutFallback(
            phase: .normal, batteryLevel: 99, maxLimit: 90,
            cycleTarget: 20, adapterRestoredAtMax: false)
        XCTAssertEqual(above.action, .discharge)

        let reached = TwoModeChargingRules.decideAdapterCutFallback(
            phase: .normal, batteryLevel: 90, maxLimit: 90,
            cycleTarget: 20, adapterRestoredAtMax: true)
        XCTAssertEqual(reached.action, .charge)

        let band = TwoModeChargingRules.decideAdapterCutFallback(
            phase: .normal, batteryLevel: 93, maxLimit: 90,
            cycleTarget: 20, adapterRestoredAtMax: true)
        XCTAssertEqual(band.action, .charge)

        let upper = TwoModeChargingRules.decideAdapterCutFallback(
            phase: .normal, batteryLevel: 95, maxLimit: 90,
            cycleTarget: 20, adapterRestoredAtMax: false)
        XCTAssertEqual(upper.action, .discharge)
    }

    func testAdapterCutOnlySpecialCycleReturnsToACAfterMax() {
        let draining = TwoModeChargingRules.decideAdapterCutFallback(
            phase: .cycleDischarging, batteryLevel: 30, maxLimit: 90,
            cycleTarget: 20, adapterRestoredAtMax: false)
        XCTAssertEqual(draining.action, .discharge)
        let atTarget = TwoModeChargingRules.decideAdapterCutFallback(
            phase: .cycleDischarging, batteryLevel: 20, maxLimit: 90,
            cycleTarget: 20, adapterRestoredAtMax: false)
        XCTAssertEqual(atTarget, .init(phase: .cycleRecharging, action: .charge))
        let atMax = TwoModeChargingRules.decideAdapterCutFallback(
            phase: .cycleRecharging, batteryLevel: 90, maxLimit: 90,
            cycleTarget: 20, adapterRestoredAtMax: true)
        XCTAssertEqual(atMax, .init(phase: .normal, action: .charge))
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
