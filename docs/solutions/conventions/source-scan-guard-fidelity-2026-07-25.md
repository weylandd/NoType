---
title: A source-scan guard that only asserts absence stays green while the feature is dead
date: 2026-07-25
last_updated: 2026-07-26
category: conventions
module: cross-cutting
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - Writing a test that scans source text to pin a convention rather than asserting on behaviour
  - Moving work out of one place and into another, and adding a test to keep it out of the old place
  - Reviewing an existing source-scan test before relying on it as coverage
  - A convention-only rule keeps regressing and someone proposes a mechanical check
  - "Writing a guard whose subject is an installed hook, a swapped function pointer, a redaction rule, or the order of two steps"
  - "A test fixture is chosen for convenience rather than for the real shape of the thing being matched"
tags: [testing, source-scan, convention-tests, guard-fidelity, launch-ordering, false-negative, hook-installation]
related_components: [NoTypeApp, UI, Permissions, Diagnostics]
---

# A source-scan guard that only asserts absence stays green while the feature is dead

## Context

NoType pins two conventions with **source-text scans** rather than behavioural assertions, because in both cases the thing being prevented cannot be observed on the maintainer's machine:

- `NoTypeTests/DSComponentsHoverTests.swift` — no raw `.onHover` outside `dsOnHover`'s own definition. The crash it prevents only reproduces on macOS 26.2.
- `NoTypeTests/LaunchOrderingTests.swift` — no type constructed by `NoTypeApp.init()` may schedule `MainActor` work or touch `NSApp`. Same reason: the [executor-identity crash family](../runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md) does not reproduce locally, so a runtime assertion would never fire where it is needed.

This is a good instrument for that job. But a source scan is a *hand-written parser plus a needle list*, and both halves fail quietly: every failure mode of a source scan produces a **false negative** — a passing test — never a loud error. The scan cannot tell "the rule is satisfied" from "I did not look there."

The launch-ordering work surfaced five distinct ways `LaunchOrderingTests` was green while the regression it exists to catch was reachable. The most severe one is not a parsing bug at all — it is a category error in what the test asserted.

## Guidance

### The load-bearing rule: when work moves from A to B, pin B as well as A

**A test that only asserts "not at A" is satisfied by "nowhere at all."**

`LaunchOrderingTests` proved that launch work was *absent* from every launch-path initializer. Nothing proved it was *present* at the launch hook. Deleting the single line `appDelegate.launchHandler = { … }` from `NoTypeApp.init()` (`NoType/NoTypeApp.swift:169`) ships an app with no hotkey tap, no permission reads, no history/stats/dictionary mirrors and no VAD — and **the entire suite stays green**, because "nothing is primed" is exactly the state the priming tests assert.

Every "move the work" refactor needs the complement:

```swift
// LaunchOrderingTests.swift:108 — the complement to every other test in the file.
func test_launchWork_isActuallyWiredUp_fromNoTypeAppInit() throws {
    let combined = LaunchPathScanner.initBodies(inSource: source).joined(separator: "\n")
    XCTAssertFalse(initBodies.isEmpty, "Could not parse NoTypeApp.init() — the scan lost its anchor.")
    XCTAssertTrue(combined.contains("launchHandler ="), "…without it nothing ever primes.")
    XCTAssertTrue(combined.contains("prime()"),         "…otherwise AppState is never initialized.")
    XCTAssertTrue(combined.contains("apply()"),         "…otherwise the theme is never applied.")
}
```

One level out, the same class again: work that *is* wired, to a hook that never fires. `test_sparkleAndTerminationHandler_areWiredFromInit_notAWindowTask` (`LaunchOrderingTests.swift:142`) exists because both had been sitting on a scene `.task` that a menu-bar-only launch never evaluates — see [`scene-task-is-not-a-launch-hook`](../architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md).

### The fidelity checklist for the scan itself

Four more ways the same guard was green while the rule was violable. Walk these whenever writing or reviewing a source scan:

1. **The needle list rots toward the original example.** The rule is "schedule no `MainActor` work"; the first needle list was `Task {`. So `DispatchQueue.main.async` — the first thing a maintainer told *"don't do this synchronously in init"* reaches for — passed silently, as did `Task{`, `Task(priority:)`, `MainActor.run` and `MainActor.assumeIsolated`. Enumerate every idiom that reaches the *rule*, not every spelling of the *example you had in hand*. Current list at `LaunchOrderingTests.swift:447`.
2. **Substring matching over-matches identifiers.** `NSApp` matched `NSAppearance` and `NSApplicationDelegate`. Matching is now whitespace-normalised (so `Task{` and `Task  {` both hit `Task {`) and identifier-boundary-aware — `LaunchPathScanner.line(_:contains:)` at `LaunchOrderingTests.swift:459`.
3. **Traversal depth is a guess until you check the known offender.** The plan specified "one call level is enough." The actual offender — `init` → `refresh()` → `startPollingIfNeeded()` — sits **two** hops down, so a single-level scan walks straight past the one shape that motivated the test. The walk is now transitive over same-file calls with a visited set.
4. **Construction-time code that lives in no function body.** `private let boot = Task { … }` is a stored-property default: it runs during construction but appears in no `func` body, so a scan of function bodies cannot see it — on a codebase where `AppState` already uses property defaults heavily. Scanned now via `storedPropertyDeclarations` (`LaunchOrderingTests.swift:663`); property *observers* stay excluded because they cannot fire during init.

Two more that generalise beyond this file: **path filters must be anchored, not substring-matched** (`guard url.path.contains("/NoType/")`, commented "never index the test target", excluded nothing — the repo root is itself named `NoType`, so the filter's behaviour depended on what the clone directory was called), and **overloads must not collapse on name** (a `Task` in a second overload reachable from `init` was walked past).

### The same trap one step out: a guard whose subject is an installed hook

A source scan is the *clearest* instance because its subject is literally text, but the failure class is wider: **any guard whose subject is an installed thing — a swapped function pointer, a redaction rule, an ordering between two steps — can pass on the exact outcome it exists to prevent.** `ExceptionBreadcrumb` (the process-wide `objc_setExceptionPreprocessor` hook from the [executor-identity family](../runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md)) shipped with three such guards. All three were green; none was green for the reason it claimed.

1. **An `Optional`-vs-non-optional comparison collapses on the failure case.** `test_install_isIdempotent_andRetainsTheReplacedPreprocessor` asserted that the hook is not chained to itself and that a second `install()` does not overwrite the captured pointer — both written as `chainedBefore.map(address)` comparisons. When the chain is dropped *entirely*, that expression is `nil`, so "is it our own hook?" reduces to `nil != Optional(ptr)` (true) and "was it retained?" to `nil == nil` (true). The one outcome that turns every swallowed exception into an immediate `HIExceptions.mm:45` `SIGABRT` satisfied all three assertions. The fix is two-part: assert the precondition (`XCTAssertNotNil(chainedBefore)`) *before* any comparison that can degenerate, and add an end-to-end proof the chain **runs** rather than merely being retained — a fresh `NSException` carries 0 `callStackReturnAddresses`, and non-empty after passing through the hook, because populating them is precisely what the replaced preprocessor does.
2. **A fixture caught by a broader rule never exercises the specific rule the test names.** The Gemini-key scrub test used a 40-character stand-in, which `SecureFieldMasker`'s generic opaque-token catch-all (`\b[A-Za-z0-9_\-]{40,}\b`, `NoType/Context/SecureFieldMasker.swift:342`) redacts on its own. The rule the test claimed to pin — `googleAPIKeyRegex` (`\bAIza[0-9A-Za-z_\-]{35}\b`, `:241`) — never fired. And a real key is `AIza` + 35 = **39** characters, one *below* the catch-all, so the only rule standing between a live key and the log was the one the test never reached. Fix: fixture corrected to the real 39-char shape, and the *specific* redaction label (`[REDACTED — likely Google API key]`) asserted rather than a generic "something was redacted."
3. **Ordering between two individually-correct steps needs its own test.** Nothing pinned that `scrubbedReason` scrubs *before* it length-caps. Swapping those two lines leaves 16 of 17 tests in the file green while slicing a 39-character key 12 characters in — publishing an unredacted key prefix into a record the README asks users to paste into a public issue. Tests that assert each step works in isolation are structurally blind to their composition order; the guard has to straddle the boundary (`test_scrubbedReason_scrubsBeforeCapping_soAStraddlingKeyCannotSurvive`).

The through-line is the same as the absence-only trap above: each guard's green state was **compatible with the defect**, so its passing carried no information. Ask of any guard, not just a source scan: *what is the worst outcome in this area, and would this test be green under it?*

### Prove the guard red

None of the above is discoverable by reading the test. The only reliable check is to **break the thing on purpose and watch the test fail** — revert the fix, delete the wiring line, add the needle you think is covered — then restore. Both new assertions in this arc were verified red that way before being trusted. A guard never observed failing is a guard whose fidelity is unmeasured.

Give the scan **self-checks against silent degradation**, too: `LaunchOrderingTests.swift:32` asserts that discovery still finds `AppState`, `PermissionsViewModel`, `AppearanceController` and (transitively) `LoginItemController` before it asserts anything about violations, and throws on a duplicate file basename rather than last-write-wins. A scan that quietly resolves to zero files passes perfectly.

## Why This Matters

The failure is asymmetric in the worst direction. A behavioural test that stops testing usually goes red (a compile error, a missing symbol). A source scan that stops testing goes **green** — indistinguishable from success, and more dangerous than no test at all, because the team now believes the rule is mechanically enforced and stops reviewing for it by hand.

That belief is the whole reason these tests exist. `DSComponentsHoverTests` was added precisely because three prior fixes in the executor-check family had been convention-only and each was rediscovered in production. Replacing "humans remember" with a guard is only an improvement if the guard's fidelity is actually higher — and the absence-only shape has *lower* fidelity than a human reviewer, who would have noticed that nothing calls `prime()`.

The absence-only trap is not new to this repo, which is the argument for stating it as a convention rather than a one-off. Two prior instances, both already written up in their own domains:

- **Prompt-eval had the identical shape** and it is still open. `test_ax_antiLeak_aboveLineDoesNotPoisonTranscript` asserts an AX-supplied proper noun the speaker did *not* say stays out of the transcript. As [`positive-spelling-ax-fixture-2026-05-18.md`](../documentation-gaps/positive-spelling-ax-fixture-2026-05-18.md) puts it: *"a regression that makes Gemini IGNORE AX context entirely would pass the anti-leak test and ship silently."* Negative assertion, no positive complement, satisfied by the feature being dead.
- **A tautological boundary fixture** — `docs/solutions/conventions/testing-spm-and-git-2026-05-15.md` records a fixture (`beg.example`) that never contained the pattern it claimed to pin, so it passed under both the old and new implementation. Same failure class at the fixture level: the test looked where the bug was not.

The concrete cost here: the shipped artifact would have been a menu-bar app that launches, shows its icon, and does nothing — no hotkey, empty history, permissions permanently `.unknown`. Indistinguishable from a genuinely ungranted install, on a branch whose entire purpose was to fix a crash the maintainer cannot reproduce. (`AppState.prime()` now logs one `.info` line on entry for exactly this reason — `NoType/AppState.swift:376`.)

## When to Apply

- **Writing any new source-scan / convention test.** Walk the four checklist items plus the anchor-and-overload notes, then prove it red.
- **Any refactor that relocates work** — init → launch hook, view → controller, sync → async, one module to another. Ask: *if the destination were deleted, which test goes red?* If the answer is none, the guard is absence-only.
- **Reviewing a diff that adds "and a test pins this."** Check what the test would do if the feature were entirely removed rather than merely misplaced.
- **Writing a guard for an installed hook, a swapped pointer, a redaction rule, or an ordering between two steps.** Apply the hook-guard section: name the worst outcome in that area, then check whether the assertion would be green under it.
- **Narrower than it looks — but not only source text.** A behavioural test that constructs the object and asserts on its output does fail loudly when the subject *disappears*; that much still holds. What it does not catch is a subject that is present and wrong in a way the assertion cannot tell from correct — a comparison that degenerates to `nil == nil`, a fixture matched by a broader rule than the one named, two correct steps composed backwards. Source scans are the worst case of this class, not the whole of it.

## Examples

**Absence-only (the trap).** Both of these pass on an app that primes nothing:

```swift
// "The work is not in the initializer."
func test_launchPathInitializers_scheduleNoMainActorWork() { XCTAssertEqual(violations, []) }
// "The initializer leaves the mirrors empty."
func test_appState_init_leavesMirrorsAtEmptyDefaults() { XCTAssertTrue(state.history.isEmpty) }
```

Delete `appDelegate.launchHandler = { … }`: violations is still `[]`, mirrors are still empty. Green. Dead app.

**Complemented.** Add the assertion that the destination is wired (`test_launchWork_isActuallyWiredUp_fromNoTypeAppInit`, above) and the same deletion goes red on the first `XCTAssertTrue`.

**Needle rot, before and after.** Both of these violate the rule; only the first was caught:

```swift
init() { Task { @MainActor in await self.load() } }          // caught by `Task {`
init() { DispatchQueue.main.async { self.load() } }          // green until the list grew
```

**Two-hop traversal.** The offender's real shape — a clean-looking initializer whose helper's helper schedules the work. Pinned as a fixture by `test_scanner_flagsTaskLiteralTransitivelyThroughSameFileHelpers` (`LaunchOrderingTests.swift:191`):

```swift
init()                       { refresh() }
func refresh()               { startPollingIfNeeded() }
func startPollingIfNeeded()  { Task { … } }   // two hops down
```

**Documentation that licenses the blind spot back in.** `LaunchOrderingTests`' own class doc-comment said "One call level is enough" while the implementation below it walked transitively and a fixture 160 lines down pinned the two-hop case. A future "simplification" reading only the doc-comment would have restored the exact gap. When a scan's depth or needle list is deliberate, the comment must say *why*, with the counter-example — the current doc-comment names the `init` → `refresh()` → `startPollingIfNeeded()` chain explicitly.

## Related

- [`architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md`](../architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md) — the sibling failure one level out: work correctly wired, to a hook that never fires. Its guard (`test_sparkleAndTerminationHandler_areWiredFromInit_notAWindowTask`) is a presence assertion for the same reason.
- [`design-patterns/observation-loop-swallows-initial-state-2026-07-25.md`](../design-patterns/observation-loop-swallows-initial-state-2026-07-25.md) — the other near-miss from the same arc; a behavioural hazard the source scan could not have caught, which is the limit of this instrument.
- [`runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`](../runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md) — why the launch-ordering rule exists at all, why a runtime assertion was rejected as the mechanism, and the interceptor whose three guards supplied the hook-guard section above (its *Guidance* step 2 carries the chaining and atomic-install rules those guards failed to protect).
- [`documentation-gaps/positive-spelling-ax-fixture-2026-05-18.md`](../documentation-gaps/positive-spelling-ax-fixture-2026-05-18.md) — the same absence-only trap in the prompt-eval domain, still open. The clearest prior statement of this failure class in the repo.
- [`conventions/verify-subagent-test-reports-2026-05-18.md`](./verify-subagent-test-reports-2026-05-18.md) — sibling principle at a different boundary: a green signal that reports something narrower than what you concluded from it.
- [`conventions/testing-spm-and-git-2026-05-15.md`](./testing-spm-and-git-2026-05-15.md) — the base testing convention this refines; its tautological-fixture bullet is the fixture-level instance of the same class.
- [`runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md`](../runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md) — where `DSComponentsHoverTests` came from; its Prevention section presents the scan as an unqualified win, which this entry qualifies.
- `NoTypeTests/LaunchOrderingTests.swift`, `NoTypeTests/DSComponentsHoverTests.swift` — the two general source-scan guards in the project. `NoTypeTests/ExceptionBreadcrumbTests.swift` carries a third, file-scoped one (`test_breadcrumbSource_schedulesNoMainActorWork_andDoesNotTouchNSApp`) added because `LaunchOrderingTests`' discovery walks constructions (`TypeName(`) and so cannot see a type reached only through a static `install()` call — an instance of checklist item 1 at the discovery layer rather than the needle layer.
- `NoType/UI/CLAUDE.md` "Launch ordering" — the rule these guards pin.
