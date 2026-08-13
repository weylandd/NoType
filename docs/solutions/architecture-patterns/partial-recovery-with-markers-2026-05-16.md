---
title: Partial recovery — gap markers instead of all-or-nothing on Gemini failure
date: 2026-05-16
last_updated: 2026-08-13
category: architecture-patterns
module: Recording
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - Touching `RecordingSession`'s error-handling path
  - Considering whether to extend / contract the terminal-vs-recoverable classifier
  - Auditing "lost transcript" user reports
tags: [error-handling, partial-recovery, gemini, session, marker]
---

# Partial recovery — gap markers instead of all-or-nothing on Gemini failure

## Context

Before PR #39, one Gemini call failing mid-session threw out of `RecordingSession.stop()` and the user lost their entire monologue. Especially painful after PR #38 raised the force-cut to 180 s and the adaptive-pause threshold to step down at 20 s — a 3-minute dictation that produced 6–10 chunks could vanish on a single transient network blip.

Wispr Flow / Monologue / other dictation apps don't expose how they handle this; whatever the user pasted is whatever they pasted, with no mention of partial state. NoType's lever is different: we own the paste, so we can be honest about gaps rather than pretending the session went perfectly when it didn't.

## Guidance

Track per-call outcomes (`ChunkResponse { chunkIndices, text: String? }` — `nil` text means the call failed) and stitch at `stop()` with `text ?? failureMarker` per response. The constant marker is `"[…]"` (single horizontal-ellipsis character in square brackets), declared as `RecordingSession.failureMarker`.

`ChunkResponse.text` has gained a third state since this doc was written: `""` (empty string), used by [`HallucinationLengthGate`](hallucination-length-gate-2026-05-20.md) to drop a Gemini response whose word/char rate exceeded plausible dictation speed for the audio duration. An empty-string entry is deliberately not a recovery failure — Gemini answered, the client filtered the output as noise — so `summary.hasFailures` does NOT count it, no `[…]` marker is stitched, and `currentPriors()` filters `""` alongside `nil`. The two-state-vs-three-state distinction matters: `nil` is "the API didn't return for us", `""` is "the API returned but we decided to discard it".

**That three-state table is now carried onto disk unchanged**, which is what makes it worth stating twice. A `ChunkResponse` becomes a `HistoryEntry.Segment` with the same three states — real text, `nil` for a gap, `""` for a gate-drop — so the distinction has to survive storage, not just stitching. `nil` is the only one that makes a row broken (`isBroken`), the only one a retry can write into, and the only one whose audio is retained; `""` is **text** for every one of those questions, because Gemini answered and the client filtered the answer. Reading `""` as "carries nothing" is the specific mistake that double-counts a recovered session's lifetime statistics — see `HistoryEntry.isEntirelyLost`'s doc-comment for the row that does it.

Classify errors via the pure static `RecordingSession.isTerminal(_:)`:

| Error | Class | Behaviour |
|---|---|---|
| `CancellationError` | terminal | abort, no paste |
| `GeminiError.missingKey` | terminal | abort, surface "add API key" |
| `GeminiError.blocked(_)` (prompt-level `blockReason` **or** candidate-level `finishReason` = SAFETY/RECITATION/PROHIBITED_CONTENT/BLOCKLIST/SPII/IMAGE_SAFETY) | terminal | abort, surface block reason |
| `GeminiError.http(401, _)` / `.http(403, _)` | terminal | abort, surface "API key rejected" — splitting won't help a revoked key |
| Any other `Error` (encoder, AVFAudio, etc) | terminal | abort, surface as-is |
| `GeminiError.http(0, _)` (network — wrapped URLError) | recoverable | marker, continue |
| `GeminiError.http(429, _)` (rate limit) | recoverable | marker, continue |
| `GeminiError.http(5xx, _)` | recoverable | marker, continue |
| `GeminiError.empty` | recoverable | marker, continue |
| `GeminiError.decoding(_)` | recoverable | marker, continue |
| `GeminiError.truncated` (`finishReason` = MAX_TOKENS) | recoverable | marker, continue |

`.truncated` and the candidate-level `.blocked` path both come from inspecting the response's `finishReason` (a response-parsing change only — the request shape and cache prefix are untouched). `.truncated` is a silently-cut partial: because NoType never sets `maxOutputTokens`, hitting the output cap on a dictation chunk means the model ran away (a hallucinated wall of text), not that the user genuinely spoke past the limit — so discarding the partial and gap-marking it is the correct recovery, and it gets no HTTP-level retry (an identical re-issue truncates identically). A candidate-level content block (`finishReason` = SAFETY/RECITATION/…) maps to `GeminiError.blocked` and is terminal, matching how a prompt-level `promptFeedback.blockReason` was already handled.

A batched call (`transcribeBatch`) failing recoverably triggers `splitRetry` — each chunk re-issued as an independent `transcribe`. Successful sub-calls become priors for the rest, so a network blip that resolved mid-batch lets later chunks recover with full context. A 250 ms inter-iteration backoff (`splitRetryBackoff`) caps burst rate at 4 sub-calls per second so sustained 429 / 5xx doesn't fire N×3 requests back-to-back.

Markers are never sent back to Gemini as priors — `currentPriors()` filters `responses` to `compactMap { $0.text }`. Sending markers would teach the model to emit them.

When *every* dispatched response failed, `stop()` throws `lastRecoverableError` instead of the generic `SessionError.noSpeech`. AppState's error catalog then surfaces the real cause (offline / 5xx / decoding) via the Error HUD.

`URLError` cancellation requires special handling: `URLSession` throws `URLError(.cancelled)` (code -999) when its parent Task is cancelled, NOT `CancellationError`. `GeminiClient.performOnce` translates this back to `CancellationError` before propagating, so the classifier sees the right type and `splitRetry` stops issuing requests against an already-cancelled session. Without that translation, the wrapped URLError would classify as recoverable and `splitRetry` would burn N sub-calls during cancellation.

Other URLError codes are wrapped as `GeminiError.http(0, "URLError code=N: …")` to preserve the retry-decider's uniform classifier surface. `AppState.payloadForSessionFailure` takes the wrapped body apart via `NetworkErrorTranslator.parse(_:)`, which returns the URLError code **and** the OS sentence beside it; the HUD is built from the sentence, never from the body (R17 of the dictation-delivery-reliability plan — the whole body used to reach the user's screen as a raw `URLError code=…` diagnostic). The parser format stays in lockstep with `performOnce`'s wrap format — both read the prefix off one shared constant — and `NetworkErrorTranslatorTests` pins the round-trip.

## Why This Matters

- **3-minute monologue safety.** Adaptive pause threshold + 180 s force-cut means real sessions are 6–10 chunks. Per-chunk reliability is ~99%; session reliability without partial recovery is ~94%. With markers it's effectively 100% (the user gets *something* back even if half the chunks failed).
- **Honesty over polish.** A pasted `[…]` is immediately legible to the user — they see exactly where the gap is and can re-dictate that piece. Silently dropping content (or polishing the gap away) would be worse: the user trusts what was pasted.
- **Terminal carve-out matters.** Without 401/403/blocked as terminal, a revoked key would burn 21 requests per session (1 batched × 3 retries + 6 split-retries × 3 retries each) before surfacing the auth failure. Fail fast on errors that won't fix themselves.
- **The serial-actor invariant survives.** `splitRetry` runs as a sequential `for await` loop inside `processBatch`'s task — still one in-flight Gemini call at a time. See `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`.
- **Markers don't poison priors.** `currentPriors()`'s `compactMap { $0.text }` filter is one line but load-bearing: the model would otherwise see `[…]` in prior chunks and learn to emit them itself.

## When to Apply

- The pattern is the default — any new Gemini call from RecordingSession should go through `processBatch`'s catch-block.
- Reconsider terminal/recoverable classification only when adding a new `GeminiError` case. The default-`true` fallback for unknown errors is conservative on purpose.
- Reconsider `splitRetryBackoff` if user reports show NoType still hammering APIs under sustained outage — but a rate-limit-aware exponential backoff would be the next step, not just a longer fixed sleep.

## Examples

### Per-chunk dispatch with classification

```swift
do {
    let text = try await gemini.transcribeBatch(...)
    responses.append(ChunkResponse(
        chunkIndices: encoded.map { $0.idx },
        text: text
    ))
} catch {
    if Self.isTerminal(error) {
        markFailure(error)               // stop() will rethrow
        return
    }
    if encoded.count > 1 {
        await splitRetry(encoded: encoded, snap: snap)
    } else {
        recordRecoverableFailure(error: error, indices: [encoded[0].idx])
    }
}
```

### Marker stitching at session end

```swift
let pieces = responses.map { $0.text ?? Self.failureMarker }
let stitched = TextInjector.stitchChunks(pieces)
    .trimmingCharacters(in: .whitespacesAndNewlines)
```

`stitchChunks` inserts a single space between `,` and `[`, and between `]` and a word-starter, so a marker in the middle reads naturally: `"Hello, […] world"`.

**A stitched marker is not durable — and that is why nothing structural is allowed to depend on one.** The transcript passes through `TextReplacementEngine.apply` (the Dictionary module's user-defined pairs) on its way to the cursor. Those boundaries are Unicode look-arounds over `[\p{L}\p{N}]`, and brackets are neither — so the `…` inside `[…]` sits at a real word boundary, and a user pair as ordinary as `…` → `...` rewrites every marker in the string.

**This was learned the expensive way, and the fix was to stop storing the marker.** For one release the history row *was* the pasted string: a lost chunk existed only as those characters, and the retry found where to write by scanning left-to-right for the *i*-th `[…]`. On a row whose markers a pair had rewritten, the row stayed broken, kept its audio, and had nowhere for a recovery to land — every retry on it was billed and recovered nothing, on precisely the row the feature existed for. The shipped mitigation *hid the retry button* for that row, which dropped the user's recovery instead of fixing the model.

Since `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`, **a gap is a position, not a character.** `HistoryEntry.segments` stores the session's response sequence — per segment, the chunk indices it covered and either the model's **raw** text or `nil` for a gap — and the `[…]` is produced at render time by `HistoryText.assemble`, with the user's *current* pairs applied downstream of that. So a pair now restyles a gap and can no longer move or delete one, and a retry writes into the gap covering the chunk's own index (`RetryMerge.merge(into:outcomes:)`) without reading the row's rendered string at all.

Two rules for anything new:

- **Never derive a structural fact from the rendered text.** Not the failure count (`HistoryEntry.failedChunkCount` is itself *derived from* the sequence and encoded only as a legacy mirror for rollback), not brokenness (`isBroken` = "the sequence contains a gap"), not "was this session ever counted" (`isEntirelyLost` = "every segment is a gap"). Reading any of them out of a string reintroduces the same class of bug one layer up.
- **Placement stays a reported outcome.** `RetryMerge.Merged.placed` says which recoveries actually reached the row, and the retry releases a chunk's audio only for those. Writing by index makes a mismatch rare, not impossible — a recovery aimed at an index no gap covers keeps its audio, because `RetainedAudioStore.take` hands out the only copy. See [`conventions/gate-irreversible-actions-on-the-outcome-2026-08-09.md`](../conventions/gate-irreversible-actions-on-the-outcome-2026-08-09.md).

### Surfacing partial state to the user

```swift
let sessionSummary = session.summary
// ...append to history, hide transcribing HUD, ...
if let notice = NoTypeErrorKind.noticeForFinishedSession(
    entry: entry, summary: sessionSummary, replacements: dictionaryReplacements
) {
    self.surfaceError(notice)
}
```

A neutral `"Pasted with gaps"` HUD says "N of M chunks didn't transcribe — `[…]` was inserted in their place".

**One notice per session, chosen up front rather than by whichever call ran last.** The success arm no longer decides inline: `noticeForFinishedSession` is a single pure seam returning `.pasteWithheld` when the paste was withheld because the destination process changed, `.partialTranscription` when only chunks were lost, and `nil` for the ordinary session. That shape is forced — `showErrorHUD` *replaces* rather than stacks, so two `surfaceError` calls in one arm silently discard one — and a session that both lost chunks and changed destination is the ordinary bad session rather than a rare intersection, since a stalled network causes both. The withheld notice wins and folds the gap count into its own copy, because "Pasted with gaps" is simply false about a session that pasted nothing. See `NoType/UI/CLAUDE.md` invariant 8.

## Related

- [serial-gemini-actor-2026-05-15.md](serial-gemini-actor-2026-05-15.md) — the one-in-flight invariant that split-retry preserves.
- [local-chunk-concatenation-2026-05-15.md](../design-patterns/local-chunk-concatenation-2026-05-15.md) — the "client owns assembly" rule that the marker stitching rides on.
- [adaptive-pause-threshold-2026-05-16.md](../design-patterns/adaptive-pause-threshold-2026-05-16.md) — the finer-chunking change that made all-or-nothing more painful and motivated this work.
- [sender-respawn-race-2026-05-16.md](../runtime-errors/sender-respawn-race-2026-05-16.md) — sister learning from the previous reliability pass.
- [hallucination-length-gate-2026-05-20.md](hallucination-length-gate-2026-05-20.md) — the third `text` state (`""` for gate-drops) and how it interacts with this contract.
- PR #38 — adaptive pause threshold + 180 s force-cut.
- PR #39 — partial recovery (this entry).
- `NoType/Recording/CLAUDE.md` — invariant 12 ("Partial recovery") and the per-class classifier matrix.
- `RecordingSession.shouldRetain(_:)` — sibling classifier governed by this same recoverable/terminal split (it retains exactly the gap-marker class, including the 401/403 carve-out). **A new `GeminiError` case belongs in both.** Guard fidelity for the pair: [`conventions/source-scan-guard-fidelity-2026-07-25.md`](../conventions/source-scan-guard-fidelity-2026-07-25.md).
- `NoType/Gemini/CLAUDE.md` — retry-policy subsection (flipped from "don't paste partial" to point at this layer), and "Request budgets" for the per-request inactivity budget that decides how long a chunk may stall before it becomes one of these markers.
- `NoType/History/CLAUDE.md` — Schema (the segment sequence a marker is stored as) and "Broken rows and retry" (the index write that lands a recovery).
- `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md` — the change that moved the gap from characters to positions, and the two defects that forced it.
