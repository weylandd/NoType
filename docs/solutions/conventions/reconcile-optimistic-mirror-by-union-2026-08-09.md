---
title: Reconciling an optimistic mirror against its persisted source must union, not replace
date: 2026-08-09
category: conventions
module: cross-cutting
problem_type: convention
component: tooling
severity: critical
applies_when:
  - "A cleanup, eviction, or GC pass is keyed on \"what the source of truth currently says\""
  - "An in-memory mirror is updated synchronously while the write behind it is fire-and-forget"
  - "Reloading a mirror wholesale from the store it mirrors"
  - "The state being released is the only copy in existence"
tags: [optimistic-mirror, reconciliation, cleanup, data-loss, eviction, actor, main-actor]
related_components: [AppState, History, Recording]
---

# Reconciling an optimistic mirror against its persisted source must union, not replace

## Context

`AppState.history` (`NoType/AppState.swift:19`) is a `@MainActor` optimistic mirror of an `actor`-backed `HistoryStore`. Every mutation path updates the mirror **synchronously** and writes to disk **fire-and-forget** — `deleteHistoryEntry(id:)` comments its own `history.removeAll { … }` as *"optimistic local update so the row disappears immediately"* before dispatching the store call. That asymmetry is the feature: the UI never waits on an actor hop or a disk write.

It also means the mirror is routinely **ahead of** the disk, and that the window is not a race to be closed but a designed state.

U5 of the retry work made that window load-bearing. `recordBrokenRow` (`NoType/AppState.swift:752`) appends the row and stores its retained audio synchronously, then hands the persist off:

```swift
recordHistoryEntry(entry, retaining: retained)   // mirror + payload, synchronous
Task { [historyStore] in await historyStore.append(entry) }   // disk, later
```

The payload is the **only copy of that audio in existence** — NoType retains no audio on disk (architecture invariant I4), so the retry it exists to enable is the only thing standing between the user and a lost recording.

The same unit added eviction, keyed on the surviving history ids. `RetainedAudioStore.retain(only:)` (`NoType/History/RetainedAudioStore.swift:161`) is a hard filter — `payloads = payloads.filter { liveEntryIDs.contains($0.key) }` — and `refreshHistory` called it against the **reloaded-from-disk set alone**:

```swift
// 7f2431f — `liveHistoryIDs` is read AFTER the assignment, so it is the disk view.
func refreshHistory() async {
    history = await historyStore.allEntries()
    retainedAudio.retain(only: liveHistoryIDs)
}
```

A `refreshHistory()` landing inside the `recordBrokenRow` window sees a row in the mirror, no such row on disk, and destroys its audio. Permanently, silently, and only for the user who just lost a recording.

`refreshHistory()` has exactly one production caller today (`prime()`, over an empty holder), so this was latent rather than shipped — which is precisely why it is worth writing down as a rule instead of an incident. It was invisible at the call site, invisible in single-view testing, and the *next* caller added to that function would have armed it.

## Guidance

**When an optimistic mirror is the authority for writes that have not landed yet, reconciliation against the persisted source must union, not replace.** A reconciliation may release only state that **every** view agrees is gone.

```swift
// NoType/AppState.swift:601 — the fix.
func refreshHistory() async {
    let reloaded = await historyStore.allEntries()
    let mirrored = liveHistoryIDs                          // pre-reload mirror
    history = reloaded
    retainedAudio.retain(only: liveHistoryIDs.union(mirrored))   // disk ∪ mirror
}
```

Two orderings are load-bearing and both deserve the comment they carry in the source:

- `mirrored` is captured **after the `await`**, so a row appended while the function was suspended is counted.
- `mirrored` is captured **before the assignment**, so it is the pre-reload set rather than a copy of `reloaded`.

**The tell to look for in review: a cleanup keyed on "what the source of truth currently says," in a system where a mirror is deliberately allowed to be ahead of it.** Grep-shaped, the family looks like `filter { live.contains(…) }`, `removeAll { !persisted.contains($0) }`, `keys.subtracting(onDisk)`. Each is correct if and only if the keyed set is the *complete* set of holders. Ask: who else can be holding a reference right now, and is any of them permitted to be ahead?

**Cleanups are where this bites, because a cleanup's failure mode is deletion.** A reconciliation that keeps too much fails as memory growth — observable, bounded, and in this case bounded anyway by the ten-entry window. One that keeps too little fails as nothing at all: no error, no log, no crash, just an absence the user discovers when they press the button that was supposed to save them. Asymmetric failure modes deserve asymmetric defaults, and the safe default for a cleanup is to keep.

**Delete tests that encode the bug as the expectation.** U5 shipped `test_refreshHistory_dropsPayloadsForRowsNotOnDisk`, whose `ghost` fixture — a row in the mirror but *not* on disk — asserted `XCTAssertNil`. That is the defect written down as the spec, and it would have made the correct behaviour look like a regression to the next reader. The remediation renamed it to `test_refreshHistory_releasesPayloadsNoViewHolds` with a `stray` fixture (present in neither view — the case eviction genuinely exists for), and added the complement that actually fails against the buggy code:

```swift
// NoTypeTests/AppStateRetentionTests.swift:181
func test_refreshHistory_keepsThePayloadOfARowNotYetPersisted() async {
    let pending = entry(text: "", failedChunkCount: 1)
    state.recordHistoryEntry(pending, retaining: payload())
    await state.refreshHistory()
    XCTAssertNotNil(store.peek(pending.id),
                    "a mirror row whose disk write has not landed keeps its audio")
}
```

Note what the complement is careful *not* to claim: the row itself does still drop out of the mirror on a wholesale reload — that is pre-existing optimistic-mirror behaviour and out of scope. What is pinned is that the **audio is not destroyed on the way**.

**The related structural move: where two views must agree on a bound, derive one from the other.** The mirror's trim cap and the store's cap were two hand-synced literals guarded by an assertion that one of them equalled `10`. Making `HistoryStore.cap` internal (`NoType/History/HistoryStore.swift:13`) and deriving `AppState.historyMirrorCap = HistoryStore.cap` makes their agreement structural, so `liveHistoryIDs` cannot name a set the store disagrees with. A guard is what you write when the invariant cannot be made structural — not the first move.

## Why This Matters

The mirror-ahead-of-store shape is not a corner of this codebase; it is the codebase's standard shape. Four actor stores (`HistoryStore`, `StatsStore`, `InstructionsStore`, `DictionaryStore`) each have a `@MainActor @Observable` mirror on `AppState`, and every one of them updates optimistically. Any future cleanup, cache eviction, or GC pass written over any of those mirrors inherits this exact question.

The bug is also structurally hard to see. At the call site the code reads perfectly: reload the truth, drop what the truth no longer contains. It needs two facts held simultaneously — that the write is fire-and-forget, and that the payload has no other copy — and those facts live in two different files from the line that is wrong. Single-view testing walks straight past it: a test that seeds the store and a test that seeds the mirror both pass, because the failure only exists in the disagreement between them.

And the consequence is uniquely bad relative to its size. A one-line fix stands between the retry feature and a path that permanently destroys the artifact the feature exists to recover, at exactly the moment the user is relying on it.

## When to Apply

- **Any eviction / cleanup / GC keyed on a live-set query**, where more than one component can hold the thing being evicted.
- **Any wholesale reload of a mirror** from the store it mirrors — ask what the mirror was holding that the store has not seen yet.
- **Any state whose only copy is in memory.** Audio, an in-flight upload buffer, an unsaved draft, a decrypted secret. The cost of keeping one too long is bounded; the cost of releasing one too early is not.
- **Reviewing a diff that adds a second caller to an existing reconciliation function.** The first caller may have been safe by accident (empty holder, launch-time only); the rule is what makes the second one safe.
- **Not applicable when the mirror is strictly behind** — a read-through cache with no local writes has no pending state to protect, and union there is just a leak.

## Examples

**Wrong** (`7f2431f`) — the eviction's key set is one of two views:

```swift
history = await historyStore.allEntries()
retainedAudio.retain(only: liveHistoryIDs)   // disk view only
```

Sequence that breaks it: `recordBrokenRow` appends row R to the mirror and stores R's audio → the `Task` performing `historyStore.append(R)` has not run yet → `refreshHistory()` runs → `reloaded` has no R → R's audio is filtered out and gone. R is still on screen, still showing a retry button, with nothing behind it.

**Right** (`9d485bb`) — the eviction releases only what both views have dropped:

```swift
let reloaded = await historyStore.allEntries()
let mirrored = liveHistoryIDs
history = reloaded
retainedAudio.retain(only: liveHistoryIDs.union(mirrored))
```

The eviction still does its job — a payload whose row appears in *neither* view is released, which is the leak the call exists to prevent. It just can no longer act on a disagreement between the views as if it were a fact.

## Related

- `7f2431f` — U5 implementation (introduced the disk-keyed eviction); `9d485bb` — review remediation (the union, the retitled fixture, the complement test, and the derived cap). Both on `feat/failed-recording-retry`, unmerged as of this writing; `docs/plans/2026-08-09-001-feat-failed-recording-retry-plan.md` is the stable reference.
- `NoType/AppState.swift:601` — `refreshHistory` and the comment carrying this rule; `:752` — `recordBrokenRow`, which opens the window; `NoType/History/RetainedAudioStore.swift:161` — `retain(only:)`, the single eviction point.
- [`guard-scope-must-match-invariant-scope`](./guard-scope-must-match-invariant-scope-2026-08-09.md) — the sibling from U2 of the same plan. That entry asks *where the check goes*; this one asks *what set the check is keyed on*. Both are a check written at a narrower extent than the state it governs.
- [`gate-irreversible-actions-on-the-outcome`](./gate-irreversible-actions-on-the-outcome-2026-08-09.md) — the U6 sibling, and the closest of the three: it releases *this same audio*, one layer further in, when a retry's settle path keys on "Gemini answered" rather than "the answer landed in the row". That entry asks *which proposition* the check asserts. Together the three cover place, set, and proposition.
- [`source-scan-guard-fidelity`](./source-scan-guard-fidelity-2026-07-25.md) — the other P1 from U5 (a scan blind to its own discovery set), and the authoring-time habits that would have surfaced the fixture encoding this bug as its expectation.
- [`design-patterns/observation-loop-swallows-initial-state`](../design-patterns/observation-loop-swallows-initial-state-2026-07-25.md) — the read-side cousin: an observer that only sees changes after its entry snapshot, so the state present at start is invisible to it. Same class of mistake about which slice of the world a query returns.
- `NoType/History/CLAUDE.md` — the `HistoryStore` / `StatsStore` contract and the optimistic-mirror wiring this rule constrains. The retention feature's own behaviour is documented there, not here.
