---
name: hallucination-length-gate
description: Post-response length-proportional sanity check that drops Gemini transcripts when output is disproportionate to audio duration. Catches Gemini Lite's conversational-fallback hallucinations on short low-information audio (BT-HFP mic).
metadata:
  type: architecture-pattern
  date: 2026-05-20
---

## Context

Gemini 3.1 Flash-Lite sometimes ignores the system prompt's `# Output contract` clause that says "if the audio is entirely unintelligible, output an empty string. Never invent words." On ~1 s of low-information audio — a Russian word "проверка" recorded through a Bluetooth-HFP headset, where the mic delivers degraded acoustic information — the model has been observed to emit a conversational fallback: `"Can you help me with this?"`. This is the same archetype as the documented `silence_only` fixture's `"Hello, how are you?"` hallucination from 2 s of pure silence (see `gemini-prompt-section-audit-2026-05-17.md`).

These fallbacks are not transcripts. They are LLM dialog-completion patterns the model defaults to when the audio encoder produces too few useful tokens. The system prompt explicitly forbids them and the eval suite (`PromptEvalTests.test_silenceOnly_full`, `unintelligible_ru_short`) tracks the regression at the model layer, but production users cannot wait for the prompt-level fix.

The Voice Activity Detection layer (Silero + 150 ms `pcm.count < 2_400` minimum chunk filter — see `Recording/CLAUDE.md` invariants 2 + 7) is the first defence. It rejects sub-150 ms accidental taps but cannot tell a degraded BT-HFP "проверка" from a legitimate one-word utterance. We need a second, complementary filter.

## Guidance

`NoType/Recording/HallucinationLengthGate.swift` runs after every successful Gemini call inside `RecordingSession.processBatch` and `splitRetry`. It is a pure function — no I/O, no state, no Gemini round-trip. It drops the transcript (returns `""`) iff **both** dimensions exceed plausible dictation rates for the audio duration:

```
maxWords = max(floorWords, ceil(durationSec * maxWordsPerSecond))  // 4 + 4 wps
maxChars = max(floorChars, ceil(durationSec * maxCharsPerSecond))  // 18 + 18 cps
isHallucination = wordCount > maxWords AND charCount > maxChars
```

Thresholds, from public speech-rate data:

| Constant | Value | Rationale |
|---|---|---|
| `maxWordsPerSecond` | 4.0 | 240 wpm — above "very fast" conversational rate (200 wpm); below auctioneer / fast-rap (250+). Real dictation runs 2–3 wps. |
| `maxCharsPerSecond` | 18.0 | Headroom for Russian (longer average word length than English) and Gemini's punctuation variability. `greeting_ru` ("Привет, как дела?", 17 chars / 1.07 s ≈ 15.89 cps) passes. |
| `floorWords` | 4 | Even on sub-1 s audio, allow 4 words. Single short utterances must pass. |
| `floorChars` | 18 | Same floor logic for chars. |

AND-mode (both ceilings must trip) is load-bearing. OR-mode would catch `"Привет, как дела?"` on the char dimension when the chunk lands at 1.07 s. AND-mode keeps borderline-dense legitimate utterances alive while still catching `"Can you help me with this?"` (6 w / 26 c on 1 s — trips both). The trade-off is that 2-word giant hallucinations (`"What did you say?"` 4 w / 18 c) sit at the floor and slip through; that's accepted scope.

The gate-dropped transcript is stored as `text: ""` (not `nil`) in `ChunkResponse`. This is a deliberate **third state** beyond the documented partial-recovery contract:

| `text` | Source | `summary.hasFailures` | Stitch behaviour | Stored as | Makes the row broken? |
|---|---|---|---|---|---|
| `"<real text>"` | Gemini, gate passed | none | concatenated normally | a text segment | no |
| `nil` | Recoverable Gemini failure | `+1` | `[…]` failure marker, "Pasted with gaps" HUD | a **gap** segment | **yes** |
| `""` | Gate fired on disproportionate length | none | stitched as empty, no marker | a text segment holding `""` | no |

**The last two columns are the reason this table survived into storage.** A history row stores the session's response sequence rather than its pasted string, and the same three states carry across: `nil` is the only one that is a gap. A gate-dropped chunk is stored as `text: ""` — *text*, not a gap (R27 of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`) — because Gemini answered and the client filtered the answer, so it makes no row broken (R19), offers no retry, and retains no audio.

The subtlety worth carrying: a real session can hold **both** at once — one chunk failed recoverably and another was gate-dropped — and that row pastes `[…]`, takes the success arm, and is counted in lifetime statistics. Reading `""` as "carries nothing" would classify it as the never-counted row and double-count it the moment its gap recovered. `HistoryEntry.isEntirelyLost` is written as "every segment is a gap" for exactly that reason; its doc-comment names this row.

In a single-chunk session, the stitched output becomes `""` → `stop()` throws `SessionError.noSpeech` → standard "no speech" Error HUD. In a multi-chunk session, the gate-dropped chunk contributes nothing to the stitch — by design, since the gate's verdict is "this is hallucination noise, not real speech". `currentPriors()` filters `""` out alongside `nil`, so the gate-emptied response doesn't disqualify a subsequent short chunk from the lite path.

## Why This Matters

Without the gate, the user's reported bug is the user experience: hold push-to-talk, say "проверка" through a Bluetooth headset, get the surprise paste `"Can you help me with this?"` in whatever app the cursor is in. There is no prompt-level fix shipping in this release. The gate provides the safety net.

The mitigation is per design only effective on the lite-path and single-chunk paths where the gate sees one chunk's text against one chunk's duration. For batched multi-chunk calls (mid-session, after a successful first chunk), `batchSamples = encoded.reduce(0) { $0 + $1.samples }` sums durations across N chunks; a 3-chunk batch of 20 s each gives a 60 s budget → 240-word / 1080-char ceiling, well above anything Gemini emits. The gate is by-construction less effective on batched calls. This is a known limitation; the reported user case is lite-path which is fully protected.

## When to Apply

Use this pattern when:

- An external model violates a contract specified in its system prompt and you have client-side signal that the output is implausible.
- The implausibility check is **cheap** (pure function, no second round-trip).
- The check has a **conservative bias** — false positives (legitimate output dropped) are tolerable because the user re-records.
- An exact-list approach (matching specific hallucinated phrases) doesn't scale — the failure mode emits *a class* of fallback patterns across languages.

Do NOT use this pattern when:

- The threshold could be gamed by adversarial users to suppress legitimate output (NoType is single-user, no such concern).
- Hallucinations are within plausible speech rates (this gate doesn't catch `silence_only`'s `"Hello, how are you?"` — 4 w / 19 c on 2 s of silence is normal dictation rate. Use audio-energy or VAD-confidence gates for silence-class.).
- The cost of a single false positive is high (e.g. transcribing a single critical phrase). Push the threshold higher rather than removing the gate.

## Examples

| Input | Duration | Words / Chars | Word ceiling | Char ceiling | Gate |
|---|---|---|---|---|---|
| `"Привет, как дела?"` (greeting_ru) | 1.07 s | 3 / 17 | 5 | 20 | **passes** ✓ |
| `"I just finished reviewing the document. The structure looks solid…"` (multi_sentence_en) | 10 s | 24 / ~140 | 40 | 180 | **passes** ✓ |
| `"Hello, how are you?"` (silence_only) | 2.0 s | 4 / 19 | 8 | 36 | **passes** (out-of-scope; not over-production) |
| `"Can you help me with this?"` (проверка reproduction) | 1.0 s | 6 / 26 | 4 | 18 | **drops** ✓ |

## Related

- Partial-recovery contract (`text: nil` markers, "Pasted with gaps" HUD): [partial-recovery-with-markers-2026-05-16](../architecture-patterns/partial-recovery-with-markers-2026-05-16.md)
- Lite-path discriminator (the path where the gate is most effective): [`NoType/Recording/CLAUDE.md`](../../../NoType/Recording/CLAUDE.md) invariant 11
- Silence-class hallucination tracking (the prompt-layer regression this gate doesn't catch): [gemini-prompt-section-audit-2026-05-17](../architecture-patterns/gemini-prompt-section-audit-2026-05-17.md)
- Adaptive pause threshold (sibling rate-shaped constant ladder): [adaptive-pause-threshold-2026-05-16](../design-patterns/adaptive-pause-threshold-2026-05-16.md)
- Implementing PR: [weylandd/NoType#63](https://github.com/weylandd/NoType/pull/63)
