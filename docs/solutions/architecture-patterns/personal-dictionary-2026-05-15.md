---
title: Personal dictionary (canonical spellings + replacement pairs)
date: 2026-05-15
category: architecture-patterns
module: Dictionary
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - Improving transcription of brand names / proper nouns / jargon
  - Adding any new prompt-prefix section
  - Considering an LLM-based extractor for a downstream task
tags: [dictionary, harvester, gemini, replacements, cache-prefix]
---

# Personal dictionary (canonical spellings + replacement pairs)

## Context

Even with full-screen AX context, Gemini transcription occasionally mishears brand names / proper nouns / jargon — especially when the user has an accent or the audio is unclear. We needed a way to:

1. **Bias** Gemini toward canonical spellings the user cares about (Anthropic, Slack, etc.).
2. **Replace** abbreviations the user uses verbally (`то есть → т.е.`) without sending them to Gemini.
3. **Auto-learn** new canonical spellings from session context, so the user doesn't have to manually curate the dictionary.

## Guidance

**Add a self-contained `NoType/Dictionary/` module backing a third main-window tab.** It owns two independent concerns:

1. **`User dictionary:` cache-prefix section.** A new section in every Gemini transcription request, between `Category instruction:` (optional) and `Insertion target:`. Comma-separated list of canonical spellings — brands, proper nouns, jargon — that biases Gemini's transcription. **Always present**, even when the list is empty (body `(empty)`).
2. **Auto-replacement pass.** Pure client-side find/replace pairs (e.g. `то есть → т.е.`) applied to the final stitched transcript **between** `finalizeForInsertion` and `paste` — i.e. after Gemini, never sent to Gemini.

Both concerns persist to `~/Library/Application Support/NoType/dictionary.json`. Mirrors `InstructionsStore` operationally: actor isolation, atomic writes, corruption recovery via `.corrupt-<ts>` rename.

Dictionary entries are mixed-source:

- **User-added** (sticky, never trimmed by cap logic, max 30 chars per entry, capped at 100 manually).
- **Auto-harvested** by `DictionaryHarvester` (pure client-side function) after each successful session. FIFO trim when total > 100 — auto entries go oldest-first; user entries are sticky.

The cached prefix grows from 7 to 8 textual parts.

## Why This Matters

- **Replacements alone can't fix transcription mistakes Gemini didn't catch in the audio.** A Russian speaker dictating "Anthropic" in their accent gets back transliterated Cyrillic; the dictionary biases Gemini to pick "Anthropic" up front, before any replacement could ever fire.
- **Auto-harvest closes the curation loop.** New canonical spellings appear in the user's dictionary just by dictating in apps where the on-screen context shows the right casing.
- **The `User dictionary:` section is always present** even when empty. Dropping it on empty would change the prefix shape and break implicit caching the rest of the prefix relies on.

## When to Apply

- Default — every session uses the cache-prefix section + replacement pass.
- Auto-harvest is **skipped only when user-entry count is at the cap (100)**. With all slots filled by sticky user entries, the harvester can't write anything anyway.
- Reconsider when:
  - Users start complaining that the harvester misses lowercase brand names they actually dictate frequently (Stripe / stripe). Add an "ignore casing" mode behind a toggle.
  - The 30-char cap turns out to truncate real entries users care about. Bump to 50.
  - The replacement pass introduces user-visible bugs at boundaries (e.g. interaction with `finalizeForInsertion`'s leading-space rule). Move replacements before boundary normalisation and add tests pinning both branches.

## Examples

**Auto-harvest design (v2 — supersedes v1 LLM extractor)** — `DictionaryHarvester.harvest`:

1. Tokenize the just-pasted transcript (Unicode word boundaries plus atypical-text binders `.`, `_`, `/`, `-`).
2. For each token position, try increasing multi-word spans (3 → 2 → 1 tokens). Search the on-screen context the model saw at session start (AX tree + optional OCR + insertion target's textBefore/After) for the phrase, case-insensitive with proper word-boundary handling.
3. When a span matches, capture the **transcript's casing**, apply a shape filter (must look proper-noun-ish or contain an atypical binder), dedup case-insensitively against existing dictionary, and save.
4. Longest-match priority — `Вася Пупкин` wins over saving `Вася` and `Пупкин` separately.
5. Cap at 5 candidates per session, 30 chars per entry.

**What Didn't Work (v1, replaced):**

The original ADR-016 v1 used a one-shot Gemini call per session to suggest dictionary candidates from the final transcript text. In practice it produced **few and noisy terms** — the extractor was given only the bare transcript text plus existing dictionary entries, so it had to guess which terms were proper nouns vs common words, with no access to the audio or the on-screen context the transcription model used.

v2 replaced it with a pure-function client-side intersector. Wins:

- **Quality**: a candidate is added iff it appears in BOTH the transcript AND the surrounding context the model saw. By construction, the entry is something the context disambiguated.
- **Cost**: zero API calls per harvest. One Gemini call per session vanishes from the bill.
- **Latency**: < 5 ms client-side vs ~500 ms LLM round-trip. Harvest is now synchronous in `AppState.finalizeRecording`, not fire-and-forget.
- **Determinism**: same input → same output. No model stochasticity, no hallucinated "weird terms" the user complained about in v1.
- **Privacy**: the transcript no longer leaves the device for the purpose of extraction.

**Decisions inside the decision (v2):**

- **No common-words stoplist.** Shape filter (proper-noun-like or atypical-binder-bearing) handles UI chrome rejection.
- **Atypical binders kept anywhere in the token** — covers `claude.md`, `generate_keys`, `bin/python`, `state-of-the-art`, `_priv`, `bin/`.
- **Internal period only.** A trailing period (sentence end) is dropped during tokenization. `Anthropic.` → `Anthropic`. `claude.md` → `claude.md` (period followed by `m`).
- **Replacement matching: word-boundary + auto-capitalised variant** — ICU-aware `\b` so Cyrillic / other Unicode alphabets work. When `from` starts with a lowercase letter, an auto-generated capitalized variant matches too: `то есть → т.е.` also matches `То есть` and replaces it with `Т.е.`. All-caps (`ТО ЕСТЬ`) is intentionally not matched.
- **`DictionaryContext` is frozen at session start.** Edits to the Dictionary tab during a recording session don't affect the in-flight transcription or the paste-time replacements. The frozen snapshot lives on `RecordingSession`; `replacements` is stored on the session as `replacementsFrozen` (separate from `cachedContext`) so a quick-release path that falls back to `ContextSnapshot.minimal(activeApp:)` still gets the user's replacement pairs applied.
- **Length filter and case-insensitive dedup at every entry point** — UI textfield, `DictionaryStore` mutators, `DictionaryHarvester` (`sanityMaxLength`), and the on-disk decoder. A hand-edited `dictionary.json` can't sneak overlong / duplicate entries past the cache prefix.

**Alternatives that were rejected:**

- **Skip the `User dictionary:` prompt section, do replacements only.** Replacements can't fix what Gemini didn't catch correctly in the audio.
- **Single mixed list with no source distinction.** Without `.user` / `.auto` source labels we can't make the trim FIFO honour manual additions.
- **Multi-turn LLM extractor.** Considered for v2; rejected — algorithm gives stronger context-derived guarantees by construction, costs nothing per session, deterministic.
- **Hybrid (algorithmic + LLM fallback).** Added complexity with unclear value.
- **Per-app dictionaries (Slack-only, Linear-only).** User's brands / names are largely consistent across apps.
- **Sync the dictionary across devices via iCloud.** Out of scope for v1.

## Related

- `NoType/Dictionary/CLAUDE.md` — implementation detail (storage, harvester algorithm, replacement contract).
- `NoType/Gemini/CLAUDE.md` "Request shape" — pins the `User dictionary:` part position.
- `docs/decisions.md` ADR-016 — legacy index entry, redirects here.
- `solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md` — the cache-prefix contract this section sits inside.
- `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` — the OCR layer the harvester reads from for context-derived candidates.
