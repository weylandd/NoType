---
title: A test that touches process-global state does not stay inside the test process
date: 2026-08-13
category: conventions
module: UI
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - "A unit test constructs a real controller that owns windows, panels, the pasteboard, or any other shared OS resource"
  - "The test host is the application bundle itself rather than a stub host"
  - "A bug report's symptoms stop reproducing, or start reproducing too well, on the developer's own machine"
  - "Suppressing a side effect in tests, and choosing between stubbing the object and gating its last step"
tags: [testing, test-host, side-effects, appkit, hud, xctest, diagnosis]
related_components: [UI, AppState, Injection]
---

# A test that touches process-global state does not stay inside the test process

## Context

A user reported that the error HUD's close button did nothing. Two rounds of investigation went into it, and the second round's log reading found that part of what the reporter had been looking at was **the test suite**.

`NoTypeTests` runs with `NoType.app` as its test host, so a test process is a full copy of the app. Four suites construct a **real** `HUDController` — `AppStateRetryTests`, `HistoryRowActionsTests`, `AppStateRetentionTests`, `LaunchPrimingTests` — with nothing stubbed. Two of them, `AppStateRetryTests` and `HistoryRowActionsTests`, then drive `AppState` into `surfaceError` (through `retryEntry` → `settleRetry`), and **that** is what builds a panel: a real `HUDPanel`, an `NSPanel` at `.statusBar` window level with `.canJoinAllSpaces`, ordered onto the screen at the same top-right coordinates the installed app uses.

Be precise about which half is which, because the sloppy version of this sentence is itself a bad claim. Constructing the controller paints nothing; the other two suites hold a live HUD controller that is never asked to show anything. What escapes is the *showing*, and only two suites reach it — which is enough, because a suite runs many times.

The maintainer's `ui.hud` log for the reporting session carries **seventeen short-lived PIDs in four minutes, two pairs of them concurrent**, alongside the installed app. Those are test hosts. A person clicking the close button on the panel they can see may be clicking a panel belonging to a process that exited, with another process's panel on top of it — which looks exactly like a dead button.

(The log itself is not in the repo; the count is the author's reading of it, recorded at `NoType/UI/HUDPanel.swift`. The mechanism is verifiable from the source; the number is not independently re-derivable.)

## Guidance

**Before writing "the test constructs a real X", ask what X does that leaves the process.** The test-host bundle has the app's Info.plist, its bundle identifier, and its entitlements, so anything the app can do to shared OS state, a test can do — to the developer's actual machine, in parallel, seventeen times a run.

The classes worth checking in a macOS app:

- **Window server** — any `NSWindow`/`NSPanel` ordered front, especially at `.statusBar` level or with `.canJoinAllSpaces`, which put it above and across everything.
- **The general pasteboard** — `NSPasteboard.general` is one object for the login session. (NoType already handles this correctly: tests that exercise a clipboard write wrap it in `PasteboardSnapshot.capture(.general)` and restore in a `defer`.)
- **The unified log** — records written by a test carry the same subsystem and category as the app's, so a later log reading cannot tell them apart without a PID column.
- **TCC prompts, login items, global event taps, notification center, the Dock** — each is per-user, not per-process.
- **Anything under `~/Library/Application Support/`** — a store pointed at the real directory, not a temp one.

**Gate the single call that leaves the process, not the object.** The fix is the entire body of `HUDPanel.show()`:

```swift
func show() {
    guard !HUDHostEnvironment.isTestHostProcess else { return }
    orderFrontRegardless()
}
```

Everything upstream still runs: the panel is constructed, its hosting view is measured, `sizeToFit()` runs, `positionTopRight(…)` computes and applies an origin. Only the ordering-on-screen is withheld, and `hide()` is deliberately not gated at all. That choice is what keeps the change free: `HUDController.errorHUDVisible` is `errorPanel != nil`, so every existing assertion is unaffected, and the panel is still constructed, measured and positioned — the runtime geometry path a stub would have removed from coverage entirely. Stubbing the controller behind a protocol would have suppressed the panels and deleted the coverage they carry in the same move.

**Detect the test host on two independent signals, and resolve once:**

```swift
static func isTestHost(environment: [String: String], xctestLinked: Bool) -> Bool {
    xctestLinked || environment["XCTestConfigurationFilePath"] != nil
}
static let isTestHostProcess: Bool = isTestHost(
    environment: ProcessInfo.processInfo.environment,
    xctestLinked: NSClassFromString("XCTestCase") != nil
)
```

Neither signal can change during a process's life, so a `static let` is right. Taking the pure function as arguments is what makes both signals testable in isolation, including the negative — `test_shippingApp_isNotMistakenForATestHost` feeds a decoy key `XCTestConfigurationFilePathXX` to pin that the match is exact rather than a prefix.

**A suppression needs a liveness assertion, or it decays into dead code silently.** If the detector ever stops recognising the host, the suppression stops suppressing and nothing goes red — the panels simply come back and everyone assumes they always did. `test_thisSuiteIsItselfRunningInARecognisedTestHost` asserts `HUDHostEnvironment.isTestHostProcess` is true *while running*, which is the one assertion that cannot be satisfied by the mechanism being broken. The gate also carries a source scan naming both the gate **and** its destination (`orderFrontRegardless`), so deleting the ordering call — which would make the shipping app show no HUDs at all — fails loudly rather than passing an absence check.

## Why This Matters

The cost here was not flaky tests or a cluttered desktop. It was **a corrupted bug report**. The reporter's description ("the close button doesn't work") was accurate about what they saw and wrong about why, and the investigation spent a round chasing a within-process explanation that turned out to be a real but different bug. Test-host escape does not usually produce a test failure — the tests were green throughout — it produces bad evidence, and bad evidence is the expensive kind.

It is also invisible to every normal signal. The suite is green, the app builds, `xcodebuild test` prints nothing unusual, and a developer who is not watching their screen during a four-minute test run never sees it at all. The only reason it was found is that a log breadcrumb added for an unrelated reason happened to carry a PID column.

The asymmetry that makes this worth a rule: a test asserting on an object's *state* is exactly as strong whether or not the object also painted a window. The side effect buys the test nothing and costs the developer's environment something, so suppressing it is close to free — but only if the suppression is placed at the boundary rather than around the object.

## When to Apply

- **Writing a test that constructs a real controller** owning windows, panels, the pasteboard, the log, or a filesystem path. Enumerate what escapes; suppress at the escape.
- **Choosing between a stub and a gate.** Prefer the gate when the object under test is also the thing you want covered. A stub removes the side effect and the coverage together.
- **Any bug report whose symptoms involve on-screen elements not responding**, on a machine where a suite has been run. Check for multiple PIDs before believing a within-process explanation.
- **Adding a new escape** to a type that already has a gated one — a second `orderFront`, a second pasteboard write. The gate is per-call, so a new call is ungated by default; the occurrence-counting habit from [source-scan guard fidelity](./source-scan-guard-fidelity-2026-07-25.md) applies.
- **Not** a licence to gate broadly. `hide()` is ungated on purpose, and nothing else in the module consults the flag. A process-wide "am I a test?" branch is a hazard in its own right the moment it starts changing behaviour the tests are asserting on.

## Examples

**The already-correct sibling in this repo** — a test that must write to the one real pasteboard saves and restores it (`NoTypeTests/AppStateFocusNoticeTests.swift`):

```swift
let saved = PasteboardSnapshot.capture(.general)
defer { saved.restore(to: .general) }
NSPasteboard.general.clearContents()
…
```

Same class of problem, different remedy: the pasteboard write *is* the thing under test, so it is restored rather than withheld. Withhold what the test does not need; restore what it does.

**The liveness complement, which is the part most likely to be left out:**

```swift
func test_thisSuiteIsItselfRunningInARecognisedTestHost() {
    // If this ever fails, the suppression above has quietly become dead
    // code and the panels are back on the developer's desktop.
    XCTAssertTrue(HUDHostEnvironment.isTestHostProcess)
}
```

## Related

- [`ui-bugs/error-hud-rebuilt-under-the-click-2026-08-13.md`](../ui-bugs/error-hud-rebuilt-under-the-click-2026-08-13.md) — the *other* half of the same investigation and the same commit. Two superpositions, one within a process and one between processes; that one is the bug the reporter actually hit.
- [`conventions/source-scan-guard-fidelity-2026-07-25.md`](./source-scan-guard-fidelity-2026-07-25.md) — the gate-and-destination shape the guard follows, and why an absence-only assertion would have been green with `orderFrontRegardless` deleted.
- [`conventions/testing-spm-and-git-2026-05-15.md`](./testing-spm-and-git-2026-05-15.md) — where the rest of this repo's test-authoring habits live.
- `NoType/UI/CLAUDE.md` — the HUD inventory and the panel contract; `NoType/UI/HUDPanel.swift` carries `HUDHostEnvironment` and the log reading behind the seventeen-PID figure.
- Commit `c9d04cd` (both halves of the fix). Branch-local to `refactor/structural-gap-tracking` and subject to rewrite on squash-merge; `NoType/UI/HUDPanel.swift` is the stable reference.
