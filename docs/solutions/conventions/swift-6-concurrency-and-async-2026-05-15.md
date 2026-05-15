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
- **For periodic work:** `Task { while !Task.isCancelled { try await Task.sleep(...); … } }`.
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
- `docs/conventions.md` — legacy index, redirects here.
