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
- **No `@unchecked Sendable` without a doc-comment** explaining the lock or thread-confinement that makes it safe. Documented exceptions: `AudioRecorder`, `HotkeyMonitor`, `MicProbe`.
- **Cross-actor communication via `await`, `AsyncStream`, or `AsyncChannel`.** No callbacks, no completion handlers in new code.
- **`async`/`await` everywhere.** No `DispatchQueue` in new code (legacy callsites can stay until they're touched).
- **For periodic work:** `Task { while !Task.isCancelled { try await Task.sleep(...); … } }`. Inside SwiftUI views, prefer `.task { while !Task.isCancelled { … } }` — `TimelineView`-driven periodic work is **banned** when the content closure would need to call `@MainActor` instance methods on the view: on macOS 26 the inserted executor check crashes during layout. See [timelineview-mainactor-instance-method-crash](../runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md).
- **macOS 26 executor-check family — three known instances.** Any closure literal whose isolation is inherited (per SE-0420) and whose dispatcher hands the runtime a malformed `SerialExecutorRef` can trip the same `swift_task_isCurrentExecutorWithFlagsImpl` → `swift_getObjectType` SIGSEGV at a small faulting address (`0x1` is what we've observed). Known instances and fixes: (1) SwiftUI `TimelineView` content closures calling `@MainActor` instance methods — restructure the closure body or use `.task` (see [timelineview-mainactor-instance-method-crash](../runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md)). (2) Non-Swift framework callbacks (Core Audio HAL, CGEventTap, CFRunLoop) created inside a `@MainActor` function — mark the closure `@Sendable` (see [audio-ioproc-mainactor-inheritance-crash](../runtime-errors/audio-ioproc-mainactor-inheritance-crash-2026-05-19.md)). (3) SwiftUI `.onHover` modifier (and same-family `.onContinuousHover`, `.onMove`, `.onDrop`, HoverResponder/PressResponder paths) — wrap in `@Sendable` + `Task { @MainActor in ... }` (see [onhover-mainactor-inheritance-crash](../runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md)). When you see `swift_task_isCurrentExecutorWithFlagsImpl` in a crash stack on macOS 26.x, treat it as an actor-isolation mismatch first — even when the failing thread is the main thread.
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
- `solutions/runtime-errors/audio-ioproc-mainactor-inheritance-crash-2026-05-19.md` — second member of the macOS 26 executor-check family; non-Swift framework callbacks inheriting `@MainActor`.
- `solutions/runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md` — third member; SwiftUI `.onHover` modifier closures inheriting `@MainActor`. The `dsOnHover` wrapper at `NoType/UI/DSComponents.swift` is the canonical example of the `@Sendable` + `Task { @MainActor in ... }` bridge pattern.
- `solutions/runtime-errors/sender-respawn-race-2026-05-16.md` — sibling Swift concurrency footgun (point-in-time await across respawn).
- `solutions/conventions/closure-scoped-return-trap-2026-05-16.md` — sibling Swift-idiom-trap learning (`return` inside `withUnsafe*`).
- `docs/conventions.md` — legacy index, redirects here.
