---
title: The ten-entry cap can evict a row mid-retry, and the exit reads that as a user deletion
date: 2026-08-13
category: documentation-gaps
module: History
problem_type: documentation_gap
component: tooling
severity: medium
---

# The ten-entry cap can evict a row mid-retry, and the exit reads that as a user deletion

## Context

`AppState.settleRetry` has three exits, and the first is:

```swift
guard history.contains(where: { $0.id == entryID }) else {
    retainedAudio.remove(entryID)
    …
    return
}
```

Its comment explains the exit as the user having deleted the row while the run
was in flight — delete stays available during a retry by design, so releasing
the payload is right: *"the user asked for the row to be gone."*

**There is a second way to reach it, and the reasoning does not cover it.** A
retry does not set `recordingState`, so `handleHotkeyPress`'s `guard case .idle`
does not block a new dictation from starting beside one. That dictation ends in
`recordHistoryEntry`, which appends and then trims the mirror to
`historyMirrorCap`:

```swift
history.append(entry)
if history.count > Self.historyMirrorCap {
    history.removeFirst(history.count - Self.historyMirrorCap)
}
```

If the row under retry is the oldest, it is the one trimmed. `settleRetry` then
finds `history.contains == false` and takes Exit 1 — **discarding the payload
and the run's merged result, having logged "retry settled onto a deleted row"
for a row the user never deleted.** `merged` is computed above the guard and is
simply not written, so text that genuinely recovered is thrown away along with
the audio for everything that did not. `RetainedAudioStore.take` already handed
out the only copy, so there is nothing to recover from.

The window is small (it needs a retry slow enough to overlap a whole new
dictation, on a history already at the cap, with the retried row oldest) and
the user-visible outcome is "the transcript I was recovering is gone" — which
is also what an ordinary cap eviction looks like, so it is unlikely to be
reported as a bug.

**Why this is filed rather than fixed.** The plan that surfaced it puts *"the
ten-entry history cap and its eviction contract"* and *"whether a retry may run
beside a recording session"* in Scope Boundaries — both explicitly out of
scope. Fixing it means changing one of them, which is a product decision about
what the cap promises, not a defect fix inside the retry.

## Guidance

Leave as-is. Note that the *safe* half already holds: nothing is corrupted and
no wrong text is written — a real recovery is dropped, which is a loss, not a
lie. When it is picked up, three shapes, in increasing cost:

1. **Distinguish the two causes at the exit.** The cheapest correct move is to
   stop calling an eviction a deletion: log them differently, so the case is
   diagnosable from a user's Console output at all. This alone changes no
   behaviour and closes the "it looks identical to an ordinary eviction" half.
2. **Exempt the retrying row from the trim.** `retryingEntryID` is a single
   slot and is already `@MainActor` state beside `history`, so the trim could
   skip it and take the next-oldest. That mutates the cap's contract ("the
   oldest is evicted") for one row, which is exactly the boundary the plan drew.
3. **Block the append, or block the retry.** Either direction resolves it
   without touching the cap, and both are the concurrent-session question in
   disguise — see the sibling entry on the silent hotkey refusal.

Do **not** "fix" it by re-putting the payload in Exit 1: that resurrects a
payload keyed by a row that no longer exists, which is unreachable memory no
`retain(only:)` will visit until the next history mutation. Exit 1's release is
correct for the case it was written for, and that is the whole difficulty.

## Why This Matters

The audio a broken row holds is the only copy in existence — never written to
disk, gone at process exit (architecture invariant I4). Every other path out of
a retry is written to be careful with it, and the invariant that makes those
paths auditable is *"every exit must re-put what it did not recover, or
deliberately release it."* This exit releases deliberately for one cause and
incidentally for another, so the audit passes while a case slips through.

## When to Apply

- Anyone changing `historyMirrorCap` / `HistoryStore.cap`, the trim in
  `recordHistoryEntry`, or the guard ladder in `handleHotkeyPress`.
- Any work that lets a recording start beside a transcription or a retry — that
  change makes this window ordinary rather than narrow.
- A report of a broken row losing its retry after an unrelated dictation.

## Examples

The two callers that reach the same exit, for opposite reasons:

```swift
// deleteHistoryEntry — the case the exit was written for.
history.removeAll { $0.id == id }
retainedAudio.remove(id)          // targeted; "this is not an eviction"

// recordHistoryEntry — the case it also catches.
history.append(entry)
if history.count > Self.historyMirrorCap {
    history.removeFirst(history.count - Self.historyMirrorCap)   // ← may take the retried row
}
retainedAudio.retain(only: liveHistoryIDs)
```

## Related

- Source plan: `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`
  — Scope Boundaries (the ten-entry cap and its eviction contract; whether a
  retry may run beside a recording session).
- `NoType/History/CLAUDE.md` invariants 1 and 4, and "Broken rows and retry".
- `NoType/History/RetainedAudioStore.swift` — the `take` contract and the
  trigger table for `remove(_:)` vs `retain(only:)`.
- [`gate-irreversible-actions-on-the-outcome`](../conventions/gate-irreversible-actions-on-the-outcome-2026-08-09.md)
  — the convention this is a residual case of: the exit's guard reads "is the
  row still there", which predicts "the user deleted it" and is not the same
  fact.
- [`concurrent-recording-and-the-silent-hotkey-refusal`](concurrent-recording-and-the-silent-hotkey-refusal-2026-08-13.md)
  — the sibling entry; resolving that one resolves this one as a side effect.
