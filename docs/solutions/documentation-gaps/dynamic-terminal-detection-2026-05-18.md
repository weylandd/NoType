---
title: Dynamic terminal-app detection via AppCategorizer
date: 2026-05-18
category: documentation-gaps
module: Context
problem_type: documentation_gap
component: ax_noise_filter
severity: medium
status: open
applies_when:
  - Reviewing terminal-scrollback R5 false-negatives in apps outside the hardcoded list
tags: [r5, terminal, scrollback, noise-filter, categorization, app-categorizer]
---

# Dynamic terminal-app detection via AppCategorizer

## Context

`AXNoiseFilter.knownTerminalBundleIDs` is a hardcoded `Set<String>` of 8 emulators (Apple Terminal, iTerm, Ghostty, Warp Stable/Preview, kitty, alacritty, hyper, wezterm — with `org.alacritty` and `io.alacritty` both covered). The R5 viewport-scrollback gate (`AXNoiseFilter.isViewportScrollback`) only fires when the parent app's bundle ID is in this set.

Apps outside the list bypass R5 entirely. Examples we know about that aren't covered: Tabby, Termius, Rio, Cool Retro Term, BlackBox. Their `AXTextArea` scrollback ships into `On-screen context:` unredacted; `SecureFieldMasker.scrubContent` only catches token-shaped secrets (JWT, GitHub PAT, AWS keys, generic 40-char opaque tokens), not free-form scrollback content like `echo $DB_PASSWORD` output, `export FOO=secret`, `psql connection_string`, internal hostnames in `ssh` history, or debug dumps that happen to be in the visible buffer.

## Guidance

Two complementary paths, short-term and long-term:

1. **Short-term (mechanical):** Extend `AXNoiseFilter.knownTerminalBundleIDs` whenever a user reports a missing emulator. One-line PR; the hard-rule on `AXNoiseFilter` mandates a new test case, so the addition is self-policing. This is the right move for the next 1–3 reported gaps; it stops being the right move once the set grows past ~15 entries or when an exotic emulator that nobody's heard of leaks something embarrassing.

2. **Long-term (preferred per user direction):** NoType already classifies apps via `NoType/Instructions/AppCategorizer.swift` and the `AppCategory` enum. Today the classifier emits 8 categories (`messaging`, `email`, `social`, `notes`, `docs`, `code`, `search`, `uncategorized`); none of them carry the "is a terminal" semantic. Add a `.terminal` case to `AppCategory` (or expose it as a categorizer-allowed value), have the Gemini classifier identify terminal-shape apps dynamically from display name + bundle ID, and have `AXNoiseFilter.isViewportScrollback` consult `InstructionsStore.cachedCategoryForBundle(_)` in addition to the hardcoded seed set.

   The hardcoded set becomes a static fallback (covers fresh installs, the no-key case, and the offline path); the category system extends it as users open new emulators. The classifier is already paying the cost of categorizing every novel app — adding one category routes that result into the noise filter for free.

## Why This Matters

`SecureFieldMasker` catches well-shaped cloud-provider keys. It does NOT catch:

- `echo $TOKEN` output (the token is a literal string in the value, but the value as a whole is a multi-line shell trace).
- `psql "postgresql://user:pass@host/db"` pasted into a terminal and reflected in scrollback.
- Internal hostnames, server names, ticket IDs, customer names in `ssh` / `kubectl` / `git log` output.
- `env | grep` dumps.
- Stack traces that include file paths revealing project structure.

Any of these shipping unredacted to Gemini through an unrecognised terminal emulator is a privacy leak — quiet because no user-visible behaviour changes; slow-burn because nobody notices until a leak hits something newsworthy.

## When to Apply

- **Short-term path:** apply on first bug report for a specific emulator. Cheap, defensible per-instance.
- **Long-term path:** apply when (a) `terminal` category gets enough product attention to justify a categorizer change AND a UI surface for the auto-classified result, OR (b) the hardcoded set crosses ~15 entries and the maintenance cost of "another emulator I've never heard of" exceeds the cost of teaching the classifier, OR (c) a bug report surfaces specifically because of the bypass (free-form scrollback content reached Gemini and the user noticed).

## Examples

The seed set as of PR #47:

```swift
// NoType/Context/AXNoiseFilter.swift
static let knownTerminalBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable",
    "dev.warp.Warp-Preview",
    "net.kovidgoyal.kitty",
    "org.alacritty",
    "co.zeit.hyper",
    "com.github.wez.wezterm",
    "io.alacritty",
]
```

The long-term shape would look like:

```swift
// NoType/Context/AXNoiseFilter.swift — sketch
static func isViewportScrollback(
    role: String?,
    value: String,
    containingBundleID: String?,
    category: AppCategory?  // new — passed in from caller
) -> Bool {
    guard let bundle = containingBundleID else { return false }
    let isTerminal =
        knownTerminalBundleIDs.contains(bundle) ||
        category == .terminal
    guard isTerminal else { return false }
    // ... existing shape predicate
}
```

The caller (`AccessibilityTree.decideForNode` / its walk-time wiring) reads the cached category from `InstructionsStore` for the parent bundle and passes it in.

## Related

- `NoType/Context/CLAUDE.md` "Noise filtering" R5 — the scrollback gate this entry is about.
- `NoType/Instructions/CLAUDE.md` — `AppCategorizer` flow + dedup + low-confidence skip; the integration surface for the long-term path.
- `docs/solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md` — categorization architecture decision; rationale for the classifier shape.
- `docs/solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` — the OCR fallback runs through the same `SecureFieldMasker.scrubContent` path, with the same caveat for free-form text.
