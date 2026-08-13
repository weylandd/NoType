---
title: Tolerating a decode failure deletes the recovery the throw was driving
date: 2026-08-13
category: conventions
module: History
problem_type: convention
component: tooling
severity: high
applies_when:
  - "Replacing a throwing decode with a lossy or defaulting one so partial data survives"
  - "Writing a `try?` inside a loop whose cursor is advanced by the call that just failed"
  - "A tolerant branch turns a small stored scalar into an allocation, a loop bound, or a retry count"
  - "Reviewing a diff whose justification is \"one bad record should not cost the whole file\""
tags: [decoding, codable, error-handling, fault-tolerance, migration, data-loss, allocation]
related_components: [History, Storage]
---

# Tolerating a decode failure deletes the recovery the throw was driving

## Context

`history.json` is a bare top-level array of the user's last ten transcripts. Decoding it as `[HistoryEntry]` meant a single unreadable row threw for the whole file, `JSONFileStorage` renamed it aside, and the user's history came back empty — ten transcripts lost to one bad field. The maintainer ruled for per-row tolerance (`NoType/History/CLAUDE.md` invariant 2), and the same arc's migration path (`HistoryEntry.migratedSegments`) had already moved a second decision the same way: a legacy row's stored failure count is *reconstructed* into gap segments rather than rejected.

Both changes replace a `throw` with a tolerant branch, and both went wrong in the same place — not in what they let through, but in what they took away. **A `throw` was doing work beyond signalling.** In the array it was ending the loop; in the file it was triggering `JSONFileStorage`'s rename-and-start-fresh recovery. Tolerance removed the signal and, with it, silently removed the mechanism.

## Guidance

**Before writing the tolerant branch, name what the throw was driving, and check the replacement still drives it.**

### 1. A `try?` at the wrong level stops the loop advancing

The obvious lossy-array shape hangs:

```swift
// Hangs. Not slow — hangs.
while !container.isAtEnd {
    if let row = try? container.decode(HistoryEntry.self) { entries.append(row) }
}
```

`UnkeyedDecodingContainer.decode` advances `currentIndex` only *after* a successful decode, so a throwing element leaves the cursor in place and the loop re-reads the same bad row forever. The throw was what moved the cursor past it — by aborting the loop entirely.

The fix is to move the tolerance down a level, into a wrapper whose initializer cannot throw, so the container's own decode always succeeds and the cursor always advances (`NoType/History/HistoryStore.swift`, `LossyHistoryArray` + `LossyRow`):

```swift
private struct LossyRow: Decodable {
    let entry: HistoryEntry?
    init(from decoder: Decoder) throws { entry = try? HistoryEntry(from: decoder) }
}
```

The failure then arrives as a `nil` payload rather than as a thrown error, which is the shape the loop can act on.

Two limits worth carrying, both recorded at the call site rather than assumed away:

- **"The decode always succeeds" is true on the observed toolchain, not by construction.** `try container.decode(LossyRow.self)` is still a `try`. Foundation throwing *before* it reaches `LossyRow.init` — older Foundation unboxed a JSON `null` ahead of a non-optional type's initializer — escapes and takes the whole-file path. That is exactly why a `decodeNil()` pre-branch is kept, even though deleting it was mutation-tested green on Swift 6.3 / macOS 26: NoType deploys back to macOS 15.
- **No test can pin the hang.** A test that exercised the naive pattern would hang the suite. What the corpus pins is the fix, and the load-bearing fixture is the **first-row** bad case (`HistoryStoreTests.test_load_aBadRow_isDroppedWhereverItSits`) — that is the only position at which a cursor bug is visible. A corpus that only ever puts the bad row last proves termination and says nothing about advancement.

### 2. The tolerant branch has its own unbounded inputs, and they are no longer catchable

`migratedSegments` reconstructs a legacy row by fabricating one gap segment per stored failure. It clamped the count below zero and not above:

```swift
let gapsWanted = max(0, failedChunkCount)      // before
let gapsWanted = min(max(0, failedChunkCount), maxMigratedGaps)   // after
```

`failedChunkCount` is read straight off disk, so nineteen bytes of JSON (`9223372036854775807`) buy an unbounded array. Measured before the clamp: **5 000 000 segments built in 0.09 s, and `Int.max` never returned.** Both halves matter — the 0.09 s is the *amplification rate*, proof that nothing self-limits the loop; the hang is the second clause.

The reason this is worse than the failure it replaced is structural, not a matter of degree. `JSONFileStorage`'s recovery is a `catch`, and **a `catch` cannot fire on a call that never returns.** A throw got the file renamed aside and the app started fresh; a hang recurs on every launch, and nothing downstream can reach it. The tolerant decoder converted a self-healing failure into a boot loop.

**Bound the branch where the amplification is, not everywhere the value appears.** The same clamp is deliberately *not* applied to a stored sequence's gap count: there the gaps are physically in the file, so the array cannot be larger than the bytes that carried it. Count-to-array is the only path where ten bytes buy an unbounded allocation, and it is the only one bounded.

**Size the ceiling to be unreachable by an honest record, not to be tight** (`maxMigratedGaps = 4096`), and pin it from both sides: a sweep above it *and* a case exactly at it. A ceiling test alone cannot distinguish "clamps correctly" from "clamps everything".

### 3. Keep the boundary where the old behaviour still applies

Tolerance should be scoped to the damage it can actually describe. Two boundaries hold this one in place:

- Damage that cannot be split into records — truncated write, non-JSON, a top-level object instead of an array — still takes the whole-file rename path. Asserted for malformed JSON and for a truncated file; the well-formed-top-level-object limb is stated at the source and has no test, which is worth knowing before relying on it.
- Nothing is defaulted into existence. A row missing its `id` or `timestamp` is *dropped*, not fabricated; defaulting those would invent data.

**And say out loud what the tolerance costs.** A renamed file is a complete, hand-recoverable copy. A dropped row has no copy anywhere — heal-on-write was considered and rejected here precisely because a read that deletes is a read that cannot be retried, and the most likely field trigger is version skew (a rollback dropping rows a newer build reads perfectly), not disk damage. Every per-row test therefore also asserts no `.corrupt-` sibling appeared; without that half it is a parsing test, not a data-loss test.

## Why This Matters

Both defects are invisible in review for the same reason: the diff reads as strictly more forgiving. "One bad row should not cost the whole file" and "an odd count should not throw" are obviously right, and neither reviewer nor author is looking at what the `throw` was *doing* — because a `throw` reads as pure signalling.

The failure modes are also the worst kind for a menu-bar app that launches at login. Both manifest at *read* time, on a path that runs before any UI, and both are permanent: the naive loop spins on every launch, and the unbounded fabrication allocates on every launch. Neither produces a crash report a user can send. The pre-tolerance behaviour was loud, lossy, and recoverable; the tolerant behaviour was silent, total, and not.

The generalisation is not about `Codable`. Any time an error path is replaced with a tolerant one, ask what the error was *driving*: a loop's termination, a transaction rollback, a circuit breaker, a retry budget's exhaustion, a supervisor restart. Tolerance is a change to control flow, not only to error reporting.

## When to Apply

- **Any `try?` or `catch` added inside a loop.** Ask what advances the loop, and whether the swallowed error was it.
- **Any decode that becomes lossy, defaulting, or partial.** Enumerate the recovery the throw used to trigger — file rename, cache invalidation, fresh-start — and check it is still reachable from the new failure shape.
- **Any tolerant branch that turns a stored scalar into work** — an allocation, an iteration count, a preallocated capacity, a retry budget. That scalar is now attacker- or corruption-controlled input on a pre-UI path.
- **When scoping the tolerance.** Keep the old whole-object path for damage the record-level path cannot describe, and refuse to default identity fields into existence.
- **Not** a licence to widen. This tolerance lives in exactly one store, on the one file with a bare-array schema (`HistoryStore`). `JSONFileStorage` is unchanged, and `StatsStore`, `InstructionsStore` and `DictionaryStore` still decode whole snapshots and still take the whole-file rename — they are single objects with nothing to split into records. A write-up claiming "the storage layer tolerates bad rows" is false.

## Examples

**The bound, and where it deliberately does not go** (`NoType/History/HistoryEntry.swift`):

```swift
// Bounded: a count read off disk becomes N allocations. Ten bytes of JSON
// buying an unbounded array is the amplification.
let gapsWanted = min(max(0, failedChunkCount), maxMigratedGaps)

// NOT bounded: a stored sequence's gaps are physically in the file, so the
// array cannot be larger than the bytes that carried it.
```

**The fixture that proves advancement rather than termination** (`NoTypeTests/HistoryStoreTests.swift`):

```swift
// first / middle / last. Only the FIRST-row case fails under a cursor bug —
// a corpus that always puts the bad row last proves nothing about advancing.
func test_load_aBadRow_isDroppedWhereverItSits() { … }
```

**The clamp pinned from both sides** — a sweep of `[maxMigratedGaps + 1, 5_000_000, Int.max]` through the pure function, with `Int.max` additionally re-asserted through the real `JSONDecoder` on a JSON row (because that is where a corrupt file actually arrives), plus `test_migration_countAtTheCeiling_isNotClamped`, so the clamp cannot silently rewrite real rows.

## Related

- `NoType/History/CLAUDE.md` invariant 2 — the per-row tolerance contract, its two boundaries, and the product ruling behind it. (The Schema section states the migration rule in two limbs; the four cases live in full on `HistoryEntry.migratedSegments`'s doc-comment and in the four `test_migration_…` functions.)
- [`architecture-patterns/json-file-storage-helper-2026-05-16.md`](../architecture-patterns/json-file-storage-helper-2026-05-16.md) — the shared file-IO layer whose `catch`-based rename is the recovery this entry is about, and the "don't add per-store branching here" rule that decided where the tolerance lives.
- [`architecture-patterns/json-history-store-2026-05-15.md`](../architecture-patterns/json-history-store-2026-05-15.md) — why history is a plain JSON array in the first place, which is what makes record-level tolerance expressible at all.
- [`conventions/testing-spm-and-git-2026-05-15.md`](./testing-spm-and-git-2026-05-15.md) — the fixture rules the corpus above follows: a fixture must be able to express the failure, and a probe must be run rather than reasoned about.
- Commits `0e7391a` (the migration), `82449f8` (the clamp), `dddc3df` (per-row tolerance). Unit U5 of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`. The SHAs are branch-local to `refactor/structural-gap-tracking` and will be rewritten if it squash-merges; the plan path and the module doc are the stable references.
