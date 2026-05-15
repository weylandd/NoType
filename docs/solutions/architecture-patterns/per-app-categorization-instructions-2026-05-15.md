---
title: Per-app categorization + user / category instructions in cache prefix
date: 2026-05-15
category: architecture-patterns
module: Instructions
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - Modifying the cache-prefix shape
  - Adding per-app behavior overrides
  - Considering window-title input to the classifier
tags: [categorization, cache-prefix, gemini, instructions, classifier, ax-search-override]
---

# Per-app categorization + user / category instructions in cache prefix

## Context

The first version of NoType used a hard-coded `appStyleHints` dictionary — 8 bundle ids → one of 5 register hints (formal, casual, code, etc.). It didn't scale (a new app needed a code change), didn't let users tune behavior, and didn't disambiguate "search field in Chrome" from "messaging in Chrome".

## Guidance

**Replace `appStyleHints` with a two-layer system:**

1. **Per-app `AppCategory`** — one of `messaging`, `email`, `social`, `notes`, `docs`, `code`, `search`, `uncategorized`. Resolved by an LLM categorizer (one `generateContent` call to `gemini-3.1-flash-lite` with `googleSearch` tool enabled) on the first session in an unfamiliar app, cached forever in `~/Library/Application Support/NoType/instructions.json`. Source-tagged (`auto` / `manual`) so a user override survives subsequent re-classifications. **`search` is never returned by the classifier** — it's an AX-only override resolved at session start when the focused element looks like a search field or address bar.
2. **`User instruction:` and `Category instruction:` prompt sections** — new optional cache-prefix parts. User instruction is a free-form textarea (global, applies to every session). Category instruction is per-category and defaults to a developer-supplied prompt, with a Settings-side override per category.

The cached prefix grows from 5 to up to 7 textual parts (later 6/7/8 after the personal-dictionary feature added `User dictionary:`). Both new sections are conditionally omitted (`User instruction:` when empty, `Category instruction:` when nil — typical for `.uncategorized`); both decisions are frozen at session start and remain stable for every chunk of that session.

## Why This Matters

- **Per-channel formatting wins.** Email gets line breaks; search gets no terminal punctuation; social gets hashtag handling. The old single-hint system couldn't express this.
- **The `search` override is the highest-leverage case.** Without it, dictating into Chrome's omnibox gets the bundle's category (often `uncategorized` or `messaging`), which adds terminal punctuation to search queries and degrades results. Implemented as a synchronous AX read at session start (no extra Gemini call).
- **User-level customization end-to-end.** Users can edit a global instruction, override a category prompt, or reassign an app — all from the Instructions tab.
- **Cache survival.** Keeping `User instruction:` and `Category instruction:` as cache-prefix sections (not mixed into the system instruction) preserves caching: a user can edit their global instruction between sessions without invalidating any per-session cache.

## When to Apply

- Default — every session goes through this path.
- The cache-prefix omission rules (User instruction omitted when empty, Category instruction omitted when nil) are **frozen at session start** — never re-read mid-session, that would shift the part count between chunks and break the cache.
- Reconsider when:
  - The classifier mis-categorizes a common app shape we didn't anticipate (e.g. a popular markdown editor lands in `code` instead of `notes`). Add to the categorizer's disambiguation guidance section; don't introduce a hard-coded override.
  - Window titles become necessary for browser-based apps. Re-introduce them as an `optional` field in the classifier input AND prepend `SecureFieldMasker.scrubContent` in the same change.

## Examples

**Decisions inside the decision:**

- **Single SKU.** Both transcription and classification use `gemini-3.1-flash-lite`. One model id, one pricing surface. The classifier turns on `tools: [{"google_search": {}}]`; transcription does not.
- **Confidence gating.** The classifier returns `{"category", "confidence": "high|medium|low"}`. Only `high` / `medium` are cached. `low` and `uncategorized` outputs trigger a retry on the next session — keeps the cache honest at the cost of occasionally re-charging.
- **Manual overrides are sticky.** `InstructionsStore.upsertAutoAssignment` refuses to overwrite an existing `source: .manual` record. The user can force re-classification from the Instructions tab via the "Re-classify with AI" menu item.
- **Two omittable sections, never both required.** The user instruction can be empty and the category can be `.uncategorized` — yielding the same part count the pre-feature behavior had. New users see no behavioral regression until they start using either field.
- **No window-title in the classifier input (v1).** Window titles can leak PII (draft subject lines, file paths) and would need scrubbing first. Acceptable accuracy hit for v1.

**Trade-offs accepted:**

- The cached prefix shape changed — all 13 `GeminiRequestBuilderTests` were rewritten to pin the new contract.
- The classifier call is one extra ~500 ms HTTP request per new app per user, on the first session. Fire-and-forget so it never blocks recording.
- The Instructions tab adds ~600 lines of SwiftUI surface (textarea + per-category drill-in + apps list with reassign menu).

**Alternatives that were rejected:**

- **Keep `appStyleHints` and grow it.** Doesn't scale, doesn't help with user customization, doesn't handle the search-field case.
- **Single big system-prompt swap based on category.** Would invalidate cache between any two sessions with different categories.
- **Pre-bake category assignments for the top 100 apps.** Covers the head, misses the long tail. The classifier handles unfamiliar apps automatically.
- **Local on-device categorizer (small Llama).** Adds a ~2 GB model dep, marginal accuracy vs Gemini-with-web-search, loses the disambiguation web search provides.

## Related

- `NoType/Instructions/CLAUDE.md` — implementation detail (storage, classifier flow, AX search override).
- `NoType/Gemini/CLAUDE.md` "Request shape — DO NOT REORDER" — the cache-prefix contract this depends on.
- `docs/decisions.md` ADR-015 — legacy index entry, redirects here.
- `solutions/architecture-patterns/personal-dictionary-2026-05-15.md` — added `User dictionary:` part shifting the count to 6/7/8.
