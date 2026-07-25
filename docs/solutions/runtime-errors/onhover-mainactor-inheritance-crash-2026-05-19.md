---
title: SwiftUI `.onHover` closure inherits @MainActor → EXC_BAD_ACCESS on macOS 26.2
date: 2026-05-19
category: runtime-errors
module: UI
problem_type: runtime_error
component: tooling
symptoms:
  - "EXC_BAD_ACCESS (SIGSEGV), `KERN_INVALID_ADDRESS at 0x0000000000000001`"
  - "Triggered by Thread 0 (main-thread), Dispatch Queue: `com.apple.main-thread`"
  - "Stack: `swift_getObjectType` ← `swift_task_isMainExecutorImpl` ← `swift::SerialExecutorRef::isMainExecutor()` ← `swift_task_isCurrentExecutorWithFlagsImpl` ← `<NoType closure>` ← `partial apply for closure #1 in HoverResponder.updatePhase(_:)` ← `Update.dispatchActions` ← `NSHostingView.sendHoverEvent` ← `NSHostingView.mouseMoved`"
  - "Crash fires the first time the cursor moves over a hover-tracked SwiftUI view in NoType's main window"
  - "Reliable on macOS 26.2 (build 25C56); the same compiled binary did not trap on macOS 15"
root_cause: thread_violation
resolution_type: code_fix
severity: critical
tags: [swiftui, onhover, hoverresponder, swift-6, concurrency, mainactor, macos-26, observation]
---

# SwiftUI `.onHover` closure inherits @MainActor → EXC_BAD_ACCESS on macOS 26.2

## Problem

Every `.onHover { hovered = $0 }` modifier written inside a `@MainActor` View body in NoType crashes the app the first time the user hovers over the affected view on macOS 26.2. The closure literal inherits `@MainActor` per SE-0420; the compiler-inserted prologue calls `swift_task_isCurrentExecutorWithFlagsImpl` to confirm the current executor is `MainActor.shared`; on macOS 26.2 the SerialExecutorRef that SwiftUI's `HoverResponder.updatePhase(_:)` hands the concurrency runtime carries an invalid identity (faulting at `0x1`); `swift_getObjectType` segfaults reading the executor's isa.

This is the third instance of the same macOS 26 concurrency-runtime family. Previous fixes:

1. **PR #41 (2026-04 / 2026-05-15)** — `TimelineView` content closures calling `@MainActor` instance methods. Fix shape: avoid the dispatch path entirely (`.task` driver loop instead of `TimelineView` for mutable state) or use only `Self.static` helpers + `let` props inside the closure. See [`timelineview-mainactor-instance-method-crash-2026-05-16.md`](./timelineview-mainactor-instance-method-crash-2026-05-16.md).
2. **PR #53 / cd36c48 (2026-05-19)** — `AudioDeviceCreateIOProcIDWithBlock` closure literal inheriting `@MainActor` from the enclosing recorder method. Fix shape: add `@Sendable` to strip the inheritance. See [`audio-ioproc-mainactor-inheritance-crash-2026-05-19.md`](./audio-ioproc-mainactor-inheritance-crash-2026-05-19.md).
3. **This entry** — SwiftUI `.onHover` modifier closures inheriting `@MainActor`. Fix shape: strip inheritance with `@Sendable`, then hop back to MainActor with `Task { @MainActor in … }` for the `@State` write. `MainActor.assumeIsolated` was considered and **rejected** as that bridge — see *What Didn't Work* below. Wrapped behind a single `dsOnHover` helper applied to every `.onHover` site in the app.

## Symptoms

- `EXC_BAD_ACCESS (SIGSEGV)` reported by the OS crash reporter; the failing thread is the main thread (not a HAL / dispatch thread, unlike the audio crash).
- The faulting address is a small integer — `0x1` was observed in the wild crash; we expect any small value an executor identity slot could hold.
- The crashing frame is `swift_getObjectType + 40`. One frame up: `swift_task_isMainExecutorImpl + 36`. Two frames up: `SerialExecutorRef::isMainExecutor()`. The NoType frame between the runtime and SwiftUI is short — it's the prologue of our `.onHover` closure literal calling the executor check before running the body.
- Five frames up: `partial apply for closure #1 in HoverResponder.updatePhase(_:)` — the SwiftUI internal that drives hover responder callbacks on macOS 26.
- Reproduces on every cursor movement over a hover-tracked view (NoType has 28 such sites: every `DSPrimaryButton`, `DSSecondaryButton`, history row, Dictionary chip, etc.).
- macOS 15 builds with the same source do not trap — this is a runtime-behavior regression in macOS 26.2's tightened executor identity check, not a Swift-compiler change.
- The wild crash was version 0.1.8 build 10, macOS 26.2 (25C56), Mac15,7 (M3 chip).

## What Didn't Work

**Treating `.onHover { hovered = $0 }` as semantically safe.** Pre-macOS-26, mutating a `@State` Bool inside an `.onHover` closure was the textbook idiom — the closure was `@MainActor`-isolated (inherited), the `@State` write was `@MainActor`-required, the executor check was a no-op when the runtime couldn't cheaply prove identity. macOS 26.2 broke that no-op behaviour. The idiom is now load-bearing on a runtime path that crashes.

**Assuming this was a SwiftUI memory bug.** The captured `self` is a value-type View struct; `@State` is owned by SwiftUI's own state machinery; there is no obvious aliasing or use-after-free in our code. Tools like Address Sanitizer surface nothing because the freed/invalid object is internal to the concurrency runtime, not ours.

**Assuming the prior PR #41 / PR #53 fixes covered the class.** They didn't. PR #41 was about `TimelineView`; PR #53 was about non-Swift framework callbacks (Core Audio HAL). `.onHover` is neither — it's a first-class SwiftUI modifier whose closure runs on the main thread but trips the same broken executor identity check.

**Adding `@Sendable` to the closure alone.** That strips the inherited `@MainActor` (good — the prologue check goes away) but then the `hovered = $0` write doesn't compile because `@State` is `@MainActor`-isolated. You need both: `@Sendable` on the literal AND a bridge inside that re-enters MainActor for the write.

**Using `MainActor.assumeIsolated` as the bridge.** Tempting because it's synchronous — the `@State` write lands in the same SwiftUI tick as the cursor event. But `assumeIsolated` ultimately calls `_taskIsCurrentExecutor` (the same `swift_task_isCurrentExecutor*` family as the wild crash) and traps unconditionally if SwiftUI ever dispatches `.onHover` off-main. `NSHostingView.mouseMoved` runs on the main thread today, but that's an AppKit invariant, not a guarantee. A future macOS minor moving hover delivery off-main (drag preview, window restore, scene-graph background diffing — paths called out below as same-family risk) would trade the SIGSEGV for an `EXC_BREAKPOINT` — same user impact, different signal. We chose the fail-soft `Task { @MainActor in ... }` bridge instead.

## Solution

A single `dsOnHover` wrapper at the end of `NoType/UI/DSComponents.swift` that pairs both required pieces, applied to every `.onHover` site in the app:

```swift
extension View {
    func dsOnHover(_ action: @escaping @MainActor (Bool) -> Void) -> some View {
        onHover { @Sendable isHovering in
            Task { @MainActor in action(isHovering) }
        }
    }
}
```

Call-site change is mechanical:

```swift
// BEFORE (crashes on macOS 26.2)
.onHover { hovered = $0 }

// AFTER
.dsOnHover { hovered = $0 }
```

Every one of the 28 `.onHover` sites in NoType has been moved over; new sites must use `dsOnHover` going forward (pinned as a Hard rule in `NoType/UI/CLAUDE.md`).

## Why This Works

Per SE-0420 (*Inheritance of actor isolation*): a closure literal inherits the actor isolation of its enclosing context unless it is `@Sendable`, `@isolated(any)`, or carries an explicit isolation annotation. When a `@MainActor`-isolated closure runs, the compiler inserts a prologue that asserts the current executor matches the expected executor via `swift_task_isCurrentExecutorWithFlagsImpl`. Pre-macOS-26 this check was permissive; macOS 26 tightened it. macOS 26.2 went further — when the expected executor is `MainActor.shared`, `SerialExecutorRef::isMainExecutor()` walks the executor identity's isa via `swift_getObjectType` to confirm the type.

When SwiftUI dispatches our `.onHover` closure through `HoverResponder.updatePhase(_:)`, it sets up a SerialExecutorRef whose identity is invalid on macOS 26.2 (the runtime ends up with `0x1` in the identity slot). The isa read in `swift_getObjectType` segfaults.

The fix works in two parts:

1. **`@Sendable` strips the inherited `@MainActor` isolation.** The closure body no longer carries an expected-executor reference; the compiler-inserted prologue check is omitted; the body executes wherever SwiftUI invoked it (which, per the crash stack, is on the main thread anyway — `NSHostingView.mouseMoved` runs on the main thread).
2. **`Task { @MainActor in action(isHovering) }` schedules the `@State` write through the Swift task scheduler.** This is a *different code path* from the broken closure-prologue check. The task scheduler builds the MainActor executor reference itself (via the runtime's well-known MainActor singleton), so it never reads the malformed SerialExecutorRef SwiftUI handed in. The MainActor hop succeeds; the body runs with `@MainActor` isolation statically asserted; the `@State` setter is satisfied.

The async hop costs ~one frame (~8 ms) of latency between cursor movement and the `@State` mutation. For hover state this is imperceptible — `.animation(value:)` on every hover-tracked surface already interpolates the visual transition.

The shape mirrors PR #53's audio fix (`@Sendable` strips inheritance) but adds the `Task { @MainActor in }` bridge because — unlike Core Audio's non-isolated `handleIOProc` — our closure body genuinely needs `@MainActor` to write to `@State`. We rejected `MainActor.assumeIsolated` as the bridge: it ultimately calls `_taskIsCurrentExecutor` (verified against `_Concurrency.swiftinterface` in the macOS 26 SDK) and traps unconditionally if SwiftUI ever moves hover dispatch off-main. The audio-IOProc doc explicitly endorses both `assumeIsolated` and `Task { @MainActor in ... }` as valid bridges; for this fix the fail-soft async hop is the safer of the two.

## Prevention

- **All `.onHover` callsites in NoType go through `dsOnHover`.** Pinned as a Hard rule in `NoType/UI/CLAUDE.md`. New code should use `.dsOnHover { ... }` from the start; PR reviews should flag any raw `.onHover` outside `DSComponents.swift`'s helper definition.
- **When you see `swift_task_isCurrentExecutorWithFlagsImpl` anywhere in a crash stack on macOS 26.x, treat it as an actor-isolation mismatch first** (per the rule in [`audio-ioproc-mainactor-inheritance-crash-2026-05-19.md`](./audio-ioproc-mainactor-inheritance-crash-2026-05-19.md)) — even when the failing thread is the main thread. The hover crash is the counter-example to "main thread = safe" — the executor identity check faults regardless of which thread the closure runs on.
- **Be suspicious of any SwiftUI modifier whose closure is invoked through SwiftUI's runtime dispatch machinery on macOS 26.x.** `TimelineView` (PR #41), `.onHover` (this entry), `.onContinuousHover`, `.onMove`, `.onDrop`, and the new HoverResponder/PressResponder paths all expose the same risk. The dispatch path doesn't have to cross a thread boundary to trip the executor identity check — it only has to hand the runtime a malformed executor reference.
- **A source-text scan test pins the convention.** `NoTypeTests/DSComponentsHoverTests.swift` walks every `.swift` file in the repo and asserts no file outside `DSComponents.swift` contains the literal `.onHover {`. ~5 ms on a warm filesystem, zero new dependencies, catches raw-`.onHover` additions at the moment they're written — locally and in CI. Six of the nine code-review personas independently flagged the missing guardrail; this test closes it.

## Related Issues

- [`macos-26-executor-identity-check-family-2026-07-25.md`](./macos-26-executor-identity-check-family-2026-07-25.md) — **read this first.** This entry is the *second* of three same-signature incidents that were later reframed as one poisoned main-executor identity rather than three independent dispatch-path bugs. Two corrections to the framing below: the `dsOnHover` fix is mitigation at one call site, not coverage of the class (a stock SwiftUI `Button` crashed the same way two months later, inside Apple's own `_ButtonGesture`, where no NoType closure exists to annotate); and the audio-IOProc crash listed below as "second instance" is the family's **counter-example**, not a member — it was a genuine isolation violation with a different signal, thread, and terminal frame.
- [`timelineview-mainactor-instance-method-crash-2026-05-16.md`](./timelineview-mainactor-instance-method-crash-2026-05-16.md) — first instance of this family. Different SwiftUI dispatch path (TimelineView), same underlying runtime mechanism (`swift_task_isCurrentExecutorWithFlagsImpl`), different fix shape (restructure closure body to avoid `@MainActor` instance method calls).
- [`audio-ioproc-mainactor-inheritance-crash-2026-05-19.md`](./audio-ioproc-mainactor-inheritance-crash-2026-05-19.md) — second instance. Different framework (Core Audio HAL), same underlying mechanism, similar fix shape (`@Sendable` strips inheritance). This entry's fix is the audio-fix pattern + a MainActor bridge to keep `@State` writes compiling.
- `NoType/UI/CLAUDE.md` — owns the UI module's hover rule pinning `dsOnHover` as the only legal `.onHover` entry point.
- `NoType/UI/DSComponents.swift` — `dsOnHover` lives next to `dsHudChrome()` so the two view modifiers stay co-located.
- [`tooling-decisions/macos-15-deployment-target-2026-05-15.md`](../tooling-decisions/macos-15-deployment-target-2026-05-15.md) — macOS version policy. This crash is macOS-26.2-specific so the floor/coverage matrix is relevant context.
- [`conventions/swift-6-concurrency-and-async-2026-05-15.md`](../conventions/swift-6-concurrency-and-async-2026-05-15.md) — Swift 6 strict-mode conventions for the project. Worth a follow-up entry pinning the "any closure handed to a SwiftUI dispatch modifier on macOS 26.x needs explicit isolation control" rule project-wide once a fourth instance gives us enough signal.
