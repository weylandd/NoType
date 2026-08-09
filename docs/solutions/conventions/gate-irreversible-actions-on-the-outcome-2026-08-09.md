---
title: Gate an irreversible action on the outcome it depends on, not on the input that predicts it
date: 2026-08-09
category: conventions
module: cross-cutting
problem_type: convention
component: tooling
severity: critical
applies_when:
  - "An action that cannot be undone (release, delete, decrement, ack-and-drop) is gated on a boolean"
  - "The gating boolean is named for what came back from a call rather than for what the call achieved"
  - "A caller re-derives, from the same inputs, a fact the operation it just called already knows"
  - "A pure function is written to degrade safely and its caller is not"
  - "The state being released is the only copy in existence"
tags: [data-loss, proxy-predicate, irreversible, postcondition, code-review, purity]
related_components: [AppState, History, Dictionary, Recording]
---

# Gate an irreversible action on the outcome it depends on, not on the input that predicts it

## Context

U6 of the failed-recording-retry work re-sends a broken history row's retained audio chunks and settles the row into its recovered or still-broken state. The run begins by taking the payload out of the holder — `_ = retainedAudio.take(entryID)` (`NoType/AppState.swift:894`) — and that take is destructive by contract: *"The taken payload is the only copy, so every path out of the retry must re-put what it did not recover"* (`NoType/History/RetainedAudioStore.swift:124`). Audio is never written to disk (architecture invariant I4), so a path that neither re-puts nor deliberately releases destroys the user's recording permanently.

`settleRetry` (`NoType/AppState.swift:1017`) makes three decisions with that payload in hand:

1. which chunks go back into the holder,
2. how much to subtract from the row's `failedChunkCount`,
3. whether the run achieved anything at all (R19's "surface the failure" exit).

All three were derived from `RetryMerge.isRecovery` — *"did Gemini return non-empty text for this chunk"* (`NoType/History/RetryMerge.swift:68`):

```swift
let recoveredCount = RetryMerge.recoveredCount(recovered)
guard recoveredCount > 0 else { /* re-put everything, surface failure */ }
let remaining = zip(payload.chunks, recovered)
    .filter { !RetryMerge.isRecovery($0.1) }
    .map(\.0)
failedChunkCount: max(0, row.failedChunkCount - recoveredCount)
```

The fact all three actually depend on is different: **did that text get placed into the row.** Recovery is an *input* fact — it describes what came back off the wire. Placement is an *outcome* fact — it describes what the merge managed to do with it. They diverge in exactly one direction: when there is no `[…]` gap marker for the text to land in.

The merge already knew this. `mergeDetailed` walks the text marker-by-marker (`RetryMerge.swift:158`), consuming one slot per marker; slots past the last marker are never visited. Its own doc-comment said the function *"is written to degrade safely if that ever slips: a slot with no recovery keeps its marker, a marker with no slot keeps itself"* — the pure function had been hardened against the mismatch and the caller had not. Degrading safely in the text is free; the caller was busy freeing audio.

**And the mismatch was already reachable, with no change to the retention class.** `TextReplacementEngine.apply` runs over the stitched transcript at `NoType/Recording/RecordingSession.swift:975` and the row is built from its output at `:999`, so history stores post-replacement text. The engine's boundary is a Unicode look-around, not `\b` (`NoType/Dictionary/TextReplacementEngine.swift:109`):

```swift
let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: find) + "(?![\\p{L}\\p{N}])"
```

The marker is `"[…]"` (`RecordingSession.swift:143`). Inside it the `…` is flanked by `[` and `]` — neither a letter nor a digit — so both look-arounds succeed, and a user replacement pair whose `from` is `…` (an ellipsis-to-three-dots normalisation is the obvious one) rewrites **every marker in the row**. The row's `failedChunkCount` is not derived from its text, so the row stays broken and keeps its audio while carrying nothing for the merge to substitute into.

The resulting sequence, on a one-chunk broken row whose marker was rewritten:

- Gemini answers. `isRecovery` → true, `recoveredCount` → 1.
- `merge` finds no marker, falls through its substitution loop, returns the text unchanged.
- Exit 2's `recoveredCount > 0` passes, so the failure exit is not taken.
- `remaining` filters out the "recovered" chunk → empty → **nothing is re-put; the only copy of the audio is gone.**
- `failedChunkCount` → `max(0, 1 - 1)` → 0 → the row is no longer `isBroken`, so retry is no longer offered.
- The recovered text is discarded with it.

The user is left with a row that looks finished, was never transcribed, and can never be retried — and no error was surfaced, because the run "recovered" something.

Note which direction is dangerous. The merge's own hazard list enumerated two ways the marker↔chunk correspondence could break, and both produce *more* markers than chunks — a narrowed `shouldRetain`, or a stray `[…]` in transcript text. Marker surplus is safe under either predicate: every slot still gets visited, so `placed` and `isRecovery` agree. Only marker *shortfall* diverges, and that was the case nobody had listed.

## Guidance

**When an action cannot be undone, gate it on the postcondition it depends on — never on an input fact that usually implies it.** "The call succeeded", "the response was non-empty", "we got a result" are facts about what arrived. "It was written", "it was placed", "it is now durably held elsewhere" are facts about what happened. Release, delete, decrement, ack-and-drop and advance-the-cursor all depend on the second kind. Substituting the first is safe right up until the step between them fails — and that step is precisely the one nobody models.

**The review tell: a boolean whose *name* describes the input, gating an action whose correctness depends on the output.** `isRecovery` reads as a property of a Gemini response. The thing it was gating — releasing the only copy of the user's audio — is a property of the history row. Whenever the noun in the predicate's name and the noun the action operates on are different objects, the predicate is a proxy. Sometimes a sound one; always worth naming out loud.

**Make the operation report its own effect instead of letting the caller re-derive it.** The fix did not add a check — it moved the fact to where it is known. `mergeDetailed` now returns the text *and* a `placed` flag per slot (`RetryMerge.swift:88`):

```swift
struct Merged {
    let text: String
    /// One flag per entry of the `recovered` array passed in: true iff
    /// that slot's text is present in `text`.
    let placed: [Bool]

    /// How many slots actually landed. This — not a count of
    /// `isRecovery` outcomes — is what a caller may release audio for.
    var placedCount: Int { placed.reduce(0) { $0 + ($1 ? 1 : 0) } }
}
```

A caller that re-derives an outcome from the inputs is running a second, independent implementation of the operation's logic — and it is the one that will rot. A caller that reads a value the operation returned cannot disagree with it.

**Gate the "nothing happened" exit on the same fact.** This is the half most easily left behind. If the failure exit still keys on the proxy, a run whose answers all had nowhere to go reads as a *success*: the row is rewritten with nothing, the count is decremented, no error surfaces, and the audio is consumed. The nothing-placed case is not a new state — it is the failure the run always was, and it has to reach the exit that already handles failure.

**Sharing a predicate guarantees agreement about the predicate, not about the effect.** The original `isRecovery` doc-comment made exactly this argument for its own safety:

> The single source of truth for that rule: `merge(existingText:recovered:)` and `AppState`'s settle path both read it, so the text and the retained set can never disagree about what recovered.

Every clause is true. It is also not the property that was needed: both sides agreed perfectly about what *recovered*, and the audio was released anyway, because releasing depends on what *landed*. A "single source of truth" claim only buys safety when the shared fact is the one the consumers actually act on.

**Keep the proxy where it was right.** `isRecovery` was not wrong; it is still the merge's own rule for what to *attempt* to place, and its empty-string handling is deliberate policy. The defect was reusing it one layer out, for a different question. Fixing this class usually means narrowing a predicate's blast radius, not deleting it.

## Why This Matters

The failure is silent, unobservable and terminal, in that order.

**Silent:** every visible signal reads as success. The row is rewritten, the count goes down, no HUD appears. There is no log line, because from the caller's point of view nothing anomalous happened.

**Unobservable:** the destroyed state is memory-only by design, so no test can assert its absence after the fact and no disk artefact survives to diagnose from. `RetainedAudioStore.take`'s doc-comment says this outright — *"nothing here holds a second reference and no test can observe the loss."*

**Terminal:** audio is never persisted, so there is no second copy anywhere in the system. This is not a corrupted row repairable on next launch; it is the user's recording, gone.

And the proxy survives review precisely because it is a *good* proxy. `isRecovery` and `placed` agree on the happy path, the all-failed path, the partial path, the empty-response path and the hallucination-gate path — on every case a reviewer or a test author naturally enumerates, and on every scenario the plan itself enumerated for U6. Reproducing the divergence needs a second, unrelated feature (a dictionary replacement pair) to have already rewritten the row's text, at a boundary two modules away from the code under review. A predicate that is wrong only in the case nobody constructs is more dangerous than one that is obviously unreliable, because it accumulates callers.

## When to Apply

- **Any release / delete / free / evict of state that is the only copy.** Ask what fact makes it safe to lose, and check that exact fact is what the guard reads.
- **Any decrement of a counter that mirrors something countable.** `failedChunkCount` is documented as staying equal to the markers left in the text (`AppState.swift:1082`); the moment its subtrahend is a *different* count than the one that changed the text, the two drift. If a counter mirrors a collection, derive it from the operation that mutated the collection.
- **Any caller that recomputes, from the arguments, a conclusion the callee already reached.** That is a second implementation. Return the conclusion instead.
- **Any "nothing happened, bail" guard on a path whose earlier steps were destructive.** Verify its condition is the negation of "something landed", not of "something came back".
- **When a pure function's doc-comment says it degrades safely.** The degradation is real end-to-end only if the caller's decisions degrade with it. A pure function returning a safe value while its caller frees a resource on the unsafe assumption has moved the bug, not removed it.
- **When one module's output passes through another module's transform before being stored.** The transform is where structural assumptions get quietly invalidated — here, a dictionary feature rewriting a recording feature's sentinel, with neither module aware of the other.

## Examples

**Wrong** (`73cd33a`) — three irreversible decisions, all keyed on the input fact, while the merge silently declines to place anything:

```swift
let recoveredCount = RetryMerge.recoveredCount(recovered)
guard recoveredCount > 0 else { /* re-put, surface failure */ }

let mergedText = RetryMerge.merge(existingText: row.text, recovered: recovered)
let remaining = zip(payload.chunks, recovered)
    .filter { !RetryMerge.isRecovery($0.1) }                       // ← releases on "it recovered"
    .map(\.0)
let updated = HistoryEntry(…, failedChunkCount: max(0, row.failedChunkCount - recoveredCount))
```

```swift
// merge, with the markers already rewritten by a dictionary pair
while let hit = rest.range(of: marker) { … }   // zero iterations
out += rest                                    // returns the row unchanged
```

**Right** (`e1101e6`) — the merge records placement where it happens, and all three decisions read it:

```swift
var placed = nonePlaced
while let hit = rest.range(of: marker) {
    if slot < slots.count, let recoveredText = slots[slot] {
        out += recoveredText
        placed[slot] = true          // set where the placement actually happens
    } else {
        out += marker
    }
    slot += 1
    rest = rest[hit.upperBound...]
}
// Slots past the last marker were never visited, so their `placed`
// flags stay false and the caller keeps holding their audio.
return Merged(text: out, placed: placed)
```

```swift
// settleRetry — NoType/AppState.swift:1028
let merged = RetryMerge.mergeDetailed(existingText: row.text, recovered: recovered)
let placedCount = merged.placedCount

guard placedCount > 0 else { /* re-put, surface failure — :1053 */ }

let remaining = zip(payload.chunks, merged.placed).filter { !$0.1 }.map(\.0)   // :1072
let updated = HistoryEntry(…, failedChunkCount: max(0, row.failedChunkCount - placedCount))  // :1088
```

`RetryMerge.recoveredCount` was deleted rather than left available — the helper existed only to serve the proxy derivation, and leaving it in the API is an invitation to reintroduce it.

The regression is pinned at both altitudes: `RetryMergeTests.test_placed_recoveryWithNoMarkerToLandIn_isNotPlaced` (`NoTypeTests/RetryMergeTests.swift:189`) for the pure half, and `AppStateRetryTests.test_retry_recoveryWithNoMarkerToLandIn_keepsTheAudioAndSurfacesTheFailure` (`NoTypeTests/AppStateRetryTests.swift:257`) for the settle path — which asserts the row is not rewritten, that it stays broken, that the chunk goes back into the holder, that the error HUD is shown, and that the tokens are still billed. The companion `test_placed_moreRecoveriesThanMarkers_marksOnlyTheOnesWithASlot` pins the safe direction so the asymmetry stays legible.

## Related

- `73cd33a` — U6 implementation (introduced the proxy derivation); `e1101e6` — review remediation (added `Merged.placed`, re-keyed all three decisions, deleted `recoveredCount`). Both on `feat/failed-recording-retry`, unmerged as of this writing; `docs/plans/2026-08-09-001-feat-failed-recording-retry-plan.md` is the stable reference.
- `NoType/History/RetryMerge.swift` — the enum doc-comment carries the full mechanism, including the `TextReplacementEngine` interaction and why `placed` exists separately from `isRecovery`; `:68` `isRecovery`, `:88` `Merged`, `:125` `mergeDetailed`.
- `NoType/AppState.swift:1017` — `settleRetry` and its three exits; `:894` — the destructive `take` that makes every exit load-bearing. `NoType/History/RetainedAudioStore.swift:124` — the "only copy" contract this entry rests on.
- `NoType/Dictionary/TextReplacementEngine.swift:109` — the Unicode look-around that makes the mismatch reachable; `NoType/Recording/RecordingSession.swift:143` — the `"[…]"` marker it rewrites; `:975` / `:999` — replacement runs before the row is built.
- [`guard-scope-must-match-invariant-scope`](guard-scope-must-match-invariant-scope-2026-08-09.md) (U2) and [`reconcile-optimistic-mirror-by-union`](reconcile-optimistic-mirror-by-union-2026-08-09.md) (U5) — the two siblings from this plan. Three variations on one theme: a check at the wrong *altitude*, keyed on the wrong *set*, and keyed on the wrong *proposition*. All three are single-fault-invisible, and the U5 one releases the same audio this one does.
- [`closure-scoped-return-trap`](closure-scoped-return-trap-2026-05-16.md) — the same "does what it says at its own site, not what the reader assumes" failure class, one altitude down.
- [`partial-recovery-with-markers`](../architecture-patterns/partial-recovery-with-markers-2026-05-16.md) — where the `[…]` marker comes from and why a marker stands for exactly one chunk. That entry predates the retry feature and does not yet note that markers are rewritable before storage. The retry feature and the retention contract themselves are owned by the module docs, not here.
