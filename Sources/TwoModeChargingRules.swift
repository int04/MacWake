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
    }

    struct Decision: Equatable {
        var phase: Phase
        var action: Action
    }

    /// CHIE-only hardware cannot inhibit charging while keeping the adapter online.
    /// Instead it can discharge down to Max, reconnect AC, and defer the next cut
    /// until a five-point band is crossed. This is NOT a battery bypass.
    static func decideAdapterCutFallback(
        phase: Phase,
        batteryLevel: Int,
        maxLimit: Int,
        cycleTarget: Int,
        adapterRestoredAtMax: Bool
    ) -> Decision {
        let ceiling = min(95, max(20, maxLimit))
        switch phase {
        case .normal:
            if batteryLevel <= ceiling {
                return Decision(phase: .normal, action: .charge)
            }
            if adapterRestoredAtMax && batteryLevel < min(100, ceiling + 5) {
                return Decision(phase: .normal, action: .charge)
            }
            return Decision(phase: .normal, action: .discharge)
        case .cycleDischarging:
            if batteryLevel <= target(cycleTarget, maxLimit: ceiling) {
                return Decision(phase: .cycleRecharging, action: .charge)
            }
            return Decision(phase: .cycleDischarging, action: .discharge)
        case .cycleRecharging:
            if batteryLevel >= ceiling {
                return Decision(phase: .normal, action: .charge)
            }
            return Decision(phase: .cycleRecharging, action: .charge)
        }
    }

    static func target(_ proposed: Int, maxLimit: Int) -> Int {
        min(max(5, maxLimit - 5), max(5, proposed))
    }

    static func decide(
        phase: Phase,
        batteryLevel: Int,
        maxLimit: Int,
        cycleTarget: Int
    ) -> Decision {
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
