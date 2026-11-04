import Foundation

/// The only two user-facing charging workflows. A cycle temporarily owns charge
/// control; the normal limit never runs alongside it.
enum TwoModeChargingRules {
    enum Phase: Equatable {
        case normal
        case cycleDischarging
        case cycleRecharging
    }

    enum Action: Equatable {
        case charge       // adapter connected, charging enabled
        case discharge    // adapter cut temporarily to consume battery
        case holdOnAC     // charge inhibit, adapter still powers the Mac
        case unavailable  // backend cannot meet the no-battery-drain contract
    }

    struct Decision: Equatable {
        var phase: Phase
        var action: Action
    }

    /// The same symbolic .discharge has different hardware semantics:
    /// normal PowerUI limit keeps AC on; a special cycle explicitly cuts CHIE.
    static func needsAdapterCut(
        action: Action, phase: Phase, nativePowerUI: Bool
    ) -> Bool {
        guard action == .discharge else { return false }
        return !nativePowerUI || phase == .cycleDischarging
    }

    static func target(_ proposed: Int, maxLimit: Int) -> Int {
        min(max(5, maxLimit - 5), max(5, proposed))
    }

    static func decide(
        phase: Phase,
        batteryLevel: Int,
        maxLimit: Int,
        cycleTarget: Int,
        supportsChargeInhibit: Bool = true
    ) -> Decision {
        // No charge-inhibit key means no exact hold on AC. Never switch the
        // adapter off to imitate a hold: that simply drains the battery.
        guard supportsChargeInhibit else {
            return Decision(phase: .normal, action: .unavailable)
        }
        let maxLimit = min(95, max(20, maxLimit))
        switch phase {
        case .normal:
            if batteryLevel > maxLimit {
                return Decision(phase: .normal, action: .discharge)
            }
            if batteryLevel < maxLimit {
                return Decision(phase: .normal, action: .charge)
            }
            return Decision(phase: .normal, action: .holdOnAC)

        case .cycleDischarging:
            if batteryLevel <= target(cycleTarget, maxLimit: maxLimit) {
                return Decision(phase: .cycleRecharging, action: .charge)
            }
            return Decision(phase: .cycleDischarging, action: .discharge)

        case .cycleRecharging:
            if batteryLevel >= maxLimit {
                return Decision(phase: .normal, action: .holdOnAC)
            }
            return Decision(phase: .cycleRecharging, action: .charge)
        }
    }
}
