# Smart Charge Cycle — MacWakeLocal

## Goal
Implement an opt-in, safe charge/discharge workflow inspired by AlDente. Preserve existing charge limit, sailing, on-demand discharge, top-up, calibration, thermal protections, lid/external display guard, and Vietnamese localization.

## Phases
- [complete] 1. Analyze existing state machine, conflict policies, and recovery boundaries.
- [complete] 2. Implement smart automatic discharge to limit with explicit settings and safety checks, including no unsafe operation under clamshell.
- [complete] 3. Expose localized controls, clear status, and manual cancellation.
- [complete] 4. Test/build, review diff, verify packaging. No commit/push without user asking.

## Decisions
- Default automatic discharge OFF. Keep Sailing 75–80 as suggested defaults but never reset user settings.
- Monthly calibration defaults to a reminder; automatic 30-day full cycles require explicit user opt-in and only start with safe live sensor data, AC power, no clamshell/external display, and no conflicting mode. Sleep cancels the cycle. No automatic no-sleep workaround.
- On sleep, unplug, quit, helper failure: restore adapter and stop active forced discharge.
- Prioritize hardware charge inhibit where possible; never mistake active discharging for charging inhibit.
- Reuse existing charging manager rather than introducing a conflicting power controller.

## Blockers
- No end-to-end hardware cycle has been exercised: XPC timing and physical battery behavior require supervised real-device observation. A true unplug may be indistinguishable from an app-induced adapter cut using IOPS alone.

## Next Step
Implementation and packaging complete. Optional next step: supervised hardware-cycle validation and, only if requested, a scoped English Git commit. Automatic discharge is OFF and deep monthly calibration remains opt-in.