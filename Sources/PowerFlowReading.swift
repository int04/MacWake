import Foundation

/// Battery and AC measurements describe different electrical paths.
/// In particular, a negative battery current while external power is connected
/// is DISCHARGE, not charging input from the adapter.
enum PowerFlowReading {
    enum State: Equatable {
        case charging
        case discharging
        case notCharging
        case onBattery
    }

    /// AppleSmartBattery reports milliamps and millivolts. Its signed current
    /// may be bridged through NSNumber as a huge UInt64 (two's complement).
    /// Preserve the sign rather than applying abs() to a discharge sample.
    static func batteryWatts(amperage: NSNumber?, voltage: NSNumber?) -> Double? {
        guard let amperage, let voltage else { return nil }
        let milliamps = Int64(bitPattern: amperage.uint64Value)
        let millivolts = voltage.doubleValue
        guard millivolts > 0, millivolts < 50_000 else { return nil }
        let watts = Double(milliamps) * millivolts / 1_000_000.0
        guard watts.isFinite, (-500...500).contains(watts) else { return nil }
        return watts
    }

    /// This is a measured AC input from telemetry, NOT battery current and NOT
    /// the adapter's advertised maximum wattage. Some devices return implausible
    /// sub-watt values (for example 175 mW for a running Mac): show "unavailable".
    static func adapterInputWatts(
        systemPowerInMilliwatts: NSNumber?, connected: Bool
    ) -> Double? {
        guard connected, let systemPowerInMilliwatts else { return nil }
        let watts = systemPowerInMilliwatts.doubleValue / 1_000.0
        guard watts.isFinite, (1...500).contains(watts) else { return nil }
        return watts
    }

    static func state(
        connected: Bool, isCharging: Bool, batteryWatts: Double?
    ) -> State {
        if isCharging { return .charging }
        if let batteryWatts, batteryWatts < -0.5 { return .discharging }
        return connected ? .notCharging : .onBattery
    }
}
