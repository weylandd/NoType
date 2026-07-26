---
title: TimelineView + @MainActor instance method = `objc_opt_class` crash on macOS 26
date: 2026-05-16
category: runtime-errors
module: UI
problem_type: runtime_error
component: tooling
symptoms:
  - "EXC_BAD_ACCESS / SIGSEGV at `objc_opt_class + 48` on the main thread"
  - "Faulting address near `0x1e` (small integer-shaped value)"
  - "Stack frames: `swift_task_isCurrentExecutorWithFlagsImpl` → `swift::SerialExecutorRef::isMainExecutor()` → `swift_getObjectType` → `objc_opt_class`"
  - "Crash originates inside `SwiftUI.TimelineView<>.UpdateFilter.updateValue()` during an `NSHostingView.layout()` pass"
  - "Reliable on macOS 26 (Tahoe); the same code may behave on macOS 15"
root_cause: framework_bug
resolution_type: code_fix
severity: critical
tags: [swiftui, timelineview, swift-6, concurrency, mainactor, macos-26, observation]
---

# TimelineView + @MainActor instance method = `objc_opt_class` crash on macOS 26

> **Annotation (2026-07-26) — this fix is a mitigation, not a cure.** The cause of this crash family has since been proven, and it is not the `TimelineView` dispatch path. A swallowed Objective-C exception, thrown on the main thread inside a Swift-concurrency job, unwinds through `libswift_Concurrency` and orphans the thread's `ExecutorTrackingInfo`; AppKit then resumes execution, and the **next** code to perform an executor check faults on the dead stack slot. The `TimelineView` closure below was one such reader — removing it stopped this site from crashing and the crash reappeared elsewhere twice. The rules in *Solution* and *Prevention* stay in force (they are good practice and they did remove a reader), but they do not close the class. Read [`macos-26-executor-identity-check-family-2026-07-25.md`](./macos-26-executor-identity-check-family-2026-07-25.md) first — including its "read the OTHER threads, look for `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`" guidance. Everything below is preserved as the historical record of how the site was diagnosed in 2026-05.

## Problem

On macOS 26, a SwiftUI `TimelineView` content closure that invokes any `@MainActor`-isolated `View` instance method (or reads an instance computed property) at every tick crashes deterministically during layout.

The stack signature is unambiguous:

```
objc_opt_class + 48
swift_getObjectType + 204
swift_task_isMainExecutorImpl + 36
swift::SerialExecutorRef::isMainExecutor() const + 24
swift_task_isCurrentExecutorWithFlagsImpl + 72
<our code>                                          ← instance method body
<our code>                                          ← TimelineView closure
closure #1 in TimelineView<>.init(_:content:) + 336
TimelineView<>.UpdateFilter.updateValue() + 5332
GraphHost.runTransaction
NSHostingView.layout()
```

Faulting address `0x000000000000001e` (or similar small value) — the runtime tried to dereference an invalid `isa` pointer while resolving the type descriptor of a `SerialExecutorRef` that is no longer valid. The check is being performed for an isolation boundary that the compiler inserts at the call site of the instance method, and on macOS 26 the executor reference SwiftUI hands the concurrency runtime at this point isn't a real heap object.

We've hit this twice:

1. **Incident 4838DA5B-4636-4468-AC06-2E9A73CED3FB** — early in development, `HistoryRowView.TimestampDisplay` called an instance method `string(secs:)` inside its `TimelineView` closure. Fixed by inlining the closure and moving the helper to a `static` function.
2. **2026-05-15** — public release v0.1.5 (build 7) crashed a tester on macOS 26.2 during the onboarding mic-check step. Same stack signature. Root cause: `OnboardingMicCheckStep.OnboardingSpectrumMeter` (and the sibling `RecordingHUD.LiveSpectrumMeter`) still used the broken pattern — TimelineView content closure called `bar(at:)`, `barColumn(at:)`, `updateLevels()` instance methods and read `tickKey` (instance computed property) every frame. The 2026-04 fix patched only the three trivial Date→String TimelineViews and missed the two spectrum meters that have the same shape but with state mutation.

## Symptoms

- Process crashes within ~3 seconds of launch when the offending view is on screen.
- 100% reproducible on macOS 26.x with the broken pattern. Behaves on macOS 15 — same compiled binary.
- Crash trace shows `TimelineView<>.UpdateFilter.updateValue()` as the caller of NoType code and `swift_task_isCurrentExecutorWithFlagsImpl` as the eventual victim.
- `Exception Subtype: KERN_INVALID_ADDRESS at 0x000000000000001e` (or another small value) — pointer-shaped but not in any memory region.

## What Didn't Work

**Hoping it was specific to certain TimelineView intervals.** It isn't. We've seen this at `by: 0.1` (timer pill), `by: 1` (recording-pill clock), `by: 15` (timestamp display), and `by: 1.0 / 30.0` (spectrum meters). Cadence is irrelevant — the trigger is the instance-method call from inside the per-tick closure.

**Treating it as a memory-management bug in our code.** The references in our code are sound — `self` is a `View` struct, not a class; `@State` arrays are owned by SwiftUI's state machinery. Tools like the address sanitizer don't surface anything because the freed object is internal to SwiftUI / the concurrency runtime, not ours.

**Assuming the 2026-04 fix to `HistoryRowView.TimestampDisplay` covered the class.** It only covered three sites. The pattern lives in five places in NoType: three time-display TimelineViews (fixed in 2026-04) and two spectrum meters (still broken until this PR). Anyone adding a new TimelineView between then and now would have reintroduced the bug.

## Solution

**Established pattern** (applies to every TimelineView in NoType):

1. The TimelineView content closure may **only** reference:
   - `let` properties on the enclosing `View` struct (e.g. `self.date`, `self.barCount`).
   - Static methods on `Self` (e.g. `Self.relativeString(secs:)`, `Self.format(elapsedFrom:to:)`).
   - The `ctx` (`TimelineViewDefaultContext`) parameter.
   - SwiftUI view builders and modifiers.

2. The closure may **not** call any instance method on `self` or read an instance computed property — both go through the `@MainActor` isolation boundary that triggers the runtime executor check.

3. If the view has mutable state that must update across frames (e.g. animated bars driven by FFT output), do **not** use TimelineView at all. Drive updates from a `.task { ... }` async loop on the View. `.task` auto-cancels on disappearance, mutates `@State`, and re-renders normally — no TimelineView dispatch path is involved.

Concretely:

| Original | Replacement |
|---|---|
| Instance method call inside closure | Inline the body, or move to a static helper on `Self`. |
| Read of instance computed property (`tickKey`) inside closure | Compute inline from `ctx.date`. |
| `TimelineView` + `.onChange(of: tickKey) { updateLevels() }` for state mutation | Drop TimelineView; use `.task { while !Task.isCancelled { … assign @State … try? await Task.sleep(for: …) } }`. |
| Per-bar rendering via instance `bar(at:)` returning `some View` | Extract `bar` into its own `private struct ChildBar: View` with `let` inputs; the parent composes children inside a `ForEach`. |

### What this PR did

- `OnboardingMicCheckStep.OnboardingSpectrumMeter`: removed the TimelineView, added a `.task` driver loop, extracted `OnboardingSpectrumBar` as a pure-input child view.
- `RecordingHUD.LiveSpectrumMeter`: same treatment — `.task` driver, extracted `LiveSpectrumBar` child.
- The three time-display TimelineViews already follow the static-helper variant of the rule and were left alone:
  - `HistoryRowView.TimestampDisplay` — uses `Self.relativeString(secs:)`.
  - `RecordingHUD.TimerPill` — uses `Self.format(elapsedFrom:to:)`.
  - `HistoryPopover.recordingPill` — uses `Self.formatElapsed(from:to:)`.
- `TranscribingHUD.AnimatedEllipsisLabel` — closure is fully self-contained, no `self` references; left alone.

**Subsequent consolidation (post-PR #41).** The two spectrum meters above were later merged into a single shared `SpectrumMeter` view at `NoType/UI/SpectrumMeter.swift` (with a private `SpectrumBar` child), consumed by both `RecordingHUD` and `OnboardingMicCheckStep` with per-call-site geometry. The `.task`-loop pattern carried through unchanged — the consolidation didn't reintroduce a TimelineView. The four TimelineView sites in NoType today are all time-display / animation pulses using the static-helper variant: `RecordingHUD.TimerPill`, `HistoryRowView.TimestampDisplay`, `HistoryPopover.recordingPill`, and `TranscribingHUD.AnimatedEllipsisLabel`.

## Why This Works

`swift_task_isCurrentExecutorWithFlagsImpl` is an isolation check the compiler inserts at the boundary of every `@MainActor`-annotated method call when the caller's isolation isn't statically provable to be `@MainActor`. Inside a TimelineView content closure on macOS 26, SwiftUI's diffing machinery is the runtime caller — and the executor reference it passes to the concurrency runtime is a freed/invalid object on that platform.

The two replacement shapes avoid the broken dispatch path entirely:

- **Static-helper variant** lets the TimelineView content closure compile down to pure value reads (`let` props, `ctx.date`, `Self.foo(...)`). No `@MainActor` instance method call → no executor check inserted → no crash.
- **`.task` driver variant** moves frame updates out of TimelineView's dispatch path completely. `.task` runs on the View's own `@MainActor` context, and `@State` mutation drives normal SwiftUI re-render without going through TimelineView's `UpdateFilter.updateValue()`.

The compiler/runtime behaviour is a SwiftUI + Swift concurrency runtime bug specific to macOS 26 SwiftUI (Sequoia is unaffected with the same binary). We can't fix the framework. We can only avoid the call shape that triggers the check.

> **Corrected (2026-07-26).** The paragraph above is wrong about *whose* bug it is, and the two paragraphs before it are wrong about *why* the replacement shapes work. The executor reference is not "freed/invalid on that platform" because of anything SwiftUI does: it is a dead stack slot left behind when an ObjC exception our own code caused unwound through `libswift_Concurrency` and AppKit resumed execution. The replacement shapes work because they perform **fewer executor checks**, not because they avoid a broken SwiftUI path — which is exactly why the crash relocated instead of ending. macOS 15 is unaffected because its runtime performs the check differently, not because the corruption doesn't happen there. See the family entry linked at the top.

## Prevention

- Adding any new `TimelineView` anywhere in NoType — apply the rules above before merging.
- Reviewing PRs that touch a TimelineView — scan the closure for `self.foo()` or `self.bar` (instance computed prop). If you see either, request the static-helper or `.task`-loop refactor.
- ~~Investigating any crash that prints `swift_task_isCurrentExecutorWithFlagsImpl` on the stack inside a SwiftUI view — search for nearby TimelineView usages first.~~ **Superseded 2026-07-26 — this is the wrong first move.** Read the *other* threads in the crash report and look for a parked thread carrying `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`; the SwiftUI frame is a witness, not the cause. See the family entry.
- The 2026-04 fix to this class of bug only patched 3 of 5 TimelineView sites in NoType (the trivial Date→String ones); the two spectrum meters shipped with the same broken pattern. **Audit *every* TimelineView when one is found broken**, not just the one that crashed.

### Time-display variant (Self.static helper)

```swift
private struct TimestampDisplay: View {
    let date: Date
    let useAccentBadge: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let secs = max(0, Int(ctx.date.timeIntervalSince(date)))
            // ← only `let` props on self, `ctx.date`, and `Self.foo()` calls.
            // No `self.foo()` or `self.bar` (instance computed prop).
            Text(Self.relativeString(secs: secs))
        }
    }

    private static func relativeString(secs: Int) -> String { … }
}
```

### Mutable-state variant (.task loop, no TimelineView)

This is the shape currently shipping in `NoType/UI/SpectrumMeter.swift`. Names below match the consolidated shared view rather than the original `LiveSpectrumMeter` / `LiveSpectrumBar`.

```swift
struct SpectrumMeter: View {
    let samplesProvider: @MainActor () -> [Float]
    let barCount: Int
    private static let frameInterval: Duration = .milliseconds(33)
    @State private var levels: [Float]

    var body: some View {
        HStack {
            ForEach(0..<barCount, id: \.self) { i in
                SpectrumBar(level: levels[i])       // ← child view, pure inputs
            }
        }
        .task {
            while !Task.isCancelled {
                let samples = samplesProvider()
                // … compute next levels …
                levels = nextLevels                  // ← triggers normal re-render
                try? await Task.sleep(for: Self.frameInterval)
            }
        }
    }
}

private struct SpectrumBar: View {
    let level: CGFloat
    var body: some View { Rectangle().frame(height: level) }
}
```

## Related Issues

- [`runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`](macos-26-executor-identity-check-family-2026-07-25.md) — **read this first.** This entry is the *first* of three same-signature incidents. The proven cause is a swallowed ObjC exception that orphans the main thread's `ExecutorTrackingInfo`; the `TimelineView` closure below was a *reader* of that corrupt state, not its source. Three corrections to this file's framing: the fix below is mitigation at one call site, not coverage of the class (the crash reappeared twice afterward at unrelated sites); the audio-IOProc entry cross-linked below is the family's **counter-example**, not its second member; and this is not a framework bug we can only work around — the exception is ours to stop throwing.
- PR #41 — fix for both spectrum meters (this file's introducing PR).
- The 2026-04 incident note inlined in `NoType/UI/HistoryRowView.swift` next to `TimestampDisplay.body` — first time this pattern was diagnosed in NoType.
- Companion comment in `NoType/UI/RecordingHUD.swift` next to `TimerPill.body`.
- [`runtime-errors/audio-ioproc-mainactor-inheritance-crash-2026-05-19.md`](audio-ioproc-mainactor-inheritance-crash-2026-05-19.md) — **the family's counter-example, not a member** (this bullet originally called it "second instance … same underlying mechanism"; that was wrong on both counts). Different framework (Core Audio HAL), different thread, different signal, deterministic rather than latent — a *genuine* isolation violation the runtime caught correctly, permanently fixed with `@Sendable`.
- [`runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md`](onhover-mainactor-inheritance-crash-2026-05-19.md) — the **second** same-signature incident (originally numbered third, before the audio crash was reclassified as a counter-example). SwiftUI `.onHover` modifier closures inheriting `@MainActor`. Fixed via the `dsOnHover` wrapper in `NoType/UI/DSComponents.swift` (`@Sendable` strips inheritance, `Task { @MainActor in ... }` re-enters MainActor for `@State` writes) — another reader removed, not a cure.
- [`runtime-errors/sender-respawn-race-2026-05-16.md`](sender-respawn-race-2026-05-16.md) — sibling macOS 26 Swift concurrency runtime failure from the same discovery window; same family of "Swift concurrency machinery behaves unexpectedly inside a non-obvious call context."
- [`tooling-decisions/macos-15-deployment-target-2026-05-15.md`](../tooling-decisions/macos-15-deployment-target-2026-05-15.md) — macOS version policy; this crash is macOS-26-specific so the floor/coverage matrix is relevant context.
- [`conventions/swift-6-concurrency-and-async-2026-05-15.md`](../conventions/swift-6-concurrency-and-async-2026-05-15.md) — broader rules on isolation and async work; the `.task`-loop fix pattern is the established "periodic work" idiom from this convention.
