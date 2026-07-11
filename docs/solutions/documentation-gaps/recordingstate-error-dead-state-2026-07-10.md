---
title: RecordingState.error is designed but never entered
date: 2026-07-10
category: documentation-gaps
module: NoTypeApp
problem_type: documentation_gap
component: tooling
severity: low
---

# RecordingState.error is designed but never entered

## Context

`RecordingState` (`NoType/AppState.swift:7`) declares four cases:
`.idle`, `.recording`, `.sending`, `.error(String)`. Every production
assignment to `recordingState` uses one of the first three — `grep`
finds `recordingState = .recording` / `.sending` / `.idle` and **no**
`recordingState = .error(...)` anywhere in `NoType/`.

Yet `.error` is referenced in four places:

- `AppState.swift:438` — `shouldCancelActiveSessionOnAxRevoke` switch arm.
- `AppState.swift:1097` — `cancelRecording()` no-op guard.
- `NoType/UI/MenuBarIcon.swift:46` — renders `mic.slash` for `.error`.
- `NoTypeTests/AppStateAxRevokeTests.swift:40` — `test_error_doesNotCancel`.

Errors are actually surfaced through a different mechanism:
`AppState.surfaceError(_:)` → `HUDController.showErrorHUD(...)` (UI
invariant 1 in `NoType/UI/CLAUDE.md`), and `recordingState` returns to
`.idle`. So `.error` is a **designed-but-never-entered** state: the
menu-bar icon has a rendering ready for it, but nothing ever puts the
state machine there.

This was flagged during the 2026-07-10 code-review remediation (R21).
The remediation deliberately did **not** drop or wire the case in PR-D,
because either action is riskier than a one-line cleanup deserves (see
Guidance).

## Guidance

**Done — dropped (option 2).** Resolved on branch
`remediation/pr-f-techdebt-followups` (PR-F tech-debt follow-ups).

The two clean resolutions were:

1. **Wire it up.** Have the "recording broke" failure sites (or
   `surfaceError`) set `recordingState = .error(message)` so the menu-bar
   `mic.slash` glyph renders during a broken state. **Rejected** — it adds
   a new, visible, *sticky* menu-bar error state that outlives the Error
   HUD, which is a UX/product change, not a tech-debt cleanup. Errors are
   deliberately HUD-only (UI invariant 1); a persistent broken glyph would
   need product sign-off.
2. **Drop it.** ✅ **What shipped.** Removed the `case error(String)` from
   the `RecordingState` enum, collapsed both `switch` arms (`.idle, .error`
   → `.idle` in `shouldCancelActiveSessionOnAxRevoke` and `cancelRecording`),
   removed the `MenuBarIcon` `.error` branch, and deleted
   `AppStateAxRevokeTests.test_error_doesNotCancel` (its subject vanished;
   the `.idle` case — `test_idle_doesNotCancel` — already covers the
   "not-live → don't cancel" intent).

The `MenuBarIcon` branch was **compiler-dead** (the state was never
assigned), so its removal has zero visual effect for the three live states
(idle / recording / sending) — a successful build proves they still render
identically, no separate visual smoke needed.

## Why This Matters

The case is harmless at runtime (never entered), but a dead enum case
invites confusion: a reader reasonably assumes some path sets it and may
wire new logic around a state that can't occur. Resolving it — render a
real broken state, or admit errors are HUD-only and remove the case —
should be a deliberate decision.

## When to Apply

- The menu-bar icon states, the error-HUD surfacing, or `RecordingState`
  are being revisited anyway.
- A design decision lands on whether the menu bar should show a distinct
  "broken" glyph vs. relying solely on the Error HUD.

## Examples

```swift
// AppState.swift — every assignment; none is .error:
recordingState = .recording(startedAt: startedAt)
recordingState = .sending
recordingState = .idle

// MenuBarIcon.swift:46 — a rendering that is never reached:
case .error:
    Image(systemName: "mic.slash")
        .foregroundStyle(DS.Color.dangerBase)
```

## Related

- `NoType/AppState.swift` (`RecordingState`, `surfaceError`, `cancelRecording`)
- `NoType/UI/MenuBarIcon.swift` (the `.error` rendering)
- `NoType/UI/CLAUDE.md` (invariant 1 — errors surface only via `showErrorHUD`)
- `NoTypeTests/AppStateAxRevokeTests.swift` (`test_error_doesNotCancel` — removed on close)
- Source plan: `docs/plans/2026-07-10-001-fix-code-review-remediation-plan.md` (R21 / U22)
- **Closed by:** `refactor(recording): drop dead RecordingState.error case (tech-debt)` on branch `remediation/pr-f-techdebt-followups`.
