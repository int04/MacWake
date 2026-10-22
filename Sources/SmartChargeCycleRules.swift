import Foundation

/// Pure safety decisions for opt-in automatic discharge. No SMC writes here.
/// The manager remains the sole owner of adapter changes and recovery.
enum SmartChargeCycleRules {
    static let calibrationInterval: TimeInterval = 30 * 24 * 3600

    static func calibrationIsDue(lastHandled: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastHandled) >= calibrationInterval
    }

    static func canStartScheduledCalibration(
        batteryTemperatureC: Double, physicallyPlugged: Bool, helperReady: Bool,
        lidClosedWithExternalDisplay: Bool, conflictingMode: Bool
    ) -> Bool {
        helperReady && physicallyPlugged && !lidClosedWithExternalDisplay
            && !conflictingMode && batteryTemperatureC >= minimumValidBatteryTemperatureC
            && batteryTemperatureC < 35
    }

    static let activationMargin = 5
    static let maximumBatteryTemperatureC = 40.0
    static let minimumValidBatteryTemperatureC = 5.0

    static func canStartDischarge(
        enabled: Bool, armed: Bool, chargeLimit: Int, batteryLevel: Int,
        helperReady: Bool, physicallyPlugged: Bool, batteryTemperatureC: Double,
        lidClosedWithExternalDisplay: Bool, conflictingMode: Bool
    ) -> Bool {
        enabled && armed && helperReady && physicallyPlugged
            && (50...95).contains(chargeLimit)
            && batteryLevel >= chargeLimit + activationMargin
            && batteryTemperatureC >= minimumValidBatteryTemperatureC
            && batteryTemperatureC < maximumBatteryTemperatureC
            && !lidClosedWithExternalDisplay && !conflictingMode
    }

    static func mustStopDischarge(
        helperReady: Bool, batteryTemperatureC: Double,
        lidClosedWithExternalDisplay: Bool, conflictingMode: Bool
    ) -> Bool {
        !helperReady
            || batteryTemperatureC < minimumValidBatteryTemperatureC
            || batteryTemperatureC >= maximumBatteryTemperatureC
            || lidClosedWithExternalDisplay || conflictingMode
    }
}
