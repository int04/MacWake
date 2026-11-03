import Foundation
import AppKit
import IOKit
import IOKit.pwr_mgt
import ServiceManagement
import MacWakeShared

/// Holding the limit by cutting the adapter on a Mac running with its lid closed and an
/// external display attached is the one case where the cut can take the display down: a single
/// USB-C cable often carries both the monitor's power and its DisplayPort video, and cutting
/// the adapter forces a power renegotiation that drops the video link — again each time power
/// is restored. Kept pure so the rule can be tested without a lid or a monitor.
enum ClamshellGuard {
    static func shouldSuppressAdapterCut(lidClosed: Bool, externalDisplayAttached: Bool, allowOverride: Bool) -> Bool {
        lidClosed && externalDisplayAttached && !allowOverride
    }
}

enum LidAndDisplay {
    /// `AppleClamshellState` on the power-management root domain; false if it can't be read.
    static func lidIsClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    @MainActor
    static func externalDisplayAttached() -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
    }
}

/// The band handed to the firmware-managed limit, kept pure so it can be tested without an SMC.
enum FirmwareChargeLimit {
    /// `upper` is the configured limit. `lower` is where the firmware lets charging resume: the
    /// Sailing floor when Sailing Mode is on (no active discharge involved any more), otherwise
    /// the usual hysteresis below the limit. Always a valid band — at least 1 and strictly below
    /// `upper` — whatever the stored values are.
    static func bounds(limit: Int, sailingEnabled: Bool, sailingLower: Int, hysteresis: Int) -> (upper: Int, lower: Int) {
        let upper = min(100, max(2, limit))
        let wanted = sailingEnabled ? sailingLower : limit - hysteresis
        return (upper, min(upper - 1, max(1, wanted)))
    }
}

/// Pure safety rules shared by the calibration state machine and its regression tests.
enum CalibrationRecovery {
    static func shouldRestoreImmediately(batteryLevel: Int, dischargeFloor: Int) -> Bool {
        batteryLevel <= dischargeFloor
    }

    static func shouldForceDischarge(batteryLevel: Int, dischargeFloor: Int, adapterEnabled: Bool?) -> Bool {
        batteryLevel > dischargeFloor && adapterEnabled != false
    }

    static func restoreSucceeded(forceDischargeCleared: Bool, chargingEnabled: Bool) -> Bool {
        forceDischargeCleared && chargingEnabled
    }
}

/// Rules for holding a charge limit, kept pure so the floors can be tested without an SMC.
///
/// On Macs whose SMC exposes no charge-inhibit key, stopping charge means cutting adapter
/// input, so every "pause" here is a real discharge. Anything that pauses charging
/// therefore needs a floor, and nothing may delay the recovery direction.
enum ChargeHoldRules {
    /// Heat Guard used to pause charging with no lower bound, so on adapter-cut hardware a
    /// hot battery drained until it cooled — reported reaching 73% under an 80% limit.
    static func heatGuardShouldRestore(batteryLevel: Int, lowerBound: Int) -> Bool {
        batteryLevel <= lowerBound
    }

    /// The anti-flapping interval must gate only the stop direction. Rate-limiting a restore
    /// leaves the Mac draining on adapter power for another window, which is what let the
    /// level overshoot the lower bound.
    static func toggleIsRateLimited(chargingAllowed: Bool, sinceLastToggle: TimeInterval?,
                                    minimumInterval: TimeInterval) -> Bool {
        guard !chargingAllowed, let sinceLastToggle else { return false }
        return sinceLastToggle < minimumInterval
    }
}

/// Manages the privileged helper daemon and drives charge limiting by toggling
/// the power adapter (SMC key CHIE) through the helper.
///
/// Apple Silicon (M-series) has no clean "inhibit charge but stay on AC" SMC key
/// that is writable on M4, so we hold the battery near the limit by cutting the
/// adapter (discharge) above the target and re-enabling it once it dips below —
/// the same discharge-to-hold strategy AlDente uses where no inhibit key exists.
@MainActor
final class ChargeLimitManager: ObservableObject {
    static let shared = ChargeLimitManager()

    enum HelperStatus {
        case notInstalled      // daemon not registered
        case requiresApproval  // registered, waiting for user approval in System Settings
        case ready             // registered and enabled
    }

    @Published private(set) var helperStatus: HelperStatus = .notInstalled

    /// Whether MacWake is actively enforcing its standing limit, or has yielded to a
    /// confirmed external hold. See `ChargeControlOwnership`.
    @Published private(set) var ownership: ChargeControlOwnership = .enforcing
    private var consecutiveClearHoldSamples = 0

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "chargeLimitEnabled")
            if !isEnabled {
                twoModePhase = .normal
                twoModeStartedAt = nil
                twoModeGeneration += 1
                twoModeError = nil
                requestTwoModeAction(.charge)
                if firmwareLimitActive { Task { await self.releaseFirmwareLimit() } }
            }
            // evaluate() returns before reaching the ownership update while disabled, so a
            // stale `.yielded` from before the toggle was switched off would otherwise
            // reappear in the UI the instant it's switched back on, up to a tick before the
            // next evaluate() call could correct it. Every (re-)enable starts from a clean
            // "assume enforcing" read instead of carrying old state across the gap.
            ownership = .enforcing
            consecutiveClearHoldSamples = 0
        }
    }

    @Published var limit: Int {
        didSet {
            let clamped = min(95, max(20, limit))
            if clamped != limit { limit = clamped; return }
            UserDefaults.standard.set(limit, forKey: "chargeLimitValue")
            if sailingLower > limit - 5 { sailingLower = limit - 5 }
            if dischargeTarget >= limit { dischargeTarget = max(5, limit - 5) }
            adapterRestoredAtMax = false
            if isEnabled, helperStatus == .ready {
                evaluate(batteryLevel: twoModeLastBatteryLevel, isPluggedIn: twoModeLastPlugged)
            }
        }
    }

    // The two charging modes are mutually exclusive. The legacy scheduling, Sailing,
    // heat-guard, calibration and top-up controls are no longer active controllers.
    @Published private(set) var twoModePhase: TwoModeChargingRules.Phase = .normal
    @Published private(set) var twoModeAppliedAction: TwoModeChargingRules.Action?
    @Published private(set) var twoModeError: String?
    var canHoldOnAdapterPower: Bool { holdCutsAdapter == false }
    private var twoModeCycleTarget = 20
    /// Adapter-cut-only Macs restore AC at Max and do not recut until Max + 5%.
    /// This is a bounded charge/discharge fallback, not a true charge inhibit.
    private var adapterRestoredAtMax = false
    var activeCycleTarget: Int { twoModeCycleTarget }
    private var twoModeStartedAt: Date?
    private var twoModeRequestedAction: TwoModeChargingRules.Action?
    private var twoModeCommandInFlight = false
    private var twoModeGeneration = 0
    private var twoModeSuspended = false
    private var twoModeMonitor: Timer?
    private var twoModeLastBatteryLevel = 0
    private var twoModeLastPlugged = false

    /// One-shot "charge to 100% this once" override (e.g. before travel). Cleared
    /// automatically when the battery reaches 100% or on cancel; deliberately NOT
    /// persisted so a forgotten override can't outlive a relaunch.
    @Published var topUpActive = false

    /// A one-shot charge hold. The normal limit takes over again at the lower
    /// recharge threshold. Not persisted: quitting restores charging safely.
    @Published private(set) var manualChargePaused = false

    func stopChargingNow(batteryLevel: Int) {
        guard helperStatus == .ready, isEnabled, !calibrationActive,
              !dischargeActive, !topUpActive, !scheduledChargeActive else { return }
        let lower = sailingEnabled ? sailingLower : limit - hysteresis
        guard batteryLevel > lower else { return }
        // Stop Charging Now is an explicit user action. Unlike the automatic
        // standing limit, it must not be silently ignored in clamshell mode.
        manualChargePaused = true
        Task {
            if firmwareLimitActive { await releaseFirmwareLimit() }
            await applyChargingAllowed(false)
        }
    }

     /// Restore adapter power synchronously before suspension, when the app-side
    /// control loop cannot guarantee a timely recovery.
    func cancelManualPauseBeforeSleep() {
        guard manualChargePaused else { return }
        manualChargePaused = false
        restoreChargingSynchronously()
    }

    func cancelManualChargePause() {
        manualChargePaused = false
        Task { await restoreCharging() }
    }

    // MARK: - Manual discharge

    /// Actively drain the battery on AC down to a chosen level. The limit alone can only
    /// stop charging, so a Mac that has sat plugged in at 95% has no way down without
    /// unplugging — this runs the adapter cut (CHIE) until the target is reached, then
    /// hands control straight back to the normal limit.
    // Opt-in one-shot return to the standing charge limit, not deep calibration.
    @Published var automaticDischargeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticDischargeEnabled, forKey: "automaticDischargeEnabled")
            if !automaticDischargeEnabled && automaticDischargeInProgress { cancelDischarge() }
        }
    }
    @Published private(set) var automaticDischargeInProgress = false
    private var automaticDischargeTarget: Int?
    var currentDischargeTarget: Int { automaticDischargeTarget ?? dischargeTarget }
    private var dischargeGeneration = 0
    private var dischargeApplyInFlight = false
    private var automaticDischargeArmed = true
    private var dischargeStartedAt: Date?
    private let automaticDischargeTimeout: TimeInterval = 6 * 3600

    @Published private(set) var dischargeActive = false
    @Published var dischargeTarget: Int {
        didSet {
            let clamped = min(max(dischargeFloor, limit - 5), max(dischargeFloor, dischargeTarget))
            if clamped != dischargeTarget { dischargeTarget = clamped; return }
            UserDefaults.standard.set(dischargeTarget, forKey: "dischargeTarget")
        }
    }
    /// Never drain below this, however low the user drags the slider.
    private let dischargeFloor = 5

    func startDischarge() {
        guard helperStatus == .ready, isEnabled, !dischargeActive, !calibrationActive,
              !topUpActive, !scheduledChargeActive, !manualChargePaused,
              !clamshellAdapterCutBlocked else { return }
        dischargeGeneration += 1
        dischargeApplyInFlight = false
        dischargeActive = true
        dischargeStartedAt = Date()
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Discharging"),
            message: String(format: String(localized: "DISCHARGE_STARTED_FMT"), currentDischargeTarget),
            isWarning: false
        ))
        requestActiveDischarge()
    }

    /// Keep one adapter-cut request in flight; a late reply after cancellation is
    /// followed by an explicit restore so it cannot strand the Mac on battery.
    private func requestActiveDischarge() {
        guard dischargeActive, !dischargeApplyInFlight else { return }
        dischargeApplyInFlight = true
        let generation = dischargeGeneration
        Task {
            guard dischargeActive, dischargeGeneration == generation else { return }
            if firmwareLimitActive {
                guard await releaseFirmwareLimit() else {
                    if dischargeGeneration == generation { finishDischarge(reachedTarget: false) }
                    return
                }
            }
            guard dischargeActive, dischargeGeneration == generation else { return }
            let ok = await forceDischarge(true)
            if dischargeGeneration != generation {
                await restoreCharging()
                return
            }
            dischargeApplyInFlight = false
            if !ok {
                automaticDischargeArmed = false
                finishDischarge(reachedTarget: false)
            }
        }
    }

    func cancelDischarge() { finishDischarge(reachedTarget: false) }

    // Avoid forced discharge continuing through suspended app execution.
    func cancelDischargeBeforeSleep() {
        guard dischargeActive else { return }
        dischargeGeneration += 1
        dischargeApplyInFlight = false
        dischargeActive = false
        automaticDischargeInProgress = false
        automaticDischargeTarget = nil
        dischargeStartedAt = nil
        automaticDischargeArmed = false
        restoreChargingSynchronously()
    }

    private func finishDischarge(reachedTarget: Bool) {
        guard dischargeActive else { return }
        let finishedTarget = currentDischargeTarget
        dischargeGeneration += 1
        dischargeApplyInFlight = false
        dischargeActive = false
        automaticDischargeInProgress = false
        automaticDischargeTarget = nil
        dischargeStartedAt = nil
        Task { await restoreCharging() }
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Discharging"),
            message: reachedTarget
                ? String(format: String(localized: "DISCHARGE_DONE_FMT"), finishedTarget)
                : String(localized: "Discharge cancelled. Charging resumed."),
            isWarning: false
        ))
    }

    private func checkScheduledCalibration(
        batteryLevel: Int, physicallyPlugged: Bool,
        batteryTemperatureC: Double, lidClosedWithExternalDisplay: Bool,
        conflictingMode: Bool
    ) {
        guard calibrationScheduleMode > 0,
              SmartChargeCycleRules.calibrationIsDue(
                lastHandled: calibrationScheduleLastHandled, now: Date()
              ) else { return }
        if calibrationScheduleMode == 1 {
            calibrationScheduleLastHandled = Date()
            UserDefaults.standard.set(calibrationScheduleLastHandled,
                                      forKey: "calibrationScheduleLastHandled")
            DynamicIslandManager.shared.trigger(.alert(
                title: String(localized: "Calibration Reminder"),
                message: String(localized: "CALIBRATION_MONTHLY_REMINDER"),
                isWarning: false
            ))
        } else if SmartChargeCycleRules.canStartScheduledCalibration(
            batteryTemperatureC: batteryTemperatureC,
            physicallyPlugged: physicallyPlugged,
            helperReady: helperStatus == .ready,
            lidClosedWithExternalDisplay: lidClosedWithExternalDisplay,
            conflictingMode: conflictingMode
        ) {
            startCalibration(batteryLevel: batteryLevel, fullCycle: true)
        }
    }

    /// Start/cancel the one-shot full charge.
    func topUp(_ on: Bool) {
        guard helperStatus == .ready, !calibrationActive else { return }
        if on && dischargeActive {
            automaticDischargeArmed = false
            cancelDischarge()
        }
        topUpActive = on
        if on {
            Task { await restoreCharging() }   // clear any active charge block right away
            DynamicIslandManager.shared.trigger(.alert(
                title: String(localized: "Topping Up"),
                message: String(localized: "Charging to 100% this once, then the limit resumes."),
                isWarning: false
            ))
        }
        // On cancel the next evaluate() tick re-applies the normal limit.
    }

    /// Scheduled full charge: hold the normal limit overnight, then start charging early
    /// enough that the battery lands at 100% around the chosen time (e.g. "ready by 9:00").
    /// After the target window passes, normal limiting resumes automatically.
    @Published var scheduledChargeEnabled: Bool {
        didSet { UserDefaults.standard.set(scheduledChargeEnabled, forKey: "scheduledChargeEnabled") }
    }
    /// Minutes past midnight (local), e.g. 540 = 09:00.
    @Published var scheduledChargeMinutes: Int {
        didSet {
            let clamped = min(1439, max(0, scheduledChargeMinutes))
            if clamped != scheduledChargeMinutes { scheduledChargeMinutes = clamped; return }
            UserDefaults.standard.set(scheduledChargeMinutes, forKey: "scheduledChargeMinutes")
        }
    }
    /// True while inside the pre-target charge window (drives the UI status line).
    @Published private(set) var scheduledChargeActive = false
    private var scheduledChargeAnnounced = false

    /// Conservative start time: ~2.5 min per missing percent + 15 min buffer. Charging
    /// slows near 100%, so err on the early side — landing full a bit before the target
    /// beats landing at 92% when the user unplugs. The window opens `lead` before the
    /// target and stays open 2h past it, so a Mac that reaches 100% at 08:40 holds full
    /// through 09:00 instead of instantly drifting back down to the limit. Today's AND
    /// tomorrow's occurrences are both checked: today's covers the hold-past-target
    /// stretch after the time passes, tomorrow's covers leads that span midnight.
    /// The target we've committed to charging for, if any. Latching is essential: the
    /// lead is sized off `missing`, which shrinks as the battery fills, pushing the
    /// open-boundary (`target - lead`) LATER in real time. Without a latch, a Mac that
    /// charges faster than the clock re-crosses that moving boundary and stutters —
    /// pause/resume/pause near ~95% — flapping the SMC and Dynamic Island. Once the
    /// window opens for a target, we hold it open through the post-target window.
    private var scheduledWindowLatch: Date?

    private func scheduledChargeWindow(batteryLevel: Int, now: Date = Date()) -> Bool {
        guard scheduledChargeEnabled else { scheduledWindowLatch = nil; return false }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = scheduledChargeMinutes / 60
        comps.minute = scheduledChargeMinutes % 60
        guard let todayTarget = cal.date(from: comps) else { return false }

        let missing = max(0, 100 - batteryLevel)
        let leadSeconds = Double(missing) * 150 + 900

        for dayOffset in 0...1 {
            guard let target = cal.date(byAdding: .day, value: dayOffset, to: todayTarget) else { continue }
            let closeAt = target.addingTimeInterval(2 * 3600)
            // Already committed to this target and still within its window → stay open,
            // regardless of how far the shrinking lead has drifted the open-boundary.
            if scheduledWindowLatch == target, now <= closeAt {
                return true
            }
            if now >= target.addingTimeInterval(-leadSeconds), now <= closeAt {
                scheduledWindowLatch = target
                return true
            }
        }
        scheduledWindowLatch = nil
        return false
    }

    /// Heat Guard: pause charging while the battery runs hot (charging heat is a major
    /// driver of battery wear), resume automatically once it cools back down.
    @Published var heatGuardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(heatGuardEnabled, forKey: "heatGuardEnabled")
            if !heatGuardEnabled && heatGuardPaused { heatGuardPaused = false }
        }
    }
    @Published private(set) var heatGuardPaused = false
    private let heatGuardPauseTempC: Double = 40
    private let heatGuardResumeTempC: Double = 37   // hysteresis so it can't flap

    /// Called whenever a fresh battery temperature is read. Only flips the paused flag —
    /// evaluate() owns the actual SMC toggling, so all charging decisions stay in one place.
    func heatGuardCheck(batteryTempC: Double) {
        guard heatGuardEnabled, helperStatus == .ready, !calibrationActive else { return }
        if !heatGuardPaused, batteryTempC >= heatGuardPauseTempC {
            heatGuardPaused = true
            DynamicIslandManager.shared.trigger(.alert(
                title: String(localized: "Heat Guard"),
                message: String(format: String(localized: "HEATGUARD_PAUSED_FMT"), batteryTempC),
                isWarning: true
            ))
        } else if heatGuardPaused, batteryTempC <= heatGuardResumeTempC {
            heatGuardPaused = false
            DynamicIslandManager.shared.trigger(.alert(
                title: String(localized: "Heat Guard"),
                message: String(localized: "Battery cooled down — charging resumed."),
                isWarning: false
            ))
        }
    }

    /// Sailing Mode: let the battery drift down to `sailingLower` before topping back
    /// up to `limit`, instead of micro-charging at the ceiling. Fewer cycles, less heat.
    @Published var sailingEnabled: Bool {
        didSet { UserDefaults.standard.set(sailingEnabled, forKey: "sailingEnabled") }
    }

    @Published var sailingLower: Int {
        didSet {
            let clamped = min(limit - 5, max(10, sailingLower))
            if clamped != sailingLower { sailingLower = clamped; return }
            UserDefaults.standard.set(sailingLower, forKey: "sailingLower")
        }
    }


    enum CalibrationPhase { case precharge, discharge, charge, hold, returnToLimit }
    @Published private(set) var calibrationActive = false
    @Published private(set) var calibrationPhase: CalibrationPhase = .discharge
    @Published var calibrationScheduleMode: Int {
        didSet {
            let normalized = min(2, max(0, calibrationScheduleMode))
            if normalized != calibrationScheduleMode { calibrationScheduleMode = normalized; return }
            UserDefaults.standard.set(calibrationScheduleMode, forKey: "calibrationScheduleMode")
        }
    }
    private var calibrationScheduleLastHandled: Date
    private var calibrationFullCycle = false
    private var calibrationGeneration = 0
    private var calibrationDischargeInFlight = false
    private var calibrationHoldStart: Date?
    private var calibrationStartedAt: Date?
    private let calibrationDischargeFloor = 15
    private let calibrationHoldSeconds: TimeInterval = 3600   // hold at 100% for 1 hour
    // Safety backstop: a normal cycle (drain to 15%, recharge to 100%, hold an hour)
    // should never take this long on AC. If it does — e.g. a genuine unplug mid-cycle
    // that the self-induced-discharge heuristic can't distinguish from our own cutoff —
    // abort rather than leave the battery parked low or charging paused indefinitely.
    private let calibrationMaxDuration: TimeInterval = 8 * 3600
    private let fullCalibrationMaxDuration: TimeInterval = 18 * 3600
    // If the helper is unreachable (mid-restart, stuck, connection dropped), forceDischarge
    // retries every evaluate() tick with no bound otherwise — surface a stop instead of
    // silently retrying forever with no diagnostic.
    private var calibrationXPCFailureCount = 0
    private let calibrationXPCFailureLimit = 6

    // MARK: - Fan control (experimental; only meaningful on Macs with fans)

    /// Number of fans (0 = fanless — the UI hides fan control entirely).
    @Published private(set) var fanCount = 0
    @Published private(set) var fanMinRPM = 0
    @Published private(set) var fanMaxRPM = 0
    @Published private(set) var fanRangesDescription = ""
    var fanHardwareRangeValid: Bool { fanMaxRPM > fanMinRPM + 200 }

    // A saved user preference is not a live SMC fan override. On launch and wake,
    // restore manual mode only after a fresh thermal sample and fan discovery.
    private var fanResumePending = false

    @Published var fanControlEnabled: Bool {
        didSet {
            if !fanControlEnabled { fanResumePending = false }
            UserDefaults.standard.set(fanControlEnabled, forKey: "fanControlEnabled")
            Task { await applyFan() }
        }
    }

    @Published var fanTargetRPM: Int {
        didSet {
            UserDefaults.standard.set(fanTargetRPM, forKey: "fanTargetRPM")
            if fanControlEnabled { Task { await applyFan() } }
        }
    }

    /// Safety: above this temperature we drop fan control back to automatic so a low
    /// manual speed can never cause overheating.
    private let fanFailsafeTempC: Double = 92

    // MARK: - Energy Mode (macOS pmset)

    /// 0 = Automatic, 1 = Low Power, 2 = High Power.
    @Published private(set) var energyMode: Int = 0
    /// True on Macs that expose High Power Mode (some MacBook Pros).
    @Published private(set) var highPowerSupported = false

    /// Hysteresis: resume charging only after dropping this far below the limit,
    /// to avoid rapid on/off oscillation around the threshold (non-sailing mode).
    private let hysteresis = 5

    /// Minimum time between adapter toggles, a hard backstop against oscillation.
    private let minToggleInterval: TimeInterval = 90

    // MARK: - Firmware-managed limit (experimental)

    /// Opt-in. Holds the limit with the firmware's own charge limit instead of cutting the
    /// adapter, so the Mac stays on adapter power. Writes undocumented SMC keys and the limit
    /// outlives the app until released — see `releaseFirmwareLimit` — hence off by default.
    @Published var useFirmwareLimit: Bool {
        didSet {
            UserDefaults.standard.set(useFirmwareLimit, forKey: "useFirmwareLimit")
            if !useFirmwareLimit {
                firmwareLimitFailed = false
                Task { await releaseFirmwareLimit() }
            }
        }
    }
    /// nil until the helper has answered; true only if all three firmware keys are readable.
    @Published private(set) var firmwareLimitSupported: Bool?
    /// True while MacWake has the firmware limit engaged and confirmed.
    @Published private(set) var firmwareLimitActive = false
    /// The helper could not confirm the firmware limit on this Mac, so MacWake went back to
    /// the adapter-cut path for this session.
    @Published private(set) var firmwareLimitFailed = false
    private var firmwareApplied: (upper: Int, lower: Int)?
    private var firmwareRequestInFlight = false
    private var firmwareVerifiedAt: Date?
    private let firmwareVerifyInterval: TimeInterval = 300

    private var clamshellAdapterCutBlocked: Bool {
        ClamshellGuard.shouldSuppressAdapterCut(
            lidClosed: LidAndDisplay.lidIsClosed(),
            externalDisplayAttached: LidAndDisplay.externalDisplayAttached(),
            allowOverride: allowCutInClamshell
        )
    }

    /// Opt-out of the clamshell guard (see `ClamshellGuard`): cut the adapter even with the lid
    /// closed and a display attached, accepting that the display may drop.
    @Published var allowCutInClamshell: Bool {
        didSet { UserDefaults.standard.set(allowCutInClamshell, forKey: "allowCutInClamshell") }
    }
    /// True while the standing limit is deliberately not cutting the adapter because the lid is
    /// closed with a display attached — the battery charges past the limit meanwhile, and the
    /// UI says so.
    @Published private(set) var clamshellHoldSuppressed = false

    /// Hold mechanism as the UI should describe it: while the firmware limit is engaged nothing
    /// is cutting the adapter, whatever the Mac's own charge-stop key would otherwise do.
    var holdCutsAdapterNow: Bool? { firmwareLimitActive ? false : holdCutsAdapter }

    private let plistName = "com.nghiaduc.macwakelocal.helper.plist"
    private var connection: NSXPCConnection?
    private var lastAdapterEnabled: Bool?
    private var lastToggleAt: Date?
    /// When the level first reached the ceiling this cycle, on adapter-cut-only hardware —
    /// so the standing limit can give native-hold detection a short head start before its own
    /// cut would pre-empt it. See `ChargeControlOwnership.mayEnforceLimitNow`. Cleared whenever
    /// the level drops back out of the ceiling band or MacWake starts its own hold.
    private var limitReachedAt: Date?

    /// True briefly after we flip the adapter, so BatteryTracker can suppress the
    /// charging animation / Dynamic Island for our own induced power-source changes.
    func didInducePowerChange(within seconds: TimeInterval) -> Bool {
        guard let t = lastToggleAt else { return false }
        return Date().timeIntervalSince(t) < seconds
    }

    /// True for as long as we are holding the adapter off ourselves (at the charge-limit
    /// ceiling, or during sailing/calibration force-discharge) — not just briefly after the
    /// toggle. macOS reports "on battery" in this state even though the cable is still
    /// physically connected; callers tracking continuous-AC time should treat this the same
    /// as plugged in, the same way `evaluate()`'s own `physicallyPlugged` check does.
    var isHoldingChargeOff: Bool { lastAdapterEnabled == false }

    private init() {
        let d = UserDefaults.standard
        // One-time transition to exactly two charge workflows. Settings left enabled by
        // older releases must not resume scheduled charging, Sailing, calibration,
        // firmware experiments or automatic discharge behind the new two-mode UI.
        if !d.bool(forKey: "twoModeChargingMigrated") {
            for key in ["sailingEnabled", "heatGuardEnabled", "scheduledChargeEnabled",
                        "automaticDischargeEnabled", "useFirmwareLimit"] {
                d.set(false, forKey: key)
            }
            d.set(0, forKey: "calibrationScheduleMode")
            d.set(true, forKey: "twoModeChargingMigrated")
        }
        self.isEnabled = d.bool(forKey: "chargeLimitEnabled")
        let savedLimit = d.integer(forKey: "chargeLimitValue")
        let lim = savedLimit == 0 ? 80 : min(95, max(20, savedLimit))
        self.limit = lim
        self.sailingEnabled = d.bool(forKey: "sailingEnabled")
        let savedLower = d.integer(forKey: "sailingLower")
        self.sailingLower = savedLower == 0 ? max(10, lim - 10) : min(lim - 5, max(10, savedLower))
        self.fanControlEnabled = false
        self.fanResumePending = d.bool(forKey: "fanControlEnabled")
        self.fanTargetRPM = d.integer(forKey: "fanTargetRPM")
        self.heatGuardEnabled = d.bool(forKey: "heatGuardEnabled")
        self.scheduledChargeEnabled = d.bool(forKey: "scheduledChargeEnabled")
        let savedSchedule = d.object(forKey: "scheduledChargeMinutes") as? Int
        self.scheduledChargeMinutes = savedSchedule.map { min(1439, max(0, $0)) } ?? 540   // default 09:00
        let savedDischarge = d.object(forKey: "dischargeTarget") as? Int
        self.dischargeTarget = savedDischarge.map { TwoModeChargingRules.target($0, maxLimit: lim) }
            ?? TwoModeChargingRules.target(20, maxLimit: lim)
        self.automaticDischargeEnabled = d.bool(forKey: "automaticDischargeEnabled")
        self.calibrationScheduleMode = min(2, max(0, d.object(forKey: "calibrationScheduleMode") as? Int ?? 1))
        self.calibrationScheduleLastHandled = d.object(forKey: "calibrationScheduleLastHandled") as? Date ?? Date()
        if d.object(forKey: "calibrationScheduleLastHandled") == nil {
            d.set(self.calibrationScheduleLastHandled, forKey: "calibrationScheduleLastHandled")
        }
        // A missing key means either a fresh install (never asked, so default off) or an
        // existing user upgrading from before this switch existed (default on, to preserve
        // their already-configured protection) — chargeLimitEnabled predates the split, so
        // its presence tells the two apart. See ChargeLimitAuthorization.defaultAllowActiveDischarge.
        let hasPriorChargeLimitConfig = d.object(forKey: "chargeLimitEnabled") != nil
        let allowActiveDischargeKeyWasMissing = d.object(forKey: "allowActiveDischarge") == nil
        self.allowActiveDischarge = (d.object(forKey: "allowActiveDischarge") as? Bool)
            ?? ChargeLimitAuthorization.defaultAllowActiveDischarge(hasPriorChargeLimitConfig: hasPriorChargeLimitConfig)
        self.showMigrationNotice = hasPriorChargeLimitConfig
            && allowActiveDischargeKeyWasMissing
            && !d.bool(forKey: "didShowActiveDischargeMigrationNotice")
        self.useFirmwareLimit = d.bool(forKey: "useFirmwareLimit")
        self.allowCutInClamshell = d.bool(forKey: "allowCutInClamshell")
        refreshStatus()
    }

    // MARK: - Daemon lifecycle

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    private var didReconcile = false

    func refreshStatus() {
        let status = service.status
        switch status {
        case .enabled:
            helperStatus = .ready
            if lastAdapterEnabled == nil { syncAdapterState() }
            if holdCutsAdapter == nil { loadChargeControlMethod() }
            if fanCount == 0 { loadFanInfo() }
            if firmwareLimitSupported == nil { loadFirmwareLimitSupport() }
            readEnergyMode()
        case .requiresApproval:
            helperStatus = .requiresApproval
        default:
            helperStatus = .notInstalled
        }

        // Reconcile on reachability, not on registration state. Replacing the app bundle can
        // drop the registration out of `.enabled` while launchd keeps the OLD daemon running
        // and answering XPC — and with this check inside the `.enabled` branch the app could
        // never repair itself. A daemon that replies to getVersion can be reloaded whatever
        // SMAppService reports about it.
        loadHelperVersion()

        if !didReconcile {
            didReconcile = true
            reloadHelperIfOutdated(observedStatus: status)
        }
    }

    /// After an app update the on-disk helper is new but the running daemon may still
    /// be the old binary (missing new XPC methods). Compare versions and re-register to
    /// load the current helper. Approval persists, so this is silent.
    private func reloadHelperIfOutdated(observedStatus: SMAppService.Status) {
        guard let proxy = remoteProxy() else {
            appendHelperReloadLog(from: "unreachable", report: "no XPC proxy")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let version = await self.xpcString(timeout: 4) { reply in proxy.getVersion(reply: reply) }
            guard version != kMacWakeHelperVersion else { return }
            if version.isEmpty {
                // No answer from a daemon that is running: an update replaced the helper binary
                // on disk, and the app refuses to talk to a process whose signature no longer
                // matches the file behind it ("Received message forbidden due to code signing
                // requirement"). Every update that changes the helper strands the old daemon
                // this way — the next steps below cannot even reach it, so recycle it through a
                // connection that skips that check.
                let report = await self.recycleUnauthenticatedDaemon()
                self.appendHelperReloadLog(from: "unreachable",
                                           report: "status before recycle: \(observedStatus.rawValue)\n" + report)
                return
            }
            // Reachable but outdated: reuse the manual path rather than repeating the sequence:
            // unregistering while our XPC connection still holds the daemon leaves launchd with
            // the old job, and this copy had the invalidate *after* the re-register, so the
            // automatic reconcile silently did nothing. A machine could sit on an outdated
            // daemon indefinitely — which is exactly what the version constant exists to prevent.
            let report = await self.forceReloadHelper()
            self.appendHelperReloadLog(
                from: version,
                report: "status before reload: \(observedStatus.rawValue)\n" + report
            )
        }
    }

    /// Asks the running daemon to exit over a connection that does NOT pin its code signature,
    /// then waits for launchd to start the current binary. The only thing sent is
    /// `exitForUpdate`, which restores charging and exits — nothing a stand-in could exploit,
    /// and only root can register the mach service name in the first place. Everything after
    /// this goes back over the normal pinned connection, which validates the new daemon.
    private func recycleUnauthenticatedDaemon() async -> String {
        var log = "daemon not answering on the pinned connection — recycling it unpinned\n"
        let bare = NSXPCConnection(machServiceName: kMacWakeHelperMachServiceName, options: .privileged)
        bare.remoteObjectInterface = NSXPCInterface(with: MacWakeHelperProtocol.self)
        bare.resume()
        let exited: Bool
        if let proxy = bare.remoteObjectProxyWithErrorHandler({ _ in }) as? MacWakeHelperProtocol {
            exited = await xpcBool(timeout: 4) { reply in proxy.exitForUpdate(reply: reply) }
        } else {
            exited = false
        }
        bare.invalidate()
        log += exited ? "daemon asked to exit\n" : "daemon did not answer the exit request\n"
        connection?.invalidate()
        connection = nil

        var reported = ""
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            reported = await xpcString(timeout: 2) { [weak self] reply in
                guard let proxy = self?.remoteProxy() else { return reply("") }
                proxy.getVersion(reply: reply)
            }
            if !reported.isEmpty { break }
            connection?.invalidate()
            connection = nil
        }
        log += "daemon now reports \(reported.isEmpty ? "nothing" : reported)"
        log += reported == kMacWakeHelperVersion ? " — up to date\n" : " — not current\n"
        helperVersion = reported.isEmpty ? nil : reported
        if !reported.isEmpty {
            forgetFirmwareLimit()
            fanCount = 0
            loadFanInfo()
            syncAdapterState()
        }
        return log
    }

    /// Record what the automatic reconcile did. It runs unattended at launch, so a failure
    /// here is invisible — which is how a machine sat on an outdated daemon for hours without
    /// anything to look at. The manual button's report goes to the clipboard; this one goes to
    /// a file so the last attempt can always be read after the fact.
    private func appendHelperReloadLog(from oldVersion: String, report: String) {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/MacWake", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("helper-reload.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(stamp)] daemon reported \(oldVersion), app expects \(kMacWakeHelperVersion)\n"
            + report + "\nfinal status: \(service.status.rawValue)\n\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    /// Reads the helper's real CHIE state to seed `lastAdapterEnabled`, so a fresh
    /// launch reconciles with whatever the daemon left set (e.g. after a crash/quit).
    private func syncAdapterState() {
        guard let proxy = remoteProxy() else { return }
        proxy.getAdapterEnabled { [weak self] enabled in
            Task { @MainActor in
                guard let self else { return }
                if self.lastAdapterEnabled == nil { self.lastAdapterEnabled = enabled }
            }
        }
    }

    /// Registers the daemon. First call usually lands in `.requiresApproval`,
    /// so we also open System Settings for the user to flip the switch.
    /// Set when registering the daemon was refused, so the UI can say why instead of looking
    /// like a dead button. macOS returns "Operation not permitted" here when it wants the
    /// background item allowed first — and a `print` in a menu-bar app reaches nobody.
    @Published private(set) var installError: String?

    func install() {
        installError = nil
        do {
            try service.register()
        } catch {
            installError = error.localizedDescription
            refreshStatus()
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        refreshStatus()
        if helperStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func uninstall() {
        Task {
            await restoreCharging()
            if let proxy = remoteProxy() {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    proxy.uninstall { _ in cont.resume() }
                }
            }
            try? await service.unregister()
            connection?.invalidate()
            connection = nil
            refreshStatus()
        }
    }

    // MARK: - XPC

    private func remoteProxy() -> MacWakeHelperProtocol? {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: kMacWakeHelperMachServiceName, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: MacWakeHelperProtocol.self)
            conn.setCodeSigningRequirement(kMacWakeCodeSigningRequirement)
            // The helper releases a firmware limit when the connection that applied it goes away,
            // so whatever this side believed about it is no longer true.
            conn.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil; self?.forgetAppliedFirmwareLimit() }
            }
            conn.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil; self?.forgetAppliedFirmwareLimit() }
            }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler { err in
            print("ChargeLimit: XPC error: \(err)")
        } as? MacWakeHelperProtocol
    }

    /// Runs an XPC Bool-reply call but never hangs — resolves to false after `timeout`
    /// (e.g. if a stale daemon lacks a newly added method).
    private func xpcBool(timeout: TimeInterval = 3,
                         _ call: @escaping (@escaping (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var done = false
            func finish(_ v: Bool) {
                lock.lock(); defer { lock.unlock() }
                if done { return }; done = true
                cont.resume(returning: v)
            }
            call { finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Apply the desired charging state. Cutting uses whichever method matches the current
    /// mode (Sailing Mode forces the adapter via CHIE so the battery actively discharges;
    /// otherwise the chip's best charge-stop method). Resuming always clears *both* — same
    /// as `restoreCharging()` — because on adapter-cut-only hardware `setForceDischarge`
    /// and `setAdapterEnabled` proved to be independent switches: clearing only the one that
    /// matched the current mode left the other one's earlier cut still in effect (reported as
    /// charging never resuming below the lower bound on its own, only via Top Up/a helper
    /// reload — both of which happen to go through the same both-keys `restoreCharging()`).
    private func applyChargingAllowed(_ allowed: Bool) async {
        guard let proxy = remoteProxy() else { return }
        guard allowed else {
            let ok = await xpcBool { reply in
                if self.sailingEnabled {
                    proxy.setForceDischarge(true, reply: reply)
                } else {
                    proxy.setAdapterEnabled(false, reply: reply)
                }
            }
            if ok {
                lastAdapterEnabled = false
                lastToggleAt = Date()
            }
            return
        }
        _ = await restoreCharging()   // sets lastAdapterEnabled/lastToggleAt itself on success
    }

    /// Clear every charge block (both CHTE inhibit and CHIE adapter-off) so charging
    /// can proceed no matter which method was last used.
    ///
    /// A failed write must NOT update `lastAdapterEnabled`: claiming the adapter is back
    /// while it's still cut makes the control loop believe there's nothing to do, and the
    /// Mac keeps running down the battery. Leaving the old state means the guard in
    /// evaluate() — and the calibration charge phase — retry on the next tick.
    @discardableResult
    private func restoreCharging() async -> Bool {
        guard let proxy = remoteProxy() else { return false }
        let dischargeCleared = await xpcBool { reply in
            proxy.setForceDischarge(false, reply: reply)
        }
        let chargingAllowed = await xpcBool { reply in
            proxy.setAdapterEnabled(true, reply: reply)
        }
        guard CalibrationRecovery.restoreSucceeded(
            forceDischargeCleared: dischargeCleared,
            chargingEnabled: chargingAllowed
        ) else { return false }
        lastAdapterEnabled = true
        lastToggleAt = Date()
        return true
    }

    /// Synchronous best-effort restore for app termination — clears charge blocks and
    /// returns fans to automatic before the process exits.
    func restoreChargingOnQuit() {
        guard let proxy = remoteProxy() else { return }
        let needsCharge = (lastAdapterEnabled == false)
        let needsFan = fanControlEnabled
        let needsFirmware = firmwareLimitActive
        guard needsCharge || needsFan || needsFirmware else { return }
        let sem = DispatchSemaphore(value: 0)
        proxy.setFanManual(false, rpm: 0) { _ in
            proxy.setForceDischarge(false) { _ in
                proxy.setAdapterEnabled(true) { _ in
                    // The firmware limit is enforced outside this process and would otherwise
                    // keep capping charge, unexplained, after the app is gone.
                    if needsFirmware { proxy.releaseFirmwareLimit { _ in sem.signal() } }
                    else { sem.signal() }
                }
            }
        }
        _ = sem.wait(timeout: .now() + 2)
        // Preserve the user's preference, not the unsafe live SMC override.
        // The next launch waits for a fresh thermal reading before restoring it.
    }

    // MARK: - Control loop

    /// A single owner for both charge workflows. No legacy mode can apply an SMC
    /// charge command from this loop.
    func evaluate(batteryLevel: Int, isPluggedIn: Bool, externalHoldPercent: Int? = nil) {
        twoModeLastBatteryLevel = batteryLevel
        twoModeLastPlugged = isPluggedIn
        guard !twoModeSuspended else { return }

        guard helperStatus == .ready, isEnabled else {
            if twoModePhase != .normal { twoModePhase = .normal }
            twoModeStartedAt = nil
            twoModeRequestedAction = .charge
            if helperStatus == .ready { requestTwoModeAction(.charge) }
            return
        }

        // CHIE makes macOS report Battery Power even when a cable is inserted.
        // The successful SMC write is the only evidence that *we* induced that.
        let plugged = isPluggedIn || lastAdapterEnabled == false
        guard plugged else {
            twoModePhase = .normal
            twoModeStartedAt = nil
            requestTwoModeAction(.charge)
            return
        }

        // A clean charge-inhibit key can hold the battery exactly at Max on AC.
        // CHIE-only hardware can still drain down to Max, then reconnect AC, but
        // needs a five-point band to avoid flapping; it cannot bypass the battery.
        guard let cutsAdapter = holdCutsAdapter else { return }
        if cutsAdapter {
            if batteryLevel <= limit ||
                (twoModePhase == .cycleRecharging && batteryLevel >= limit) {
                adapterRestoredAtMax = true
            }
            if twoModePhase == .normal && batteryLevel >= min(100, limit + 5) {
                adapterRestoredAtMax = false
            }
        }

        if let started = twoModeStartedAt, twoModePhase != .normal,
           Date().timeIntervalSince(started) > 18 * 3600 {
            twoModePhase = .normal
            twoModeStartedAt = nil
            twoModeError = String(localized: "TWO_MODE_TIMEOUT")
        }

        let decision = cutsAdapter
            ? TwoModeChargingRules.decideAdapterCutFallback(
                phase: twoModePhase, batteryLevel: batteryLevel, maxLimit: limit,
                cycleTarget: twoModeCycleTarget, adapterRestoredAtMax: adapterRestoredAtMax
              )
            : TwoModeChargingRules.decide(
                phase: twoModePhase, batteryLevel: batteryLevel, maxLimit: limit,
                cycleTarget: twoModeCycleTarget
              )
        if decision.phase != twoModePhase {
            twoModePhase = decision.phase
            if decision.phase == .normal { twoModeStartedAt = nil }
        }

        var action = decision.action
        if action == .discharge {
            let sensor = BatteryTracker.sharedForIntents
            let sampleFresh = sensor?.lastBatteryTemperatureSampleAt.map {
                Date().timeIntervalSince($0) >= 0 && Date().timeIntervalSince($0) < 120
            } ?? false
            let temperature = sampleFresh ? (sensor?.batteryTemperature ?? 0) : 0
            let safe = sampleFresh &&
                temperature >= SmartChargeCycleRules.minimumValidBatteryTemperatureC &&
                temperature < SmartChargeCycleRules.maximumBatteryTemperatureC &&
                !clamshellAdapterCutBlocked

            if !safe {
                // The regular mode may safely inhibit charge while waiting for a valid
                // temperature reading. The explicit cycle instead stops if unsafe.
                if twoModePhase != .normal {
                    twoModePhase = .normal
                    twoModeStartedAt = nil
                    action = batteryLevel >= limit && !cutsAdapter ? .holdOnAC : .charge
                } else {
                    action = cutsAdapter ? .charge : .holdOnAC
                }
                twoModeError = String(localized: "TWO_MODE_DISCHARGE_PAUSED")
            } else {
                twoModeError = nil
            }
        } else if twoModeError == String(localized: "TWO_MODE_DISCHARGE_PAUSED") {
            twoModeError = nil
        }

        requestTwoModeAction(action)
    }

    func startSpecialCycle(batteryLevel: Int, isPluggedIn: Bool) {
        guard isEnabled, helperStatus == .ready, holdCutsAdapter != nil,
              twoModePhase == .normal, (isPluggedIn || lastAdapterEnabled == false) else { return }
        twoModeCycleTarget = TwoModeChargingRules.target(dischargeTarget, maxLimit: limit)
        twoModeStartedAt = Date()
        twoModeError = nil
        twoModePhase = batteryLevel <= twoModeCycleTarget ? .cycleRecharging : .cycleDischarging
        evaluate(batteryLevel: batteryLevel, isPluggedIn: isPluggedIn)
    }

    func stopSpecialCycle() {
        guard twoModePhase != .normal else { return }
        twoModePhase = .normal
        twoModeStartedAt = nil
        // In-flight writes are serialized; a late discharge reply is unwound before
        // the normal mode is allowed to take ownership again.
        twoModeGeneration += 1
        twoModeError = nil
        evaluate(batteryLevel: twoModeLastBatteryLevel, isPluggedIn: twoModeLastPlugged)
    }

    /// Called synchronously from NSWorkspace.willSleep. Never leave a force-discharge
    /// request active while the app is suspended and cannot check the discharge floor.
    func prepareTwoModeForSleep() {
        twoModeSuspended = true
        twoModeGeneration += 1
        twoModeRequestedAction = nil
        twoModeMonitor?.invalidate()
        twoModeMonitor = nil
        twoModePhase = .normal
        twoModeStartedAt = nil
        if twoModeAppliedAction == .discharge || twoModeCommandInFlight {
            restoreChargingSynchronously()
            twoModeAppliedAction = nil
        }
    }

    func resumeTwoModeAfterWake() {
        twoModeSuspended = false
        twoModeGeneration += 1
        twoModeAppliedAction = nil  // SMC state can be reset across sleep
    }

    private func requestTwoModeAction(_ action: TwoModeChargingRules.Action) {
        if twoModeAppliedAction == action, !twoModeCommandInFlight { return }
        twoModeRequestedAction = action
        guard !twoModeCommandInFlight else { return }
        twoModeCommandInFlight = true
        Task { await runTwoModeCommands() }
    }

    /// One XPC writer at a time. The latest requested state wins, including Stop.
    /// A late response from an earlier generation is always followed by a restore.
    private func runTwoModeCommands() async {
        while let action = twoModeRequestedAction {
            twoModeRequestedAction = nil
            if action == twoModeAppliedAction { continue }
            let generation = twoModeGeneration
            let ok = await applyTwoModeAction(action)
            if generation != twoModeGeneration {
                _ = await restoreCharging()
                twoModeAppliedAction = nil
                continue
            }
            if ok {
                twoModeAppliedAction = action
                if twoModeError == String(localized: "TWO_MODE_COMMAND_FAILED") {
                    twoModeError = nil
                }
            } else {
                twoModeAppliedAction = nil
                twoModeError = String(localized: "TWO_MODE_COMMAND_FAILED")
                _ = await restoreCharging()
            }
        }
        twoModeCommandInFlight = false
        updateTwoModeMonitor()
    }

    private func applyTwoModeAction(_ action: TwoModeChargingRules.Action) async -> Bool {
        // Clear both CHIE discharge and CHTE inhibit before switching modes.
        guard await restoreCharging() else { return false }
        switch action {
        case .charge:
            return true
        case .discharge:
            return await forceDischarge(true)
        case .holdOnAC:
            guard holdCutsAdapter == false, let proxy = remoteProxy() else { return false }
            let applied = await xpcBool { reply in
                proxy.setAdapterEnabled(false, reply: reply)
            }
            guard applied else { return false }
            // Unlike xpcBool, a timeout must NOT be mistaken for a readback of false.
            // A missing helper reply is not evidence that charge inhibition succeeded.
            guard let chargingAllowed = await readChargingAllowed(proxy),
                  !chargingAllowed else { return false }
            lastAdapterEnabled = false
            lastToggleAt = Date()
            return true
        }
    }

    private func readChargingAllowed(_ proxy: MacWakeHelperProtocol) async -> Bool? {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            let lock = NSLock()
            var completed = false
            func finish(_ value: Bool?) {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                cont.resume(returning: value)
            }
            proxy.getAdapterEnabled { finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }

    /// Poll more frequently than the 30-second heartbeat when force-discharging.
    /// This matters particularly for a special target as low as 5%.
    private func updateTwoModeMonitor() {
        if twoModeAppliedAction == .discharge, !twoModeSuspended {
            guard twoModeMonitor == nil else { return }
            twoModeMonitor = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let tracker = BatteryTracker.sharedForIntents else { return }
                    let sample = tracker.chargeControlSample()
                    self.evaluate(batteryLevel: sample.level, isPluggedIn: sample.plugged)
                }
            }
        } else {
            twoModeMonitor?.invalidate()
            twoModeMonitor = nil
        }
    }

    // MARK: - Firmware limit

    private func loadFirmwareLimitSupport() {
        guard let proxy = remoteProxy() else { return }
        proxy.firmwareLimitSupported { [weak self] supported in
            Task { @MainActor in self?.firmwareLimitSupported = supported }
        }
    }

    /// Returns true while the firmware is the thing holding the limit, so the caller skips
    /// every other enforcement path. Anything that needs the battery to go past the limit
    /// (calibration, Top Up, manual discharge, a scheduled full charge, Heat Guard) or a
    /// confirmed macOS-native hold releases it and returns false.
    private func manageFirmwareLimit(batteryLevel: Int, externalHoldPercent: Int?) -> Bool {
        let eligible = useFirmwareLimit && firmwareLimitSupported == true && !firmwareLimitFailed
        let overridden = dischargeActive || calibrationActive || topUpActive || heatGuardPaused
            || externalHoldPercent != nil || scheduledChargeWindow(batteryLevel: batteryLevel)
        guard eligible, !overridden else {
            if firmwareLimitActive || firmwareApplied != nil { Task { await releaseFirmwareLimit() } }
            return false
        }

        let wanted = FirmwareChargeLimit.bounds(
            limit: limit, sailingEnabled: sailingEnabled, sailingLower: sailingLower, hysteresis: hysteresis
        )
        guard !firmwareRequestInFlight else { return true }

        if let applied = firmwareApplied, applied == wanted {
            // Re-check periodically: firmware state can be reset (sleep, a reboot of the SMC
            // endpoint) without this process hearing about it.
            if let checked = firmwareVerifiedAt, Date().timeIntervalSince(checked) < firmwareVerifyInterval { return true }
            firmwareRequestInFlight = true
            Task { await verifyFirmwareLimit(wanted) }
            return true
        }

        firmwareRequestInFlight = true
        Task { await applyFirmwareLimit(wanted) }
        return true
    }

    private func applyFirmwareLimit(_ bounds: (upper: Int, lower: Int)) async {
        defer { firmwareRequestInFlight = false }
        guard let proxy = remoteProxy() else { return }
        // A cut left over from the adapter-cut path would keep the Mac on battery regardless.
        if lastAdapterEnabled == false { _ = await restoreCharging() }
        let confirmed = await xpcBool { reply in
            proxy.setFirmwareLimit(upper: bounds.upper, lower: bounds.lower, reply: reply)
        }
        if confirmed {
            firmwareApplied = bounds
            firmwareLimitActive = true
            firmwareVerifiedAt = Date()
        } else {
            firmwareApplied = nil
            firmwareLimitActive = false
            firmwareLimitFailed = true   // this session: use the adapter-cut path instead
        }
    }

    private func verifyFirmwareLimit(_ bounds: (upper: Int, lower: Int)) async {
        defer { firmwareRequestInFlight = false }
        guard let proxy = remoteProxy() else { return }
        let intact = await xpcBool { reply in
            proxy.verifyFirmwareLimit(upper: bounds.upper, lower: bounds.lower, reply: reply)
        }
        if intact { firmwareVerifiedAt = Date() }
        else {
            // Drifted: forget it so the next evaluation applies it again from scratch.
            firmwareApplied = nil
            firmwareLimitActive = false
        }
    }

    @discardableResult
    private func releaseFirmwareLimit() async -> Bool {
        guard let proxy = remoteProxy() else { return false }
        let released = await xpcBool { reply in proxy.releaseFirmwareLimit(reply: reply) }
        if released {
            firmwareApplied = nil
            firmwareLimitActive = false
        }
        return released
    }

    private func forgetAppliedFirmwareLimit() {
        firmwareApplied = nil
        firmwareLimitActive = false
        firmwareVerifiedAt = nil
    }

    /// A recycled daemon releases the firmware limit on its way out, so what this process
    /// remembers about it is no longer true.
    private func forgetFirmwareLimit() {
        firmwareApplied = nil
        firmwareLimitActive = false
        firmwareVerifiedAt = nil
        firmwareLimitSupported = nil
        loadFirmwareLimitSupport()
    }

    // MARK: - Calibration


    /// Manually start a calibration cycle now (from the Settings button).
    func calibrateNow(batteryLevel: Int) {
        guard helperStatus == .ready else { return }
        startCalibration(batteryLevel: batteryLevel)
    }

    /// Force a force-discharge state via the adapter (CHIE), independent of sailing mode.
    @discardableResult
    private func forceDischarge(_ on: Bool) async -> Bool {
        guard let proxy = remoteProxy() else { return false }
        let ok = await xpcBool { reply in proxy.setForceDischarge(on, reply: reply) }
        if ok {
            lastAdapterEnabled = !on
            lastToggleAt = Date()
        }
        return ok
    }

    /// Serialize calibration adapter cuts and unwind delayed XPC writes after cancel/sleep.
    private func requestCalibrationDischarge() {
        guard calibrationActive, !calibrationDischargeInFlight else { return }
        let generation = calibrationGeneration
        calibrationDischargeInFlight = true
        Task {
            guard calibrationActive, calibrationGeneration == generation else { return }
            if firmwareLimitActive {
                _ = await releaseFirmwareLimit()
            }
            guard calibrationActive, calibrationGeneration == generation else { return }
            let succeeded = await forceDischarge(true)
            if calibrationGeneration != generation {
                // An older request completed after cancellation: restore AC immediately.
                await restoreCharging()
                return
            }
            calibrationDischargeInFlight = false
            if succeeded {
                calibrationXPCFailureCount = 0
            } else {
                calibrationXPCFailureCount += 1
                if calibrationXPCFailureCount >= calibrationXPCFailureLimit {
                    abortCalibration(reason: .helperUnreachable)
                }
            }
        }
    }

    /// A battery already at or below the safety floor must never be drained further, so
    /// the discharge phase is skipped and the cycle starts by charging to 100%.
    private func startCalibration(batteryLevel: Int, fullCycle: Bool = false) {
        guard helperStatus == .ready, isEnabled, !calibrationActive, !dischargeActive,
              !manualChargePaused, !topUpActive, !scheduledChargeActive,
              !clamshellAdapterCutBlocked else { return }
        let alreadyAtFloor = CalibrationRecovery.shouldRestoreImmediately(
            batteryLevel: batteryLevel, dischargeFloor: calibrationDischargeFloor
        )
        calibrationFullCycle = fullCycle
        calibrationGeneration += 1
        calibrationDischargeInFlight = false
        calibrationActive = true
        if fullCycle {
            calibrationPhase = batteryLevel >= 100 ? .discharge : .precharge
        } else {
            calibrationPhase = alreadyAtFloor ? .charge : .discharge
        }
        calibrationHoldStart = nil
        calibrationStartedAt = Date()
        calibrationXPCFailureCount = 0
        calibrationScheduleLastHandled = Date()
        UserDefaults.standard.set(calibrationScheduleLastHandled, forKey: "calibrationScheduleLastHandled")
        if calibrationPhase == .precharge || calibrationPhase == .charge {
            Task { await restoreCharging() }
        } else {
            requestCalibrationDischarge()
        }
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Battery Calibration"),
            message: String(localized: fullCycle
                            ? "CALIBRATION_FULL_CYCLE_STARTED"
                            : alreadyAtFloor
                                ? "Charging to 100% to recalibrate the battery."
                                : "Discharging, then a full charge to recalibrate the battery."),
            isWarning: false
        ))
    }

    private func endCalibration() {
        calibrationGeneration += 1
        calibrationDischargeInFlight = false
        calibrationActive = false
        calibrationFullCycle = false
        calibrationHoldStart = nil
        calibrationStartedAt = nil
        calibrationXPCFailureCount = 0
        DynamicIslandManager.shared.dismiss()
    }

    /// Cancel an in-progress calibration and resume normal charging/limiting.
    func cancelCalibration() {
        guard calibrationActive else { return }
        endCalibration()
        Task { await restoreCharging() }
    }

    /// Sleep suspends the app-side control loop, so release forced discharge before
    /// the system can sleep past the calibration floor.
    func cancelCalibrationBeforeSleep() {
        guard calibrationActive else { return }
        endCalibration()
        restoreChargingSynchronously()
    }

    private func restoreChargingSynchronously() {
        guard let proxy = remoteProxy() else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var forceDischargeCleared = false
        var chargingEnabled = false
        proxy.setForceDischarge(false) { cleared in
            forceDischargeCleared = cleared
            proxy.setAdapterEnabled(true) { enabled in
                chargingEnabled = enabled
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + 2) == .success,
              CalibrationRecovery.restoreSucceeded(
                forceDischargeCleared: forceDischargeCleared,
                chargingEnabled: chargingEnabled
              ) else { return }
        lastAdapterEnabled = true
        lastToggleAt = Date()
    }

    private enum CalibrationAbortReason { case timeout, helperUnreachable, unsafeCondition }

    /// Safety backstop: either the cycle ran far longer than any normal AC cycle should
    /// (e.g. a genuine unplug mid-cycle), or the helper stopped responding to repeated
    /// force-discharge calls — either way, stop draining/holding and restore normal
    /// charging rather than retrying silently forever.
    private func abortCalibration(reason: CalibrationAbortReason) {
        calibrationGeneration += 1
        calibrationDischargeInFlight = false
        calibrationActive = false
        calibrationFullCycle = false
        calibrationHoldStart = nil
        calibrationStartedAt = nil
        calibrationXPCFailureCount = 0
        Task { await restoreCharging() }
        let message: String
        switch reason {
        case .timeout:
            message = String(localized: "Calibration took too long and was stopped. Charging has resumed.")
        case .helperUnreachable:
            message = String(localized: "Calibration was stopped because the helper stopped responding. Charging has resumed.")
        case .unsafeCondition:
            message = String(localized: "CALIBRATION_UNSAFE_STOP")
        }
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Calibration Stopped"),
            message: message,
            isWarning: true
        ))
    }

    private func finishCalibration() {
        let wasFullCycle = calibrationFullCycle
        calibrationGeneration += 1
        calibrationDischargeInFlight = false
        calibrationActive = false
        calibrationFullCycle = false
        calibrationHoldStart = nil
        calibrationStartedAt = nil
        calibrationXPCFailureCount = 0
        if wasFullCycle { Task { await restoreCharging() } }
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Calibration Complete"),
            message: String(localized: "Battery recalibrated. Charge limit resumed."),
            isWarning: false
        ))
    }

    // MARK: - Fan control

    /// Queries fan hardware info from the helper and (re)applies the saved fan setting.
    func loadFanInfo() {
        guard let proxy = remoteProxy() else { return }
        proxy.getFanInfo { [weak self] count, minRPM, maxRPM in
            Task { @MainActor in
                guard let self else { return }
                self.fanCount = count
                self.fanMinRPM = minRPM
                self.fanMaxRPM = maxRPM
                proxy.getFanRanges { [weak self] report in
                    Task { @MainActor in self?.fanRangesDescription = report }
                }
                if self.fanTargetRPM == 0 {
                    // Safe default ~40% of max, never 0 (0 RPM would stop the fan).
                    self.fanTargetRPM = maxRPM > 0 ? max(minRPM, Int(Double(maxRPM) * 0.4)) : 2500
                }
                if self.fanControlEnabled, count > 0 { await self.applyFan() }
            }
        }
    }

    /// True when the last attempt to force a fan speed didn't take on this Mac, so the UI
    /// can say so instead of leaving a slider that does nothing.
    /// Whether holding the limit on this Mac means cutting adapter input — i.e. the battery
    /// actually discharges — rather than inhibiting charge while staying on adapter power.
    /// `nil` until the helper has answered. Detected from SMC key availability per machine,
    /// so it cannot be inferred from the chip name.
    @Published private(set) var holdCutsAdapter: Bool?

    /// User authorization for the *standing limit* to cut adapter input to enforce itself,
    /// on hardware where that's the only mechanism available. A fresh install defaults to
    /// off (never asked); an existing user upgrading with Charge Limit already configured
    /// defaults to on, so upgrading doesn't silently turn off protection they already had —
    /// see ChargeLimitAuthorization.defaultAllowActiveDischarge. The toggle sits right next
    /// to the existing disclosure that explains what it's authorizing. Manual Discharge and
    /// calibration are unaffected — they carry their own explicit start confirmation and
    /// don't read this at all.
    @Published var allowActiveDischarge: Bool {
        didSet {
            UserDefaults.standard.set(allowActiveDischarge, forKey: "allowActiveDischarge")
            // Release promptly if the standing limit was plausibly the one holding it —
            // but never touch charging state that belongs to a different, independently
            // authorized mechanism that happens to be active at the same moment.
            if !allowActiveDischarge, lastAdapterEnabled == false,
               !dischargeActive, !calibrationActive, !heatGuardPaused {
                Task { await self.restoreCharging() }
            }
        }
    }

    /// One-time disclosure for the upgrade case above: an existing user's active-discharge
    /// authorization was just turned on for them without asking, so say so once. Dismissing
    /// it persists — this never reappears once acknowledged, and never appears at all for a
    /// fresh install (which defaulted off and has nothing to disclose).
    @Published var showMigrationNotice: Bool

    func dismissMigrationNotice() {
        showMigrationNotice = false
        UserDefaults.standard.set(true, forKey: "didShowActiveDischargeMigrationNotice")
    }

    /// The running daemon's reported version. Surfaced in Settings because a machine on an
    /// outdated helper behaves in ways the current build cannot explain, and until now there
    /// was nothing in the UI that said so.
    @Published private(set) var helperVersion: String?

    /// What this build ships, for the UI to compare against `helperVersion` without needing
    /// the shared module.
    let expectedHelperVersion = kMacWakeHelperVersion

    private func loadHelperVersion() {
        guard let proxy = remoteProxy() else { return }
        proxy.getVersion { [weak self] version in
            Task { @MainActor in self?.helperVersion = version }
        }
    }

    private func loadChargeControlMethod() {
        guard let proxy = remoteProxy() else { return }
        proxy.chargeControlMethod { [weak self] method in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // "none" leaves this nil: there is no hold to describe.
                if method.hasPrefix("adapter:") { self.holdCutsAdapter = true }
                else if method.hasPrefix("inhibit:") { self.holdCutsAdapter = false }
            }
        }
    }

    @Published private(set) var fanControlUnsupported = false

    // Set right before a failed manual attempt flips fanControlEnabled back to false itself,
    // so the automatic-restore Task that didSet immediately queues can tell "the switch is
    // off because activation just failed" apart from "the user turned it off" — the former
    // must not erase the failure note the previous Task set a moment earlier.
    private var isRollingBackFanAfterFailure = false

    /// True while a manual request is waiting on the helper. Taking a fan over on M3/M4 means
    /// asking macOS to let go first, which takes several seconds — the UI says so instead of
    /// showing a switch that appears to do nothing.
    @Published private(set) var fanControlEngaging = false

    private var fanApplyInFlight = false
    private var fanApplyQueued = false

    /// Longest a manual request may take end to end: the helper waits up to 20 s for the
    /// system to release the fan, plus the target write.
    private let fanEngageTimeout: TimeInterval = 30

    private func applyFan() async {
        guard helperStatus == .ready, fanCount > 0, let proxy = remoteProxy() else { return }

        guard fanControlEnabled else {
            // Never queued behind a manual request: the helper treats this call as the
            // cancel for a takeover still waiting on the system.
            _ = await xpcBool { reply in proxy.setFanManual(false, rpm: 0, reply: reply) }
            if !isRollingBackFanAfterFailure { fanControlUnsupported = false }
            isRollingBackFanAfterFailure = false
            return
        }

        // An unknown or inconsistent hardware RPM range must never become a guessed
        // manual fan limit.
        guard fanHardwareRangeValid else {
            fanControlUnsupported = true
            isRollingBackFanAfterFailure = true
            fanControlEnabled = false
            return
        }

        // A slider drag re-applies the target on every step. One request at a time; whatever
        // arrived meanwhile is folded into a single follow-up with the latest target.
        if fanApplyInFlight { fanApplyQueued = true; return }
        fanApplyInFlight = true
        fanControlEngaging = true
        var applied = false
        repeat {
            fanApplyQueued = false
            let rpm = min(max(fanTargetRPM, fanMinRPM), fanMaxRPM == 0 ? fanTargetRPM : fanMaxRPM)
            applied = await xpcBool(timeout: fanEngageTimeout) { reply in
                proxy.setFanManual(true, rpm: rpm, reply: reply)
            }
            // Switched off while waiting: the restore call already ran, and the request that
            // just came back false was cancelled by it — not a failure to report.
            if !fanControlEnabled { break }
        } while fanApplyQueued && applied
        fanApplyInFlight = false
        fanControlEngaging = false
        guard fanControlEnabled else { return }

        // The helper confirms manual mode by reading it back, so a false here means this
        // Mac's SMC genuinely refused fan control — don't pretend it's on.
        fanControlUnsupported = !applied
        if !applied {
            isRollingBackFanAfterFailure = true
            fanControlEnabled = false
        }
    }

    func restoreFanAuto() {
        guard let proxy = remoteProxy() else { return }
        proxy.setFanManual(false, rpm: 0) { _ in }
    }

    /// Sleep suspends the app-side control loop the same way it does for charge control
    /// (see `cancelCalibrationBeforeSleep`) — a manual fan target has no thermal failsafe
    /// once evaluate()'s heartbeat stops running for the whole sleep duration. Live M5 Pro
    /// testing (#16) found manual mode surviving real system sleep/wake untouched, because
    /// the only cleanup attempted was an async Task queued from the willSleep notification —
    /// not guaranteed to run before the OS actually suspends. Blocks on a semaphore like the
    /// calibration path. The saved preference survives sleep, but the fan override
    /// is only reapplied after fresh thermal and fan information is available.
    func cancelFanControlBeforeSleep() {
        guard fanControlEnabled else { return }
        if let proxy = remoteProxy() {
            let semaphore = DispatchSemaphore(value: 0)
            proxy.setFanManual(false, rpm: 0) { _ in semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 2)
        }
        fanControlEnabled = false
        // Keep the requested mode in preferences while the hardware is back on auto.
        UserDefaults.standard.set(true, forKey: "fanControlEnabled")
        fanResumePending = true
    }

    /// Builds a copyable fan report and puts it on the pasteboard. Console logging proved
    /// useless for remote debugging — it can't tell you whether the daemon even reloaded —
    /// so this asks the running daemon directly and shows its answer, including the helper
    /// version actually serving XPC versus the one this app expects.
    func copyFanDiagnostics() async -> String {
        let header = """
        MacWake fan diagnostics
        app \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") \
        (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))
        expects helper v\(kMacWakeHelperVersion)

        """
        guard var proxy = remoteProxy() else {
            let report = header + "helperStatus=\(helperStatus)\nfanCount=\(fanCount) min=\(fanMinRPM) max=\(fanMaxRPM)\n" +
                "manualEnabled=\(fanControlEnabled) target=\(fanTargetRPM)\n\nXPC: no connection to the daemon"
            copyToPasteboard(report)
            return report
        }
        var body = processStalenessReport() + "\n"
        var daemonReport = await askDaemonForDiagnostics(proxy)
        // A stale daemon can't answer, and asking the tester to press Reload first proved
        // unreliable — so remediate here and report both attempts.
        if daemonReport.hasPrefix("XPC:") {
            body += daemonReport + "\n\nforcing reload…\n"
            body += await forceReloadHelper() + "\n\n"
            guard let fresh = remoteProxy() else {
                let report = header + "helperStatus=\(helperStatus)\nfanCount=\(fanCount) min=\(fanMinRPM) max=\(fanMaxRPM)\n" +
                    "manualEnabled=\(fanControlEnabled) target=\(fanTargetRPM)\n\n" + body + "XPC: no connection after reload"
                copyToPasteboard(report)
                return report
            }
            proxy = fresh
            daemonReport = await askDaemonForDiagnostics(proxy)
        }
        // Refresh fanCount/min/max from the daemon we actually just talked to before
        // printing them. The old code snapshotted these at the top of the function, so a
        // report captured mid-reload showed the pre-reload (often zeroed) values next to a
        // daemon dump reporting FNum=2 from the daemon that had just replaced it.
        await refreshFanInfo(proxy)
        let summary = "helperStatus=\(helperStatus)\nfanCount=\(fanCount) min=\(fanMinRPM) max=\(fanMaxRPM)\n" +
            "manualEnabled=\(fanControlEnabled) target=\(fanTargetRPM)\n\n"
        let report = header + summary + body + daemonReport
        copyToPasteboard(report)
        return report
    }

    /// Fetches current fan info from a live proxy and updates published state, so both the
    /// UI and the diagnostics report reflect the daemon actually being talked to right now.
    private func refreshFanInfo(_ proxy: MacWakeHelperProtocol) async {
        let (count, minRPM, maxRPM) = await withCheckedContinuation { (cont: CheckedContinuation<(Int, Int, Int), Never>) in
            var resumed = false
            proxy.getFanInfo { c, mn, mx in
                guard !resumed else { return }; resumed = true
                cont.resume(returning: (c, mn, mx))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard !resumed else { return }; resumed = true
                cont.resume(returning: (0, 0, 0))
            }
        }
        guard count > 0 else { return }
        fanCount = count
        fanMinRPM = minRPM
        fanMaxRPM = maxRPM
    }

    private func askDaemonForDiagnostics(_ proxy: MacWakeHelperProtocol) async -> String {
        await withCheckedContinuation { cont in
            var resumed = false
            proxy.fanDiagnostics { text in
                guard !resumed else { return }; resumed = true
                cont.resume(returning: text)
            }
            // An old daemon has no fanDiagnostics selector: the call fails via the
            // connection's error handler, so don't hang the button forever.
            // Generous: the probe runs the real fan takeover, which on M3/M4 alone can wait
            // ~20 s for macOS to release each fan before the 4 s response measurement.
            DispatchQueue.main.asyncAfter(deadline: .now() + 75) {
                guard !resumed else { return }; resumed = true
                cont.resume(returning: "XPC: no reply in 75s — the running daemon is OLD (no fanDiagnostics).")
            }
        }
    }

    /// Compares when the running daemon process started against when the on-disk helper
    /// binary was last written. A process older than the binary is proof it's stale — the
    /// question no XPC call can answer once the daemon is too old to respond.
    private func processStalenessReport() -> String {
        #if !APPSTORE
        let helperPath = Bundle.main.bundlePath + "/Contents/MacOS/MacWakeHelper"
        let mtime = (try? FileManager.default.attributesOfItem(atPath: helperPath)[.modificationDate] as? Date) ?? nil

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid,lstart,comm"]
        let pipe = Pipe()
        p.standardOutput = pipe
        var line = "(daemon process not found)"
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            if let match = out.split(separator: "\n").first(where: { $0.contains("MacWakeHelper") }) {
                line = match.trimmingCharacters(in: .whitespaces)
            }
        }
        let mtimeText = mtime.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        return "on-disk helper mtime: \(mtimeText)\nrunning daemon: \(line)"
        #else
        return ""
        #endif
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Forces the daemon to be torn down and re-registered, regardless of version, and
    /// reports each step. Order matters: our live XPC connection keeps the old process
    /// alive, so it must be invalidated BEFORE unregistering, and launchd needs a moment
    /// to actually reap the job before a re-register loads the new binary. The previous
    /// version unregistered first and swallowed every error with `try?`, which is why a
    /// tester's daemon silently stayed on the original binary.
    @discardableResult
    /// Replace a stale daemon by recycling the process, not the registration.
    ///
    /// The obvious sequence — unregister, then register — cannot work: macOS refuses
    /// `register()` immediately after `unregister()` in the same session with "Operation not
    /// permitted", so the old code tore the daemon down and left the Mac with none at all.
    /// The job is already registered and points into the app bundle, so asking the running
    /// process to exit is enough; launchd starts the current binary on the next connection.
    ///
    /// `register()` is attempted only when the job genuinely isn't registered — the one case
    /// where it is both necessary and permitted.
    func forceReloadHelper() async -> String {
        var log = "status: \(service.status.rawValue)\n"

        guard service.status == .enabled else {
            do { try service.register(); log += "register ok\n" }
            catch { log += "register FAILED: \(error.localizedDescription)\n" }
            log += "final status: \(service.status.rawValue)"
            helperVersion = nil
            refreshStatus()
            return log
        }

        let exited = await xpcBool(timeout: 5) { [weak self] reply in
            guard let proxy = self?.remoteProxy() else { return reply(false) }
            proxy.exitForUpdate(reply: reply)
        }
        log += exited ? "daemon asked to exit\n" : "daemon did not answer the exit request\n"
        connection?.invalidate()
        connection = nil

        // launchd starts the replacement on demand, so reconnect and read the version back
        // instead of assuming the swap happened.
        var reported = ""
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            reported = await xpcString(timeout: 2) { [weak self] reply in
                guard let proxy = self?.remoteProxy() else { return reply("") }
                proxy.getVersion(reply: reply)
            }
            if reported == kMacWakeHelperVersion { break }
            connection?.invalidate()
            connection = nil
        }
        log += "daemon now reports \(reported.isEmpty ? "nothing" : reported)"
        log += reported == kMacWakeHelperVersion ? " — up to date\n" : " — still not current\n"

        // A daemon that never answers even getVersion across 15 fresh-connection retries
        // isn't outdated — it isn't actually running (crashed, or held down by launchd's
        // crash-loop backoff) despite SMAppService still reporting it `.enabled`. Asking a
        // dead process to gracefully exit was the only recovery this had, so it did nothing
        // and left the daemon unreachable indefinitely — reported live, with "Reload Helper"
        // producing the same unreachable report every time. unregister()+register() forces
        // launchd to tear down the stale job registration and spawn a genuinely new process,
        // the same recovery uninstall() already relies on elsewhere in this file.
        if reported.isEmpty {
            log += await recycleUnauthenticatedDaemon()
            reported = helperVersion ?? ""
        }
        if reported.isEmpty {
            log += "daemon unreachable — attempting hard reset (unregister + register)\n"
            do {
                try await service.unregister()
                try service.register()
                log += "hard reset ok\n"
            } catch {
                log += "hard reset FAILED: \(error.localizedDescription)\n"
            }
            connection?.invalidate()
            connection = nil
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                reported = await xpcString(timeout: 2) { [weak self] reply in
                    guard let proxy = self?.remoteProxy() else { return reply("") }
                    proxy.getVersion(reply: reply)
                }
                if !reported.isEmpty { break }
                connection?.invalidate()
                connection = nil
            }
            log += "after hard reset, daemon reports \(reported.isEmpty ? "nothing" : reported)"
            log += reported == kMacWakeHelperVersion ? " — up to date\n"
                : (reported.isEmpty ? " — still unreachable\n" : " — still not current\n")
        }

        log += "final status: \(service.status.rawValue)"
        helperVersion = nil
        refreshStatus()
        forgetFirmwareLimit()
        fanCount = 0
        loadFanInfo()
        return log
    }

    /// String-reply counterpart of `xpcBool`, with the same never-hang guarantee: a stale
    /// daemon missing a newly added method would otherwise leave the caller waiting forever.
    private func xpcString(timeout: TimeInterval = 3,
                           _ call: @escaping (@escaping (String) -> Void) -> Void) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let lock = NSLock()
            var done = false
            func finish(_ value: String) {
                lock.lock(); defer { lock.unlock() }
                if done { return }; done = true
                cont.resume(returning: value)
            }
            call { finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish("") }
        }
    }

    /// Failsafe: called with the hottest sensor reading. If fan control is forcing a
    /// manual speed while the Mac runs hot, revert to automatic so it can cool.
    // MARK: - Energy Mode

    /// Reads the current macOS Energy Mode from `pmset -g custom` (no root needed).
    /// Energy Mode is a helper-backed feature; the App Store build has no helper and can't
    /// spawn subprocesses in the sandbox, so this whole path (Process/pmset) is compiled out.
    func readEnergyMode() {
        #if !APPSTORE
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "custom"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            // Use the AC ("AC Power") block if present, else whatever is reported.
            let low = lastValue(of: "lowpowermode", in: out)
            let high = lastValue(of: "highpowermode", in: out)
            highPowerSupported = out.contains("highpowermode")
            if high == 1 { energyMode = 2 }
            else if low == 1 { energyMode = 1 }
            else { energyMode = 0 }
        } catch {
            // pmset unavailable — leave defaults.
        }
        #endif
    }

    #if !APPSTORE
    private func lastValue(of key: String, in text: String) -> Int {
        var result = 0
        for line in text.split(separator: "\n") where line.contains(key) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let v = parts.last, let n = Int(v) { result = n }
        }
        return result
    }
    #endif

    /// Applies an Energy Mode via the helper (needs root). 0=Auto, 1=Low, 2=High.
    func setEnergyMode(_ mode: Int) {
        guard helperStatus == .ready, let proxy = remoteProxy() else { return }
        let target = (mode == 2 && !highPowerSupported) ? 0 : mode
        energyMode = target
        proxy.setEnergyMode(target) { [weak self] _ in
            Task { @MainActor in self?.readEnergyMode() }
        }
    }

    /// A closed lid without an active external display is not necessarily system sleep
    /// (e.g. a sleep-prevention utility). Never leave a forced RPM running in that state.
    func refreshFanForDisplayState() {
        let unattended = LidAndDisplay.lidIsClosed() && !LidAndDisplay.externalDisplayAttached()
        if unattended && fanControlEnabled {
            cancelFanControlBeforeSleep()
        }
    }

    func fanTemperatureCheck(maxTempC: Double) {
        refreshFanForDisplayState()
        let unattended = LidAndDisplay.lidIsClosed() && !LidAndDisplay.externalDisplayAttached()
        guard !unattended else { return }
        if fanResumePending, helperStatus == .ready, fanCount > 0, maxTempC > 0 {
            fanResumePending = false
            if maxTempC < fanFailsafeTempC {
                fanControlEnabled = true
            } else {
                UserDefaults.standard.set(false, forKey: "fanControlEnabled")
            }
        }
        guard fanControlEnabled, fanCount > 0, maxTempC >= fanFailsafeTempC else { return }
        fanControlEnabled = false   // didSet restores auto
        DynamicIslandManager.shared.trigger(.alert(
            title: String(localized: "Fan Control Paused"),
            message: String(localized: "High temperature — fans returned to automatic."),
            isWarning: true
        ))
    }
}

/// Whether MacWake is actively enforcing its own standing charge limit right now, or has
/// yielded runtime enforcement to a confirmed external hold (typically macOS's native
/// Charge Limit) while keeping the user's MacWake configuration untouched.
///
/// Yielding is prompt: a single confirmed external hold is enough, because letting MacWake's
/// own CHIE enforcement keep re-asserting while something else already holds the battery is
/// exactly the two-controllers-fighting outcome this exists to prevent — both mechanisms are
/// known to use the same SMC key on hardware with no separate inhibit key. Resuming is
/// deliberately slower: the user's MacWake authorization was never revoked, so control should
/// only come back once the external hold has reliably ended, not on the first ambiguous or
/// missing sample the detector's own conservative verdicts can produce even while a real hold
/// is still in effect.
enum ChargeControlOwnership: Equatable {
    case enforcing
    /// `toPercent` is always the *last confirmed* hold — it never resets to some other value
    /// during the grace period below, which is what a UI reading the live detector's verdict
    /// instead of this one got wrong: the moment a single tick came back ambiguous, the raw
    /// signal fell back to "100, nothing detected" and got shown as "macOS is holding at
    /// 100%" while still genuinely yielded and waiting to confirm the real hold had cleared.
    /// `confirmingResume` distinguishes "actively confirmed this tick" from "grace period,
    /// counting clear samples toward resuming" so the UI can word those two states honestly
    /// instead of presenting the grace period as if it were still a live, current reading.
    case yielded(toPercent: Int, confirmingResume: Bool)

    /// - Parameters:
    ///   - externalHoldPercent: this tick's detector verdict; `nil` means nothing confirmed.
    ///   - consecutiveClearSamples: how many ticks in a row have read `nil` while yielded.
    static func next(current: ChargeControlOwnership, externalHoldPercent: Int?,
                     consecutiveClearSamples: Int, resumeAfterClearSamples: Int = 3) -> ChargeControlOwnership {
        if let percent = externalHoldPercent {
            return .yielded(toPercent: percent, confirmingResume: false)
        }
        guard case .yielded(let lastConfirmed, _) = current else { return .enforcing }
        if consecutiveClearSamples >= resumeAfterClearSamples { return .enforcing }
        return .yielded(toPercent: lastConfirmed, confirmingResume: true)
    }

    /// Whether the standing limit may cut the adapter *yet* on adapter-cut-only hardware, or
    /// should still hold off a little longer to give native-hold detection its own chance
    /// first. `ExternalChargeHold.detect` needs several consecutive samples (3 × the 30s
    /// heartbeat ≈ 90s) before it will ever confirm a hold — and once MacWake's own cut is
    /// live, every sample gathered while holding is excluded from that detection (it would
    /// otherwise "detect" its own hold as external). So enforcing immediately on the very
    /// first tick the level crosses the ceiling wins the race by construction: a native macOS
    /// Charge Limit configured at the same threshold never gets the ~90s it needs to prove
    /// itself, and MacWake drains the battery to its own lower bound before the detector could
    /// have ever said otherwise. `graceInterval` is set comfortably above that window so the
    /// detector's verdict — checked earlier in `evaluate()`, every tick — has room to land
    /// first; this only delays the *first* cut of a cycle, never an already-enforcing hold.
    static func mayEnforceLimitNow(sinceLimitFirstReached: TimeInterval, graceInterval: TimeInterval = 100) -> Bool {
        sinceLimitFirstReached >= graceInterval
    }
}

/// Whether the standing charge limit may actually cut adapter input to enforce itself.
///
/// Enforcing a ceiling on hardware with no clean charge-inhibit key means running the
/// battery down on AC — a real, sometimes surprising, consequence "limit charging" alone
/// doesn't convey. This gates only the standing limit's own enforcement, not Manual
/// Discharge or calibration, which already carry their own explicit start confirmation and
/// represent the user acting right now rather than a background policy acting on their
/// behalf indefinitely.
enum ChargeLimitAuthorization {
    /// A confirmed clean charge-inhibit key never discharges to hold, so there is nothing to
    /// authorize — the switch this drives is not even shown on that hardware. Unconfirmed
    /// (`nil`, e.g. detection hasn't completed yet) is treated the same as adapter-cut: the
    /// safer assumption until proven otherwise, matching how this codebase already treats
    /// ambiguity elsewhere (fail toward not enforcing, never toward silently discharging).
    static func standingLimitMayEnforce(holdCutsAdapter: Bool?, allowActiveDischarge: Bool) -> Bool {
        if holdCutsAdapter == false { return true }
        return allowActiveDischarge
    }

    /// The default for a missing `allowActiveDischarge` key can't be a single constant: a
    /// fresh install has never earned the right to discharge the battery unasked, but an
    /// existing user who already had Charge Limit configured before this switch existed
    /// would otherwise have their protection silently switched off on upgrade. `chargeLimitEnabled`
    /// predates the authorization split, so its presence in defaults distinguishes the two.
    static func defaultAllowActiveDischarge(hasPriorChargeLimitConfig: Bool) -> Bool {
        hasPriorChargeLimitConfig
    }
}
