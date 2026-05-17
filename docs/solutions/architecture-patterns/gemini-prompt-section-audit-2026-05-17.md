---
category: architecture-patterns
created: 2026-05-17
status: tier-1-2-applied
---

> **Update — 2026-05-17 post-Tier-2:** Tier 1 + Tier 2 trims have landed
> in feature branch `feat/gemini-prompt-eval-harness` (commits C1-C8).
> Cumulative result: **full prompt 4 318 → 2 714 tokens (-37.1%)**,
> lite prompt 1 012 → 956 tokens (-5.5%). 13/15 eval still passing,
> 2 known failures unchanged (silence non-production + number
> normalisation). The original baseline figures below are preserved
> for historical reference.

# Gemini transcription prompt — section-by-section audit

## Context

NoType ships two Gemini transcription prompts:

- `systemPrompt` (`NoType/Gemini/GeminiClient.swift:848-1002`) — ~3 500 words, **~4 030 tokens** in `promptTokenCount` (system + cache prefix, excluding audio).
- `systemPromptLite` (`NoType/Gemini/GeminiClient.swift:1017-1062`) — ~600 words, **~1 012 tokens** in `promptTokenCount`.

The user's question: *"не перебор ли мы кидаем такие огромные куски промпта для, по сути, простой задачи транскрибации аудио?"*

This audit gives an empirical answer. **TL;DR — on the current eval coverage, yes, most of the prompt is over-engineered. No individual section measurably defends behavior on any of our representative fixtures. But eval coverage has known gaps; do not interpret this as license to delete everything until those gaps close.**

## Guidance

### Baseline behaviour (current `main` prompts, 15-fixture eval)

13 passing tests, 2 failing tests. Both failures are real regressions on production prompts:

- ⚠️ **`silence_only`** — pure digital silence (-91 dB, 2.0 s) transcribes as *"Hello, how are you?"*. Prompt requires empty string. **Hallucination from silence.** *Synthetic edge case only* — in production NoType's Silero VAD + `PauseDetector` (150 ms voiced floor, `pcm.count >= 2400` minimum chunk size) ensures silence chunks never reach Gemini. Fixture kept as a robustness probe for "what if VAD ever fails" defence-in-depth, **not** as a Tier 4 blocker.
- ⚠️ **`long_monologue_en`** — *"sixteen pixel"* normalised to *"16-pixel"* (similarly `twelve`/`twenty`/`thirty`). Verbatim contract violated; spelled-out → digit normalization. Partial — `"three sprints"` and `"accessibility"` preserved.

### Removal-experiment matrix

Each of 13 `systemPrompt` sections and 8 `systemPromptLite` sections was blanked out via `sed Nd` on `GeminiClient.swift`, the eval re-run against a 4-fixture (full path) or 3-fixture (lite path) subset, results recorded, prompt restored via `git restore`. Subset choice:

- **Full-path subset:** `multi_sentence_en` (verbatim baseline), `silence_only` (silence regression detector), `long_monologue_en` (number-normalisation detector), `code_switch_en_es` (multilingual / technical-term preservation).
- **Lite-path subset:** `greeting_ru` × 2 contexts (uncategorized + mid-sentence insertion) + `single_word_ambiguous` (phonetic faithfulness).

#### Full prompt (`systemPrompt`) — 13 sections

| # | Section | Tokens (full prompt avg) | Δ vs baseline (~4318) | Passed / Failed | Effect on silence hallucination | Effect on long-mono numbers | Recommendation |
|---|---|---:|---:|---:|---|---|---|
| 1 | Intro paragraph | 4 192 | **-126** | 2 / 2 | `"Hello world."` (was `"Hello, how are you?"`) | still normalised | **Trim** |
| 2 | `# How a session works` | 4 172 | **-146** | 2 / 2 | `"Hello, how are you doing today?"` (longer) | still normalised | **Trim heavily / drop** |
| 3 | `# Sections you will receive (in this order)` | 4 029 | **-289** | 2 / 2 | unchanged | still normalised | **Drop** (labels referenced individually by other sections) |
| 4 | `# Output contract` | 3 932 | **-386** | 2 / 2 | `"Hello."` (shorter) | still normalised | **Keep — only section measurably influencing output length** |
| 5 | `# Context is never a source of words` | 3 343 | **-975 (biggest)** | 2 / 2 | unchanged | still normalised | **Trim heavily** — section is 25% of the prompt and didn't defend any measurable failure mode. But eval has no AX / OCR / dictionary fixtures (see "Eval coverage gaps") so caution before total removal. |
| 6 | `# Cleanup — strict whitelist` | 3 921 | **-397** | 2 / 2 | `"Hello world."` | still normalised — just `"16 pixel"` instead of `"16-pixel"` | **Trim** — doesn't prevent normalization, may discourage other cleanup overreach not covered by eval |
| 7 | `# Punctuation across chunk boundaries` | 4 131 | **-187** | 2 / 2 | unchanged | still normalised | **Not measurable** — eval has no multi-chunk fixtures. Keep until multi-chunk fixture added. |
| 8 | `# Insertion target` | 3 848 | **-470** | 2 / 2 | unchanged | still normalised | **Trim** — full removal didn't break baseline, but `GeminiRequestBuilderTests` pins structural behavior at the prompt-part level, and greeting_ru tests rely on sentence-start capitalisation rules (not in this 4-fixture subset). Keep core rules, drop prose. |
| 9 | `# Using on-screen context` | 4 089 | **-229** | 2 / 2 | unchanged | still normalised | **Not measurable** — eval has no AX-tree / OCR fixtures. Keep until added. |
| 10 | `# User dictionary` | 3 963 | **-355** | 2 / 2 | unchanged | still normalised | **Not measurable** — eval fixtures use empty dictionary. Keep until dictionary fixture added; ADR-016 commitment. |
| 11 | `# Category` | 4 190 | **-128** | 2 / 2 | unchanged | still normalised | **Trim heavily** — short paragraph; routing is just label-→-format, can compress to one sentence. |
| 12 | `# User instruction` | 4 208 | **-110** | 2 / 2 | unchanged | still normalised | **Not measurable** — eval doesn't exercise non-empty userInstruction. Keep until added. |
| 13 | `# Category instruction` | 4 257 | **-61** | 2 / 2 | unchanged | still normalised | **Not measurable** — eval doesn't exercise non-empty categoryInstruction. Keep until added. |

Aggregate per-section token saving if every "Trim" or "Drop" recommendation lands (rough upper bound): **~2 100 tokens**, taking the full prompt's system-instruction portion from ~3 030 → ~930 tokens, roughly matching lite-prompt density. **~50% trim ceiling** on the measurable-by-current-eval portion.

#### Lite prompt (`systemPromptLite`) — 8 sections

| # | Section | Tokens (lite prompt avg) | Δ vs baseline (~1012) | Passed / Failed (of 3) | Recommendation |
|---|---|---:|---:|---:|---|
| L1 | Intro paragraph | 954 | **-58** | 3 / 0 | **Drop** — no measurable effect |
| L2 | `# Sections you receive` | 898 | **-114** | 3 / 0 | **Drop** — labels referenced individually |
| L3 | `# Output contract` | 925 | **-87** | 3 / 0 | **Trim** — short but not load-bearing on subset |
| L4 | `# Audio is the ONLY source of words` | 797 | **-215 (biggest)** | 3 / 0 | **Trim heavily** — biggest single section, no measurable effect on subset. But this is the lite mirror of full's #5; same coverage caveat applies. |
| L5 | `# Cleanup — strict whitelist` | 930 | **-82** | 3 / 0 | **Trim** |
| L6 | `# Insertion target` | 821 | **-191** | 3 / 0 | **Trim** — keep core rules, drop prose |
| L7 | `# User dictionary` | 944 | **-68** | 3 / 0 | **Not measurable** (empty-dict fixtures) |
| L8 | `# Category + instructions` | 933 | **-79** | 2 / 1 | **Trim** — only section whose removal broke a test (`single_word_ambiguous` → `"VorbiTech"`, edge case). Maybe keeping a short version helps phonetic robustness. |

Aggregate trim ceiling for lite prompt: **~600 tokens** (the prompt is already trimmed; remaining sections are mostly load-bearing-or-unmeasured). **~60% trim ceiling.**

### Eval coverage gaps (CRITICAL caveat)

The current eval's 9 fixtures exercise:

✅ Single-chunk full path · Single-chunk lite path · Verbatim length floor on EN/DE/ES/RU · Sentence-start capitalisation via insertion target · Adversarial imperative ignoring · Code-switch preservation · Phonetic faithfulness · Silence handling · Number normalisation

❌ NOT exercised:

- **Multi-chunk batched mode** — no test sends > 1 audio chunk in a session. Sections #7 (punctuation across chunk boundaries) untestable.
- **AX-tree context leakage** — all fixtures use empty `RedactedAXSnapshot`. Section #9 untestable.
- **OCR sub-block** — all fixtures use nil `RedactedScreenText`. Part of section #9 untestable.
- **Non-empty user dictionary** — all fixtures use `dictionary: []`. Section #10 / L7 untestable.
- **Non-empty user instruction** — all fixtures use empty `userInstruction`. Section #12 untestable.
- **Non-empty category instruction** for non-uncategorized — `messaging` is used but `categoryInstruction` is the *default* prompt. Section #13 partially testable, mostly untested.
- **Prior chunks context leakage** — single-chunk fixtures only. Anti-leakage rule for `Prior chunks (this session)` untestable.

**The 6 sections marked "Not measurable" above are not safe to drop until eval fixtures exercise their failure modes.**

### Recommended action plan for U3

Tier 1 — **trim aggressively**, eval defends:
- Intro paragraph (#1, L1) — drop to one terse sentence or remove
- `# Sections you will receive` (#3, L2) — drop entirely; labels live with their own sections
- `# How a session works` (#2) — compress to 2-3 lines about chunk/batch mode if multi-chunk eval lands, else drop
- `# Category` (#11) — compress to one sentence about register

Tier 2 — **trim carefully**, eval is partial:
- `# Output contract` (#4, L3) — KEEP but compress; only measurable shorten-influence on output
- `# Cleanup — strict whitelist` (#6, L5) — compress; doesn't prevent number normalisation but discourages other overreach
- `# Insertion target` (#8, L6) — keep core rules tight, drop prose; tests rely on structural pins
- `# Context is never a source of words` (#5) / `# Audio is the ONLY source of words` (L4) — biggest sections; trim significantly but DON'T remove until eval adds AX / OCR / dictionary fixtures

Tier 3 — **defer until eval expands**:
- `# Punctuation across chunk boundaries` (#7) — add multi-chunk fixture, then audit
- `# Using on-screen context` (#9) — add AX + OCR fixtures, then audit
- `# User dictionary` (#10, L7) — add non-empty-dict fixture, then audit
- `# User instruction` (#12), `# Category instruction` (#13, L8) — add fixtures with non-default instructions, then audit

Tier 4 — **NEEDS NEW INTERVENTION** (not in any section's removal experiment):
- ⚠️ **Number normalisation.** Model normalises `sixteen` → `16` despite cleanup-whitelist rule, and removing the rule doesn't change behavior. Hypothesis: needs an explicit positive rule like `"if the speaker pronounced a number as a word, output the word — do not convert to digits"` in either per-call instruction or as a structural constraint.

The number-normalisation fix goes through `prompt-master` in U3.

**Silence handling is *not* in Tier 4.** Per NoType's VAD + min-chunk-size pipeline (see `NoType/Recording/CLAUDE.md`), silence-only chunks never reach Gemini in production — they're filtered before the chunk builder. The `silence_only` fixture stays in the eval as a robustness probe (defence-in-depth for hypothetical VAD failure modes), but designing new prompt scaffolding for silence handling would optimise for a case that doesn't ship.

## Why This Matters

Three concrete answers to the user's question:

1. **Yes, the prompt is currently over-engineered for what the eval can prove.** Removing any single section doesn't measurably change behaviour on 13 of 15 passing fixtures. Approximately 50-60% of the system-instruction tokens are not earning their cost against the eval suite as currently configured.

2. **The 2 failing fixtures (silence, numbers) aren't defended by ANY section.** Scaffolding language *describing* the rule isn't enforcing it. Only the number-normalisation case is a real production concern; silence is filtered out by VAD before it reaches Gemini.

3. **But eval coverage is incomplete.** The prompt sections most likely to be defending real production failure modes — context leakage from AX trees, OCR, dictionaries, multi-chunk behavior — aren't testable with current fixtures. Trimming those without first expanding the eval is risky.

The right U3 sequencing:
- Apply Tier 1 trims (safe — eval defends)
- Apply Tier 2 trims via `prompt-master` (compress, don't delete)
- Add new fixtures for Tier 3 sections, then audit those
- Design Tier 4 interventions via `prompt-master` for the two known failures

## When to Apply

Re-run this audit:

1. After `gemini-3.1-flash-lite` snapshot upgrade — section behaviour can shift; refresh deltas.
2. After U3 ships — confirm trims didn't introduce regressions; populate `usageTokensCeiling` in fixture JSON from the post-trim baseline.
3. After eval expansion (Tier 3 enablers) — re-score the previously-unmeasured sections.
4. Whenever someone proposes adding a new section to either prompt — score it as part of the addition.

## Examples

### Raw per-section experiment logs

All experiment logs persisted under `/tmp/exp_*.log` from the audit run on 2026-05-17. Reproduce via:

```bash
bash /tmp/audit_runner.sh
column -t -s, /tmp/audit_results.csv
```

The runner script applies one `sed Nd` per section, runs the fixture subset, parses, and restores via `git restore` before the next iteration.

### Silence hallucination variety across removals

The model invents different sentences from silence depending on which section is missing — but always hallucinates *something*:

- baseline: `"Hello, how are you?"`
- without intro: `"Hello world."`
- without `# How a session works`: `"Hello, how are you doing today?"`
- without `# Output contract`: `"Hello."` (shortest — section influenced length norms)
- without `# Context is never a source of words`: `"Hello, how are you doing today?"`
- without `# Cleanup`: `"Hello world."`

This is the strongest piece of evidence that **silence handling needs a different intervention than more prose**.

## Related

- Plan: `docs/plans/2026-05-17-001-refactor-gemini-prompt-audit-and-trim-plan.md`
- Module: `NoType/Gemini/GeminiClient.swift` + `NoType/Gemini/CLAUDE.md`
- Test contract: `NoTypeTests/GeminiRequestBuilderTests.swift` (structural pins) + `NoTypeTests/PromptEvalTests.swift` (behavioural baseline).
- ADR-003 (model choice + implicit caching): `docs/solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md`
- ADR-016 (User dictionary cache-prefix section): `docs/solutions/architecture-patterns/personal-dictionary-2026-05-15.md`
