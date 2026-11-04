import XCTest
@testable import MacWake

final class PowerFlowReadingTests: XCTestCase {
    func testSignedBatteryDischargeRemainsNegativeEvenWhenACIsConnected() {
        // AppleSmartBattery may bridge a signed -888 mA to this UInt64 value.
        let rawAmperage = NSNumber(value: UInt64(bitPattern: Int64(-888)))
        let power = PowerFlowReading.batteryWatts(
            amperage: rawAmperage, voltage: NSNumber(value: 12_430)
        )
        XCTAssertNotNil(power)
        XCTAssertEqual(power!, -11.03784, accuracy: 0.01)
        XCTAssertEqual(
            PowerFlowReading.state(
                connected: true, isCharging: false, batteryWatts: power
            ), .discharging
        )
        XCTAssertEqual(MenuBarLabel.batteryWatts(power!, compact: false), "-11.0W")
        XCTAssertEqual(MenuBarLabel.batteryWatts(power!, compact: true), "-11W")
    }

    func testPositiveBatteryPowerIsChargingOnlyWhenSystemReportsCharging() {
        let power = PowerFlowReading.batteryWatts(
            amperage: NSNumber(value: 1200), voltage: NSNumber(value: 12_000)
        )
        XCTAssertEqual(power!, 14.4, accuracy: 0.01)
        XCTAssertEqual(
            PowerFlowReading.state(
                connected: true, isCharging: true, batteryWatts: power
            ), .charging
        )
        XCTAssertEqual(MenuBarLabel.batteryWatts(power!, compact: false), "+14.4W")
        XCTAssertEqual(
            PowerFlowReading.state(
                connected: true, isCharging: false, batteryWatts: power
            ), .notCharging
        )
    }

    func testIdleAndUnpluggedHaveDifferentStatus() {
        XCTAssertEqual(
            PowerFlowReading.state(
                connected: true, isCharging: false, batteryWatts: nil
            ), .notCharging
        )
        XCTAssertEqual(
            PowerFlowReading.state(
                connected: false, isCharging: false, batteryWatts: nil
            ), .onBattery
        )
    }

    func testNeverUsesBatteryDischargeAsACInput() {
        // Actual machine reports 175 mW telemetry alongside -11 W battery
        // discharge. That value is implausible for total AC system power.
        XCTAssertNil(PowerFlowReading.adapterInputWatts(
            systemPowerInMilliwatts: NSNumber(value: 175), connected: true
        ))
        XCTAssertNil(PowerFlowReading.adapterInputWatts(
            systemPowerInMilliwatts: nil, connected: true
        ))
        XCTAssertNil(PowerFlowReading.adapterInputWatts(
            systemPowerInMilliwatts: NSNumber(value: 20_000), connected: false
        ))
        XCTAssertEqual(
            PowerFlowReading.adapterInputWatts(
                systemPowerInMilliwatts: NSNumber(value: 20_000), connected: true
            )!, 20.0, accuracy: 0.01
        )
    }

    func testUnavailableOrInvalidBatterySensorsHaveNoInventedPower() {
        XCTAssertNil(PowerFlowReading.batteryWatts(
            amperage: nil, voltage: NSNumber(value: 12_000)
        ))
        XCTAssertNil(PowerFlowReading.batteryWatts(
            amperage: NSNumber(value: -100), voltage: NSNumber(value: 0)
        ))
        XCTAssertNil(PowerFlowReading.batteryWatts(
            amperage: NSNumber(value: Int64.max), voltage: NSNumber(value: 12_000)
        ))
    }
}
