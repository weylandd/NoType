---
title: A burst of identical errors made the HUD's close button unclickable — the view was replaced mid-click
date: 2026-08-13
category: ui-bugs
module: UI
problem_type: ui_bug
component: tooling
symptoms:
  - "User reports the error HUD's close button \"does nothing\" — the panel stays up until it auto-dismisses"
  - "Not reproducible on demand; only during a burst of the same failure"
  - "`ui.hud` log shows five `HUD column: error` records in 244 ms from one PID with no `empty` between them"
root_cause: logic_error
resolution_type: code_fix
severity: medium
tags: [swiftui, button, nspanel, hud, gesture, identity, coalescing, diagnosis]
related_components: [UI, AppState, Gemini]
---

# A burst of identical errors made the HUD's close button unclickable — the view was replaced mid-click

## Problem

A user reported that the error HUD's close button did nothing: the panel stayed up until its eight-second auto-dismiss fired. Nothing about the button's wiring was wrong. `showErrorHUD` tore down and rebuilt the panel on **every** call, and during a burst of the same failure the view the user pressed down on no longer existed by the time they lifted the mouse.

## Symptoms

- "The close button doesn't work." Intermittent, and the user could not say what made it happen.
- The maintainer's `ui.hud` log for the session carries **five `HUD column: error` records in 244 ms from one PID, with no `empty` record between them** — five panels built and destroyed back to back, four of them carrying the same payload. (The log is not in the repo. This is the author's reading of it, recorded at `NoType/UI/CLAUDE.md` and beside the coalescing fixture; the mechanism below is verifiable from source, the count is not.)
- The same log also carries seventeen short-lived PIDs in four minutes: test hosts painting their own panels over the installed app's. That is a **separate** defect with the same visible symptom, written up in [test-host side effects escape the test process](../conventions/test-host-side-effects-escape-the-test-process-2026-08-13.md), and it shipped in the same commit.

## What Didn't Work

**Round one fixed a real bug that was not the reported one.** `7476742` found and fixed a genuine within-process superposition — two HUD panels overlapping because the column arithmetic did not reserve a slot per occupant — and its own message said, correctly, that it was *not* confirmed as the instance behind the report:

> Scope note: this fixes a provable collision, but it is *not* confirmed as the instance behind the report. On the reporter's machine all permissions are granted (so no cards) and no retry ran, which are the only ways two panels could have co-existed there — see the PR/issue discussion for the alternative mechanism the logs do point at.

That fix was never retracted; the `Slot` column is live today. Calling it a failed fix would misstate the record — it fixed a real bug, and the report survived it.

**What round one contributed to the diagnosis was not its fix — it was a log line.** `HUDController` had *no logger at all* before `7476742`. That commit added one `.notice` per layout naming the occupied slots, with `empty` as the "nothing is up" marker:

```swift
Self.log.notice("HUD column: empty")
Self.log.notice("HUD column: \(column.rows.map(\.slot.description).joined(separator: ", "), privacy: .public)")
```

That record's *shape* is what made round two possible: `.public` so it persists in `log show`, one line per layout so a rebuild burst is countable, an `empty` marker so "five records with nothing between them" is a meaningful sentence, and a PID column so multiple processes are distinguishable. Its rationale, written in round one, says as much — *"this is the record whose absence made a 'the close button does nothing' report undiagnosable from logs alone."*

## Solution

Coalesce a repeat of the payload already on screen into a timer reset, instead of rebuilding (`NoType/UI/HUDController.swift`):

```swift
func showErrorHUD(payload: ErrorPayload, autoDismissAfter: TimeInterval? = 8, …) {
    if Self.shouldCoalesceError(showing: errorPayload, incoming: payload) {
        Self.log.notice("HUD column: error repeat coalesced")
        armErrorAutoDismiss(after: autoDismissAfter)
        return
    }
    errorPanel?.hide(); errorPanel?.close(); errorPanel = nil
    …
}

nonisolated static func shouldCoalesceError(showing: ErrorPayload?, incoming: ErrorPayload) -> Bool {
    guard let showing, showing == incoming else { return false }
    return incoming.retryLabel == nil && incoming.secondaryLabel == nil
}
```

Two terms, both required:

1. **Whole-struct equality.** `ErrorPayload` is `Equatable` over all eight stored properties — title, description, code, severity, icon, both action labels, retry kind. Not a title-and-code subset. (`ErrorPayload` has been `Equatable` since the initial public release; nothing gained a conformance for this fix.)
2. **No action buttons.** This is a **proxy for closure equality, which Swift cannot express**: handlers are closures, so an equal payload does not imply an equal panel — *unless no button is rendered to run them*. With both labels `nil`, `ErrorHUD.body` renders no action row at all, and the only interactive element left is the close button, wired to a payload-independent `hideErrorHUD()`.

`armErrorAutoDismiss` cancels the outstanding task before arming a new one. That ordering is load-bearing: a repeat that left the original timer running would dismiss the card eight seconds after the *first* occurrence — mid-burst, which is the same user-visible complaint from the other direction.

The coalesce arm deliberately does not call `relayout()`: the panel set has not changed and neither has any height.

## Why This Works

A click is not an event; it is **two** events that must reach the same live view. SwiftUI's `Button` arms on mouse-down and fires on mouse-up delivered to the view that saw the down. Rebuilding the panel between them hands the up-event to a replacement that never saw the down, so nothing fires — and the user, who sees an apparently continuous panel, has no way to tell that they interacted with three different views.

The burst is what makes the window wide enough to hit. A single failure rebuilds once and the odds of a click straddling it are negligible; five teardown-and-rebuild cycles inside a quarter of a second give a click landing in that window five chances to be split — and a user reacting to an error card is clicking exactly then. (How much of those 244 ms is actually dead is not measured; what is measured is five rebuilds with no hide between them.)

Coalescing removes the rebuild rather than trying to make the rebuild survivable — the panel is simply left alone, so the view identity a gesture depends on is preserved for free.

## Prevention

- **Treat "show X" as idempotent on the view, not on the call.** Any presentation API that unconditionally tears down and recreates its view has this bug latent in it; it only surfaces when the same thing is shown twice quickly. Ask what a second identical call does to the *view*, not to the state.
- **When identity is the fix, name what makes two things "the same" completely, and pin that it stays complete.** `test_coalesce_isReachedOnlyThroughEqualityOfTheWholePayload` mutates `severity` and `iconSymbol` specifically to stop the predicate decaying into a title/code comparison — those two fields are the ones a shortcut would drop first. Three more sweep the refusal cases (no HUD up, a different notice, an actionable notice with an equal payload), a fourth pins the positive repeat, and a source scan pins gate **and** destination (`shouldCoalesceError` present, `errorPanel?.close` still present — without the second needle, "the coalesce guards nothing" passes).
- **When a report cannot be reproduced, ship the breadcrumb even if you also ship a fix.** Round one's durable contribution was a `.notice` per layout. Design it to be read: `.public` so it persists, one record per state change, an explicit "nothing is up" marker so absence is countable, and enough that two processes can be told apart.
- **Two known edges, unpinned.** The coalesce path uses the *incoming* call's `autoDismissAfter`, so a repeat with a different delay re-arms at the new one — and a repeat passing `nil` cancels auto-dismiss entirely, turning a self-dismissing card sticky. No test covers this; in practice `AppState.surfaceError` always passes the default eight seconds. Worth knowing before adding a second caller.

## Related Issues

- [`conventions/test-host-side-effects-escape-the-test-process-2026-08-13.md`](../conventions/test-host-side-effects-escape-the-test-process-2026-08-13.md) — the same investigation's other finding, shipped in the same commit: the same superposition one level up, between processes, which no per-process column can reach.
- [`runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`](../runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md) — the repo's other case of a fix that held while the reported symptom survived it, and the standing warning against treating a same-signature recurrence as a missing annotation.
- `NoType/UI/CLAUDE.md` — the HUD inventory, the one-notice-per-session constraint (`showErrorHUD` replaces rather than stacks), and why the per-method relayout guard still passes with one arm no longer relayouting.
- `CONCEPTS.md` → *Notice* — the at-most-one-per-dictation rule that makes a replacing `showErrorHUD` the right primitive in the first place.
- Commits `7476742` (column fix + the breadcrumb) and `c9d04cd` (coalescing + the test-host guard). Branch-local to `refactor/structural-gap-tracking`; `NoType/UI/HUDController.swift` is the stable reference.
