---
title: A guard at the producer site enforces only that site's scope — put it on the shared latch
date: 2026-08-09
category: conventions
module: cross-cutting
problem_type: convention
component: tooling
severity: high
applies_when:
  - "Adding a field whose contract is written in whole-object terms (\"this session\", \"this request\", \"this process\") but written from a per-iteration site"
  - "A local boolean (`didFail`, `isCancelled`, `didTimeout`) is read to decide something the doc-comment states more broadly"
  - "Reviewing a diff that guards an accumulator at the point of accumulation"
  - "Inheriting a hand-off note that asserts an invariant the next unit will branch on"
tags: [invariants, scope, guard-placement, state-machine, latch, code-review, hand-off]
related_components: [Recording, AppState]
---

# A guard at the producer site enforces only that site's scope — put it on the shared latch

## Context

U2 of the failed-recording-retry work made `RecordingSession` retain the encoded audio of chunks whose Gemini call failed in the recoverable class, so a later unit could offer a retry. The accumulator (`retained`, `NoType/Recording/RecordingSession.swift:501`) carries a doc-comment written in session terms, and the rule it has to satisfy is also a session fact: **a session that ends terminally retains nothing** — a rejected key, a content block, an encode failure, or a cancel means no retry can ever succeed, so there must be nothing to retry.

The implementation enforced that with a check at the place the state is produced — inside `processBatch`, next to the accumulate call:

```swift
if !didFail {
    accumulateRetained(Self.retainedPayload(...))
}
```

`didFail` is true, correctly, for the batch that just failed terminally. But `processBatch` runs once per batch, and each invocation only knows about itself. A session that lost chunk 0 to a 5xx (recoverable → retained) and *then* hit a rejected key on chunk 3 kept chunk 0's audio and returned a non-nil `summary.retained` — contradicting the field's own doc-comment, and poisoning the exact signal the next unit branches on. `AppState`'s catch arm was to read `retained != nil` as "this session lost chunks in the recoverable class"; under the bug it would have put a live retry button on a session no retry can fix.

Seven reviewers converged on this independently, which is itself the signal: the mismatch is legible from the diff alone, because the guard and the contract are written at visibly different altitudes.

## Guidance

**Match the guard's scope to the invariant's scope.** A check placed where the state is *produced* enforces the invariant only over that producer's extent — one loop body, one batch, one call. When the invariant is scoped wider (whole object, whole session, whole process), the guard belongs at the **shared latch every path into that scope already passes through**, not replicated at each producer.

The tell to look for in review: **a local boolean is being read to decide something whose contract is written in wider terms.** `didFail` scopes to a batch; "this session retains nothing" scopes to a session. `isCancelled` scopes to a task; "the pasteboard is never touched on cancel" scopes to a lifecycle. Whenever those two altitudes differ in one statement, the guard is in the wrong place.

**Find the existing latch before inventing a new one.** The fix here was one line, because a shared latch was already there: `markFailure(_:)` (`:1574`) is what all four terminal paths funnel through, so clearing the accumulator inside it covers every one of them for free — including paths nobody enumerated:

```swift
private func markFailure(_ error: Error) {
    if failure == nil { failure = error }
    // Unconditional (not inside the `failure == nil` guard) because it
    // is idempotent and must hold on every latch.
    retained = nil
}
```

Two follow-ons that come with this shape:

- **Route stragglers through the latch too.** `cancel()` was setting `failure` inline; it now calls `markFailure(CancellationError())` (`:712`) so the reset lands synchronously, before the awaits that follow, rather than only after them. A latch only covers what actually calls it.
- **Keep the producer-site guard.** It is not redundant — it stops the *current* batch from accumulating, and its emptiness term keeps the ordinary success path allocation-free. Just annotate what each half covers so the next reader does not read either as the whole rule.

**A confident claim in a hand-off note is a claim to verify, not to inherit.** The implementer's own note asserted that "session retained something" was already a safe proxy for recoverable-class loss. It was false as written, and the next unit was about to be built on it. Hand-off notes carry the author's intent, not the code's behaviour; when the next unit's design rests on one, re-derive it from the tree before building on it.

## Why This Matters

Scope mismatches are cheap to fix and expensive to find later, because the guard *looks* correct at its own site and the failing case needs two events in the right order to reproduce — a recoverable failure followed by a terminal one. Neither in isolation shows anything wrong. Single-fault testing walks straight past it.

Worse, the state it corrupts here is a **cross-unit interface**. The value was going to be consumed as a boolean proxy by a component not yet written. A field whose invariant holds "almost always" is more dangerous than one that is obviously unreliable: downstream code reads the doc-comment, believes it, and stops defending.

## When to Apply

- **Any accumulator, cache, or companion field whose lifetime is the enclosing object**, written from a per-item or per-iteration site.
- **Any review of `if !someLocalFlag { … }` guarding a stored property.** Ask: what is the flag's extent, and what is the property's contract's extent? If they differ, the guard is misplaced.
- **Any state machine with several terminal paths.** Find the one latch they share and make the invariant hold there; adding the rule to each path individually is the shape that leaves the fourth path uncovered.
- **Before building on an inherited invariant.** If the next unit's branch depends on "X implies Y", check X and Y in the tree, not in the hand-off note.

## Examples

**Wrong** (`a9c727c`) — the guard's extent is one batch; the invariant's is the session:

```swift
// processBatch, once per batch
if !didFail {
    accumulateRetained(Self.retainedPayload(
        inBatch: encoded.map(\.retainable),
        failedChunkIndices: retainableFailures, ...
    ))
}
// ...nothing anywhere drops what an EARLIER batch already accumulated.
```

Sequence that breaks it: batch 1 fails 5xx → `retained = [chunk 0]`. Batch 2 fails 401 → `didFail` true, batch 2 accumulates nothing — and chunk 0 is still there. `stop()` throws, `summary.retained != nil`.

**Right** (`370e1ff`) — the session-wide half moves to the latch; the producer-site guard stays and says what it covers:

```swift
// processBatch — covers only THIS batch; the session-wide half lives
// in `markFailure`. The emptiness term keeps the success path from
// materialising a chunk struct per chunk only to discard it.
if !didFail && !retainableFailures.isEmpty {
    accumulateRetained(...)
}

// markFailure — the single latch all four terminal paths share.
private func markFailure(_ error: Error) {
    if failure == nil { failure = error }
    retained = nil
}
```

Note the asymmetry that makes the latch the right home: `splitRetry` has its own early-out on `didFail` (`:1359`) and returns whatever it collected before the terminal error, trusting the caller to drop it. With the rule on the latch, that trust is no longer a third place the invariant has to be re-stated correctly.

## Related

- `a9c727c` — U2 implementation (introduced the batch-scoped guard); `370e1ff` — review remediation (moved the session-wide half onto `markFailure`, routed `cancel()` through it). Both on `feat/failed-recording-retry`, unmerged as of this writing.
- `NoType/Recording/RecordingSession.swift:501` — the `retained` field and the session-scoped doc-comment the guard had to satisfy; `:1574` — `markFailure`, the shared latch.
- [`partial-recovery-with-markers`](../architecture-patterns/partial-recovery-with-markers-2026-05-16.md) — the terminal-vs-recoverable classification this invariant sits on top of. The retention contract itself is owned by the Recording module docs, not here.
- [`closure-scoped-return-trap`](closure-scoped-return-trap-2026-05-16.md) — the language-level sibling: a `return` that escapes only the closure, not the function. Same failure class one altitude down — a construct doing its job over a narrower extent than the reader assumes.
- [`onboarding-reset-clears-permission-flags`](onboarding-reset-clears-permission-flags-2026-05-18.md) — the completeness cousin: a reset must clear every field scoped to the thing being reset. That entry asks *which fields*; this one asks *where the clearing goes*.
- [`source-scan-guard-fidelity`](source-scan-guard-fidelity-2026-07-25.md) — how the tests around this arc were themselves hardened (both drift guards gained the missing recoverable ⇒ retain direction; two tautological hallucination-gate tests were deleted rather than repaired).
- `docs/plans/2026-08-09-001-feat-failed-recording-retry-plan.md` — parent plan; carries R4 / AE1 / KTD3 and the decisions this entry deliberately does not restate.
