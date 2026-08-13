---
title: Adaptive pause threshold — let VAD pause-detection sensitivity scale with chunk length
date: 2026-05-16
category: design-patterns
module: Recording
problem_type: design_pattern
component: tooling
severity: medium
applies_when:
  - Slicing a continuous audio stream into chunks for a network transcription API
  - Designing a VAD-driven pause detector that must balance accuracy against network latency
  - Believing chunk size is what a request's timeout budget scales with (see the 2026-08-13 correction below — it was the part count)
  - Choosing between "fixed pause threshold + hard force-cut" and "adaptive threshold"
tags: [vad, silero, pause-detection, chunking, transcription, gemini, adaptive, threshold]
---

# Adaptive pause threshold — let VAD pause-detection sensitivity scale with chunk length

## Context

*(This section describes the state before PR #38, which is the problem this decision was made against. The force-cut is 180 s today.)*

NoType records push-to-talk audio and sends chunked AAC blobs to Gemini for transcription. Where a chunk ends is decided by VAD-driven pause detection: when Silero reports ≥N consecutive unvoiced frames, emit a chunk boundary. A fixed pause threshold of 1.0 s catches end-of-thought pauses cleanly for short utterances, but loses gracefully on long monologues — a user dictating an email for two minutes typically pauses ~300–700 ms to inhale, never the full 1 s, so the detector holds the chunk open until a 30 s hard force-cut chops it mid-sentence. The mid-sentence cut shows up as a duplicated word at the seam (300 ms pre-roll overlap) and an awkward space when the model can't tell whether the chunk-internal silence was end-of-clause or breath.

~~Underneath, there's also a network-budget constraint: Gemini's `URLSessionConfiguration.timeoutIntervalForResource` caps the whole request. Past a chunk size of ~40 s of audio, the upload + Gemini wall-clock starts pressing on a 30 s timeout. Long chunks aren't just an artefact problem; they're a network reliability problem too.~~

**Superseded 2026-08-13 — the second constraint was real but mis-attributed.** A controlled measurement against the live API found that request latency tracks the **number of audio parts** in the request, not the audio's duration and not its byte size: a 4-part batch (159 s of audio, 653 KB) took ~4× a single-part 180 s force-cut (735 KB) — 26.85 s against 7.62 s idle. So a *longer chunk* is not what presses on the budget; a *batch of chunks in one call* is. The per-request inactivity budget now scales on that axis (`GeminiClient.requestInactivityBudget(audioPartCount:)`), while the whole-transfer `resourceCeiling` stays a single flat value sized for the largest request that budget will ever serve — it moved, but it does not scale. The flat 30 s ceiling this paragraph reasoned against is retired — it had in fact been silently killing legitimate 5-part batches. The ladder below survives on its audio-quality merits alone.

The naive fix — drop the pause threshold globally — destroys short-utterance behaviour. A 500 ms threshold catches normal inter-phrase pauses ("так… значит…") and cuts mid-sentence. Different chunk lengths need different sensitivity.

## Guidance

**Let the pause threshold decrease as the chunk gets longer.** Short chunks demand confident "end of thought" pauses (1 s) before cutting. Long chunks accept any breath (500 ms) as a cut signal — by that point, the user is clearly monologuing and breath inhales are the only seams we'll get.

```swift
/// Effective pause threshold for the current chunk, given how many
/// samples its voiced span has accumulated so far.
func pauseThresholdSamples(forChunkLength chunkLength: Int) -> Int {
    switch chunkLength {
    case ..<320_000:    return pauseThresholdSamples  // <20 s → base (1000 ms)
    case ..<640_000:    return 11_200                 // 20–40 s → 700 ms
    default:            return 8_000                  // ≥40 s → 500 ms (floor)
    }
}
```

Three rungs, three constants. The ladder is intentionally coarse (not a continuous function) — predictable, easy to unit-test, easy to debug "why did it cut there."

**500 ms is the floor on purpose.** Below ~300 ms the threshold starts catching stop-consonant closures ("t", "p", "k" hold ~80–150 ms of silence before the burst) and inter-phrase micropauses, which would shred normal speech mid-word. 500 ms cleanly separates a breath from a comma-pause.

**Keep a hard force-cut as the ultimate safety net**, well above any rung — in NoType, 180 s. The ladder will catch any realistic monologue long before this fires, but a wedged VAD or pathologically continuous audio still gets a bounded chunk.

## Why This Matters

- **Chunk size is dual-constrained.** Adaptive thresholds let the same code path serve short utterances (1 s pause for clean cuts) and long monologues (500 ms pause to find breath seams) without either degrading.
- ~~**Network ceiling drives ladder shape.**~~ **Retired 2026-08-13 — the ladder is an audio-quality decision, and only that.** The boundaries (20 s, 40 s, 500 ms floor) were originally justified as keeping the *resulting* chunks inside a flat 30 s `timeoutIntervalForResource`. The measurement above shows a shorter chunk buys no network headroom at all — a single-part request costs about the same whether it carries 20 s or 180 s of audio (7.62 s idle for the 180 s force-cut). What costs time is how many parts one call carries, which is the sender's batching, not this detector's. Keep the ladder for the reason that survives: it cuts on breath seams instead of mid-sentence. Do not re-derive its rungs from a network timeout.
- **A hard force-cut alone is brittle.** With a fixed 1 s threshold and a 30 s force-cut, long-form dictation hits the cut every time, producing pre-roll-overlap dupes and seam pauses the model has to guess at. With the ladder, force-cut is a true safety net — it fires only if VAD pause detection itself wedges.
- **Predictable beats clever.** Three discrete rungs are easier to test, easier to reason about under code review, and produce a clear story when debugging ("the chunk hit the 700 ms rung at 26 s, then a 768 ms pause cut it"). A continuous function (e.g., exponential decay) would be marginally smoother but much harder to debug.

## When to Apply

- VAD-driven chunked transcription where **chunk quality** is what the rungs are tuned for. (This bullet used to read "…with a network timeout ceiling on each request — the network budget anchors the ladder's upper rungs", which is the claim the 2026-08-13 measurement retired two sections above. Measure before you anchor a ladder to a network budget: here the budget turned out to track the *number of parts per request*, not the length of any one chunk, so it anchors the sender's batching instead.)
- Any pause-detection scheme where short-utterance and long-utterance regimes need different sensitivity. (Spoken-form streaming, voice memos, lecture transcription.)
- **Reconsider** if the transcription model's processing time scales non-linearly with audio length — the ladder assumes roughly linear processing per second of audio. A model with worst-case 10× slowdown on long inputs needs more aggressive cutting earlier.
- **Don't apply** to live-streaming pipelines where the consumer must see partial transcripts as they happen — that's a different design (sub-chunk streaming, server-side VAD). The ladder only makes sense when chunks are atomic units shipped at boundaries.

## Examples

**Before (fixed threshold + 30 s force-cut, NoType pre-PR #38):**

```swift
init(
    pauseThresholdSamples: Int = 16_000,    // 1.0 s — always
    maxChunkSamples: Int = 480_000          // 30 s force-cut
)
```

Long monologue → no natural ≥1 s pause for 30 s → force-cut at 30 s mid-word → "I was going go" + "ing to the store" with duplicated "go-go" at the seam.

**After (3-rung ladder + 180 s force-cut, NoType post-PR #38):**

```swift
init(
    pauseThresholdSamples: Int = 16_000,    // 1.0 s — base / short-chunk
    maxChunkSamples: Int = 2_880_000        // 180 s safety net
)

func pauseThresholdSamples(forChunkLength chunkLength: Int) -> Int {
    switch chunkLength {
    case ..<320_000:    return pauseThresholdSamples         // <20 s → 1000 ms
    case ..<640_000:    return 11_200                        // 20–40 s → 700 ms
    default:            return 8_000                         // ≥40 s → 500 ms
    }
}
```

Long monologue → after 20 s, threshold drops to 700 ms → user takes a 768 ms breath at 26 s → clean cut at the inhale. Force-cut at 180 s exists but realistically never fires.

**Trade-off accepted:** A short utterance with a long internal pause (e.g., "так… [800 ms thought] …что ты думаешь?" at 22 s of voiced audio) will get cut once the chunk crosses 20 s, even though the user wasn't done. The threshold drops to 700 ms; 800 ms exceeds it. Two chunks instead of one. Acceptable: the local-concat-and-stitch path on the client side reassembles them with a single space. (The original wording added "and the chunks are still under 30 s each", which read the split as a network win — under the 2026-08-13 part-count finding it is mildly the opposite, since two chunks can end up as two parts of one batched call. Still acceptable, but on stitching quality alone.)

## Related

- [architecture-patterns/serial-gemini-actor-2026-05-15.md](../architecture-patterns/serial-gemini-actor-2026-05-15.md) — the serial scheduler that ships these chunks; the ladder feeds it.
- [tooling-decisions/silero-vad-coreml-2026-05-15.md](../tooling-decisions/silero-vad-coreml-2026-05-15.md) — the VAD model that produces the per-frame probabilities the detector consumes.
- [tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md](../tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md) — the transcription model these chunks are sent to. Its request budgets no longer anchor the ladder; see the retired bullet above and `NoType/Gemini/CLAUDE.md` "Request budgets".
- [design-patterns/local-chunk-concatenation-2026-05-15.md](local-chunk-concatenation-2026-05-15.md) — the client-side stitching that absorbs the ladder's "cut a hair early" trade-off.
- `NoType/Recording/PauseDetector.swift` `pauseThresholdSamples(forChunkLength:)` — the implementation.
- `NoType/Recording/CLAUDE.md` invariant 4 — the ladder pinned as a module invariant.
- PR #38 — the change that introduced the ladder.
