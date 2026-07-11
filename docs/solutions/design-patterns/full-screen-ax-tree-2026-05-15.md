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
  - Adding a new text path from AX / Vision to the Gemini prompt
  - Changing SecureFieldMasker skip rules or scrub patterns
tags: [accessibility-tree, context, gemini, secure-field-masker, payload-size, secure-field-redaction, egress-contract]
---

# Full-screen accessibility tree (not just focused window)

## Context

When building the context snapshot that ships to Gemini, NoType has to choose how much of the screen to walk:

1. **Focused window only** — small, simple, ~1–3K tokens.
2. **Full-screen** — every on-screen window across all running apps, ~5–15K tokens.

The walked tree is what disambiguates proper nouns / jargon during transcription.

## Guidance

**Walk the AX tree of all on-screen windows**, not just the focused one. Implementation lives in `NoType/Context/AccessibilityTree.swift`, walked in parallel via `withTaskGroup` with a per-app 100 ms wall-clock cap, a per-app rendered-lines budget that gives modest priority to the active app (**1000 lines active / 700 non-active**, ~1.4× ratio), and a 5000-line global budget. `applyGlobalCap` moves the active app to the front before truncating so it survives on a busy machine. The earlier draft used a 1200/500 split (2.4×); it over-rotated to active and starved the cross-window case below.

### Secure-field redaction is an egress contract, not a per-consumer choice

Walking every window widens the attack surface — a secret can be in any window, not just the one being typed into. `SecureFieldMasker` is what keeps the full-screen walk safe, and four rules (hardened in PR-B, the security-boundary pass) keep it airtight. All four generalise beyond this module: **every** text path from AX / Vision to the prompt is subject to them.

1. **One skip predicate, two call sites.** `SecureFieldMasker.skipReason(for: NodeMetadata)` is `internal` (not `private`) and consumed by BOTH the AX walker (`decideForNode`) AND `InsertionTarget.captureSync` — which builds a `NodeMetadata` from the focused element **plus its parent** (`AXAttr.element(_, kAXParentAttribute)`). Never re-implement a security decision per consumer. `captureSync` previously refused only `AXSecureTextField`, silently missing identifier tokens ("password"/"passcode"/"token"), `roleDescription == "secure"`, and the sensitive-sheet-parent heuristic — so a plain `AXTextField` named "password", or a field inside a "Sign in" sheet, leaked its value into the `Insertion target:` section. Parent role/title are read only to *decide* the skip; they are never emitted.

2. **Every new text path to the prompt goes through `SecureFieldMasker.scrubContent`.** Node titles (`formatLine`) and window titles (before `RedactedWindowDump`) previously reached the prompt with only quote-swapping while `value` went through the masker — a title-shaped leak (`https://user:pass@host`, token-shaped labels). Both now scrub. Secure-field `.skip` still short-circuits **before** the title render, so masking precedence is preserved. The `RedactedWindowDump` / `RedactedAXSnapshot` type names are promises: a value of that type must never carry a raw secret.

3. **Scrub-then-split, never split-then-scrub.** When a focused field's value is sliced at the cursor into before/after halves, scrub the FULL value ONCE and split afterward. Scrubbing the two halves independently let a secret *straddling* the cursor evade the anchored patterns — a JWT / PEM / card split at the cursor left neither half matching a prefix-anchored regex (`AIza…`, `eyJ…`, `Bearer …`), and a PEM body extending past the 500-char after-window lost its `BEGIN` marker. The cursor offset is advisory (spacing / capitalisation only), so re-clamp against the scrubbed length and accept minor cursor drift. The new behaviour redacts a strict superset of the old.

4. **base64 scrub rule sits between specific and generic (order is load-bearing).** A `[A-Za-z0-9+/=]` ≥40 rule, gated on letter AND digit AND a base64-special char (`+` / `/` / `=`), catches AWS secret access keys and raw base64 key material that the opaque catch-all (`[A-Za-z0-9_\-]`) structurally *cannot* match. It sits directly ABOVE the generic catch-all and BELOW every specific provider rule — specific → generic ordering is load-bearing, so provider keys keep their specific labels and nothing generic shadows them. **Deliberate accepted tradeoff (intentional, not a bug):** the rule over-redacts long developer file paths containing a digit (e.g. `/Users/…/Xcode26/…`). Privacy-first was the explicit choice over sparing path-shaped runs, because any heuristic that spares `/`-runs risks leaking a real `/`-bearing secret (AWS keys). A dedicated path-vs-secret heuristic is a follow-up if path context ever proves important.

Every change to `SecureFieldMasker.swift` must add a `SecureFieldMaskerTests` case, and any new AX → prompt egress path must route through it — see `NoType/Context/CLAUDE.md` "Hard rules".

## Why This Matters

**Cross-window context meaningfully improves transcription of names and jargon.** Examples that bite when you only walk the focused window:

- The Slack channel sidebar names the people you're about to mention by name.
- The document open next to the email mentions the project codename you're dictating about.
- The issue tracker title has the proper-noun spelling of the feature name.

For natural-language dictation (the whole point of NoType), these cross-window signals are the difference between "Anthropic" and "antropic / anthropik / anthrop". Once the dictionary is seeded (ADR-016) the gap narrows for known terms — but new proper nouns the user dictates for the first time still benefit from neighbour-window context.

## When to Apply

- Every session. The contextTask runs once on press and stays bounded by the 5000-line global budget plus the per-app 1000/700 split.
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
