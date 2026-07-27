---
title: The macOS 26 executor-identity crash family is a swallowed ObjC exception, not a bad call site
date: 2026-07-25
last_updated: 2026-07-26
category: runtime-errors
module: UI
problem_type: best_practice
component: tooling
severity: critical
applies_when:
  - "A macOS 26.x crash stack contains swift_task_isCurrentExecutorWithFlagsImpl or swift_task_isMainExecutorImpl"
  - "Triaging a SIGSEGV at a small integer address inside swift_getObjectType or objc_opt_class"
  - "Deciding whether a per-call-site isolation annotation will actually end a crash or only relocate it"
  - "Any AppKit app crash whose faulting frame looks unrelated to anything the app recently changed"
symptoms:
  - "EXC_BAD_ACCESS (SIGSEGV) at a small integer address — 0x1e, 0x1, and 0x0 observed across the three incidents"
  - "Faults in swift_getObjectType — or one frame deeper in objc_opt_class — reached via SerialExecutorRef::isMainExecutor() <- swift_task_isCurrentExecutorWithFlagsImpl"
  - "A parked background thread in the same report whose stack contains SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION"
  - "The frame below the runtime differs every time: a TimelineView closure, an .onHover closure, then SwiftUI's own _ButtonGesture"
  - "Each per-call-site fix held at that site, and the crash reappeared at an unrelated site that still performed the check"
root_cause: logic_error
tags: [macos-26, concurrency, mainactor, executor, objc-exception, crash-family, diagnosis]
related_components: [UI, Onboarding, Recording, NoTypeApp]
---

# The macOS 26 executor-identity crash family is a swallowed ObjC exception, not a bad call site

> **Rewritten 2026-07-26.** The first version of this entry (2026-07-25) got the *shape* right — one poisoned main-executor identity, three readers — and the *cause* wrong. It named early-launch `MainActor` use as the leading hypothesis; that was tested in production and did not fix the crash. The mechanism below is reproduced, not inferred. The superseded hypotheses are kept verbatim under *Examples* because losing them is how a team relitigates a dead end.

## Context

NoType has taken three crashes with an identical runtime signature. Each was investigated, documented, and fixed as if it were its own bug:

| Date | Incident | Faulting address | Fix shape | What happened next |
|---|---|---|---|---|
| 2026-05-16 | `TimelineView` content closure calling a `@MainActor` instance method — [entry](./timelineview-mainactor-instance-method-crash-2026-05-16.md) | `0x1e` | Restructure the closure so no isolated instance method is called | Crash reappeared at `.onHover` |
| 2026-05-19 | `.onHover` closure literal inheriting `@MainActor` — [entry](./onhover-mainactor-inheritance-crash-2026-05-19.md) | `0x1` | `dsOnHover`: `@Sendable` strips inheritance, `Task { @MainActor in … }` bridges back | Crash reappeared at a stock SwiftUI `Button` |
| 2026-07-25 | Stock SwiftUI `Button`, inside Apple's own `_ButtonGesture` — [issue #82](https://github.com/weylandd/NoType/issues/82) | `0x0` | *(none — the check is inside Apple's binary)* | Cause found 2026-07-26 |

**The proven mechanism.** An Objective-C `NSException` raised on the main thread *inside a Swift-concurrency job* (`Task { @MainActor in … }` body, `await MainActor.run { … }` body) unwinds via `objc_exception_throw` straight through `libswift_Concurrency.dylib`. The runtime's `ExecutorTrackingInfo` — its record of "which executor is this thread currently on" — is a **stack-allocated, thread-local linked-list node, and its pop is not exception-safe**. Unwinding past it orphans the main thread's executor identity, leaving a pointer into a dead stack slot. AppKit catches the exception at the run-loop boundary and **resumes execution**. The next code to ask "am I on the main executor?" — `swift_task_isCurrentExecutorWithFlagsImpl` → `isMainExecutor()` → `swift_getObjectType(identity)` — reads that dead slot and SIGSEGVs.

This was reproduced locally on Swift 6.3.3 against the macOS 26 SDK: a probe raising an `NSException` inside `Task { @MainActor }` produces `objc_exception_throw` with `libswift_Concurrency.dylib completeTaskWithClosure(…)` in the unwind path. It is not a reading of the stack traces; it is the stack trace.

It explains every fact the per-call-site framing could not:

| Fact | Explained by |
|---|---|
| Three different tiny addresses (`0x1e`, `0x1`, `0x0`) | one dead stack slot, reused differently each time — not three call sites, not drifting heap corruption |
| The crash site is arbitrary and unrelated to anything recently changed | it is whoever *read* the identity next |
| Every per-call-site fix "held" and the crash moved | we kept deleting **readers** of the corrupt state, never the **corrupter** |
| A ~675 ms gap between the swallowed exception and the SIGSEGV | corruption is latent until the next read |

`TimelineView`, `.onHover`, and `_ButtonGesture` are not causes. They are witnesses.

## Guidance

**When you see the executor-check SIGSEGV, read the OTHER threads first, not the crashing one.**

A crash report from this family carries a parked background thread whose stack contains `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`, inside `HIServices`. Its thread name embeds the timestamp of the swallow. That thread is the whole answer: it says *an exception was thrown and eaten at time T*, and the SIGSEGV is the aftershock. The crashing thread tells you only which innocent frame happened to ask the runtime a question afterwards.

Then, in order:

1. **Stop AppKit swallowing, so the next crash report shows the exception's own stack.** Zero build required — the reporter runs this against the already-installed app:

   ```
   defaults write app.notype NSApplicationCrashOnExceptions -bool YES
   ```

   The process now dies *at the throw*. Revert with `defaults delete app.notype NSApplicationCrashOnExceptions`. Caveat: it only affects exceptions that reach AppKit's top-level handler — one caught by an intermediate `@try` (Sparkle, CoreML internals) stays invisible, which is itself informative.

2. **If that isn't enough, install `objc_setExceptionPreprocessor` as the first statement of app startup.** It runs at `objc_exception_throw` time, before any unwinding, so `Thread.callStackSymbols` inside it captures the throwing stack. Public API since 10.5, process-local (a function-pointer swap — no code injection, no `DYLD_INSERT_LIBRARIES`), no entitlement, fine under non-sandboxed hardened runtime, zero cost when nothing throws. Log at `.fault` so it lands in the persistent store and the reporter can retrieve it with `/usr/bin/log show`. Shipped for NoType as `NoType/Diagnostics/ExceptionBreadcrumb.swift`, installed as the first statement of `NoTypeApp.init()`.

   Two properties of that install are load-bearing, and both look like tidiness if you don't know better:

   - **Chain outward to whatever you replaced. This is correctness, not hygiene.** `objc_setExceptionPreprocessor` returns the preprocessor it displaced, and Foundation already has one installed — so an interceptor that discards the returned pointer is not merely losing a hop. Foundation's preprocessor is what populates `NSException.callStackReturnAddresses`, and HIToolbox asserts on that field: `Assertion failed: (callStackReturnAddresses), -[NSException(HIServices) hashString], HIExceptions.mm:45` → `SIGABRT`. Measured, not argued — a freshly constructed `NSException` carries **0** return addresses, and non-empty (3, in the probe) after passing through the chained hook. Dropping the chain therefore converts every exception AppKit currently swallows into an instant crash on every machine, which is strictly worse than the latent bug the interceptor was added to diagnose.
   - **The swap and the store of the replaced pointer must share one critical section.** `objc_setExceptionPreprocessor` publishes your hook to the whole process the instant it returns. Publishing first and storing the previous pointer one statement later leaves a window in which a throw on another thread reads the chain as `nil` and skips the preprocessor you just replaced — which lands on the same `HIExceptions.mm:45` abort above, not on a merely-missing breadcrumb. `ExceptionBreadcrumb.State.performInstall` does the `dlsym`, the swap and the store under one `NSLock`; readers of the chained pointer take that same lock, so they block for the couple of instructions the swap costs instead of observing the gap.

   Neither property is visible from a passing test suite by default — see [`source-scan-guard-fidelity`](../conventions/source-scan-guard-fidelity-2026-07-25.md), whose hook-guard section is drawn from this interceptor's own review.

3. **`NSSetUncaughtExceptionHandler` does NOT work here.** AppKit catches the exception before it reaches the top-level handler. That is precisely why this went unseen across three incidents — the obvious hook is the one that never fires.

4. **Do not count call-site fixes as coverage of the class.** Every one of them removed a reader. They are real mitigations for a specific user-facing breakage and should stay in force; they are not cures and must not be written up as such.

5. **This is our bug.** An exception thrown by our code (or by a framework reacting to our arguments) is what starts the chain. Apple's concurrency runtime not being exception-safe across that unwind is a genuine contributing factor and worth an Apple Feedback report — but the fix that is ours to make is to stop throwing.

**The check itself stays enabled.** It is a safety net that has already earned its keep: it caught a genuine actor-isolation violation on the Core Audio HAL thread. Suppressing it would trade a loud crash for a silent data race — and it would not help anyway, because the fault happens before the check-mode options word is ever read (see *Examples*).

### Prevention — and the two things deliberately NOT done

The rule that comes out of all this is one line, and it lives beside the two call-site rules in `NoType/UI/CLAUDE.md`: **inside a `Task { @MainActor }` or `MainActor.run` body, an AppKit / AVFoundation / CoreAudio API that can raise is called only after its preconditions have been validated at the call.** The audit of currently-reachable sites is recorded there, split by whether the precondition is *checkable* — because that split is what decides whether a site can be fixed or only contained.

Two moves that look obviously right were considered and are not being made. Both are recorded here rather than left to be re-derived.

**1. Containment — a `DispatchQueue.main.async` bridge, or an ObjC `@try/@catch` shim — is the escalation, not the fix.** Both genuinely work on the mechanism: a dispatch block is not a Swift-concurrency job, so no `ExecutorTrackingInfo` node is pushed and an unwind orphans nothing; a `@try` shim catches before any unwind reaches the Swift frames. And both leave the defect completely in place — the tap still fails to install, the panel still fails to position — so the user trades a crash for a dead spectrum meter or a HUD in the wrong corner, *with no crash report to notice it by*. That is the same silent-degradation shape this entry's *Why This Matters* blames for two months of invisible cost. Reach for containment only where validating the argument is impossible (`FixedSizeWindowConfigurator`, whose precondition has no API), or if a validated site is later proven to still raise.

**2. A general source scan for "raise-prone API inside a main-actor `Task`" is rejected.** It is the natural next thought and it would be worse than nothing. There is no closed set of AppKit APIs that can raise, so the needle list would be a guess — and a source scan's failure mode is not noise, it is a **passing test** ([`source-scan-guard-fidelity`](../conventions/source-scan-guard-fidelity-2026-07-25.md): *every* way a scan fails produces green). The risk is therefore not false alarms; it is a green check sitting over an unbounded set of raise sites it never learned to look for, while reviewers stop reading for them by hand because "a test pins this." A guessed needle list here has strictly lower fidelity than a human reviewer.

What is guarded instead is only where a **named chokepoint makes the set genuinely closed** — `RaiseSiteScanner` in `NoTypeTests/HUDPanelGeometryTests.swift`, over exactly two files: every `setContentSize` / `setFrameOrigin` / `setFrame` in `HUDPanel.swift` must sit inside `applyValidated`; every `installTap` / `removeTap` in `MicProbe.swift` inside `installTapAndStart` / `removeTapIfInstalled`. Note the predicate is *positional*, not an absence needle — a guarded call still contains the literal `setContentSize(`, so "this string does not appear" cannot express the rule at all. It carries the presence complement (the mutator still occurs, the chokepoint is declared, something calls it, **and its body still contains the validation**), and its limits are written down beside it: `HUDController.swift`'s geometry calls are outside the closed set, and a *new kind* of mutator added inside an existing wrapper would pass. The general case is covered by the interceptor above, not by a scan.

## Why This Matters

The process failure here cost more than the bug did.

The reporter attached a full `.ips` in **May 2026**, for the `.onHover` incident. The answer — the parked thread carrying `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION` — was in that file the whole time. Nobody read past the crashing thread. What followed: two more incidents, three write-ups framing the crash as a SwiftUI dispatch-path bug, one build-setting investigation, and one shipped non-fix (v0.1.13-rc1) handed to the reporter as a test. Roughly two months, on evidence that was already in hand on day one.

The habit that produced it is ordinary and worth naming: a crash report is read top-down from thread 0 because thread 0 is where the signal landed. For any latent-corruption bug — and this whole class is latent by construction — thread 0 is the *last* place the information is.

The user-facing cost is asymmetric in a way that shapes triage. Dictation runs through `CGEventTap` and never touches SwiftUI's button dispatch, so an already-configured user can still work. But onboarding's primary control is a stock `Button`, so a **new** user on the affected build cannot complete setup at all — and NoType ships no telemetry (ADR-013), so those users are invisible. They uninstall silently. That is why the README known-issue note exists.

## When to Apply

- **In the family** — any macOS 26.x crash that faults at a small integer address inside `swift_getObjectType`, reached from `SerialExecutorRef::isMainExecutor()` / `swift_task_isCurrentExecutorWithFlagsImpl`, on any thread including the main thread. **The terminal symbol varies by one frame and is not a discriminator:** the `.onHover` incident stopped at `swift_getObjectType + 40` (with `swift_task_isMainExecutorImpl` symbolicated above it), while the `TimelineView` incident stopped one frame deeper at `objc_opt_class + 48`, which `swift_getObjectType` tail-calls for ObjC-interop types. Match on the `isMainExecutor()` caller plus the small-integer address, not on the leaf symbol. "Main thread" is not an alibi either — the `.onHover` incident faulted on `com.apple.main-thread`.
- **Beyond NoType** — this signature is not ours. At least eight other macOS apps carry the byte-identical stack publicly, and five traced it to their own code. If you are reading this while triaging a different app, the guidance transfers unchanged: read the other threads, find the breadcrumb, stop the swallow. Links in *Related*.
- **Not in the family** — [`audio-ioproc-mainactor-inheritance-crash-2026-05-19.md`](./audio-ioproc-mainactor-inheritance-crash-2026-05-19.md) remains the explicit counter-example, and the proven mechanism **strengthens** rather than weakens that separation. Three independent reasons: (1) the corruption is *thread-local* — `ExecutorTrackingInfo` is a per-thread stack node, and the poisoned thread is the main thread, whereas that crash fires on `com.apple.audio.IOThread.client`; (2) its check terminates in `dispatch_assert_queue` / `_dispatch_assert_queue_fail`, a libdispatch queue identity test that never reads the Swift executor identity slot at all, so a poisoned slot could not produce it; (3) it was **deterministic** — first IOProc invocation, every recording attempt — and latent-corruption faults are by nature non-deterministic and delayed. It was a genuine actor-isolation violation, the one-keyword `@Sendable` fix was correct and final, and it has not recurred. Folding it in would corrupt this family's evidence with a case where the runtime was right.
- **Before proposing a build-setting fix** — read the runtime path below. Both check-mode levers were disproved before the cause was known, and they are now moot besides.

## Examples

### The mechanism, end to end

1. An ObjC exception is raised on the main thread **inside a Swift-concurrency job** (`Task { @MainActor }` body or `await MainActor.run { … }` body).
2. It unwinds through `libswift_Concurrency`, orphaning `ExecutorTrackingInfo::current()` — the pop has no landing pad, so the thread-local head is left pointing at a dead stack frame.
3. AppKit / HIToolbox swallows it at the run-loop / event-dispatch boundary and parks the breadcrumb thread. Execution resumes.
4. Whatever later reuses that stack memory becomes the main thread's "executor identity".
5. The **next** executor check — a `_ButtonGesture` dispatch, `HoverResponder.updatePhase`, a `TimelineView` closure prologue, a `MainActor.assumeIsolated` — calls `swift_task_isCurrentExecutorWithFlagsImpl` → `isMainExecutor()` → `swift_getObjectType(garbage)` → SIGSEGV.

Observed timing in the v0.1.8 report (macOS 26.2 build 25C56, Mac15,7 / M3 Pro): launch `10:57:45.7231` → exception swallowed `10:57:49.189` (T+3.47 s) → SIGSEGV `10:57:49.8639` (T+4.14 s). The corruption and the crash are **675 ms and one unrelated user action apart**.

### The breadcrumb, in a real crash report

That `.ips` — the `.onHover` incident's own report — contains a suspended background thread whose stack frame is `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION` in `HIServices`, with the swallow timestamp encoded in the thread name. It was thread 13. It was there in May.

Apple Swift-runtime engineer Mike Ash, [swiftlang/swift#89197](https://github.com/swiftlang/swift/issues/89197#issuecomment-4845997855):

> Something is throwing an exception on the main thread and it's being thrown through the Swift Concurrency runtime. This leaves the runtime in a corrupted state and it crashes sometime afterwards due to that.
>
> You should see a little breadcrumb left behind in the form of a background thread with `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION` in the stack trace.

And on [swiftlang/swift#86083](https://github.com/swiftlang/swift/issues/86083#issuecomment-4481329992):

> Weird crashes in `swift_task_isCurrentExecutorWithFlagsImpl` usually indicate that something threw an exception through the concurrency runtime, then resumed execution. AppKit will resume execution if an otherwise uncaught exception is thrown on the main thread […] This is often caused by assertion failures in Foundation or AppKit, as they're implemented as throwing exceptions when they fail.

### Disproven hypotheses — kept on purpose

Deleting these is how the next investigation re-runs them.

| Hypothesis | Status | Evidence |
|---|---|---|
| **Early-launch `MainActor` use corrupts a lazily-created main executor.** The 2026-07-25 framing's leading suspect: `NoTypeApp.init()` scheduling `Task { @MainActor }` before `NSApplicationMain` started the app. | **Disproven** | Shipped as stage B′ (`bfcec4a`, v0.1.13-rc1) and tested on the reporter's machine. It did not fix the crash. It removes no exception, so under the proven mechanism it could not have. The reordering is still correct on its own merits — scheduling into that window is a latent ordering bug — and stays in force under `NoType/UI/CLAUDE.md` "Launch ordering". It is not coverage of this crash. |
| **Three separate SwiftUI dispatch-path bugs**, each fixable at its call site. | **Disproven** | Each fix held at its site and the crash reappeared elsewhere; the third landed inside Apple's compiled `_ButtonGesture`, where no app closure exists to annotate. |
| **A check-mode lever can suppress it** — the `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE` env knob, or the runtime's linked-on-or-after bincompat gate. | **Disproven, and now moot** | Both feed the same `options` word, consulted at `Actor.cpp:589`; `isMainExecutor()` is called at `:554`. The fault lands between them. This reasoning is still *correct* — but it is answering the wrong question: the defect is not in the check, it is in state corrupted long before the check ran. Chasing check-mode was a symptom-suppression path even if it had worked. |
| **`AXIsProcessTrustedWithOptions` with the inlined `AXTrustedCheckOptionPrompt` literal is throwing.** Attractive because `HIServices` appears in the report. | **Investigated and exonerated** | Measured at runtime: the inlined literal is byte-identical to the real global, and `["AXTrustedCheckOptionPrompt": kCFBooleanFalse as Any] as CFDictionary` bridges to a genuine `CFBoolean` (CFTypeID 21), not a `_SwiftValue` box — so no unrecognized-selector hazard. The call returns normally. The `HIServices` frame is where the exception was **swallowed** (HIToolbox/Carbon event dispatch backs AppKit's main run loop), not where it was thrown. Do not re-suspect it. |
| **A split or back-deployed Swift concurrency runtime.** | **Ruled out** | The v0.1.12 artifact is a universal binary, `minos 15.0`, SDK 26.5, with no embedded Swift runtime dylibs — it links only `/usr/lib/swift/*`. One runtime, the OS's own. |

### Suspected throwers — NOT confirmed

The mechanism is proven. **Which** exception NoType throws is not. These are ranked suspects from a static + runtime audit, listed so the next reader starts from evidence rather than from scratch. None has been observed firing in the wild.

- **`MicProbe.installTapAndStart()` — `AVAudioEngine.installTap` format mismatch.** `installTap` raises `NSException` (`com.apple.coreaudio.avfaudio`, *"Input HW format and tap format not matching"*) whenever the tap format differs from the input node's live hardware format — reproduced on demand in a standalone probe. The device switch goes through `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`, which is **asynchronous**, but the format is read immediately afterwards. It is not a Swift error, so the surrounding `do/catch` cannot catch it. `rebuild()` is invoked from two Swift-concurrency jobs (the config-change observer and the device-observation loop), which is exactly the §1 requirement. Device-set dependent — which would explain why the maintainer's machine is clean. Corroborating, not conclusive: the crash report's live threads include `com.apple.audio.toolbox.AUScheduledParameterRefresher`, which requires an instantiated AudioUnit, and `MicProbe` is the app's only `AVAudioEngine` user.
- **`HUDPanel` NaN geometry reaching `setFrameOrigin` / `setContentSize`.** Measuring an `NSHostingView` before it has a stable window/screen context can yield a NaN `fittingSize`; `-[NSWindow setFrameOrigin:]` then raises `NSInvalidArgumentException` (*"Invalid parameter not satisfying: !((__x) != (__x))"*). Driven roughly once per second by the permission poll's HUD reposition loop for any post-onboarding user with a permission still ungranted.
- **`FixedSizeWindowConfigurator` mutating `styleMask` mid-configure.** Removing `.resizable` and then calling `setFrame(_:display: true)` on a window AppKit is still configuring can raise `NSInternalInconsistencyException`. Runs from `updateNSView`, i.e. on every SwiftUI body update.
- **`SileroVAD`'s CoreML load on a main-actor `Task` — ranked LOW–MEDIUM, and deliberately NOT acted on.** `SileroVAD` is an `actor` with a throwing initializer, so `MLModel(contentsOf:configuration:)` with `computeUnits = .all` executes on the **caller** — the main actor — inside a concurrency job. Espresso / ANE is plain Objective-C/C++ and can raise. Two load sites, `AppState.swift:454` (`prime()`) and `AppState.swift:927` (the lazy retry on the hotkey path, which `HotkeyMonitor` also dispatches through `Task { @MainActor }`). **Status: deferred pending evidence, not rejected.** There is no positive evidence for it — it does not explain the AudioUnit threads in the reporter's report — and the plan that enumerated it (`docs/plans/2026-07-26-001-…`, Step 6 / U6) gated the change on a diagnosis naming a CoreML/Espresso exception. That diagnosis was never obtained: the zero-build reporter round was cancelled by the maintainer, so the step is recorded there as intentionally skipped. **Re-arm condition, stated so nobody re-derives it: an `OBJC THROW` record naming an Espresso / CoreML exception re-opens Step 6 immediately, and both load sites move — not just `prime()`'s.** There is also an independent, non-crash argument for moving it (a first-run ANE compile is routinely 1–3 s of main-actor work at launch); that is a launch-hitch question and must be decided on its own evidence, never folded in as coverage of this crash.

There may be **more than one** corrupter. That is fully consistent with the mechanism — any swallowed throw anywhere poisons the same slot — so do not assume fixing the top suspect closes the class. The instrumentation in *Guidance* is what converts this list into a named file:line.

### Where the runtime reads the identity

```
SwiftUI _ButtonGesture fires MainActor.assumeIsolated
  -> swift_task_isCurrentExecutorWithFlagsImpl        Actor.cpp:539
       options = flags                                 <- seeded by the bincompat gate,
                                                          adjusted by the env knob
       ExecutorTrackingInfo::current()                 Actor.cpp:547
         -> the orphaned / dead-stack node             <- CORRUPTED HERE, 675 ms EARLIER
       expectedExecutor.isMainExecutor()               Actor.cpp:554   <- FAULT PATH
         -> swift_task_isMainExecutorImpl              ExecutorImpl.cpp
              swift_getObjectType(identity)            <- SIGSEGV on a dead-slot identity
       ...
       options consulted here                          Actor.cpp:589   <- AFTER the fault
```

### Discriminating the two signatures at a glance

| | This family | Core Audio IOProc (counter-example) |
|---|---|---|
| Signal | `EXC_BAD_ACCESS` / SIGSEGV | `EXC_BREAKPOINT` / SIGTRAP |
| Address | small integer (`0x1e`, `0x1`, `0x0`) | n/a — a deliberate trap |
| Thread | main thread (where the tracking info was orphaned) | `com.apple.audio.IOThread.client` |
| Terminal frame | `swift_getObjectType`, or `objc_opt_class` one frame deeper | `_dispatch_assert_queue_fail` |
| Timing | latent — fires at an arbitrary later moment | deterministic — first IOProc call, every time |
| Breadcrumb thread present? | **yes** | no |
| Was the runtime right? | No — it read a dead stack slot | **Yes** — the closure really was off-main |
| Fix | stop throwing the exception; call-site work is mitigation | `@Sendable`; correct and final |

## Related

- [`timelineview-mainactor-instance-method-crash-2026-05-16.md`](./timelineview-mainactor-instance-method-crash-2026-05-16.md) — first same-signature incident (`0x1e`). Its fix removed a *reader*.
- [`onhover-mainactor-inheritance-crash-2026-05-19.md`](./onhover-mainactor-inheritance-crash-2026-05-19.md) — second same-signature incident (`0x1`); also the source of the `dsOnHover` shape and of the rejection of `MainActor.assumeIsolated` as its bridge. Its `.ips` is the report that carried the breadcrumb.
- [`audio-ioproc-mainactor-inheritance-crash-2026-05-19.md`](./audio-ioproc-mainactor-inheritance-crash-2026-05-19.md) — the **counter-example**, not a member. Different thread, different signal, deterministic, no breadcrumb; genuine isolation violation, correctly and permanently fixed.
- [`sender-respawn-race-2026-05-16.md`](./sender-respawn-race-2026-05-16.md) — sibling macOS 26 concurrency-runtime oddity from the same discovery window; different mechanism.
- `NoType/Diagnostics/ExceptionBreadcrumb.swift` + `NoTypeTests/ExceptionBreadcrumbTests.swift` — the shipped interceptor from *Guidance* step 2, and the guards that pin its chaining and redaction contracts. Its user-facing surface is the README's `## Known issues` retrieval recipe.
- [`conventions/source-scan-guard-fidelity-2026-07-25.md`](../conventions/source-scan-guard-fidelity-2026-07-25.md) — why three of that interceptor's guards were green for reasons unrelated to their claim, including the one that passed on the chain-dropped `SIGABRT` outcome. It is also the authority behind *Prevention*'s rejection of a general scan, and behind `RaiseSiteScanner`'s presence complement.
- `NoTypeTests/HUDPanelGeometryTests.swift` — `RaiseSiteScanner`, the narrow two-file guard from *Prevention*, its presence complement, and the fixtures pinning the scanner itself. `NoType/UI/CLAUDE.md` carries the rule it enforces and the audit table.
- `docs/plans/2026-07-25-001-fix-macos-26-executor-crash-plan.md` — the staged investigation this entry came out of. Its stage B′ shipped and returned a negative result; its KD6 check-mode disproof is correct but moot. Read it as history, not as the current plan.
- `docs/plans/2026-07-26-001-fix-swallowed-exception-executor-corruption-plan.md` — the current plan, replanned from the proven mechanism above. Step 2 / U2 shipped the interceptor.
- `GitHub issue weylandd/NoType#82` — the third incident, and where reporter results are recorded.
- `NoType/UI/CLAUDE.md` — the two UI hard rules (`TimelineView` closure contents, `dsOnHover`) that mitigate the first two incidents, and the "Launch ordering" rule that stage B′ produced.
- Upstream, same mechanism, Apple's own words: [swiftlang/swift#89197](https://github.com/swiftlang/swift/issues/89197) and [swiftlang/swift#86083](https://github.com/swiftlang/swift/issues/86083).
- Other macOS apps with the byte-identical stack, five of which traced it to their own code: [Detto #10](https://github.com/Gremble-io/Detto/issues/10) (same macOS build, 25C56), [EchoNotes #183](https://github.com/itsahedge/echonotes/pull/183) and [#184](https://github.com/itsahedge/echonotes/pull/184), [AIUsage #16](https://github.com/dowoonlee/ai-service-usage/issues/16), [OpenOats #56](https://github.com/yazinsai/OpenOats/issues/56), [Communitas #24](https://github.com/saorsa-labs/communitas/issues/24).
- [`tooling-decisions/macos-15-deployment-target-2026-05-15.md`](../tooling-decisions/macos-15-deployment-target-2026-05-15.md) — macOS version policy. Raising the floor was never a lever for this family, and is now plainly irrelevant: the exception is ours.
