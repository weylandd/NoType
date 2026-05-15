---
title: macOS 15 (Sequoia) deployment target
date: 2026-05-15
category: tooling-decisions
module: NoTypeApp
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - Considering whether to drop the macOS deployment target below 15
  - Auditing 15+ APIs in use for "can we replace this?"
  - Adopting a new SwiftUI Scene API that requires macOS 15+
tags: [deployment-target, swiftui, macos-15, scene-api, onboarding, lsuielement]
---

# macOS 15 (Sequoia) deployment target

## Context

NoType is an `LSUIElement = true` menu-bar utility. On a fresh install with no API key on file, the main window must auto-present so the onboarding wizard can run — but the `MenuBarExtra` is suppressed during onboarding by design (`NoTypeApp.body` gates `MenuBarExtra(isInserted:)` on `OnboardingState.isComplete`). Without an OS-level mechanism to present the `Window` scene at launch, a fresh install lands at "process alive, no UI anywhere" — empirically observed and shipped in v0.1.4 (see "Examples" below).

## Guidance

**Keep the deployment target at macOS 15 (Sequoia).** The load-bearing API is `Scene.defaultLaunchBehavior(_:)` (macOS 15+), used in `NoTypeApp.swift` on the main `Window` scene to set `.presented` while onboarding is pending and `.automatic` once it completes.

Other 14+ APIs in active use are valuable but **are not deployment-target drivers** on their own:

- `@Observable` + `@Environment(Type.self)` + `@Bindable` (Observation framework, 14.0+)
- `ScreenCaptureKit` (14.0+; used for the OCR fallback path)

When adopting a new API above 15, **`@available`-gate it** rather than raising the floor. The cost of dropping users on older macOS is higher than a small fork in code.

## Why This Matters

Before macOS 15 there is no one-modifier way to present a SwiftUI `Window` scene at launch on an LSUIElement app. The alternatives are:

- **AppKit interop** — `NSHostingController` + a raw `NSWindow`. ~hundreds of lines, owns its own lifecycle, fights SwiftUI's scene graph.
- **`WindowGroup`-on-launch hack** — works in some configurations but breaks the menu-bar-utility model: window auto-opens on every launch, state restoration may open multiples, and the user loses the "quit window, app stays in tray" affordance.

`Scene.defaultLaunchBehavior(_:)` is the one API specifically designed to solve this case. Losing access to it forces one of the two refactors above or a regressed first-launch UX. The 15+ floor is the smallest restriction that lets us keep the modifier.

## When to Apply

- Any PR that touches `MACOSX_DEPLOYMENT_TARGET` in `project.yml`.
- Any audit that asks "could we lower the floor for a wider audience?" — the answer is no until either Apple back-ports `Scene.defaultLaunchBehavior(_:)` or we accept rewriting first-launch presentation in AppKit.
- Any PR that introduces an API above 15 — `@available`-gate it rather than bumping the floor.

## Examples

**The decision in code:**

```swift
// NoTypeApp.swift
@main
struct NoTypeApp: App {
    @State private var onboarding = OnboardingState.shared

    var body: some Scene {
        Window("NoType", id: "main") {
            MainWindowView()
        }
        .defaultLaunchBehavior(onboarding.isComplete ? .automatic : .presented)

        MenuBarExtra(isInserted: $onboarding.isComplete) {
            // ...
        }
    }
}
```

**The failure mode the floor prevents** (PR #7 / v0.1.4 regression):

PR #7 dropped the floor from macOS 26 to 14 with an API audit that claimed nothing above 14 was needed. The audit missed `Scene.defaultLaunchBehavior(_:)` — it was removed in the same PR with a "fallback exists in `MenuBarIcon`'s `.task`" justification, but no such `.task` existed in the codebase, and the `MenuBarExtra` is suppressed during onboarding anyway so a view-layer hook couldn't help.

Net result on a fresh install across **every** supported macOS:

- Process alive.
- No menu-bar icon (`MenuBarExtra` gated by `onboarding.isComplete == false`).
- No main window (`SwiftUI.Window` creates its `NSWindow` lazily — never triggered).
- User has no way to start onboarding.

v0.1.4 shipped with this regression. v0.1.5 bumped the floor to 15 and restored the modifier, fixing it cleanly.

## Related

- `docs/decisions.md` ADR-001 — the legacy index entry, now a redirect to this file.
- `NoType/UI/CLAUDE.md` "Onboarding wizard" — describes the auto-open hook on the consumer side.
- `NoType/Onboarding/` — wizard implementation that depends on the present-on-first-launch contract.
- PR #14 in NoType — "docs: sweep stale macOS 26 references after the floor drop to 14" (the cleanup PR following the regression).
- PR #17 in NoType — "fix(onboarding): bump floor to macOS 15, restore defaultLaunchBehavior" (the fix).
