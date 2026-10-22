# Findings

- Repo: `/Users/ducnghia/Downloads/MacWake-fix`, branch `main`, last checked HEAD `995780d`; working tree has untracked build bundle, do not stage it.
- Current manager already supports `startDischarge`, `stopDischarge`, Sailing, scheduled top-up, calibration 15% → 100% → hold 1h, and `stopChargingNow`.
- HDMI experimental IOPM assertion removed; clamshell guard must remain active.
- Distinguish AlDente's Sailing/Automatic Discharge (routine) from deep calibration (occasional).
- Safety: no deep cycling daily and never defeat macOS lid sleep protection.

- `evaluate()` handles manual hold, firmware arbitration, discharge, calibration, heat guard, schedule then standing limit; new automation must start before manual discharge branch and defer to higher-priority states.
- Existing `startDischarge` and `finishDischarge` own forceDischarge and restoration. Existing discharge does not have explicit sleep cancellation; implement it.
- `manualPauseClamshellUnsafe` guards adapter cuts under lid-closed external display; reuse this rule before automatic discharge.
- Keep deep calibration manual for now: current deep cycle is 15%→100%→hold 1 h and has an 8h timeout; extending to unattended schedule needs additional policy/telemetry.

- Implementation: SmartChargeCycleRules pure checks (5-point activation margin, valid/fresh battery temperature below 40°C, no clamshell/external monitor). Opt-in Automatic Discharge uses existing discharge manager, 6-hour watchdog, XPC generation guard, explicit Sleep cancellation.
- Calibration schedule: mode off/remind/auto every 30 days; default reminder. Automatic only after opt-in and safe conditions, phases precharge 100% → discharge 15% → recharge 100% → hold one hour → return to current charge limit. 18-hour overall timeout; no resume following Sleep or relaunch.
- Existing Sailing Mode and charge-limit user thresholds intentionally preserved; no blanket resetting to 80%/75%.
- Temperature freshness via BatteryTracker.lastBatteryTemperatureSampleAt. Calibration and discharge canceled on hot readings / unsafe clamshell. Native IOPS reports battery when app cuts adapter, so independent physical-cable detection is limited.

- Live install: MacWakeLocal PID 75377 and helper v15 running. CLI reports 80%, battery/discharging, which can result from standing charge-limit adapter cut, not proof that automatic discharge is enabled.
- Backup ~/Downloads/MacWakeLocal-before-smart-cycle-20261022.app; official MacWake unchanged. automaticDischargeEnabled defaults false; calibrationScheduleMode defaults to monthly reminder. No source commit/push.
- Remaining validation: no real deep charge/discharge run, Sleep/unplug fault injection, or screenshot QA. IOPS may report battery when the application itself cuts adapter; physical unplug cannot always be independently distinguished. Sleep/quit restoration remains best effort.
