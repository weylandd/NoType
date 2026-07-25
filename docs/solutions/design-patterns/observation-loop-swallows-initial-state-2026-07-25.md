---
title: A snapshot-then-diff observer swallows the initial state — moving an eager read is a behaviour change
date: 2026-07-25
category: design-patterns
module: Permissions
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - Changing when an @Observable value is first populated (moving a read out of or into an initializer)
  - Writing or reviewing a withObservationTracking loop that diffs against an entry snapshot
  - Replacing a Combine publisher chain with an observation loop
  - A side effect driven by an observer fires on later changes but not for the state present at startup
tags: [observation, observable, swift, initialization, launch-ordering, permissions, near-miss]
related_components: [Permissions, Hotkey, NoTypeApp]
---

# A snapshot-then-diff observer swallows the initial state — moving an eager read is a behaviour change

## Context

NoType drives its accessibility-permission side effects from a long-lived observation loop rather than Combine (`NoType/Permissions/CLAUDE.md` invariant 5). `AppState.observePermissions()` (`NoType/AppState.swift:522`) has the standard shape:

```swift
var lastAx = permissions.accessibility          // entry snapshot
while !Task.isCancelled {
    await withCheckedContinuation { cont in
        withObservationTracking { _ = self.permissions.accessibility }
            onChange: { cont.resume() }
    }
    let ax = permissions.accessibility
    if ax != lastAx { applyAccessibilityState() }   // install / uninstall the hotkey tap
    lastAx = ax
}
```

Snapshot on entry, react to *subsequent* mutations only — deliberately mirroring Combine's `removeDuplicates`. This is correct and desirable as long as somebody else has already acted on the value that was true when the loop started.

The [launch-ordering rework](../architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md) removed that somebody. `PermissionsViewModel.init` used to call `refresh()`, so by the time `AppState.init` ran `applyAccessibilityState()`, the statuses were real and the hotkey tap installed. Moving that read out of `init` (required by the no-work-before-`NSApplicationMain` rule) left `applyAccessibilityState()` reading `.unknown` — which takes the *uninstall* branch — and the observation loop, snapshotting `.unknown` and then never seeing it change for an already-granted user, would never install it.

**Following the plan literally would have shipped a build where a returning user with Accessibility already granted has no hotkey at all** — the app's entire input mechanism, dead. The plan explicitly reasoned the other way: *"The hotkey still installs — `applyAccessibilityState()` stays in `init` per step 3."* That is the trap in one line. The **call** stayed put; its **input** moved. Auditing a refactor by asking "is this call still there?" cannot see that, because what changed is what the call reads. This was caught during implementation, not by the plan and not by any test.

## Guidance

**Treat "when is this value first populated?" as part of an observer's contract, not as an implementation detail of whoever populates it.** A snapshot-then-diff observer is *only* half of a state-application mechanism. The other half is an explicit application of the initial value, and it must be an ordered, synchronous call — not something inferred from the observer.

The shipped shape makes both halves explicit and orders them, in the object that owns the dependency rather than in the launch hook:

```swift
// AppState.prime() — NoType/AppState.swift:391
permissions.prime()        // 1. live TCC read; until this runs every status is .unknown
applyAccessibilityState()  // 2. apply those now-real values, synchronously
```

Three rules:

1. **Apply the initial state explicitly, adjacent to the read that produces it.** Not from the observer, and not "it'll converge on the next change" — for a value that is already at its final state, there is no next change.
2. **Order the two calls where the dependency lives.** `AppState.prime()` drives both rather than the launch hook making two calls that a later edit could reorder or split. The comment at the call site says what breaks if they swap.
3. **When a default value is a meaningful branch, say so.** `.unknown` is not neutral here — `applyAccessibilityState()` treats anything not `.granted` as "revoked" and tears the tap down. A sentinel that silently means "do the destructive thing" is what turns a missing read into an inverted decision rather than a no-op.

**The general form: changing *when* initial state is populated is a behaviour change, not a refactor.** Moving a read later, making it lazy, deferring it to a launch hook, or replacing an eager `init` call with a `prime()` — each one can invert the first decision of every downstream snapshot-then-diff consumer. Before moving such a read, grep for the observers of that value and ask what each one does with the pre-read default.

## Why This Matters

The failure is silent in both directions and survives the obvious tests.

- **No error.** The observer runs, the loop is healthy, `withObservationTracking` is correctly wired. It is waiting for a change that will never come because the value it wants was already correct before it looked.
- **Correct for the user who changes the permission.** Grant it *while the app is running* and everything works — the loop sees the transition and installs the tap. The break is exclusive to the state being **already correct at launch**, i.e. every returning user. That is the same inversion as the [scene `.task`](../architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md) bug from the same arc: the steady-state user is the one who is broken, and the developer exercising the grant flow is not.
- **The source scan could not see it.** `LaunchOrderingTests` mechanically pins that no launch-path initializer schedules `MainActor` work. Deleting `refresh()` from `PermissionsViewModel.init` makes that test *greener*. The guard rewards the move that breaks the behaviour — see [`source-scan-guard-fidelity`](../conventions/source-scan-guard-fidelity-2026-07-25.md).
- **A written plan asserted the wrong outcome.** The reasoning "the observer will pick it up" is plausible enough to survive planning and review; it takes reading `observePermissions()` line by line to see the entry snapshot swallow it.

## When to Apply

- **Any refactor that moves a read out of an initializer** — lazy init, deferred launch work, DI restructuring, test-seam extraction.
- **Writing a new `withObservationTracking` loop.** Decide explicitly who applies the value that is true at loop start. If the answer is "nobody", the loop is incomplete.
- **Migrating Combine → observation.** `removeDuplicates()` chains have the same swallow, and `.prepend(currentValue)` / `CurrentValueSubject` may have been quietly doing the initial-application job.
- **Reviewing a claim that an observer will "pick up" existing state.** It will not. Observers pick up *changes*.
- **Does not apply** to observers that genuinely only care about transitions (analytics on change, animating a delta) — but be sure that is the requirement, not an accident.

## Examples

**The inversion, concretely.** Returning user, Accessibility already granted, `PermissionsViewModel.init` no longer reads:

| Step | `permissions.accessibility` | Effect |
|---|---|---|
| `AppState.init` | `.unknown` | `applyAccessibilityState()` (if called here) takes the **uninstall** branch |
| `observePermissions()` entry snapshot | `.unknown` | `lastAx = .unknown` |
| `permissions.prime()` → live TCC read | `.granted` | loop *would* wake here — but only if it started before the read |
| Steady state | `.granted` | no further mutation, ever → no hotkey tap |

The whole outcome turns on whether the eager application happens after the read. Hence `prime()` calling `permissions.prime()` and then `applyAccessibilityState()` synchronously, in that order.

**The doc-comment that keeps it from being "simplified" back.** `applyAccessibilityState()` (`NoType/AppState.swift:483`) now states the constraint rather than describing the call graph — the previous comment said it was "called once at init", which was no longer true and would have licensed removing the `prime()` call as redundant:

> Called once from `prime()` — immediately after `permissions.prime()`, whose live TCC read it depends on — and once after every change observed by `observePermissions()`. It is NOT called from `init`: the statuses are all `.unknown` there, so it would uninstall rather than install.

**A related swallow in the same subsystem.** `installHotkeyIfPossible()` silently swallowed a failed `CGEvent.tapCreate`, and since `observePermissions()` only re-applies on a *change*, that failure was permanent for the process lifetime — the same "no second chance" property, from the failure side rather than the initial-state side. It now logs.

## Related

- [`architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md`](../architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md) — the sibling hazard from the same arc; same inversion (steady-state users broken, developers not).
- [`conventions/source-scan-guard-fidelity-2026-07-25.md`](../conventions/source-scan-guard-fidelity-2026-07-25.md) — why the mechanical guard could not catch this, and what it can catch.
- [`design-patterns/consuming-cgeventtap-teardown-2026-05-18.md`](./consuming-cgeventtap-teardown-2026-05-18.md) — the mirror image on the same accessibility → hotkey-tap coupling: every install path needs a symmetric teardown. This entry is about the install path's *first* decision.
- [`design-patterns/right-option-cgeventtap-2026-05-15.md`](./right-option-cgeventtap-2026-05-15.md) — what the tap that never installs actually is.
- [`conventions/module-architecture-and-naming-2026-05-15.md`](../conventions/module-architecture-and-naming-2026-05-15.md) — the `@Observable` + `@Environment` rule (no `ObservableObject` / `@Published`) that put `withObservationTracking` on this path.
- [`runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`](../runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md) — why the eager `init` read was removed at all.
- `NoType/Permissions/CLAUDE.md` invariants 5 and 7 — the observation mechanism, and `init()` being inert with `prime()` doing the first read.
- `NoType/UI/CLAUDE.md` "Launch ordering" — the ordering rule this entry explains.
