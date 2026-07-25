---
title: A SwiftUI scene .task is not a launch hook — for an LSUIElement app it never fires
date: 2026-07-25
category: architecture-patterns
module: NoTypeApp
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - Wiring work that must run once per app launch in a SwiftUI lifecycle app
  - The app is LSUIElement / menu-bar-only, or any scene uses defaultLaunchBehavior(.automatic)
  - Reviewing a justification of the form "a .task on the view will cover it"
  - A background service (updater, scheduler, telemetry) appears never to run for some users
tags: [swiftui, lsuielement, launch, scene, app-delegate, sparkle, silent-failure]
related_components: [NoTypeApp, Updates, UI]
---

# A SwiftUI scene `.task` is not a launch hook — for an LSUIElement app it never fires

## Context

NoType is `LSUIElement = true` (no Dock icon, no main menu) and its main window scene carries:

```swift
.defaultLaunchBehavior(OnboardingState.hasCompletedOnboarding ? .automatic : .presented)
```

For a **returning** user — onboarding complete, therefore `.automatic` — that window is simply not presented at launch. The user's whole session may be menu-bar-only. `.task` on a view inside an unpresented scene never evaluates: SwiftUI only runs it when the view appears.

Two pieces of launch work had been hanging off exactly that modifier on `MainWindowView`, and both were therefore dead for every returning user:

- **`updates.start()`** — Sparkle's scheduler never started. Menu-bar-only users got **no update checks at all**, ever, until they happened to open the main window. The 24 h `SUScheduledCheckInterval` (`NoType/Info.plist:58`) was moot, and `NoType/Updates/CLAUDE.md` invariant 4 documented the `.task` as the *correct* home.
- **`terminationHandler`** — never assigned, so `applicationWillTerminate(_:)` had nothing to call. Quitting from the popover after a `MusicInterruption` could leave the user's system **muted**.

Neither produced an error, a log line, or a visible symptom. Both were found incidentally while moving unrelated work off `NoTypeApp.init()` for the [executor-identity crash family](../runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md).

This is the repo's **second** instance of the same misconception. PR #7 removed `Scene.defaultLaunchBehavior(_:)` justifying it with "fallback exists in `MenuBarIcon`'s `.task`" — and no such `.task` existed at all; see [`macos-15-deployment-target-2026-05-15.md`](../tooling-decisions/macos-15-deployment-target-2026-05-15.md). The 2026-07-25 plan then cited a `.task` as precedent for where launch work belongs. A view-layer hook reads like a launch hook to almost everyone who looks at it.

## Guidance

**Launch work hangs off `NSApplicationDelegate` callbacks, never off a scene or view modifier.** In a SwiftUI-lifecycle app that means an `@NSApplicationDelegateAdaptor` whose closures are assigned in `App.init()` and invoked from AppKit:

```swift
// NoTypeApp.init() — assigning a closure schedules nothing and touches no NSApp,
// so it is legal here, and guarantees the handler is installed before AppKit calls back.
appDelegate.willFinishLaunchingHandler = { appearance.apply() }   // before the first View.body
appDelegate.launchHandler = {                                     // applicationDidFinishLaunching
    appearance.apply()      // idempotent re-apply
    state.prime()
    updates.start()         // last: background work, no launch-time surface
}
appDelegate.terminationHandler = { state.releaseMusicInterruption() }
```

Three rules fall out:

1. **Assignment in `init` is fine; work in `init` is not.** Assigning a closure schedules nothing and touches no `NSApp`, so it satisfies the no-work-before-`NSApplicationMain` rule (`NoType/UI/CLAUDE.md` "Launch ordering") — and doing it in `init` is what guarantees the handler exists before AppKit fires the callback. That is why `terminationHandler` is assigned directly rather than from inside `launchHandler`: it needs no hook, and wiring it from a closure the delegate itself owns would only add a retain cycle.
2. **Pick the hook by what the work must precede.** `applicationWillFinishLaunching(_:)` is the last hook before SwiftUI evaluates the first `View.body` — that is where the appearance write goes, preserving "the very first frame already has the correct appearance". Everything else goes on `applicationDidFinishLaunching(_:)`.
3. **Removing a `.task` removes its retry.** A window re-presentation used to re-fire `.task`, which was the only recovery from a failed `start()`. `UpdateController.checkForUpdates()` now calls `start()` first so Settings → "Check for updates" can recover a launch-time failure, instead of running against an unstarted `SPUUpdater` for the process lifetime.

**A scene `.task` is still correct for genuinely window-scoped work** — anything that only matters while the window is up. The discriminator is whether the work must happen for a user who never opens the window.

**Pin it mechanically**, because the failure is invisible at runtime. `LaunchOrderingTests.test_sparkleAndTerminationHandler_areWiredFromInit_notAWindowTask` (`NoTypeTests/LaunchOrderingTests.swift:142`) asserts both wirings are present in `NoTypeApp.init()` *and* that `NoTypeApp.swift` contains no `.task` at all. Note it is a **presence** assertion — an absence-only guard would have stayed green through this entire bug; see [`source-scan-guard-fidelity`](../conventions/source-scan-guard-fidelity-2026-07-25.md).

## Why This Matters

The failure mode is silent, permanent, and inverted with respect to who it hits.

- **Silent.** No exception, no log, no degraded UI. The code is present, correct, and reviewed; it simply never runs. Nothing in a crash report, a test run, or a manual smoke test performed by a developer — who opens the main window constantly — will surface it.
- **Permanent for the process.** Not a race that occasionally loses. For a returning user with the window closed, it is never.
- **It targets the intended usage.** NoType is designed to be used from the menu bar. The users who use it exactly as intended are precisely the ones who never fire the hook. A developer, who opens the window every session, is the least likely person to notice.

For Sparkle that meant the auto-update channel — the whole delivery mechanism for every fix this project ships, including the crash mitigations — was inert for the app's core audience. NoType ships no telemetry (ADR-013), so there was no signal that update checks were not happening.

## When to Apply

- **Any LSUIElement / menu-bar app**, always. There is no launch guarantee for any scene.
- **Any app using `defaultLaunchBehavior(.automatic)`** on the scene the work hangs off, even with a Dock icon — `.automatic` means "AppKit decides", which frequently means "not presented".
- **Any work whose correctness is per-launch rather than per-window**: schedulers, updaters, permission reads, hotkey/event-tap installation, termination handlers, migrations.
- **When reviewing a justification of the form "the `.task` will cover it."** Twice in this repo that claim was made about a `.task` that either did not exist or could not run. Verify the modifier exists and that the view it is attached to is presented at launch.
- **Does not apply** to work that is genuinely window-scoped — a data refresh for content the window displays, an animation driver, a focus effect. `.task` is the right tool there.

## Examples

**Before — dead for every returning user:**

```swift
// MainWindowView, inside the Window scene
MainWindowView()
    .task { updates.start() }          // Sparkle: never ran, no update checks ever
    .task { wireTerminationHandler() } // mute-restore: never assigned
```

`wireTerminationHandler()` had a second defect the move exposed: it read `self.appState` / `self.appDelegate`, i.e. `@State` outside a view update, which is only valid from `body`. The inlined form in `init` captures the same `AppState` instance from the local `let state`.

**After — on the launch path** (`NoType/NoTypeApp.swift:169`, `:190`): as in *Guidance* above. Both `.task` modifiers were **removed, not kept as fallbacks** — they are provably dead for the launch case, and a dead fallback is a future maintainer's evidence that the hook is optional.

**Idempotence still matters at the new home.** `UpdateController.start()` keeps its `didStart` latch even though the launch hook fires once, because `checkForUpdates()` now calls it too. `terminationHandler` is a stored-property assignment, so it was idempotent by overwrite already.

**The diagnostic breadcrumb.** Because "the hook never fired" is indistinguishable from "the user never granted anything", `AppState.prime()` logs one `.info` line on entry (`NoType/AppState.swift:376`). In the field:

```bash
/usr/bin/log stream --predicate 'subsystem == "app.notype"' --info
# expect: "launch: priming AppState"
```

Its absence means the launch path did not run — a completely different investigation from a permissions problem, and otherwise unobservable.

## Related

- [`conventions/source-scan-guard-fidelity-2026-07-25.md`](../conventions/source-scan-guard-fidelity-2026-07-25.md) — why the guard for this had to assert *presence*; the absence-only shape would not have caught it.
- [`design-patterns/observation-loop-swallows-initial-state-2026-07-25.md`](../design-patterns/observation-loop-swallows-initial-state-2026-07-25.md) — the other launch-ordering hazard from the same arc.
- [`runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`](../runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md) — the crash whose remediation established the launch path these two moved onto.
- [`tooling-decisions/macos-15-deployment-target-2026-05-15.md`](../tooling-decisions/macos-15-deployment-target-2026-05-15.md) — `Scene.defaultLaunchBehavior(_:)` is the reason the window is unpresented; also records the first instance of the "a `.task` will cover it" claim (PR #7).
- [`tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md`](../tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md) — the update path that was inert.
- [`runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md`](../runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md) — sibling launch-path failure that shipped (v0.1.11 could not launch at all, with no crash report). Launch-path defects are the ones that pass every verification tool and that users never report.
- `NoType/UI/CLAUDE.md` "Launch ordering" — the current rule and hook assignment.
- `NoType/Updates/CLAUDE.md` invariants 4–5 — previously documented the `.task` as correct; now records the opposite.
