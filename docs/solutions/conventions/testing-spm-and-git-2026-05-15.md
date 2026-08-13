---
title: Testing, SPM dependency, and Git/PR hygiene conventions
date: 2026-05-15
last_updated: 2026-08-11
category: conventions
module: cross-cutting
problem_type: convention
component: development_workflow
severity: medium
applies_when:
  - Adding a new test file or fixture
  - Proposing a new SPM dependency
  - Writing a commit message or PR description
tags: [testing, spm, dependencies, git, conventional-commits, pr-hygiene, comments]
---

# Testing, SPM dependency, and Git/PR hygiene conventions

## Context

The day-to-day conventions for how code lands in the repo. Less load-bearing than the concurrency or error-model rules, more about keeping the working set sane — what tests are mandatory, what dependencies are acceptable, how a commit gets framed.

## Guidance

### Testing

- **Every non-UI module should have unit tests.** Coverage isn't a hard target, but each public function should have at least one happy-path test and one error-path test.
- **UI uses snapshot tests where they pay off.** We don't aim for full UI test coverage.
- **Hard rule:** any change to `NoType/Context/SecureFieldMasker.swift` must add a new test case to `NoTypeTests/SecureFieldMaskerTests.swift`. Security boundary.
- **Hard rule:** `NoTypeTests/GeminiRequestBuilderTests.swift` must verify the cache-friendly part ordering. If the test changes, the cache-prefix invariant changed — get explicit review.
- **Use synthetic AX trees and synthetic audio buffers for tests.** Don't depend on the live system in unit tests.
- **A boundary / over-match regression fixture must embed the exact pattern flanked by adjacent word-characters, or it silently tests nothing.** PR-DICT found a tautological test: the fixture `beg.example` never contains the substring `e.g.`, so it passed under both the old `\b` idiom and the new Unicode look-around — pinning nothing. `code.g.example` (embeds `e.g.` with a word-char on each side) actually exercises the boundary. When a test guards a "must NOT over-match across a boundary" rule, verify the target string genuinely contains the pattern at a boundary the old code would have mishandled. This is the fixture-level case of a broader class — see [source-scan guard fidelity](./source-scan-guard-fidelity-2026-07-25.md) for tests that pin a convention by scanning source text.
- **Before you commit a test, break the thing it pins and watch it go red.** Revert the fix, delete the wiring line, change the constant — then restore. A test that has never been observed failing has *unmeasured* fidelity, and the ways it can be green-for-the-wrong-reason are not visible by reading it: a comparison that degenerates to `nil == nil`, a fixture caught by a broader rule than the one named, an assertion over a discovery set that quietly narrowed. Four consecutive units of one plan (`docs/plans/2026-08-09-001-feat-failed-recording-retry-plan.md`, U1 / U2 / U5 / U6) each shipped one of these; all four were caught at review. The catalogue of shapes lives in [source-scan guard fidelity](./source-scan-guard-fidelity-2026-07-25.md) — but it is a *review* instrument, so the habit belongs here. **The probe is necessary, not sufficient**, and U6 is why: it was performed and reported, and a mutant still survived — because the fixture could not express it (next bullet).
- **An accumulation, ordering, or merge bug is invisible to any fixture whose elements are equal.** Give every element a distinct, identifiable value, so the assertion pins the *operation* and not merely the arity. U6's retry loop accumulates per-chunk spend as `tokens = tokens + result.tokens`; mutating it to `tokens = result.tokens` — silent under-billing — left all 38 new tests green, because the fixture helper handed **one shared `TokenUsage` to every chunk** (`NoTypeTests/AppStateRetryTests.swift:633`, `func sender(_ answers: [String], tokens: TokenUsage = .zero)`). With equal values, summing and overwriting produce the same result; with the `.zero` default they produce the same result even for a single chunk, because zero is the identity element of the operation under test. The remediation gives each chunk `input: 100 * (chunk.idx + 1)` and says so in the fixture (`:299`). The same shape has a sibling in the same commit: `HistoryStore.update`'s replace path had no coverage because every fixture seeded rows through the mirror-only path, leaving the store empty so `update` only ever took its no-op branch. Generalised — **a fixture must be able to express the failure**; a uniform value and an unreachable branch are two ways it cannot, and no amount of diligent probing recovers either.
  **The same accumulation is still unpinned in the older code U6 was mirroring.** `sessionTokens = sessionTokens + result.tokens` appears at `NoType/Recording/RecordingSession.swift:1311` (`processBatch`) and `:1440` (`splitRetry`), feeding `StatsStore` through `SessionSummary.tokens` — and no test drives either site, so the identical overwrite mutation would go unnoticed there today. `RecordingSessionPartialRecoveryTests.test_sessionSummary_carriesTokens_verbatim` names the exact risk in its comment ("anything that mutates this value silently would skew per-day token totals") and then pins only the struct's storage, not the accumulation that fills it. Pinning a value's *round-trip* is not pinning the *arithmetic* that produced it.
- **A fixture can stop being able to express the failure *later*, without anyone touching the test.** The two cases above are fixtures that never could; this one is decay, and the trigger is a change that is itself correct. R30 of the dictation-delivery plan requires the withheld-paste notice's Copy to place exactly the string the history row shows, and its test ran on a session that recovered nothing — stored `""`, rendered as synthesised markers — *precisely because* `entry.text` and the shown string diverge there, so a handler written against the wrong field failed. A later product ruling (the notice offers Copy iff the row does) made that fixture the one row offering no Copy at all, and the two facts collapsed into one: `HistoryRowView.displayText(for:)` synthesises only when the stored text is empty, and empty text is not copyable. The test still passes and no longer discriminates — a handler reading `entry.text` would pass it today. **The tell is a legitimate product change that narrows the reachable state space, not an edit to the test**, which is why nothing goes red and no diff points at it. Two moves when you find one, and the second is what keeps the coverage: (1) say so in the test — `NoTypeTests/AppStateFocusNoticeTests.swift:424` now opens by recording that it can no longer prove the accessor, because a green test that quietly proves less than its name is worse than a deleted one; (2) **pin the implication that made the fixture unreachable** — `test_everyEntryWhoseShownTextDiverges_offersNoCopy` (`:460`) asserts on both divergent shapes that they offer no Copy, which is simultaneously the argument that the weakening is harmless and a tripwire that fires if a second synthesising branch ever restores the divergence. It also asserts its own fixtures still diverge, so it degrades loudly rather than silently — the self-check rule from [source-scan guard fidelity](./source-scan-guard-fidelity-2026-07-25.md).

  **Postscript (U6 of the same plan): the decay reversed, and move (1) is why anyone noticed.** Once a row stored a response *sequence* and its shown string became `HistoryText.rendered` — the sequence assembled, with the user's current pairs applied — `entry.text` became a legacy mirror that is neither reassembled nor re-substituted, so the two diverge on every row carrying a gap or touched by a pair. The accessor is load-bearing again and `test_copyAction_placesExactlyWhatTheRowShows` runs on a real divergent fixture once more; `test_everyEntryWhoseShownTextDiverges_offersNoCopy` retired into `test_everyRowTheNoticeRefusesToCopy_isOneTheRowRefusesToo`, which pins the surviving half (both surfaces answer copy-ability from the same predicate). The lesson is not "the weakening was harmless after all" — it was real for two units — but that **the recorded admission is what made the restoration a deliberate step rather than an accident.** A test whose name still promised more than it proved, with no note saying so, would have been rewritten by whoever touched it next without either of them knowing the coverage had ever been lost.
- **Before writing a drift guard between two values, try to delete the drift instead.** `AppState.historyMirrorCap` and `HistoryStore.cap` were two hand-copied literals plus `XCTAssertEqual(AppState.historyMirrorCap, 10)` — an assertion that could only fail in the harmless direction, and was blind to the one that mattered (`HistoryStore.cap` moving under a stale mirror constant). Making `HistoryStore.cap` internal and deriving `historyMirrorCap = HistoryStore.cap` removed the drift outright and freed the test to aim at what can still break: both trim *implementations*, driven past the cap, survivors compared. A guard is what you write when the invariant cannot be made structural — not the first move.
- **Integration tests against the real Gemini API live behind env var `NOTYPE_INTEGRATION=1`**; they are not part of the default `NoTypeTests` run.

### SPM dependencies

- **Justify new dependencies in the PR description.**
- **Current SPM dependencies: Sparkle 2** (`from: 2.6.0`) for auto-updates — see `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md`. Otherwise the app builds against system frameworks only (`AVFoundation`, `CoreML`, `CoreAudio`, `AppKit`, `SwiftUI`, `Security`).
- **Planned acceptable:** `onnxruntime-swift` for Silero fallback if CoreML conversion fidelity becomes a problem — see `solutions/tooling-decisions/silero-vad-coreml-2026-05-15.md`.
- **Avoid:** HTTP libraries (we use `URLSession`), JSON libraries (`Codable` is enough), DI containers, reactive frameworks.

### Comments

- **Comments explain *why*, not *what*.** The code says what.
- **A comment that asserts behaviour is a claim, and a false one is worse than no comment** — downstream readers believe it and stop defending, and nothing goes red when it drifts. Verify a behavioural claim against the code before shipping it, and re-verify when the code it describes moves. U6 shipped two, both caught at review and corrected without changing behaviour: one asserted that `handleHotkeyPress` reads `retryingEntryID` (it does not — a recording session can start beside an in-flight retry, so the exclusion is one-directional), and one asserted that R16's stop-at-first-failure bounds the retry wait in general (it bounds only a *failing* run; a run whose chunks all answer slowly pays every chunk's latency). This keeps recurring because it has only ever been recorded as somebody else's supporting example — a `prime()` comment saying "called once at init" that "would have licensed removing the call as redundant" ([observation-loop-swallows-initial-state](../design-patterns/observation-loop-swallows-initial-state-2026-07-25.md)), a test's class doc-comment claiming one call level while the code walked transitively ([source-scan guard fidelity](./source-scan-guard-fidelity-2026-07-25.md), "Documentation that licenses the blind spot back in"), and a hand-off note asserting an invariant the next unit branched on ([guard-scope-must-match-invariant-scope](./guard-scope-must-match-invariant-scope-2026-08-09.md)). The hand-off case aims at the *consumer* — re-derive before building on it; this one aims at the *author and reviewer*, and unlike a note, a shipped comment never expires.
- When working around a known SDK bug, link the Apple Forums thread or rdar.
- **TODOs should include an owner or a tracking issue:** `// TODO(@user): replace with X once Apple fixes FB12345`. Better: promote it to a `docs/solutions/documentation-gaps/` entry.

### Git / PR hygiene

- **Conventional Commits** (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`).
- **One logical change per PR.** Refactors that touch many files are fine but should be a single coherent move.
- **PR description includes:** what changed, why, and which `CLAUDE.md` (or `docs/solutions/` entry) you updated — or why none was needed.

## Why This Matters

- **Hard-rule tests** mark the two security / correctness boundaries that get the most scrutiny — `SecureFieldMasker` (PII redaction) and the Gemini request shape (cache-prefix invariant). Forgetting to add a test there is the kind of regression that breaks for users we'll never see.
- **SPM allow-list** keeps the dependency graph small enough to audit. Each new dep is supply-chain surface; saying "no by default" is cheaper than retrofitting risk later.
- **Comments explain why** because code rots faster than rationale. Six months in, the `git blame` answer to "what does this do?" is the file itself; the answer to "why is it this shape?" needs a comment or a `solutions/` doc.
- **Conventional Commits + one-PR-one-change** make `git log --oneline` an actual changelog and let `git revert` work without surprises.

## When to Apply

- Default for every PR.
- Reviewer enforces the test hard rules in the security / Gemini paths.

## Examples

**Conventional commit message** (style this repo uses):

```
docs: migrate ADR-002..009 to docs/solutions/ (batch 1 of 2)
```

**TODO promoted to a solutions/ entry** (instead of leaving the comment):

```swift
// Was: // TODO: switch to in-memory AAC encoding (slow temp-file write)
// Now: see solutions/documentation-gaps/in-memory-aac-encoding-2026-05-15.md
```

## Related

- [source-scan guard fidelity](./source-scan-guard-fidelity-2026-07-25.md) — the catalogue of ways a guard is green for the wrong reason, and why the authoring-time habits above live here rather than there.
- [prove absence by indistinguishability](./prove-absence-by-indistinguishability-2026-08-11.md) — what to reach for when the probe above shows a needle list cannot close a "must not appear" rule, because the forbidden set is any function of an unbounded input.
- `docs/build.md` — release workflow that depends on these conventions.
- `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md` — the only current SPM dep.
- `docs/conventions.md` — legacy index, redirects here.
