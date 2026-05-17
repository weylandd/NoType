---
title: "refactor: Audit and trim Gemini transcription prompts (full + lite)"
type: refactor
status: active
created: 2026-05-17
depth: standard
posture: audit-driven-trim
---

# Summary

NoType's two transcription system prompts have accreted over many product decisions:

- `systemPrompt` (`NoType/Gemini/GeminiClient.swift:821-975`) — ~3 500 words / ~5 k tokens, served on the full path (any session with mid-session chunks OR audio ≥ 2 s).
- `systemPromptLite` (`NoType/Gemini/GeminiClient.swift:990-1035`) — ~600 words / ~900 tokens, served on the short-utterance path (single chunk, no priors, < 2 s).

The user's read is that the full prompt is overkill for what is, at the contract level, "transcribe this audio verbatim". This plan is an **evidence-based audit + trim** of both prompts. Every section gets scored on what it earns vs. what it costs in tokens. Trims are applied in this plan, not deferred — but only to sections the eval harness proves can be cut without regressing transcription quality.

A single regression fixture covers the *"Привет, как дела?"* case the user observed on another machine. If that fixture fails today, the audit gets a real failure mode to defend against — but no preemptive "anti-conversational reply" clause is added unless the fixture actually reproduces the failure.

---

# Problem Frame

**Why the prompts got this big.** Each anti-hallucination scaffold in `systemPrompt` was added for a specific reason: context-leakage from `Insertion target` / `On-screen context` / `Prior chunks` / `User dictionary`, autoregressive completion ("smoothing" the end of a phrase), cleanup overreach (model summarising or rewording). The forbidden-failure-modes list under `# Context is never a source of words` is the heaviest single block.

**Why the prompts may be over-built today.** A few reasons that are worth checking empirically before any trim:

1. **Redundancy across sections.** The "audio is the ground truth" / "you are not an assistant" / "never extend or smooth" themes are repeated in several sections. Some repetition is intentional reinforcement; some may be cargo.
2. **Implicit caching changes the cost shape.** The first chunk of each session pays the full prompt; subsequent chunks pay ~10 % (ADR-003). So prompt size mostly affects **first-chunk latency**, not steady-state cost. Trim value is in time-to-first-paste.
3. **Sections may be defended by tests that don't actually test their effect on output.** `GeminiRequestBuilderTests` (38 tests) pins **structure** (order, labels, presence) and a couple of **anchor phrases**, but does NOT measure transcription quality on real audio. A section could be "covered" by tests and still earn nothing.
4. **Lite prompt was already trimmed** but never measured against the full prompt on shared fixtures. May be cuttable further OR may need something back.

---

# Scope Boundaries

**In scope**

- Building a small offline eval harness for both prompts (audio fixtures + assertions).
- Recording 5–8 audio fixtures (user provides voice; plan ships ingestion recipe and metadata schema).
- Section-by-section audit of `systemPrompt` AND `systemPromptLite` via `prompt-master`.
- Applying trims in this plan — one commit per section.
- Updating `GeminiRequestBuilderTests` deliberately where the prompt contract changes.
- Updating `NoType/Gemini/CLAUDE.md` and adding an audit-methodology entry under `docs/solutions/`.

**Out of scope (this product / this plan)**

- Migrating off `gemini-3.1-flash-lite` (ADR-003).
- Changing user-message part order / labels (invariant I3).
- Changing `shouldUseLitePath` discriminator.
- Streaming responses (ADR-007).
- VAD / chunking / pause-detector changes.
- Auto-adding any anti-conversational-reply clause **unless** the regression fixture proves it's needed.

### Deferred to Follow-Up Work

- Multilingual fixture coverage beyond what's recorded in U1 (additional languages, accents, dialects).
- A live-API eval scheduled against multiple Gemini snapshots over time (regression net for model-side changes).
- Exposing VAD voiced-frame threshold in Settings.

---

# Key Technical Decisions

### KTD-1. `prompt-master` is mandatory for every prompt edit

Any change to `systemPrompt`, `systemPromptLite`, `categorizerPrompt`, or the per-call instruction templates (`midChunkInstruction`, `finalChunkInstruction`, `batchedChunkInstruction`, `liteChunkInstruction`) goes through the `prompt-master` skill — either via direct invocation, or via inline application of its rubric when single-prompt-output mode doesn't fit (e.g. when audit recommendations apply to multiple insertion points). Pure deletions skip the skill but still record rationale. Hand-edited prompts without skill involvement are rejected at commit time. Rationale: the existing prompts exist *because* unscaffolded ad-hoc edits produced hallucinations the project then had to defend against; the skill's rubric is the safety net.

### KTD-2. The eval harness is the trim safety net

A section is a candidate for trim only if removing or rewording it leaves all of the following intact across the eval suite (U1):

- Verbatim length floor on multi-sentence fixtures in EN and DE (the DE fixture additionally exercises the noun-capitalisation contract — model must keep `Dokument` / `Struktur` / `Einleitung` capitalised).
- Insertion-target capitalisation / leading-space behaviour.
- Empty / silence-only / single-word fixtures produce expected outputs (empty string for silence, single-word phonetic for ambiguous).
- The *"Привет, как дела?"* regression fixture (U4) produces the verbatim question, not an answer.
- All 38 existing `GeminiRequestBuilderTests` still pass (or get an explicit, reviewer-acknowledged update).

If a trim breaks any of these, the section earned its tokens and stays. **Token reduction is reported, not optimised against** — the goal is "honest accounting of what each section buys you", not a percentage target.

### KTD-3. Cache-prefix shape is immutable

User-message part order, labels, and empty-state rendering (`(none yet)`, `(empty)`, empty quoted strings) stay byte-stable per invariant I3. Trims happen *inside* the system instruction and *inside* each part's body — never to the part list itself.

### KTD-4. Lite prompt audited on the same rubric, not by symmetry

The lite prompt is not treated as "trimmed full prompt" — it's a separate artifact with its own audit. Some sections may end up *expanded* in lite if the audit shows the trim went too far; others may be cut further. Symmetry with the full prompt is not a goal.

### KTD-5. The "Привет, как дела?" fixture is regression, not motivation

The fixture is added to the eval suite. If it fails today's prompts, that's a real signal and U3 includes a `prompt-master`-driven clause add. If it passes today's prompts, it stays in the suite as forever-on regression coverage. **No preemptive clause** is added based on the user's recall of the incident — the user explicitly de-prioritised the bug after their second message.

---

# Implementation Units

### U1. Build offline eval harness + record audio fixtures

**Goal.** Deterministic test target that runs each recorded audio fixture through `GeminiClient.transcribe` / `.transcribeShort` and asserts substring + word-count + structural constraints on the result. Foundation for everything downstream.

**Requirements.** KTD-2 — the trim safety net.

**Dependencies.** None.

**Files.**

- `NoTypeTests/PromptEvalHarness.swift` *(new)* — helper around `GeminiClient` that records `{transcript, tokenUsage}` per fixture.
- `NoTypeTests/Fixtures/Audio/` *(new dir)* — m4a files, 16 kHz mono. 5–8 fixtures recorded by maintainer:
  - `greeting_ru.m4a` — "Привет, как дела?" short delivery (~1.07 s); naturally routes through the **lite** path in prod.
  - `greeting_ru_long.m4a` — same phrase, slower delivery (~2.43 s); naturally routes through the **full** path. This is the variant that matches the user's incident.
  - `multi_sentence_en.m4a` — 3–4 connected sentences, neutral content.
  - `multi_sentence_de.m4a` — 3–4 connected sentences in German; exercises noun-capitalisation contract (`Dokument`, `Struktur`, `Einleitung` must stay capitalised).
  - `code_switch_en_es.m4a` — Spanish + English mid-sentence switch with technical terms (`pull request`, `state machine`, `actor`) kept in English.
  - `single_word_ambiguous.m4a` — one made-up / unfamiliar token.
  - `silence_only.m4a` — 2 s of silence (sanity).
  - `please_summarize_en.m4a` — adversarial: imperative request directed at "you" ("Please summarise this paragraph").
  - `long_monologue_en.m4a` *(optional 8th)* — ~30 s monologue to exercise the verbatim length floor.
- `NoTypeTests/Fixtures/audio_fixtures.json` *(new)* — fixture metadata: filename, mime, duration (s), expected transcript (plain text), `mustContain: [...]`, `mustNotContain: [...]`, `wordCountFloor: N`, `usageTokensCeiling: N`.
- `NoTypeTests/Fixtures/README.md` *(new)* — recording recipe (QuickTime / `rec` → `ffmpeg -ac 1 -ar 16000 -c:a aac -b:a 64k`) so any maintainer can regenerate.
- `NoTypeTests/PromptEvalTests.swift` *(new)* — wraps the harness; gated by `NOTYPE_INTEGRATION=1` (same convention as existing live-API tests in `docs/build.md`).

**Approach.**

- Harness takes `(fixturePath, context, isFinal, pathHint)` and returns `(transcript, usage)`. `pathHint` lets a test force the full path on a short fixture by toggling `transcribe` vs. `transcribeShort` directly.
- Assertions are **substring + word-count floor**, never full equality — Gemini's punctuation varies between runs.
- Token-usage upper bound is enforced as an absolute ceiling per fixture. Reduces silently with trims; will *fail* if a future change accidentally bloats the prompt.
- `NOTYPE_INTEGRATION` unset → tests skip cleanly with `XCTSkip`. The standard `xcodebuild test` run is unchanged; the eval runs only when the env var is set.

**Patterns to follow.** `NoTypeTests/GeminiRequestBuilderTests.swift` for the `GeminiClient` direct-call pattern. Live-API gating per `docs/build.md` "Local development".

**Test scenarios.**

- Each fixture produces a non-empty transcript when not silence.
- `silence_only` produces empty string.
- `please_summarize_en` transcript contains the literal request, does NOT contain a summary.
- Token-usage ceiling enforced per fixture.
- `NOTYPE_INTEGRATION` unset → all tests skip; no live API calls.

**Verification.** `NOTYPE_INTEGRATION=1 xcodebuild test … -only-testing:NoTypeTests/PromptEvalTests` runs all fixtures, prints transcripts + token usage, no crashes. User confirms the recorded fixtures sound right.

---

### U2. Audit full + lite prompts section by section

**Goal.** Produce `docs/solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md` — for each section of each prompt: token cost, defending tests, removal-experiment outcome against U1's eval, recommended action.

**Requirements.** Evidence-based answer to "что можно убрать безболезненно".

**Dependencies.** U1.

**Files.**

- `docs/solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md` *(new)* — knowledge-track shape per `docs/solutions/README.md` (`## Context → ## Guidance → ## Why This Matters → ## When to Apply → ## Examples → ## Related`).
- No code changes in this unit.

**Approach.**

For each section of `systemPrompt` (intro, `# How a session works`, `# Sections you will receive (in this order)`, `# Output contract`, `# Context is never a source of words`, `# Cleanup — strict whitelist`, `# Punctuation across chunk boundaries`, `# Insertion target`, `# Using on-screen context`, `# User dictionary`, `# Category`, `# User instruction`, `# Category instruction`) and `systemPromptLite` (intro, `# Sections you receive`, `# Output contract`, `# Audio is the ONLY source of words`, `# Cleanup — strict whitelist`, `# Insertion target`, `# User dictionary`, `# Category + instructions`):

1. **Token cost** — measured via actual `usage.promptTokenCount` delta from a test run with the section blanked out.
2. **Defending tests** — string-search in `GeminiRequestBuilderTests.swift` for content the section anchors.
3. **Removal experiment** — temporarily blank the section in a throwaway branch; run U1's eval; record which fixtures' assertions broke and by how much (token saving on success, broken assertion count on failure).
4. **Recommendation:**
   - **Keep verbatim** — removal breaks ≥ 1 assertion.
   - **Trim** — section can be compressed without breaking assertions; sketch candidate wording (run through `prompt-master` in U3, not here).
   - **Split** — section combines two concerns; better separated.
   - **Move to per-call instruction** — content is per-request, not load-bearing across cache.

The audit doc is the deliverable. Removal-experiment branches are throwaway.

**Process gate.** `prompt-master`'s rubric (intent extraction → tool routing → output contract → hard rules) frames the per-section scoring. The skill itself is not invoked here (no new prompt text being generated); its checklist is applied as a scoring framework.

**Patterns to follow.** Knowledge-track shape per `docs/solutions/README.md`. Existing solution entries under `docs/solutions/architecture-patterns/` for tone.

**Test scenarios.**

- Test expectation: none — documentation unit. Quality bar: reviewer reading the audit can tell, per section, what it earns and the recommended action.

**Verification.** Audit doc complete; per-section table + the eval-token deltas captured.

---

### U3. Apply trims that pass the eval

**Goal.** Implement the "trim" / "split" / "move" recommendations from U2. One commit per section.

**Requirements.** Actually reduce prompt size where evidence supports it.

**Dependencies.** U2.

**Files.**

- `NoType/Gemini/GeminiClient.swift` — `systemPrompt` and `systemPromptLite`.
- `NoTypeTests/GeminiRequestBuilderTests.swift` — test-pin updates per commit; new pin (if any) for any new anchor phrase introduced.
- `NoType/Gemini/CLAUDE.md` — refresh "any change to the system prompt" rule's pointers if needed; record the final token counts after all trims land.

**Approach.**

- Iterate section-by-section in the order from U2's recommendations (lowest-risk first).
- For each section:
  1. If trim introduces new wording → invoke `prompt-master` with target = `gemini-3.1-flash-lite`, intent = "compress this transcription system-prompt section; preserve [anchor X / guarantee Y]; output replacement text". Use skill's output verbatim.
  2. If trim is pure deletion → apply directly; commit message records "pure deletion, no `prompt-master` required".
  3. Run the full `GeminiRequestBuilderTests` + U1 eval. Both must be green.
  4. Update test pins deliberately if the contract changed; commit message calls out the pin update with the reviewer note "prompt contract changed — see audit doc section X".
  5. Commit.
- After all trims land, update U2's audit doc with the final token counts.

**Patterns to follow.** Conventional Commits per `docs/solutions/conventions/testing-spm-and-git-2026-05-15.md`. The "every prompt change requires explicit reviewer attention to `GeminiRequestBuilderTests`" hard rule in `NoType/Gemini/CLAUDE.md` is the contract.

**Test scenarios.**

- All 38 `GeminiRequestBuilderTests` pass after each commit (or have a reviewer-acknowledged pin update).
- U1 eval suite passes after each commit.
- *"Привет, как дела?"* fixture (U4) passes after each commit — including the first one that adds the fixture.

**Verification.** Final commit shows reduced token count vs. `main` for both prompts; full test suite green; audit doc updated with deltas.

---

### U4. Add the "Привет, как дела?" regression fixture

**Goal.** The user's incident case is captured as a fixture in the eval suite. The fixture is added *as-is* — no preemptive prompt change. If it fails the current prompts, U3's section work has a real signal to defend against. If it passes, it stays as forever-on regression coverage.

**Requirements.** KTD-5.

**Dependencies.** U1 (harness exists), no dependency on U2 / U3.

**Files.**

- `NoTypeTests/Fixtures/Audio/greeting_ru.m4a` — already listed in U1, recorded by maintainer.
- `NoTypeTests/Fixtures/audio_fixtures.json` — entry with `mustContain: ["привет", "как дела"]`, `mustNotContain: ["как ты", "хорошо", "i'm doing"]`, `wordCountFloor: 3`.
- `NoTypeTests/PromptEvalTests.swift` — test case covering this fixture across the matrix below.

**Approach.**

Test matrix is split across the two greeting variants — each goes through *its natural path only*, not both, so each test exercises the prompt path that would actually be served in production for that audio length:

- **`greeting_ru.m4a` (1.07 s) × lite path** (`transcribeShort`) × 2 insertion targets × 2 categories = 4 combinations.
- **`greeting_ru_long.m4a` (2.43 s) × full path** (`transcribe` with `isFinal=true`) × 2 insertion targets × 2 categories = 4 combinations.

Insertion targets: `(before: "", after: "")` AND `(before: "I just wanted to say ", after: "")`.
Categories: `uncategorized` AND `messaging` (chat-context bias amplifier).

8 combinations total. Each must produce the verbatim question, not a reply. The full-path arm is the **primary** test case — it matches the user's incident; the lite-path arm is supplementary coverage for the trimmed prompt.

**Process gate (conditional).** If any combination fails on today's prompts → U3 has a real failure mode to address, and the section work that introduces a new anchor phrase invokes `prompt-master` per KTD-1. If all 8 pass → no clause add; fixture stays as regression.

**Patterns to follow.** Matrix-style tests in `NoTypeTests/CategoryResolverTests.swift`.

**Test scenarios.**

- 8 combinations as above, each asserting `mustContain` + `mustNotContain`.
- (Optional sanity) one combination with a different unrelated fixture to confirm the matrix harness is general.

**Verification.** Tests run under `NOTYPE_INTEGRATION=1`. Outcome (all-pass vs. partial-fail) informs U3's section work and is recorded in U2's audit doc.

---

### U5. Update CLAUDE.md and add audit-methodology entry

**Goal.** Knowledge survives the PR — the audit's methodology and any new contract is durable.

**Requirements.** Compound-engineering practice.

**Dependencies.** U3.

**Files.**

- `NoType/Gemini/CLAUDE.md` — update `## Invariants` if U3 introduced a new anchor; refresh `## Cache-prefix shape` quick-ref if any inline content materially changed (labels remain invariant); record final token counts under a new `## Prompt sizing` mini-section.
- `docs/solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md` — finalised after U3 with the actual outcome per section.
- `docs/decisions.md` — append a line for the audit if any KTD graduated into a load-bearing decision.

**Approach.** Read U2's audit doc and U3's commit history; finalise the "before / after" comparison in `## Why This Matters`. If any clause was added (only if U4 forced it), add a separate `docs/solutions/design-patterns/...` entry for that learning.

**Patterns to follow.** Recent design-pattern / architecture-pattern entries under `docs/solutions/`.

**Test scenarios.**

- Test expectation: none — documentation unit.

**Verification.** Reviewer can read CLAUDE.md and the solutions entry, understand the rubric used, see the final token counts, and know which sections were kept verbatim and why.

---

# System-Wide Impact

- **First-chunk latency.** Most of the trim's user-visible benefit lands here — the full prompt is paid in full on the first chunk of each session (ADR-003). Subsequent chunks pay ~10 % thanks to implicit caching.
- **Cache contract.** User-message part order is byte-stable (invariant I3). System-instruction content changes; the system instruction has its own cache key, stable across all sessions for a given build.
- **Test contract.** `GeminiRequestBuilderTests` is the prompt contract per `NoType/Gemini/CLAUDE.md`. This plan touches it deliberately in U3 commits.
- **User-visible.** No new behaviour, no UI change. Strictly an internal-quality refactor.

---

# Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Trim regresses a hallucination class the eval doesn't cover | Medium | KTD-2; U2's removal experiments catch most; conservative posture keeps anything ambiguous. Tradeoff: some over-spending on tokens may persist. |
| Live-API integration tests are flaky | Medium | Gated by `NOTYPE_INTEGRATION=1`. Assertions are substring + word-count floor, not equality. Document flakiness budget in `NoTypeTests/Fixtures/README.md`. |
| Gemini model upgrade silently changes behaviour mid-plan | Low | Plan pins against `gemini-3.1-flash-lite` (ADR-003). U1 eval catches snapshot changes; audit becomes more valuable, not less. |
| Audio fixtures contain accidental PII or proper nouns | Low | Maintainer records own voice; neutral content only (`README.md` carries the rule). |
| `prompt-master` rubric overlaps oddly with NoType's existing prompt conventions | Low | Rubric is a scoring framework, not a replacement contract. KTD-3 keeps cache-prefix shape inviolable regardless of skill output. |

---

# Deferred Questions

- **Should we add `responseSchema` (structured output) to transcription requests?** Currently disabled per `NoType/Gemini/CLAUDE.md`. Could further constrain the chat-reflex class. Deferred — schema affects cache key, merits its own decision.
- **Lite-path threshold (< 2 s) — change it?** Out of scope per "Out of scope" bullet. Revisit after U2's audit if lite prompt turns out to be substantially better.
- **A second-layer post-processing filter** (e.g. "transcript shorter than audio + no overlap with audio fingerprint → reject")? Deferred — wait for eval data first.

---

# Origin

Generated from `/ce-plan /prompt-master` invocation on 2026-05-17. Two user clarifications during planning:
1. Incident audio was > 2 s → full path, not lite (was originally framed as a lite-path bug).
2. The incident is one unconfirmed sample, not a confirmed bug — plan should be **audit-centred**, not bug-centred. The fixture stays as regression coverage only.
