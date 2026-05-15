---
title: Clipboard + ⌘V text injection (not AX text writes)
date: 2026-05-15
category: architecture-patterns
module: Injection
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - Adding any new text-injection path
  - Considering AX-based or per-character synthetic input
  - Auditing for cross-app compatibility regressions
tags: [paste, clipboard, accessibility, cgevent, electron, ime]
---

# Clipboard + ⌘V text injection (not AX text writes)

## Context

NoType needs to insert the final transcript at the user's cursor in whatever app is focused at release time. Three candidates were considered:

1. **AX text injection** — write the value via `AXValue` on the focused element.
2. **Per-character synthetic key events** — type each character via `CGEvent.keyboardEventSource`.
3. **Pasteboard + ⌘V** — copy to `NSPasteboard.general`, post a synthetic ⌘V, restore the prior clipboard contents after a short delay.

## Guidance

**Use the pasteboard path** (`NoType/Injection/TextInjector.swift`):

1. Capture the entire pasteboard via `PasteboardSnapshot.capture(.general)`.
2. `clearContents` + `setString(text, forType: .string)`.
3. Post a synthetic ⌘V (`CGEvent` keyDown / keyUp on virtual key 9, modifier `.maskCommand`).
4. Wait `pasteRestoreDelayMs` (default 150 ms; user-tunable 50–500 ms via Settings).
5. Restore the snapshot to the pasteboard.

## Why This Matters

**AX text writes don't work on the apps users dictate into most.** Electron (Slack, Discord, VS Code, Notion), terminals, native NSText views with custom field editors — all of them either don't expose `AXValue` for write or silently drop the write. We'd be perfect on Mail / TextEdit and broken everywhere else.

**Per-character synthetic input is too slow and breaks IME.** Typing 100 chars character-by-character is visible and laggy; it also fights autocorrect / IME composition state in apps that intercept keystrokes.

**Pasteboard + ⌘V works wherever ⌘V works** — the universal lower bound for any text field that accepts standard editing commands.

## When to Apply

- Default for every text injection.
- Reconsider only if: a fundamentally new system primitive lands (a "Universal Insertion API", etc.) that beats clipboard on compatibility AND privacy.

## Examples

**The trade-off accepted:** brief clipboard pollution. Mitigated by save/restore around the paste. Worst case visible to the user is "old clipboard restored 150 ms after paste" — not ideal, not catastrophic.

**Restore-delay tuning:** `PasteSettings.defaultRestoreDelayMs = 150`, range 50–500. Native AppKit views need ~50 ms; Slack / Discord 100–150; heavy Electron apps up to 250. User-adjustable in Settings if "old clipboard pasted instead of mine" reports come in.

**Reference product:** Wispr Flow uses the same approach — it's what works in production for a paid product with compatibility SLAs.

**Alternatives that were rejected:**

- **AX text injection (`AXValue`).** Rejected — compatibility.
- **Per-character `CGEvent` typing.** Rejected — slow, breaks IME, autocorrect interference.

## Related

- `NoType/Injection/CLAUDE.md` — pipeline detail, edge cases, restore-delay matrix per app family.
- `docs/decisions.md` ADR-004 — legacy index entry, redirects here.
- `solutions/design-patterns/right-option-cgeventtap-2026-05-15.md` — the same `CGEvent` API on the input side.
