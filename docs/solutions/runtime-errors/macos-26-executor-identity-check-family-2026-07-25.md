---
title: The macOS 26 executor-identity crash family is one poisoned check, not three dispatch-path bugs
date: 2026-07-25
category: runtime-errors
module: UI
problem_type: best_practice
component: tooling
severity: critical
applies_when:
  - "A macOS 26.x crash stack contains swift_task_isCurrentExecutorWithFlagsImpl or swift_task_isMainExecutorImpl"
  - "Deciding whether a per-call-site isolation annotation will actually end a crash or only relocate it"
  - "Considering a Swift-runtime check-mode knob, a linked-SDK pin, or a deployment-target change as the fix"
symptoms:
  - "EXC_BAD_ACCESS (SIGSEGV) at a small integer address — 0x1e, 0x1, and 0x0 observed across the three incidents"
  - "Faults in swift_getObjectType — or one frame deeper in objc_opt_class — reached via SerialExecutorRef::isMainExecutor() <- swift_task_isCurrentExecutorWithFlagsImpl"
  - "The frame below the runtime differs every time: a TimelineView closure, an .onHover closure, then SwiftUI's own _ButtonGesture"
  - "Every occurrence so far from one machine and one OS build: Mac15,7 / M3 Pro / macOS 26.2 (25C56)"
  - "Each per-call-site fix held at that site, and the crash reappeared at an unrelated site that still performed the check"
tags: [macos-26, concurrency, mainactor, executor, swiftui, crash-family, diagnosis]
related_components: [UI, Recording, NoTypeApp]
---

# The macOS 26 executor-identity crash family is one poisoned check, not three dispatch-path bugs

## Context

NoType has now taken three crashes with an identical runtime signature, and each was investigated, documented, and fixed as if it were its own bug:

| Date | Incident | Faulting address | Fix shape | What happened next |
|---|---|---|---|---|
| 2026-05-16 | `TimelineView` content closure calling a `@MainActor` instance method — [entry](./timelineview-mainactor-instance-method-crash-2026-05-16.md) | `0x1e` | Restructure the closure so no isolated instance method is called | Crash reappeared at `.onHover` |
| 2026-05-19 | `.onHover` closure literal inheriting `@MainActor` — [entry](./onhover-mainactor-inheritance-crash-2026-05-19.md) | `0x1` | `dsOnHover`: `@Sendable` strips inheritance, `Task { @MainActor in … }` bridges back | Crash reappeared at a stock SwiftUI `Button` |
| 2026-07-25 | Stock SwiftUI `Button`, inside Apple's own `_ButtonGesture` — [issue #82](https://github.com/weylandd/NoType/issues/82) | `0x0` | *(none available — see below)* | — |

Read one at a time, each looks like "a SwiftUI dispatch path that hands the concurrency runtime a bad executor reference". Read together, three facts refuse that framing:

1. **All three are the same machine and the same OS build.** Mac15,7 / M3 Pro / macOS 26.2 build 25C56. Not three users, not three OS versions — one process environment, three times.
2. **Each faults at a *different* small address.** `0x1e`, `0x1`, `0x0`. A framework consistently building one malformed executor reference would produce a consistent malformed value. Three different garbage values in the identity slot reads as one identity that is wrong in a drifting way, sampled at three moments.
3. **Every fix relocated the crash rather than ending it.** Each deleted one *call site* of the executor check. The check that faults is not a NoType behavior; NoType only chooses how many places perform it.

The third incident is where the per-call-site strategy runs out. The check happens inside Apple's compiled SwiftUI binary, in `_ButtonGesture`. There is no NoType closure to annotate, so the strategy that worked twice has no next move.

## Guidance

**Treat this signature as one poisoned main-executor identity for the process, not as a bug at the call site that crashed.** A new crash site is where the process *read* the bad identity, not where it was corrupted. That reframing changes four things:

1. **Do not count call-site fixes as coverage of the class.** Two prior entries each concluded that the class was addressed; both were followed by a new incident. Annotating a call site is real mitigation for a specific user-facing breakage — it is not a cure, and it should not be written up as one.
2. **Do not reach for a check-mode lever.** Neither the `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE` environment knob nor the runtime's linked-on-or-after bincompat gate can help. Both feed the same `options` word, and the fault happens before that word is read. Evidence in *Examples*.
3. **Do not fold the Core Audio IOProc crash into this family.** It has a different signature and a different truth. See *When to Apply*.
4. **Look for what corrupts the identity, not for another call site to silence.** The live hypothesis is `MainActor` work scheduled before `NSApplicationMain` has started the application — plausible against a lazily-created main executor on macOS 26, but it is a hypothesis, not a traced cause, which is why it is being staged as a test rather than shipped as a fix.

**The check itself stays enabled.** It is a safety net that has already earned its keep — it is what caught a genuine actor-isolation violation on the Core Audio HAL thread. Suppressing it, even if it were reachable, would trade a loud crash for a silent data race.

## Why This Matters

The cost of the wrong frame is not academic. Under the per-site frame, each fix ships, the issue closes, and the class is considered handled — and then a user on the affected OS build hits the next unpatched site. Under this frame, a call-site fix ships as deliberate mitigation with the cause still open, which is what "fixed" honestly means here.

The current incident's cost is also asymmetric in a way that shapes triage. Dictation runs through `CGEventTap` and never touches SwiftUI's button dispatch, so an already-configured user can still work. But onboarding's primary control is a stock `Button`, so a *new* user on the affected build cannot complete setup at all — and NoType ships no telemetry (ADR-013), so those users are invisible. They uninstall silently. That is why the README known-issue note exists.

## When to Apply

- **In the family** — any macOS 26.x crash that faults at a small integer address inside `swift_getObjectType`, reached from `SerialExecutorRef::isMainExecutor()` / `swift_task_isCurrentExecutorWithFlagsImpl`, on any thread including the main thread. **The terminal symbol varies by one frame and is not a discriminator:** the `.onHover` incident stopped at `swift_getObjectType + 40` (with `swift_task_isMainExecutorImpl` symbolicated above it), while the `TimelineView` incident stopped one frame deeper at `objc_opt_class + 48`, which `swift_getObjectType` tail-calls for ObjC-interop types. Match on the `isMainExecutor()` caller plus the small-integer address, not on the leaf symbol. "Main thread" is not an alibi either — the `.onHover` incident faulted on `com.apple.main-thread`.
- **Not in the family** — [`audio-ioproc-mainactor-inheritance-crash-2026-05-19.md`](./audio-ioproc-mainactor-inheritance-crash-2026-05-19.md) is the explicit counter-example. It shares the `swift_task_isCurrentExecutorWithFlagsImpl` frame but nothing else that matters: `EXC_BREAKPOINT` (SIGTRAP) rather than SIGSEGV, on the Core Audio HAL thread rather than the main thread, terminating in `_dispatch_assert_queue_fail` rather than in a bad-pointer read. It was a **genuine** actor-isolation violation — a `@MainActor`-inheriting closure literal really was running on `ioQueue` — and the one-keyword `@Sendable` fix was correct and final. It has not recurred. Folding it in would corrupt the family's evidence with a case where the runtime was right.
- **Before proposing a build-setting fix** — read the runtime path below first. Two of the three obvious levers are already disproved.

## Examples

**The runtime path, and where each lever lands.** From the Swift runtime source:

```
SwiftUI _ButtonGesture fires MainActor.assumeIsolated
  -> swift_task_isCurrentExecutorWithFlagsImpl        Actor.cpp:539
       options = flags                                 <- seeded by the bincompat gate,
                                                          adjusted by the env knob
       ExecutorTrackingInfo::current()                 Actor.cpp:547
         -> null (plain AppKit main thread)
       expectedExecutor.isMainExecutor()               Actor.cpp:554   <- FAULT PATH
         -> swift_task_isMainExecutorImpl              ExecutorImpl.cpp
              swift_getObjectType(identity)            <- SIGSEGV on a bad identity
       ...
       options consulted here                          Actor.cpp:589   <- AFTER the fault
```

`swift_task_isMainExecutorImpl` calls `swift_getObjectType(identity)` whenever the expected executor carries a serial-executor witness table — so a bad identity pointer faults there unconditionally. And `swift_task_isCurrentExecutorWithFlagsImpl` calls `isMainExecutor()` at line 554 but does not consult its check-mode options until line 589. **Both check-mode levers therefore land after the fault:** `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE` (`crash|nocrash|swift6|legacy|isIsolatingCurrentContext`, in `EnvironmentVariables.def`) and the linked-on-or-after gate (`Runtime/Bincompat.h`) both resolve to the same `options` word that is never reached. Neither can prevent it, from either end.

**What the shipped artifact rules out.** The v0.1.12 build is a universal binary (arm64 + x86_64), `minos 15.0`, SDK 26.5, with **no embedded Swift runtime dylibs** — it links only `/usr/lib/swift/*`. So there is no split concurrency runtime and no back-deployed one: the app is running the OS's own runtime, and the poisoned identity is not an artifact of two runtimes disagreeing.

**Discriminating the two signatures at a glance:**

| | This family | Core Audio IOProc (counter-example) |
|---|---|---|
| Signal | `EXC_BAD_ACCESS` / SIGSEGV | `EXC_BREAKPOINT` / SIGTRAP |
| Address | small integer (`0x1e`, `0x1`, `0x0`) | n/a — a deliberate trap |
| Thread | main thread | `com.apple.audio.IOThread.client` |
| Terminal frame | `swift_getObjectType`, or `objc_opt_class` one frame deeper | `_dispatch_assert_queue_fail` |
| Was the runtime right? | No — the identity is garbage | **Yes** — the closure really was off-main |
| Fix | mitigation only; cause open | `@Sendable`; correct and final |

## Related

- [`timelineview-mainactor-instance-method-crash-2026-05-16.md`](./timelineview-mainactor-instance-method-crash-2026-05-16.md) — first same-signature incident (`0x1e`).
- [`onhover-mainactor-inheritance-crash-2026-05-19.md`](./onhover-mainactor-inheritance-crash-2026-05-19.md) — second same-signature incident (`0x1`); also the source of the `dsOnHover` shape and of the rejection of `MainActor.assumeIsolated` as its bridge.
- [`audio-ioproc-mainactor-inheritance-crash-2026-05-19.md`](./audio-ioproc-mainactor-inheritance-crash-2026-05-19.md) — the **counter-example**, not a member. Different signature, genuine isolation violation, correctly and permanently fixed.
- [`sender-respawn-race-2026-05-16.md`](./sender-respawn-race-2026-05-16.md) — sibling macOS 26 concurrency-runtime oddity from the same discovery window; different mechanism.
- `docs/plans/2026-07-25-001-fix-macos-26-executor-crash-plan.md` — the staged investigation this reframing came out of, including the disproof of both check-mode levers (KD6).
- `GitHub issue weylandd/NoType#82` — the third incident, and where stage results are recorded.
- `NoType/UI/CLAUDE.md` — the two UI hard rules (`TimelineView` closure contents, `dsOnHover`) that mitigate the first two incidents.
- [`tooling-decisions/macos-15-deployment-target-2026-05-15.md`](../tooling-decisions/macos-15-deployment-target-2026-05-15.md) — macOS version policy. Raising the floor is not a lever available to this family without relitigating ADR-001.
