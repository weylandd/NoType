---
title: Full-screen accessibility tree (not just focused window)
date: 2026-05-15
category: design-patterns
module: Context
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - Modifying the AccessibilityTree walker
  - Considering a "focused window only" optimisation
  - Auditing prompt-payload size or per-session cost
tags: [accessibility-tree, context, gemini, secure-field-masker, payload-size]
---

# Full-screen accessibility tree (not just focused window)

## Context

When building the context snapshot that ships to Gemini, NoType has to choose how much of the screen to walk:

1. **Focused window only** — small, simple, ~1–3K tokens.
2. **Full-screen** — every on-screen window across all running apps, ~5–15K tokens.

The walked tree is what disambiguates proper nouns / jargon during transcription.

## Guidance

**Walk the AX tree of all on-screen windows**, not just the focused one. Implementation lives in `NoType/Context/AccessibilityTree.swift`, walked in parallel via `withTaskGroup` with a per-app 100 ms wall-clock cap and a 5000-node global budget.

## Why This Matters

**Cross-window context meaningfully improves transcription of names and jargon.** Examples that bite when you only walk the focused window:

- The Slack channel sidebar names the people you're about to mention by name.
- The document open next to the email mentions the project codename you're dictating about.
- The issue tracker title has the proper-noun spelling of the feature name.

For natural-language dictation (the whole point of NoType), these cross-window signals are the difference between "Anthropic" and "antropic / anthropik / anthrop". Once the dictionary is seeded (ADR-016) the gap narrows for known terms — but new proper nouns the user dictates for the first time still benefit from neighbour-window context.

## When to Apply

- Every session. The contextTask runs once on press and stays bounded by the 5000-node global budget.
- Reconsider if: payload size pushes us past Gemini's input-token budget for high-density sessions, OR users report a security incident traceable to cross-window leakage. Both are mitigatable inside the current shape (tighten the budget; harden `SecureFieldMasker`) — full-screen → focused-only would be the last resort.

## Examples

**Trade-offs accepted:**

- **Larger payload** (~5–15K tokens vs. ~1–3K). Recovered by implicit caching after chunk 1 — see `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md` and `solutions/design-patterns/local-chunk-concatenation-2026-05-15.md`.
- **Stricter requirement on `SecureFieldMasker`** — secure fields can be in any window, not just the one being typed into. The masker enforces this at the type level: `AccessibilityTree.snapshot()` returns `RedactedAXSnapshot`, never raw text. See `NoType/Context/CLAUDE.md` "Secure-field masking".
- **Slight increase in per-session cost** — recovered by caching after chunk 1.

**Alternative that was rejected:**

- **Focused window only.** Smaller and simpler, but loses the cross-window context that's valuable for natural-language dictation. Tested informally during early development; transcription accuracy on proper nouns dropped enough to be noticeable.

## Related

- `NoType/Context/CLAUDE.md` — full implementation: depth caps, per-app deadline, secure-field rules.
- `docs/decisions.md` ADR-009 — legacy index entry, redirects here.
- ADR-014 (planned migration) — the OCR fallback that complements AX when AX returns nothing.
- ADR-016 (planned migration) — the personal dictionary that seeds canonical spellings, working alongside AX context.
- `architecture.md` invariant I7 — secure-field masking, type-level guarantee.
