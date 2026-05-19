---
title: Core Audio HAL IOProc closure inherits @MainActor → SIGTRAP on macOS 26
date: 2026-05-19
category: runtime-errors
module: Recording
problem_type: runtime_error
component: tooling
symptoms:
  - "EXC_BREAKPOINT (SIGTRAP), code 0x1 / 0x000000018256a4fc in `_dispatch_assert_queue_fail`"
  - "Triggered by Thread: `com.apple.audio.IOThread.client`, Dispatch Queue: `app.notype.recording.ioproc`"
  - "Stack: `_dispatch_assert_queue_fail` ← `dispatch_assert_queue` ← `_swift_task_checkIsolatedSwift` ← `swift_task_isCurrentExecutorWithFlagsImpl` ← `closure #1 in AudioRecorder.openAndStartHAL() + 132`"
  - "Crash fires on the very first IOProc invocation after `AudioDeviceStart` (≈10–50 ms into recording, before any audio buffers are processed)"
  - "Reliable on macOS 26 (Tahoe); the same compiled binary did not trap on macOS 15"
root_cause: thread_violation
resolution_type: code_fix
severity: critical
tags: [swift-6, concurrency, mainactor, macos-26, audio, hal, ioproc, recording]
---

# Core Audio HAL IOProc closure inherits @MainActor → SIGTRAP on macOS 26

## Problem

`AudioRecorder.openAndStartHAL()` passes a Swift closure literal as the IOProc block to `AudioDeviceCreateIOProcIDWithBlock`. Core Audio invokes that block on the recorder's dedicated `ioQueue` (`app.notype.recording.ioproc`) — not on the main queue. On macOS 26 the runtime traps with `EXC_BREAKPOINT` at the closure prologue before any audio data is touched, taking the whole app down on the user's first hotkey press.

## Symptoms

- `EXC_BREAKPOINT (SIGTRAP)` reported by the OS crash reporter; the failing thread is the HAL IO thread, not the main thread.
- The crashing frame is `closure #1 in AudioRecorder.openAndStartHAL() + 132` — the `+132` offset is the closure's prologue, not anywhere in `handleIOProc`.
- Above it in the stack: `swift_task_isCurrentExecutorWithFlagsImpl` → `_swift_task_checkIsolatedSwift` → `dispatch_assert_queue` → `_dispatch_assert_queue_fail`.
- Reproduces on every recording attempt. macOS 15 builds with the same source did not trap — this is a runtime-behavior regression in macOS 26's concurrency runtime, not a Swift-compiler change.

## What Didn't Work

**Assuming the closure was already non-isolated because `handleIOProc` is non-isolated.** The closure literal's isolation is decided at the point the literal is *written*, not at the point the captured method is *called*. `openAndStartHAL()` is annotated `@MainActor`, so the closure literal it contains inherits `@MainActor` even though the body only calls a non-isolated method.

**Assuming `@convention(block)` (Objective-C block bridging) would strip the inheritance.** It strips the Swift calling convention but does not strip inherited actor isolation. The closure still carries an "expected executor" reference and the runtime still checks it on entry.

**Assuming a `[weak self]` capture changed the isolation.** Captures are an orthogonal axis. `[weak self]` only changes how `self` is retained; it has no effect on the closure's actor context.

## Solution

Add `@Sendable` to the closure literal so it does **not** inherit `@MainActor`:

```swift
// BEFORE (crashes on macOS 26)
let createStatus = AudioDeviceCreateIOProcIDWithBlock(
    &procID,
    device.id,
    ioQueue
) { [weak self] _, inInputData, _, _, _ in
    self?.handleIOProc(inputData: inInputData)
}

// AFTER (matches handleIOProc's actual non-isolated declaration)
let createStatus = AudioDeviceCreateIOProcIDWithBlock(
    &procID,
    device.id,
    ioQueue
) { @Sendable [weak self] _, inInputData, _, _, _ in
    self?.handleIOProc(inputData: inInputData)
}
```

That's the whole fix — one keyword. `handleIOProc` is already declared without `@MainActor`, so `self?.handleIOProc(...)` from a non-isolated closure compiles and runs without a hop.

## Why This Works

Per SE-0420 (*Inheritance of actor isolation*): a closure literal inherits the actor isolation of its enclosing context **unless** it is `@Sendable`, `@isolated(any)`, or carries an explicit isolation annotation. The Swift compiler inserts the actor-isolation check as part of every closure that inherits isolation — the prologue effectively asserts "I am running on my expected executor" before executing the body.

Pre-macOS-26, `_swift_task_checkIsolatedSwift` was permissive about how it satisfied the check — many implementations treated it as a no-op when the runtime couldn't cheaply prove the executor identity. macOS 26 tightened this: when the expected executor is `MainActor.shared`, the check delegates to `dispatch_assert_queue(dispatch_get_main_queue())`. Core Audio invokes the IOProc block on `ioQueue`, the assert fails, libdispatch traps with `EXC_BREAKPOINT`.

`@Sendable` strips the inherited isolation. The closure becomes non-isolated, the prologue check is omitted, and the body — which only calls a non-isolated method — runs cleanly on `ioQueue` as intended.

## Prevention

- **Any Swift closure passed to a non-Swift framework (Core Audio, CGEventTap, `CFRunLoop`, IOKit blocks, `kqueue` handlers, etc.) created inside a `@MainActor` function should be marked `@Sendable`.** The framework has no concept of Swift actor isolation and will call the closure on whatever thread its API contract specifies. Inheriting `@MainActor` is almost always wrong for these call sites.
- **The opposite is also true:** if the closure body *does* need to touch `@MainActor` state, do not strip the isolation — instead, bridge explicitly with `MainActor.assumeIsolated { ... }` or hop via `Task { @MainActor in ... }`. Don't make `@Sendable` the reflexive answer; make it the answer when the body is honestly non-isolated. The `dsOnHover` wrapper in `NoType/UI/DSComponents.swift` (see [`onhover-mainactor-inheritance-crash-2026-05-19.md`](./onhover-mainactor-inheritance-crash-2026-05-19.md)) is the canonical example of the `Task { @MainActor in ... }` form. It deliberately chose the async hop over `MainActor.assumeIsolated` because the latter ultimately calls `_taskIsCurrentExecutor` (same family as the original crash) and traps unconditionally if the closure ever fires off-main.
- **When you see `swift_task_isCurrentExecutorWithFlagsImpl` anywhere in a crash stack on macOS 26, treat it as an actor-isolation mismatch first** — not as a memory bug or a framework bug. Look for a closure literal inside a `@MainActor` function that crosses a thread boundary at runtime.
- **A targeted regression test would be valuable** — pin that `openAndStartHAL`'s IOProc closure is `@Sendable` (or equivalently, that it does not inherit MainActor). No such test exists today; the recording path lives behind a hardware-smoke protocol (see `NoType/Recording/CLAUDE.md` "Testing"). Worth a `documentation-gaps/` entry if this recurs.

## Related

- [`solutions/runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md`](./timelineview-mainactor-instance-method-crash-2026-05-16.md) — same underlying runtime mechanism (`swift_task_isCurrentExecutorWithFlagsImpl`), different framework (SwiftUI TimelineView vs Core Audio HAL), different fix (restructure closure body to avoid instance methods vs add `@Sendable`). Cross-references each other because both surface as "macOS 26 trap originating in `_swift_task_*Impl`" — start at whichever doc is closer to your crashing module.
- [`solutions/runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md`](./onhover-mainactor-inheritance-crash-2026-05-19.md) — third member of the macOS 26 executor-check family. SwiftUI `.onHover` modifier closures inheriting `@MainActor`; fixed via the `dsOnHover` wrapper at `NoType/UI/DSComponents.swift` that pairs `@Sendable` (this file's pattern) with `Task { @MainActor in ... }` to bridge back for `@State` writes.
- `NoType/Recording/CLAUDE.md` — owns the recording module's threading rules. The "No `AVAudioEngine` in the recording path" hard rule is adjacent context; this fix is about the IOProc block's actor isolation, not its dispatch queue.
- `solutions/conventions/swift-6-concurrency-and-async-2026-05-15.md` — Swift 6 strict-mode conventions for the project. Worth a follow-up addition there pinning the "non-Swift-framework callbacks need `@Sendable`" rule project-wide.
