---
title: Sender-respawn race — Task.detached wrapper loses respawned work behind a one-shot await
date: 2026-05-16
category: runtime-errors
module: Recording
problem_type: runtime_error
component: tooling
symptoms:
  - "`.noSpeech` error after a normal recording session"
  - "Final chunk's audio silently never reaches Gemini"
  - "responses[] is empty in `stop()` even though the user clearly spoke (was `transcripts[]` before PR #39)"
root_cause: async_timing
resolution_type: code_fix
severity: high
tags: [swift, swift-6, actor, task-detached, race-condition, lifecycle, async-await]
---

# Sender-respawn race — Task.detached wrapper loses respawned work behind a one-shot await

## Problem

In `RecordingSession`, the sender drains the `pending` chunk queue in a `Task.detached` wrapper that ends by calling `markSenderFinished()` on the main actor. When that finalizer respawns a fresh sender to handle late-arriving work, the caller awaiting the **old** sender's wrapper returns as soon as the old wrapper finishes — it never picks up the new Task, so the respawned work stays unprocessed.

The user-visible symptom: a session ends with `SessionError.noSpeech` even though the user actually spoke. The final-chunk audio is sitting in `pending` indefinitely, with nothing draining it.

## Symptoms

- `SessionError.noSpeech` thrown by `RecordingSession.stop()` after sessions that clearly contained speech
- `responses: []` at the throw site, even though VAD enqueued chunks (renamed from `transcripts: []` in PR #39's partial-recovery refactor; same field, different name)
- Final chunk's PCM lingers in the recorder's ring buffer after the session ends
- Only reproduces under a narrow timing window — most sessions look fine

## What Didn't Work

**Attempt 1 (PR #38, first commit) — respawn inside `markSenderFinished`.** Adding:

```swift
private func markSenderFinished() {
    senderTask = nil
    if !pending.isEmpty && failure == nil {
        ensureSenderRunning()  // spawn TaskB
    }
}
```

closed the race for the **mid-recording** path (where VAD's `enqueueChunk` arrives between `runSender` returning and `markSenderFinished` running) — TaskB now drains the orphan.

But it left the **release path** broken. In `stop()`:

```swift
await emitFinalChunkIfAny()       // adds final chunk to `pending`
await senderTask?.value           // expression evaluates senderTask ONCE → captures TaskA
```

If TaskA's wrapper is between "runSender returned" and "markSenderFinished runs," `senderTask` is still TaskA at expression-evaluation time. `stop()` awaits TaskA. TaskA's wrapper finishes via `markSenderFinished`, which respawns into TaskB and clears `senderTask` to TaskB. TaskA's `.value` resolves immediately. `stop()` resumes, finds `responses == []` (named `transcripts` at the time of PR #38; renamed in PR #39's partial-recovery refactor), throws `.noSpeech`. TaskB hasn't even started yet — by the time it runs, the result is discarded.

The respawn happened. The await missed it.

## Solution

Drain in a loop so every respawn is observed:

```swift
// Drain the sender. A single `await senderTask?.value` would
// capture whichever Task ref is current at evaluation time — but
// `markSenderFinished` may respawn into a fresh Task while we're
// suspended on the dying one. Loop until the field is genuinely
// nil so every respawn is awaited.
while let task = senderTask {
    await task.value
}
```

Each iteration re-reads `senderTask` after the previous await resolved. If `markSenderFinished` cleared the field cleanly (no pending) the loop exits. If it respawned, the loop picks up the new Task and waits.

## Why This Works

`Task.detached { ... }.value` resolves when **that specific Task's closure completes** — not "when whatever the field points to next is done." Swift's expression evaluation captures the optional once; the await binds to that captured reference.

When the wrapper's closure ends with `await self?.markSenderFinished()` and that call respawns a successor, the wrapper's closure still finishes immediately afterward (markSenderFinished returns Void). The wrapper's `.value` resolves. The new Task is a separate `.value` to await.

Re-reading the field in a loop converts "await the current Task ref once" into "await the chain until the field is nil," which is what we actually want.

## Prevention

- **For any `Task.detached { ... }` wrapper that ends by calling a respawning finalizer:** drain via `while let task = field { await task.value }`, not `await field?.value`.
- **A finalizer that respawns must coexist with a caller that loops.** If you add respawn semantics to a `markFinished` method, audit every `await senderTask?.value` (or analog) call site — point-in-time awaits become silent bugs.
- **Treat "field captured once at evaluation" as a Swift concurrency footgun.** Same trap shows up with `await observers.first?.callback`, `await pool.head?.complete`, anywhere a field is mutated under us while we suspend.
- **The serial-actor invariant doesn't enforce itself by construction.** [serial-gemini-actor](../architecture-patterns/serial-gemini-actor-2026-05-15.md) describes the rule ("one Gemini request in flight"); the implementation must defend the invariant at every Task lifecycle handoff. The respawn-race fix is implementation enforcement, not a pattern change.

Sister learnings — both are cases where a Swift idiom silently does less than the reader expects:

- [closure-scoped-return-trap](../conventions/closure-scoped-return-trap-2026-05-16.md) — `return` inside `withUnsafe*` only escapes the closure; `await field?.value` across respawn captures the field once.
- [timelineview-mainactor-instance-method-crash](timelineview-mainactor-instance-method-crash-2026-05-16.md) — calling a `@MainActor` instance method from inside a TimelineView content closure inserts a runtime executor check that crashes on macOS 26.

## Related Issues

- PR #38 — both commits (initial respawn-in-finalizer, then the stop() drain-loop)
- [conventions/closure-scoped-return-trap-2026-05-16.md](../conventions/closure-scoped-return-trap-2026-05-16.md) — sibling Swift-idiom-trap learning
- [runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md](timelineview-mainactor-instance-method-crash-2026-05-16.md) — sibling macOS 26 Swift concurrency runtime failure from the same discovery window
- [architecture-patterns/serial-gemini-actor-2026-05-15.md](../architecture-patterns/serial-gemini-actor-2026-05-15.md) — the "one in flight" invariant whose implementation had the leak
- [conventions/swift-6-concurrency-and-async-2026-05-15.md](../conventions/swift-6-concurrency-and-async-2026-05-15.md) — the broader strict-concurrency conventions this falls under
- `NoType/Recording/RecordingSession.swift` `stop()` + `markSenderFinished()` — canonical fix sites
