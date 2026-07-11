---
title: Sender-respawn race — Task.detached wrapper loses respawned work behind a one-shot await
date: 2026-05-16
last_updated: 2026-07-10
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
tags: [swift, swift-6, actor, task-detached, race-condition, lifecycle, async-await, cancellation]
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

## Sibling races around `stop()`'s suspension points (PR-A)

The respawn race above is one instance of a broader hazard: `RecordingSession.stop()` runs its sender drain-loop (`while let task = senderTask { await task.value }`) across **suspension points**, and any lifecycle transition that lands *during* that suspension can violate a contract `stop()` only checked at its top. PR-A (Recording & session correctness) closed two more races of exactly this shape.

### U2 — cancel latch must be set first, and re-checked before the paste

`cancel()` (Esc, the cancel binding, the recording-HUD close button, or the AX-revoke unwind in U4) can fire while `stop()` is suspended in the drain-loop. `stop()`'s early `if let err = failure` guard runs *before* the drain, so a cancel landing mid-drain slipped past it — and the previous ordering set `failure = CancellationError()` only at the *end* of `cancel()`, after `recorder.stop()` and two `await` points. That left a window where a resuming `stop()` pasted and wrote history for a session the user had already cancelled.

Two moves close it:

1. **Latch synchronously at the source.** `failure = CancellationError()` is now the *first* statement of `cancel()`, before `recorder.stop()` / `senderTask?.cancel()` / `vadTask?.cancel()` and both awaits.
2. **Re-check at the last synchronous point before the side effect.** `stop()` calls the pure `shouldAbortBeforePaste(failureIsSet: failure != nil, taskIsCancelled: Task.isCancelled)` immediately before `TextInjector.paste`, and throws `failure ?? CancellationError()` when it fires — routing into `finalizeRecording`'s `catch is CancellationError` arm (no paste, no history, no double sleep-assertion release). A cancel landing *after* `paste` begins is genuinely late and acceptable — the text is already in flight.

The general rule: **a one-shot guard at the top of an async method does not cover a transition that lands while the method is suspended.** Latch the cancel synchronously at the source *and* re-verify at the last synchronous instruction before the irreversible side effect.

### U3 — a cancelled session must stop feeding the app-shared VAD actor

`SileroVAD` is an *app-shared, stateful* actor — one instance reused across sessions, carrying hidden/cell state plus a 64-sample look-back that each session zeroes via `vad.reset()` at start (Recording invariant 8). The per-session VAD consumer loop kept pulling frames and calling `vad.probability(...)` after its session was cancelled, so a cancelled session A's late frames could interleave with the next session B's `vad.reset()` and opening frames — corrupting B's inference state.

Fix: `if Task.isCancelled { break }` at the top of the consumer loop. `cancel()` calls `vadTask?.cancel()`, so the flag is observed by the next frame.

The general rule: **a per-session `Task` that feeds a process-shared stateful actor must break on `Task.isCancelled` before every submission.** Cancelling the owning session is not enough — the shared actor keeps accepting the feeder's next frame until the feeder itself stops.

## Prevention

- **For any `Task.detached { ... }` wrapper that ends by calling a respawning finalizer:** drain via `while let task = field { await task.value }`, not `await field?.value`.
- **A finalizer that respawns must coexist with a caller that loops.** If you add respawn semantics to a `markFinished` method, audit every `await senderTask?.value` (or analog) call site — point-in-time awaits become silent bugs.
- **Treat "field captured once at evaluation" as a Swift concurrency footgun.** Same trap shows up with `await observers.first?.callback`, `await pool.head?.complete`, anywhere a field is mutated under us while we suspend.
- **The serial-actor invariant doesn't enforce itself by construction.** [serial-gemini-actor](../architecture-patterns/serial-gemini-actor-2026-05-15.md) describes the rule ("one Gemini request in flight"); the implementation must defend the invariant at every Task lifecycle handoff. The respawn-race fix is implementation enforcement, not a pattern change.
- **A guard at the top of an async method is not a cancellation check for the whole method.** If the method has suspension points and ends in an irreversible side effect (paste, network write, disk commit), re-check the cancel latch synchronously right before that side effect — the transition can land while you're suspended. Extract the check as a pure function (`shouldAbortBeforePaste`) so a test pins it without a live session (U2).
- **Set a cancellation latch as the first synchronous statement of `cancel()`, before any teardown call or `await`.** A latch installed after the awaits leaves a window where a racing consumer resumes into the un-latched state (U2).
- **A `Task` feeding a process-shared stateful actor must break on `Task.isCancelled` before each submission.** Cancelling the session doesn't stop the shared actor from accepting the feeder's next frame; only the feeder stopping does (U3, VAD drain).

Sister learnings — both are cases where a Swift idiom silently does less than the reader expects:

- [closure-scoped-return-trap](../conventions/closure-scoped-return-trap-2026-05-16.md) — `return` inside `withUnsafe*` only escapes the closure; `await field?.value` across respawn captures the field once.
- [timelineview-mainactor-instance-method-crash](timelineview-mainactor-instance-method-crash-2026-05-16.md) — calling a `@MainActor` instance method from inside a TimelineView content closure inserts a runtime executor check that crashes on macOS 26.

## Related Issues

- PR #38 — both commits (initial respawn-in-finalizer, then the stop() drain-loop)
- PR-A (Recording & session correctness) — U2 (cancel-latch-first + `shouldAbortBeforePaste` pre-paste re-check) and U3 (VAD drain `Task.isCancelled` break). Unmerged to `main` as of 2026-07-10 (branch `remediation/pr-a-recording-correctness`).
- [design-patterns/consuming-cgeventtap-teardown-2026-05-18.md](../design-patterns/consuming-cgeventtap-teardown-2026-05-18.md) — U4 is the AppState-side sibling of this family: on Accessibility revoke, `applyAccessibilityState()` calls `cancelRecording()` (gated by the pure `shouldCancelActiveSessionOnAxRevoke`) *before* `uninstallHotkey()`, so the tap that delivers the session's release / Esc events isn't torn down under a live session — which would otherwise strand it with the mic hot. Relies on `releaseSleepAssertion()` idempotence for exactly-once release.
- [conventions/closure-scoped-return-trap-2026-05-16.md](../conventions/closure-scoped-return-trap-2026-05-16.md) — sibling Swift-idiom-trap learning
- [runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md](timelineview-mainactor-instance-method-crash-2026-05-16.md) — sibling macOS 26 Swift concurrency runtime failure from the same discovery window
- [architecture-patterns/serial-gemini-actor-2026-05-15.md](../architecture-patterns/serial-gemini-actor-2026-05-15.md) — the "one in flight" invariant whose implementation had the leak
- [conventions/swift-6-concurrency-and-async-2026-05-15.md](../conventions/swift-6-concurrency-and-async-2026-05-15.md) — the broader strict-concurrency conventions this falls under
- `NoType/Recording/RecordingSession.swift` `stop()` (top guard + pre-paste re-check) + `cancel()` (latch-first) + `markSenderFinished()` + the VAD consumer loop — canonical fix sites. Pinned by `RecordingSessionCancellationTests` (U2 `shouldAbortBeforePaste` contract) and `AppStateAxRevokeTests` (U4 `shouldCancelActiveSessionOnAxRevoke`).
