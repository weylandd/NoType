---
title: Settings section for screen-capture fallback (planned)
date: 2026-05-15
category: documentation-gaps
module: UI
problem_type: documentation_gap
component: tooling
severity: low
applies_when:
  - User reports they want OCR fallback off without revoking TCC permission
  - Expanding the Settings sheet with feature toggles
tags: [settings, screen-capture, ocr-fallback, ui, tech-debt]
---

# Settings section for screen-capture fallback (planned)

## Context

The screenshot + OCR fallback (see `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md`) is currently gated purely by Screen Recording TCC permission state. Granting in onboarding (or System Settings) turns the feature on; there is **no in-app way to disable it** without revoking the TCC grant.

The Settings redesign (PR #52) added a Screen Recording permission **chip** to the About pane that surfaces the grant state and opens System Settings on click — but that's a status display, not a runtime toggle. The gap this doc describes remains open: a user who wants OCR off but doesn't want to revoke TCC permission still has no in-app recourse.

## Guidance

When users start asking for an off-switch that doesn't require revoking system permission, add a Settings section with: a status badge (granted / denied / needed), an explicit "Use screen capture for context" toggle that gates the runtime independently of permission, a "Re-open onboarding step" link, and a short explanation of when the fallback fires. The natural home is the **Recording** pane in the new shell, adjacent to "Input device" and "Music interruption" — close to the other capture-related settings.

Until then, leave the existing About-pane permission chip as-is.

## Why This Matters

V1 ships the feature behind the simplest possible gate so we don't expand the Settings sheet during the same change. A user who wants OCR off but doesn't want to revoke TCC permission has no recourse — acceptable in beta, not long-term.

## When to Apply

- Reconsider when: a user reports the gap on GitHub Issues or in support email.
- Reconsider when: the Settings sheet grows for another reason and "one more toggle" becomes cheap to add.

## Examples

The new control lives as a `DSCard` inside `RecordingPane`, alongside the existing Input device card:

```swift
// NoType/UI/Settings/Panes/RecordingPane.swift — sketch
DSCard(title: "Screen capture") {
    DSCardRow(
        title: "Use screen capture for context",
        subtitle: "Fires only when accessibility returns no content for the active app — primarily Electron / web-views."
    ) {
        Toggle("", isOn: $appState.screenCaptureFallbackEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(DS.Color.accent)
    }
    // Status row links into the About-pane permission chip when ungranted.
}
```

Plus a `UserDefaults` flag (`notype.screenCaptureFallbackEnabled`) honoured by `RecordingSession.start`.

Approximate effort: **S**.

## Related

- `NoType/UI/CLAUDE.md` "Settings scope" — what's currently in the sheet + planned additions.
- `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` — the feature that needs the toggle.
- `docs/TECHDEBT.md` — legacy index entry, redirects here.
