---
title: Swift 6 strict concurrency and async conventions
date: 2026-05-15
category: conventions
module: cross-cutting
problem_type: convention
component: tooling
severity: high
applies_when:
  - Writing any new Swift module or actor
  - Introducing producer/consumer pipelines
  - Adopting an `@unchecked Sendable` workaround
tags: [swift-6, concurrency, actor, async-await, sendable, asyncstream]
---

# Swift 6 strict concurrency and async conventions

## Context

NoType builds with `SWIFT_STRICT_CONCURRENCY: complete` enabled in `project.yml`. CI treats every concurrency warning as an error. The convention here is the set of rules that lets us stay clean under strict concurrency without scattering ad-hoc workarounds.

## Guidance

- **Strict concurrency is non-negotiable.** Every new file builds clean under `complete`. Don't silence warnings; refactor.
- **`actor` for any shared mutable state.** Current actors: `GeminiClient`, `HistoryStore`, `SileroVAD`. `@MainActor` classes: `RecordingSession`, `AppState`, `PermissionsViewModel`, `OnboardingState`, `AppearanceController`, `HUDController`.
- **No `@unchecked Sendable` without a doc-comment** explaining the lock or thread-confinement that makes it safe. Documented exceptions: `AudioRecorder`, `HotkeyMonitor`, `MicProbe`, `ExceptionBreadcrumb.State` (`NSLock`-guarded; the Objective-C exception preprocessor fires on whichever thread raised).
- **Cross-actor communication via `await`, `AsyncStream`, or `AsyncChannel`.** No callbacks, no completion handlers in new code.
- **`async`/`await` everywhere.** No `DispatchQueue` in new code (legacy callsites can stay until they're touched).
- **For periodic work:** `Task { while !Task.isCancelled { try await Task.sleep(...); … } }`. Inside SwiftUI views, prefer `.task { while !Task.isCancelled { … } }` — `TimelineView`-driven periodic work is **banned** when the content closure would need to call `@MainActor` instance methods on the view: on macOS 26 the inserted executor check crashes during layout. See [timelineview-mainactor-instance-method-crash](../runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md).
- **Never let an ObjC `NSException` escape a `Task { @MainActor }` or `MainActor.run` body.** It unwinds through `libswift_Concurrency` and orphans the thread's `ExecutorTrackingInfo` (stack-allocated, thread-local, pop not exception-safe); AppKit swallows it and resumes, and the next executor check anywhere in the process SIGSEGVs on a dead stack slot. `do/catch` does not help — an `NSException` is not a Swift `Error`. This is the **proven** cause of NoType's macOS 26 executor-identity crash family. In practice it means: AppKit / Foundation / AVFoundation calls that raise on bad arguments (`AVAudioEngine.installTap` with a stale format, `NSWindow.setFrameOrigin` with NaN geometry, `styleMask` mutation mid-configure) are hazardous **specifically** when reached from inside a concurrency job. Prefer validating the argument before the call over hoping something catches. Read [macos-26-executor-identity-check-family](../runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md).
- **Triage rule — split on the signal, then read the *other* threads.** For `swift_task_isCurrentExecutorWithFlagsImpl` in a macOS 26.x crash stack: an **`EXC_BREAKPOINT` / `_dispatch_assert_queue_fail` on a non-main thread** is a real isolation mismatch — look for a closure literal inside a `@MainActor` function that crosses a thread boundary (see [audio-ioproc-mainactor-inheritance-crash](../runtime-errors/audio-ioproc-mainactor-inheritance-crash-2026-05-19.md), where the runtime was right and `@Sendable` was the correct final fix). An **`EXC_BAD_ACCESS` / SIGSEGV at a small integer address** in `swift_getObjectType` / `objc_opt_class` is the exception family above — the crashing frame is an innocent reader, so read the *other* threads and look for a parked thread carrying `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`.
- **Per-call-site executor-check mitigations are mitigations, and stay in force.** Two ship today and both are still correct where they apply — but neither closes the class, because each only deletes a *reader* of the poisoned identity: (1) SwiftUI `TimelineView` content closures calling `@MainActor` instance methods — restructure the closure body or use `.task` (see [timelineview-mainactor-instance-method-crash](../runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md)). (2) SwiftUI `.onHover` (and same-family `.onContinuousHover`, `.onMove`, `.onDrop`, HoverResponder/PressResponder paths) — wrap in `@Sendable` + `Task { @MainActor in ... }` (see [onhover-mainactor-inheritance-crash](../runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md)). The third incident landed on a stock SwiftUI `Button` inside Apple's own `_ButtonGesture`, where no app closure exists to annotate — which is where the per-call-site strategy runs out, and why the cause hunt happened.
- **For producer/consumer:** `AsyncStream` or `AsyncChannel`.
- **`withTaskGroup` for fan-out is rare in this codebase** — most things are serial by design. The load-bearing example is `AccessibilityTree.snapshot()`, which parallelises per-app walks.
- **Cancellation:** every long-running task must either check `Task.isCancelled` or be cancelled by deinit of its owner.

## Why This Matters

Swift 6's data-race safety promise is the whole point of opting in. The moment we ship an `@unchecked Sendable` without explanation or a `nonisolated(unsafe)` to "make the warning go away", we've voluntarily traded that safety for a hidden trap. Future contributors won't know which `@unchecked` is principled and which is a smell. The convention says: any deviation explains itself in a doc-comment at the deviation site.

The async-style rule prevents callback/promise/async hybrids from accumulating. Mixing styles is what makes a Swift module hard to reason about — pick one (we picked `async/await`) and stick to it.

## When to Apply

- Every new Swift file.
- Every touched legacy callsite that uses `DispatchQueue` or completion handlers — migrate as you go, don't leave half.
- Every PR that adds an `@unchecked Sendable` — the reviewer should ask for the explanatory doc-comment if it's missing.

## Examples

**Actor declaration with reasoning:**

```swift
/// Serial Gemini scheduler — at most one request in flight per session.
/// See solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md.
actor GeminiClient { ... }
```

**Documented `@unchecked Sendable`** (from `AudioRecorder.swift`):

```swift
/// `@unchecked Sendable` because the mutating state (`samples` ring) is
/// guarded by `lock`; the tap callback and the VAD consumer always go
/// through it. Verified by the strict-concurrency build.
final class AudioRecorder: @unchecked Sendable { ... }
```

**Periodic task that respects cancellation:**

```swift
Task {
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(1))
        refresh()
    }
}
```

## Related

- `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md` — the most load-bearing actor.
- `solutions/runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md` — concrete macOS 26 anti-pattern the "periodic work" rule's `.task` form sidesteps inside SwiftUI views.
- `solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md` — the proven cause behind the three bullets above: an ObjC exception swallowed by AppKit after unwinding through the concurrency runtime. Also carries the disproven hypotheses (early-launch `MainActor` use, three independent dispatch-path bugs, the check-mode levers) so they don't get re-run.
- `solutions/runtime-errors/audio-ioproc-mainactor-inheritance-crash-2026-05-19.md` — the executor-check family's **counter-example**, not a member; non-Swift framework callbacks inheriting `@MainActor`, where the runtime was right and `@Sendable` was the correct final fix.
- `solutions/runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md` — second same-signature incident; SwiftUI `.onHover` modifier closures inheriting `@MainActor`. The `dsOnHover` wrapper at `NoType/UI/DSComponents.swift` is the canonical example of the `@Sendable` + `Task { @MainActor in ... }` bridge pattern.
- `solutions/runtime-errors/sender-respawn-race-2026-05-16.md` — sibling Swift concurrency footgun (point-in-time await across respawn).
- `solutions/conventions/closure-scoped-return-trap-2026-05-16.md` — sibling Swift-idiom-trap learning (`return` inside `withUnsafe*`).
- `docs/conventions.md` — legacy index, redirects here.
