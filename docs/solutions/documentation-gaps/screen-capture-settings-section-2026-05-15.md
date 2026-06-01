---
title: Settings section for screen-capture fallback (shipped)
date: 2026-05-15
category: documentation-gaps
module: UI
problem_type: documentation_gap
component: tooling
severity: low
status: closed
applies_when:
  - Historical reference — gap closed by the screen-capture toggle plan
  - Considering the deferred permission status-badge follow-up
tags: [settings, screen-capture, ocr-fallback, ui, tech-debt, closed]
---

# Settings section for screen-capture fallback (shipped)

## Context

The screenshot + OCR fallback (see `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md`) was gated purely by Screen Recording TCC permission state. Granting in onboarding (or System Settings) turned the feature on; there was **no in-app way to disable it** without revoking the TCC grant.

The Settings redesign (PR #52) added a Screen Recording permission **chip** to the About pane that surfaces the grant state and opens System Settings on click — a status display, not a runtime toggle. That left the gap this doc describes: a user who wants OCR off but doesn't want to revoke TCC permission had no in-app recourse.

## Guidance

**Closed** by `docs/plans/2026-06-01-001-feat-screen-capture-toggle-plan.md`. Shipped shape:

- An `AppState.screenCaptureFallbackEnabled` flag (UserDefaults `notype.screenCaptureFallbackEnabled`, default **on** via `object(forKey:) as? Bool ?? true` so upgraders keep OCR), frozen into `RecordingSession.start(...)` and consumed by the pure `RecordingSession.shouldRunOCR(fallbackEnabled:permissionGranted:pid:)`. The flag is an independent off-switch layered on top of the TCC permission.
- A **"Screen capture"** `DSCard` in `RecordingPane`, below "Input device". The toggle is driven by a **computed `Binding`**, not `$appState.screenCaptureFallbackEnabled` directly — its *displayed* position is the **effective** state (`permission granted && intent flag`), while the stored flag is the user's *intent*.

**Deviations from the original sketch below** (the sketch is left intact for the record):

- The sketch bound the `Toggle` straight to `$appState.screenCaptureFallbackEnabled`. The shipped version cannot — the displayed position has to fold in permission state, and an ungranted tap must redirect to System Settings rather than flip. Both live in the pure `AppState.screenCaptureToggleAction(permissionGranted:requestedOn:)` (ungranted → `.openSettings`, never a silent flip).
- The "status badge (granted / denied / needed)" and "Re-open onboarding step" link from the original guidance were **not** shipped. The About-pane chip already owns permission-status display; duplicating it in the Recording card was deferred (see below). The card surfaces only a one-line subtitle hint when ungranted.

## Why This Matters

V1 shipped the feature behind the simplest possible gate (TCC only) so the Settings sheet didn't grow in the same change. A user who wanted OCR off without revoking TCC had no recourse — acceptable in beta, now resolved.

## When to Apply

The core gap is closed. One **deferred follow-up** remains if a user asks for it: a full permission **status badge** (granted / denied / needed) inside the Recording card. Today the card shows only a muted subtitle hint when ungranted and relies on the grant-on-tap redirect + the About-pane chip for status. Add the badge only if the redirect proves insufficient in practice.

## Examples

The shipped control is a `DSCard` in `RecordingPane`, below the Input-device card. Original sketch (pre-implementation — note the shipped `Toggle` uses a computed `Binding`, not the direct `$` binding shown here):

```swift
// NoType/UI/Settings/Panes/RecordingPane.swift — original sketch
DSCard(title: "Screen capture") {
    DSCardRow(
        title: "Use screen capture for context",
        subtitle: "Fires only when accessibility returns no content for the active app — primarily Electron / web-views."
    ) {
        Toggle("", isOn: $appState.screenCaptureFallbackEnabled)   // shipped: computed Binding (effective state + grant-redirect)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(DS.Color.accent)
    }
}
```

The decision logic is pinned by `RecordingSessionOCRGateTests` (gate) + `ScreenCaptureToggleActionTests` (toggle action).

## Related

- Closed in [PR #71](https://github.com/weylandd/NoType/pull/71).
- `docs/plans/2026-06-01-001-feat-screen-capture-toggle-plan.md` — the closing plan (U1–U4), incl. KTD-6 (intent vs displayed position).
- `NoType/UI/CLAUDE.md` "Settings file list" — the Recording-pane card.
- `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` — the feature the toggle gates.
- `docs/TECHDEBT.md` — index entry removed on close.
