---
title: A source-scan guard that only asserts absence stays green while the feature is dead
date: 2026-07-25
last_updated: 2026-08-11
category: conventions
module: cross-cutting
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - Writing a test that scans source text to pin a convention rather than asserting on behaviour
  - "Moving work out of one place and into another — or extracting a factory, constant, or seam so a test can reach it — and adding a test that pins only one of the two places"
  - Reviewing an existing source-scan test before relying on it as coverage
  - A convention-only rule keeps regressing and someone proposes a mechanical check
  - "Writing a guard whose subject is an installed hook, a swapped function pointer, a redaction rule, or the order of two steps"
  - "A test fixture is chosen for convenience rather than for the real shape of the thing being matched"
  - "Adding a type to a path a scan enforces a rule over — especially via a default argument, a stored-property default, or a factory"
tags: [testing, source-scan, convention-tests, guard-fidelity, launch-ordering, false-negative, hook-installation, discovery-set]
related_components: [NoTypeApp, UI, Permissions, Diagnostics, Recording, Gemini]
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

**The same rule with nothing moved: a seam extracted so a test can reach it.** The A→B framing assumes a relocation, which is why it did not fire on the shape U1 of the dictation-delivery work shipped. Nothing left production there — `makeSessionConfiguration()` (`NoType/Gemini/GeminiClient.swift:280`) was carved out of `init` expressly so the two `URLSession` budgets `requestInactivityBudget` and `resourceCeiling` (`:260`, `:273`) would be nameable from a test at all, and the values still ship from the same place. Extraction-for-testability nonetheless creates the same two-address problem, because the test now proves a fact about a **symbol**, and the symbol is the shipped value only for as long as the wiring holds. `test_sessionConfiguration_appliesBothNamedBudgets` (`NoTypeTests/GeminiRetryPolicyTests.swift:226`) asserts the factory applies both constants. Rewrite `init` with a hand-rolled `URLSessionConfiguration` and a literal `30`, and every assertion in that file stays green, `makeSessionConfiguration()` becomes dead code, and a stalled chunk costs whatever the literal says.

The cost is specific rather than theoretical. The same plan's R20 owns *cutting* that budget once its measurement exists. Under the mutation, R20's cut lands on a constant nothing reads: the diff says the wait is now N seconds, the release notes say it, and the app still waits 30.

`test_shippedSession_isBuiltFromTheNamedBudgetFactory` (`NoTypeTests/GeminiClientOfflineShortCircuitTests.swift:349`) closes it, in the same shape as `test_launchWork_isActuallyWiredUp_fromNoTypeAppInit`: a source scan asserting `self.session = URLSession(configuration: Self.makeSessionConfiguration())` occurs, **plus a uniqueness assertion** that `URLSession(configuration:` occurs exactly once — without which a surviving call could sit beside a second session carrying its own budgets, which is the one that ships. Pin the count as well as the presence whenever "the thing exists" and "the thing is the one used" can come apart. It is a source assertion rather than a behavioural one for a stated reason: `session` is `private`, so reading `.configuration` back off it from a test would trade an encapsulation boundary for the same fact.

Ask the question as **"does any test fail if the production call site stops calling this?"** rather than "did the work move?" Every seam added for testability — a factory, a `static` hoisted out of a body, an injected default, a protocol extracted to allow a fake — answers *no* by default, and only the relocation half of that set is described by the heading above.

### The fidelity checklist for the scan itself

Six ways a source scan was green while the rule it names was violable — four from the launch-ordering work, two from the dictation-delivery work (whose cases also widened items 2 and 5). Walk these whenever writing or reviewing a source scan:

1. **The needle list rots toward the original example.** The rule is "schedule no `MainActor` work"; the first needle list was `Task {`. So `DispatchQueue.main.async` — the first thing a maintainer told *"don't do this synchronously in init"* reaches for — passed silently, as did `Task{`, `Task(priority:)`, `MainActor.run` and `MainActor.assumeIsolated`. Enumerate every idiom that reaches the *rule*, not every spelling of the *example you had in hand*. Current list at `LaunchOrderingTests.swift:447`.
2. **Substring matching over-matches identifiers.** `NSApp` matched `NSAppearance` and `NSApplicationDelegate`. Matching is now whitespace-normalised (so `Task{` and `Task  {` both hit `Task {`) and identifier-boundary-aware — `LaunchPathScanner.line(_:contains:)` at `LaunchOrderingTests.swift:459`. **The same over-match happens semantically, not only lexically.** A needle naming a call also matches that call *under negation*: the R28 guard's gate needle was `Self.requiresFreshConnection(after: error)`, and it was green on `if !Self.requiresFreshConnection(after: error)` — an inversion that drops the connection pool on every 429 and 5xx and never on the status-0 transport class the feature exists for, i.e. precisely backwards. The needle now carries its `if ` (`NoTypeTests/GeminiClientOfflineShortCircuitTests.swift:290`). When a guard's subject is a *decision*, the needle must include enough of the expression to fix its sense, not merely name the predicate being consulted.
3. **Traversal depth is a guess until you check the known offender.** The plan specified "one call level is enough." The actual offender — `init` → `refresh()` → `startPollingIfNeeded()` — sits **two** hops down, so a single-level scan walks straight past the one shape that motivated the test. The walk is now transitive over same-file calls with a visited set.
4. **Construction-time code that lives in no function body.** `private let boot = Task { … }` is a stored-property default: it runs during construction but appears in no `func` body, so a scan of function bodies cannot see it — on a codebase where `AppState` already uses property defaults heavily. Scanned now via `storedPropertyDeclarations` (`LaunchOrderingTests.swift:663`); property *observers* stay excluded because they cannot fire during init.
5. **Commented-out text is still text.** A scan matches source, and source includes the code that no longer runs — so a needle satisfied by a comment is satisfied by dead code. The R28 guard asserted that `flushPooledConnections` still calls `session.flush`; hollowing the helper out and leaving `// Disabled while investigating: session.flush { … }` in its place passed. **Scoping the assertion did not fix it.** The check was narrowed from the whole file to the helper's own body — which looks like exactly the right correction, and is not, because the comment is *inside* the body. "Disable while investigating" is the routine way matching-text and matching-behaviour come apart, and it survives review precisely because it advertises itself as temporary. The fix is to run every needle in the file against comment-stripped source (`GeminiClientOfflineShortCircuitTests.swift:445`). Note what that costs: **the stripper is new hand-written parsing added to a guard, which is new false-negative surface of exactly the kind this checklist is about** — so it needs its own fixture, and the fixture earned its keep immediately, catching a defect in the stripper's own first draft where the sentinel protecting URL literals itself contained `//` and truncated every endpoint literal at the scheme (`:375`, `:449`). Where the parse is deliberately naive — block comments stripped non-recursively, `//` inside string literals stripped except a URL's `://` — the limits are recorded on the helper rather than assumed away.

   **The reason originally given for tolerating those limits has since been retracted, and the retraction generalises further than the limits do.** The helper's doc-comment claimed a wrong parse here fails *loud* — a mangled needle stops matching, the anchor stops resolving, the test goes red. That was true of the file it was written in, which asserted only **presence**. U3 of the dictation-delivery plan ported the helper into a file that also asserts **absence** (`start()` must not contain `destinationPID`; the withheld arm must not contain `TextInjector.paste(`), and deleting text is exactly how an absence assertion passes for the wrong reason. Nothing about the helper changed — the assertions around it did. **A helper's safety argument is scoped to the kinds of assertion in its file, so adding an assertion of a new kind can falsify a comment nobody edited.** The claim is now explicitly forbidden from being restated (`NoTypeTests/RecordingSessionFocusGuardTests.swift:938`).

   Two more ways the same needle survives while the code does not, both from U3:

   - **A block comment is not a line comment, and the fix does not travel by itself.** U3's guard shipped with line-only stripping and was green with `/* … */` wrapped around the freeze — the identical hole this item already describes, in a file written well after it was closed elsewhere. The remedy was to **port** `GeminiClientOfflineShortCircuitTests`' stripper verbatim (`:445`) rather than grow a second one. A stripper is not boilerplate; it is the part of the guard whose failure mode is silence, which makes it a thing to share rather than re-derive. Neither file U3 scans contains a block comment today — that makes the hole latent, not absent, and latent is what a guard is for.
   - **`#if` cannot be stripped away, because the text is genuinely there.** A freeze inside `#if DEBUG` reads present to a scan and is absent from the shipping binary; no parse fixes this, since the scan matches source and the question is about a build configuration. Both scanned bodies now assert `#if` does not occur at all (`:628`, `:675`). Blunt on purpose: a legitimate future `#if` fails the guard loudly and forces it to be re-derived, which is the right direction for an instrument whose other failure mode is a silent pass.

6. **An ordering assertion anchors on one occurrence, and a second occurrence is invisible to it.** U3's guard pins the paste destination's freeze *before* the stop path suspends — three separate ordering assertions (ahead of the first `await`, ahead of the stop `Task`, ahead of `recordingState = .sending`), each resolving the freeze with `body.range(of: "session.freezePasteDestination(")`, which returns the **first** match. Add a *second* freeze after the suspension and all three still pass, while the later call is the one that wins and reads the frontmost application at a moment the user was never promised — precisely the bug the three assertions exist to prevent. The fix is an occurrence count beside them (`NoTypeTests/RecordingSessionFocusGuardTests.swift:668`). Generalised: **an ordering assertion is a claim about a position, and a position constrains nothing unless the thing occupying it is unique.** Every "X precedes Y" needs "X occurs once" beside it, and the hazard is sharpest wherever last-writer-wins — a re-assignment, a re-registration, a second `defer`, a later `install()`. This is the same instruction as the uniqueness assertion in the extraction section above, reached from the other direction: there the second occurrence wins by being *the one used*, here by being *later*.

Two more that generalise beyond this file: **path filters must be anchored, not substring-matched** (`guard url.path.contains("/NoType/")`, commented "never index the test target", excluded nothing — the repo root is itself named `NoType`, so the filter's behaviour depended on what the clone directory was called), and **overloads must not collapse on name** (a `Task` in a second overload reachable from `init` was walked past).

### The same trap one step out: a guard whose subject is an installed hook

A source scan is the *clearest* instance because its subject is literally text, but the failure class is wider: **any guard whose subject is an installed thing — a swapped function pointer, a redaction rule, an ordering between two steps — can pass on the exact outcome it exists to prevent.** `ExceptionBreadcrumb` (the process-wide `objc_setExceptionPreprocessor` hook from the [executor-identity family](../runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md)) shipped with three such guards. All three were green; none was green for the reason it claimed.

1. **An `Optional`-vs-non-optional comparison collapses on the failure case.** `test_install_isIdempotent_andRetainsTheReplacedPreprocessor` asserted that the hook is not chained to itself and that a second `install()` does not overwrite the captured pointer — both written as `chainedBefore.map(address)` comparisons. When the chain is dropped *entirely*, that expression is `nil`, so "is it our own hook?" reduces to `nil != Optional(ptr)` (true) and "was it retained?" to `nil == nil` (true). The one outcome that turns every swallowed exception into an immediate `HIExceptions.mm:45` `SIGABRT` satisfied all three assertions. The fix is two-part: assert the precondition (`XCTAssertNotNil(chainedBefore)`) *before* any comparison that can degenerate, and add an end-to-end proof the chain **runs** rather than merely being retained — a fresh `NSException` carries 0 `callStackReturnAddresses`, and non-empty after passing through the hook, because populating them is precisely what the replaced preprocessor does.
2. **A fixture caught by a broader rule never exercises the specific rule the test names.** The Gemini-key scrub test used a 40-character stand-in, which `SecureFieldMasker`'s generic opaque-token catch-all (`\b[A-Za-z0-9_\-]{40,}\b`, `NoType/Context/SecureFieldMasker.swift:342`) redacts on its own. The rule the test claimed to pin — `googleAPIKeyRegex` (`\bAIza[0-9A-Za-z_\-]{35}\b`, `:241`) — never fired. And a real key is `AIza` + 35 = **39** characters, one *below* the catch-all, so the only rule standing between a live key and the log was the one the test never reached. Fix: fixture corrected to the real 39-char shape, and the *specific* redaction label (`[REDACTED — likely Google API key]`) asserted rather than a generic "something was redacted."
3. **Ordering between two individually-correct steps needs its own test.** Nothing pinned that `scrubbedReason` scrubs *before* it length-caps. Swapping those two lines leaves 16 of 17 tests in the file green while slicing a 39-character key 12 characters in — publishing an unredacted key prefix into a record the README asks users to paste into a public issue. Tests that assert each step works in isolation are structurally blind to their composition order; the guard has to straddle the boundary (`test_scrubbedReason_scrubsBeforeCapping_soAStraddlingKeyCannotSurvive`).

The through-line is the same as the absence-only trap above: each guard's green state was **compatible with the defect**, so its passing carried no information. Ask of any guard, not just a source scan: *what is the worst outcome in this area, and would this test be green under it?*

### A third shape: the guard measures an axis the compiler already owns

The two shapes above are green *while the defect is reachable*. This one is green for a different reason — the guard is real, but it duplicates a stronger mechanism, and the axis where the policy actually lives is unguarded. The tell is a drift guard between two **exhaustive switches over the same enum**.

`RecordingSession` grew a second classifier in U1 of the retry work: `shouldRetain(_:)` (`NoType/Recording/RecordingSession.swift:237`) decides whether a failed chunk's audio is kept for a retry, sitting immediately below `isTerminal(_:)` (`:190`), which decides whether the same error aborts the session. Adjacency is deliberate — a new error case should be added to both — and the unit shipped `test_everyTerminalCase_declinesRetention` to pin that they cannot diverge.

Two things were wrong with it as a guard:

1. **The case axis belongs to the compiler.** Both functions switch over `GeminiClient.GeminiError` (six cases, `NoType/Gemini/GeminiClient.swift:34`) with **no `default`**. A seventh case does not compile in either function — the type system, not the test, is what forces a maintainer to visit both. Worse, on that axis the test is *weaker* than the compiler it duplicates: it iterates a hand-maintained `fixtures` list, so a classification disagreement on a new case is caught only if someone also remembers to append a fixture. The compiler needs no such cooperation.
2. **The real policy lives in the associated value, which had zero coverage.** Neither function's interesting behaviour is "which case is this" — it is the `Int` inside `.http`. `isTerminal` returns `status == 401 || status == 403`; `shouldRetain` returns `status != 401 && status != 403`. That carve-out is the entire policy, it is duplicated by hand in two places, and no fixture list or `CaseIterable` conformance can enumerate an `Int`.

The fix sweeps the value space instead of the case space, asserting the complement property directly (`NoTypeTests/RetainedRecordingTests.swift:195`):

```swift
func test_noHTTPStatusIsBothTerminalAndRetained() {
    for status in 0...599 {
        let error = GeminiClient.GeminiError.http(status: status, body: "")
        if RecordingSession.isTerminal(error) {
            XCTAssertFalse(RecordingSession.shouldRetain(error),
                           "HTTP \(status) is terminal, so it must retain nothing")
        }
    }
}
```

Proved red per the section below: adding `|| status == 402` to `isTerminal` fails the sweep on 402 while **every other test in the file — including the no-drift test — stays green**. That divergence would retain audio for a session that aborted, writing a history row with a live retry button for a failure a retry can never fix.

Generalised: **when a guard's subject is two exhaustive switches over the same enum, the compiler already owns the case axis, so the guard earns its keep only on the associated-value axis.** A drift test that iterates enum cases is measuring the compiler. Before writing any consistency guard, name the axis it covers and ask what *else* already covers that axis — then check whether the axis carrying the actual policy is covered by anything at all. The same question applies wherever a stronger mechanism is already in play: an exhaustive switch, a non-optional type, a `let` binding, a database constraint.

This does not mean deleting the enum-axis test. It means not counting it as the coverage — keep it if it documents intent (it names the invariant in prose for the next reader), but write the comment that says what it does *not* close, so the next maintainer does not read its green as "these two agree."

**A second instance, with both mechanisms removed.** `GeminiClient.requiresFreshConnection(after:)` (`NoType/Gemini/GeminiClient.swift:1130`) and `RecordingSession.isNetworkClass(_:)` (`NoType/Recording/RecordingSession.swift:312`) answer the same question — *is this the status-0 transport class* — for two different consumers: drop the connection pool before a retry, and bound `splitRetry`'s dispatch. `isTerminal` / `shouldRetain` at least sit adjacent in one file, and the section above treats that adjacency as the weak thing keeping them in step. **Across a module boundary there is no adjacency to lean on, and here there is no compiler term either** — neither function is an exhaustive switch, and `isNetworkClass` takes `Error` rather than `GeminiError` and casts, so nothing whatsoever forces a maintainer widening one to visit the other. Run this section's own prescribed check ("what else already covers this axis?") and the answer comes back *nothing*: the value-axis sweep is not the *remaining* coverage, it is the *only* coverage. `test_freshConnectionPredicate_agreesWithRecordingSessionsNetworkClass` (`NoTypeTests/GeminiRetryPolicyTests.swift:160`) asserts the two agree across `-5...699` plus every non-`.http` case. The other half of the fix is prose, and it took a second pass: `requiresFreshConnection`'s doc-comment named `isNetworkClass` as its twin (`GeminiClient.swift:1116`) while `isNetworkClass`'s named only `isTerminal` and `shouldRetain` and carried no pointer back. A sweep in a third file is not what a maintainer reads before editing a predicate, and **a one-directional pointer makes only one of the two authors aware** — so a Recording-side widening still met nothing. Both directions or neither; the reciprocal pointer landed in `8eebf8b` (`RecordingSession.swift:509`). (The first draft's doc-comment disclaimed the two neighbours it is *not* — `retryDecision` and `isTerminal` — while omitting the one it must agree with; that asymmetry was the same failure mode, one step smaller.) The tell for which branch you are in: **can you delete one function's body and get a compile error at the other?** For `isTerminal` / `shouldRetain` a new enum case is caught; for this pair nothing is.

**Then check the sweep can express the mutation.** That predicate's own sweep shipped as `for status in 100...599 where status != 0` — a `where` clause that can never fire on a range starting at 100. Widening `requiresFreshConnection` to `status <= 0` passed every assertion in the file. The floor now starts below zero (`GeminiRetryPolicyTests.swift:135`, with the reason written beside it). **A sweep is only stronger than an enumeration over the values it actually visits**; a range chosen to look plausible rather than to bracket the mutation is an enumeration wearing a `for` loop, and it inherits every weakness this section attributes to a hand-maintained fixture list. Same lesson as the uniform-fixture case in *Why This Matters* below: prescribing the mutation probe does not help when the input space cannot express the mutation.

**The mirror case: two predicates that must *not* agree.** Everything above concerns twins whose contract is agreement, where the guard's job is to prove they never diverge. U3 shipped the inverse, and it is the easier one to guard backwards. `shouldWithholdPaste(destinationPID:currentPID:)` (`NoType/Recording/RecordingSession.swift:197`) and `shouldDiscardInsertionContext(sourcePID:destinationPID:)` (`:270`) have bodies that are identical modulo parameter names — `guard a > 0, b > 0 else { return false }; return a != b` — they share an operand, and they were deliberately given the same conservatism direction so that one notion of process identity governs the whole paste region. Everything about them invites a merge, and the compiler will never object to one. But they answer different questions about different moments: the first compares the frozen destination against the frontmost process **at paste time** ("may we paste at all"), the second against the process the session **started in** ("is the cursor context we captured about the place we are pasting into"). Neither implies the other, and the hands-free flow is the pair a reader collapses first, because it is cross-application *and* it pastes.

Run this section's own check and the axis inverts. A sweep proving these two never diverge — the instrument that was right for the twins above — would here be **actively wrong**, because divergence is the contract. What earns its keep is **independence cases**: one fires and the other does not, in both directions, plus the session where both fire (`NoTypeTests/RecordingSessionFocusGuardTests.swift:376`, `:395`, `:410`). Generalised: **before writing any consistency guard between two similar predicates, decide whether their relationship is agreement or independence — identical bodies are evidence of neither.** Getting it backwards produces either a test that goes red on correct code, or (worse) one that passes today and licenses a merge which silently fuses two policies that were meant to evolve apart. Here only the doc-comments and those three cases stand between the pair and that merge, which is why both predicates carry an explicit "this is not the other one" paragraph.

### A fourth shape: the property is checked correctly, over a discovery set that quietly narrowed

The three shapes above are all about the *assertion*. This one is about the **population the assertion runs over**. A source scan is two scans stacked: one that decides *which subjects to look at*, and one that checks *the property* on each. Only the second is ever written down as the rule, so only the second gets reviewed — and a discovery pass that silently returns a smaller set produces exactly the same green as a rule that holds.

`LaunchPathScanner.launchPathTypes` (`NoTypeTests/LaunchOrderingTests.swift:549`) builds the launch path by walking `constructedTypeNames(in: fn.body)` over every reachable `init` body. `functionBodies` deliberately "walk[s] to the opening brace of the body, skipping the signature (parameters, effects, return type)" (`:816`), so nothing inside a parameter list is ever seen.

U5 of the retry work put a new type on the launch path as a **default argument**:

```swift
// NoType/AppState.swift:349 — the default is still there; it is the test surface.
init(…, retainedAudio: RetainedAudioStore = RetainedAudioStore()) { … }
```

A default argument is evaluated **at the call site** — inside `NoTypeApp.init()` — so `RetainedAudioStore` was genuinely constructed on the launch path and genuinely subject to the rule. But its `RetainedAudioStore(` text sits in a parameter list in a *different file*, appearing in no `init` body the scanner reads. The type never entered the population, so `violations(inSource:)` never opened its source. A `Task { … }` or an `NSApp` read inside `RetainedAudioStore.init` would have shipped with the entire suite green.

The sharp part: this file had already reasoned its way to this exact conclusion **on the other axis**. `violations(inSource:)` scans `storedPropertyDeclarations` (`:647`) explicitly because those "execute as part of construction even though they appear in no function body" — checklist item 4 above. That sentence describes a default argument verbatim. The insight was applied to the property scan and not to the discovery scan, because nobody had written down that **discovery is a scan too**.

So: **a scan must assert its own discovery set, not only the property it checks over that set.** For every subject the rule is meant to cover, either the scan demonstrably found it, or a named assertion pins it:

```swift
// LaunchOrderingTests.swift:64 — inside the repo-wide violations test, beside the
// existing AppState / PermissionsViewModel / AppearanceController discovery guards.
XCTAssertTrue(
    types.keys.contains("RetainedAudioStore"),
    "Launch-path discovery lost RetainedAudioStore — NoTypeApp.init() must construct it explicitly rather than relying on AppState.init's default argument, which this scan cannot see. Found: \(types.keys.sorted())"
)
```

**Say plainly whether you repaired the scan or routed around it.** This fix routed around: `NoTypeApp.init()` now names the type in a body (`NoType/NoTypeApp.swift:160`) and the assertion above stops that being "simplified" back to the elided form. But `constructedTypeNames` still cannot see default arguments, so the *next* defaulted construction added anywhere on the launch path is invisible again, with nothing to catch it. That is a defensible trade — parsing parameter lists correctly is hard, and a wrong parse fails **green**, which is the hazard this whole entry is about — but it is a tripwire for one type, not a closed class. A write-up that implies otherwise hands the next reader a false sense of coverage.

**Enumerate against the runtime state, not against the syntax you had in hand.** The discovery axis rots the same way needle lists do (checklist item 1). Shapes that reach construction in this repo:

| Reaches construction | In an `init` body? | Covered by |
|---|---|---|
| `let x = Foo()` inside an initializer | yes | the discovery walk itself |
| `private let x = Foo()` stored-property default | no | `storedPropertyDeclarations` (`:647`) |
| `init(x: Foo = Foo())` default argument | **no** | one per-type assertion (`:64`) — not the class |
| `Foo.install()` static call that constructs nothing | **no** | a separate file-scoped guard in `ExceptionBreadcrumbTests` |

Factory functions (`Foo.make()`) and protocol-witness construction sit in the same column and have no guard at all today. The generalisation past source scans: **any rule enforced over an enumerated population inherits the enumeration's blind spots**, and the enumeration is usually the part nobody restates when the rule is quoted.

### Prove the guard red

None of the above is discoverable by reading the test. The only reliable check is to **break the thing on purpose and watch the test fail** — revert the fix, delete the wiring line, add the needle you think is covered — then restore. Both new assertions in this arc were verified red that way before being trusted. A guard never observed failing is a guard whose fidelity is unmeasured.

U1 of the dictation-delivery work is the fullest instance so far: `68c67bf` reports six mutations proved red — inverted gate, commented-out gate, hollowed helper, always-false `where` clause, hand-rolled `init` config, mutated budget. (Reported by its author and not re-run here, which is the qualification this file's own rule about a *claimed* probe demands — see [`verify-subagent-test-reports`](./verify-subagent-test-reports-2026-05-18.md).) **Five of those six had survived the guards as originally written**; only the mutated budget was caught by an assertion that already existed. Every one of the other five was found by running the probe, not by reasoning about the guard — which is the argument for the probe *over* the reasoning, not as a supplement to it.

Give the scan **self-checks against silent degradation**, too: `LaunchOrderingTests.swift:32` asserts that discovery still finds `AppState`, `PermissionsViewModel`, `AppearanceController` and (transitively) `LoginItemController` before it asserts anything about violations, and throws on a duplicate file basename rather than last-write-wins. A scan that quietly resolves to zero files passes perfectly.

## Why This Matters

The failure is asymmetric in the worst direction. A behavioural test that stops testing usually goes red (a compile error, a missing symbol). A source scan that stops testing goes **green** — indistinguishable from success, and more dangerous than no test at all, because the team now believes the rule is mechanically enforced and stops reviewing for it by hand.

That belief is the whole reason these tests exist. `DSComponentsHoverTests` was added precisely because three prior fixes in the executor-check family had been convention-only and each was rediscovered in production. Replacing "humans remember" with a guard is only an improvement if the guard's fidelity is actually higher — and the absence-only shape has *lower* fidelity than a human reviewer, who would have noticed that nothing calls `prime()`.

The absence-only trap is not new to this repo, which is the argument for stating it as a convention rather than a one-off. Two prior instances, both already written up in their own domains:

- **Prompt-eval had the identical shape** and it is still open. `test_ax_antiLeak_aboveLineDoesNotPoisonTranscript` asserts an AX-supplied proper noun the speaker did *not* say stays out of the transcript. As [`positive-spelling-ax-fixture-2026-05-18.md`](../documentation-gaps/positive-spelling-ax-fixture-2026-05-18.md) puts it: *"a regression that makes Gemini IGNORE AX context entirely would pass the anti-leak test and ship silently."* Negative assertion, no positive complement, satisfied by the feature being dead.
- **A tautological boundary fixture** — `docs/solutions/conventions/testing-spm-and-git-2026-05-15.md` records a fixture (`beg.example`) that never contained the pattern it claimed to pin, so it passed under both the old and new implementation. Same failure class at the fixture level: the test looked where the bug was not.

The concrete cost here: the shipped artifact would have been a menu-bar app that launches, shows its icon, and does nothing — no hotkey, empty history, permissions permanently `.unknown`. Indistinguishable from a genuinely ungranted install, on a branch whose entire purpose was to fix a crash the maintainer cannot reproduce. (`AppState.prime()` now logs one `.info` line on entry for exactly this reason — `NoType/AppState.swift:376`.)

**The recurrence rate is itself a finding, and it says something about this file.** Four units of one plan — U1, U2, U5 and U6 of `docs/plans/2026-08-09-001-feat-failed-recording-retry-plan.md` — each shipped at least one guard that passed for a reason other than the property it named, and each was caught at review, not at authoring, *with this entry already written and already extended twice in the same plan*. The reason it did not reach the authors is structural: a catalogue of failure shapes is a **review** instrument. Its title selects for "I am writing a source scan," and none of the authors thought they were — one was pinning two enum classifiers, one a numeric constant, one a token accumulator. So the authoring-time habits (mutate the thing and watch it go red; try to delete a drift before guarding it) now live where a test author actually looks, in [`testing-spm-and-git`](./testing-spm-and-git-2026-05-15.md) > Testing, and this entry stays what it is: the place a reviewer looks the shape up once they already suspect one. Adding a fifth failure-shape section for the constant-drift or uniform-fixture cases would have been this same mistake again.

U6 sharpens the conclusion rather than just extending the count. By then the authoring-time habit was documented in the file its author reads, **and the author reported having performed it** — yet a mutant survived, because the fixture handed every element the same value and so could not express the mutation at all. Prescribing the probe is not enough when the fixture cannot answer it, which is why the fixture-distinctness rule sits next to the probe in `testing-spm-and-git`, and why a *claim* that a probe was run is verified by re-running it (see [`verify-subagent-test-reports`](./verify-subagent-test-reports-2026-05-18.md)).

**The 2026-08-11 arc moves the number that matters, and it is not the one you would expect.** U1 of the dictation-delivery plan again shipped guards that were green under the mutations they existed to catch — five of six, by the remediation commit's own account — so the recurrence count keeps rising. What changed is the *lag*: the gaps were found and closed inside the same unit's review pass (`0bb8286` → `68c67bf`, 34 minutes apart) rather than surfacing a unit or a plan later. Be precise about what that does and does not show. The remediation commit is labelled review remediation, so this is **not** evidence that the authoring-time probe fired before the guard shipped; the review dependency is intact. It is evidence that the feedback loop tightened, which is the cheaper of the two wins and the only one the artifacts support. The same arc also produced a failure this catalogue does *not* cover, because its subject is a comment rather than a guard: see [`cited-invariant-must-cover-the-population`](./cited-invariant-must-cover-the-population-2026-08-11.md).

**U3 of that plan adds the limit of the whole instrument, and it is worth stating plainly here rather than leaving implicit.** Its guard was the most thorough in the repo — a swept truth table, four wiring assertions, ordering, occurrence count, comment stripping — and it spent its first two commits defending a freeze that was **in the wrong place**, because the destination was captured at session start and the product's answer was the stop. No amount of fidelity reaches that: a guard proves the code does what its author intended, and every failure shape in this file is about the gap between the assertion and the intent. A guard cannot notice that the intent was scoped to one interaction mode. That gap has its own entry — [`frozen-value-assumes-the-interaction-shape`](./frozen-value-assumes-the-interaction-shape-2026-08-11.md) — and the pairing is the useful thing to carry: when a guard is unusually rigorous, check separately that what it pins is what was wanted.

## When to Apply

- **Writing any new source-scan / convention test.** Walk the four checklist items plus the anchor-and-overload notes, then prove it red.
- **Any refactor that relocates work, or extracts a seam for testability** — init → launch hook, view → controller, sync → async, one module to another, a constant hoisted into a factory a test can call. Ask: *if the destination were deleted, which test goes red?* — and, for an extraction, *does any test fail if the production call site stops calling this?* If the answer is none, the guard is absence-only.
- **Reviewing a diff that adds "and a test pins this."** Check what the test would do if the feature were entirely removed rather than merely misplaced.
- **Writing a guard for an installed hook, a swapped pointer, a redaction rule, or an ordering between two steps.** Apply the hook-guard section: name the worst outcome in that area, then check whether the assertion would be green under it.
- **Adding a sibling classifier, or any consistency guard between two functions over the same type — especially across a module boundary, where neither adjacency nor an exhaustive switch is available.** Name the axis the guard covers, ask what else already covers it (an exhaustive switch, a non-optional type, a constraint), and check whether the axis carrying the real policy — usually an associated value or a numeric range — is covered by anything at all. Then check the sweep's range actually brackets the widening it is meant to catch.
- **Adding a type to a path that a scan enforces a rule over.** Ask how it is constructed, not just where: a default argument, a stored-property default, a factory, or a static entry point all reach the runtime state without appearing in an `init` body. Then check the scan's *discovery* output names it, not just that its violation count is zero.
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
- [`architecture-patterns/partial-recovery-with-markers-2026-05-16.md`](../architecture-patterns/partial-recovery-with-markers-2026-05-16.md) — the recoverable/terminal split that `isTerminal(_:)` encodes, and which `shouldRetain(_:)` now mirrors; the source of the 401/403 carve-out the status sweep guards.
- Commits `a77cf9d` (adds `shouldRetain` beside `isTerminal`) and `97e4a21` (review remediation: the `0...599` status sweep, proved red) — where the compiler-owns-the-case-axis section came from. Unit U1 of `docs/plans/2026-08-09-001-feat-failed-recording-retry-plan.md`. Both SHAs are branch-local to `feat/failed-recording-retry` at time of writing and will be rewritten if that branch squash-merges; the plan path is the stable reference.
- [`runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md`](../runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md) — where `DSComponentsHoverTests` came from; its Prevention section presents the scan as an unqualified win, which this entry qualifies.
- Commits `7f2431f` (U5 implementation — put `RetainedAudioStore` on the launch path through a default argument) and `9d485bb` (review remediation: `NoTypeApp.init()` names it explicitly, plus the discovery assertion, plus the constant-drift test rewrite). Unit U5 of the same plan. Branch-local to `feat/failed-recording-retry` at time of writing; the plan path is the stable reference.
- [`conventions/reconcile-optimistic-mirror-by-union-2026-08-09.md`](./reconcile-optimistic-mirror-by-union-2026-08-09.md) — the other P1 from U5. Not a guard-fidelity problem, but the same underlying move: a check written against one of two views of the same state, where the two are deliberately allowed to disagree.
- Commits `0bb8286` (U1 implementation — hoists the two `URLSession` budgets into named `nonisolated static let`s behind `makeSessionConfiguration()`, adds the R28 connection drop and its source guard) and `68c67bf` (review remediation: pins that `init()` calls the factory, hardens the guard against comments and gate inversion, widens the sweep floor below zero, corrects the flush's invariant citation). Unit U1 of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`. Both SHAs are branch-local to `refactor/structural-gap-tracking` at time of writing and will be rewritten if that branch squash-merges; the plan path is the stable reference.
- [`conventions/cited-invariant-must-cover-the-population-2026-08-11.md`](./cited-invariant-must-cover-the-population-2026-08-11.md) — the fourth learning from that same unit, and the one that does *not* belong here: its subject is a doc-comment's justification rather than a guard, and no mechanical check would help. Same review posture, different artifact.
- [`conventions/frozen-value-assumes-the-interaction-shape-2026-08-11.md`](./frozen-value-assumes-the-interaction-shape-2026-08-11.md) — the companion to U3's amendments above, and this file's outer boundary: the guard that motivated checklist item 6 and the comment-stripping additions was rigorous, green, and pinning a capture at the wrong moment. Read it whenever a guard in this shape looks unusually thorough.
- Commits `95c0a66` (U3 implementation — the destination guard and its first source guard), `1be7246` (review remediation: the wiring assertions, and comment stripping added after a commented-out freeze passed), `43f7c0a` (the product ruling — the freeze crosses into `AppState.swift` and the guard follows it), `f8ee2c2` (the occurrence count, the `#if` assertions, and the block-comment stripper ported from `GeminiClientOfflineShortCircuitTests`) and `7d46a0c` (the sibling cursor-context gate and its independence cases). Unit U3 of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`. All SHAs are branch-local to `refactor/structural-gap-tracking` at time of writing and will be rewritten if that branch squash-merges; the plan path is the stable reference.
- `NoTypeTests/LaunchOrderingTests.swift`, `NoTypeTests/DSComponentsHoverTests.swift` — the two general, repo-wide source-scan guards. There are now five more file-scoped ones, and the inventory is worth keeping current because each is a place these failure shapes can recur: `NoTypeTests/GeminiClientOfflineShortCircuitTests.swift` carries three (short-circuit position, the R28 connection drop, and the budget factory's wiring) plus the comment-stripper and body-extractor fixtures that pin its own parsing, `NoTypeTests/HUDPanelGeometryTests.swift` carries `RaiseSiteScanner`, and `NoTypeTests/RecordingSessionFocusGuardTests.swift` carries the largest cluster yet — the `stop()` wiring of each of the two paste-region gates, the `start()` freeze of the source pid and the complement that `start()` does *not* freeze the destination, the destination freeze in `AppState.finalizeRecording` with its ordering and occurrence assertions, the transcribing HUD's label, and the `HUDPanel` style-mask dependency the gate rests on — plus its own stripper and block-extractor fixtures. It is the file checklist item 6 and the item-5 additions came from. `NoTypeTests/ExceptionBreadcrumbTests.swift` carries another, file-scoped one (`test_breadcrumbSource_schedulesNoMainActorWork_andDoesNotTouchNSApp`) added because `LaunchOrderingTests`' discovery walks constructions (`TypeName(`) and so cannot see a type reached only through a static `install()` call — an instance of checklist item 1 at the discovery layer rather than the needle layer.
- `NoType/UI/CLAUDE.md` "Launch ordering" — the rule these guards pin.
