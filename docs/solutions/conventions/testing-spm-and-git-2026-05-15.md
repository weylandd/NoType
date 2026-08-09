---
title: Testing, SPM dependency, and Git/PR hygiene conventions
date: 2026-05-15
last_updated: 2026-08-09
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
- **Before you commit a test, break the thing it pins and watch it go red.** Revert the fix, delete the wiring line, change the constant — then restore. A test that has never been observed failing has *unmeasured* fidelity, and the ways it can be green-for-the-wrong-reason are not visible by reading it: a comparison that degenerates to `nil == nil`, a fixture caught by a broader rule than the one named, an assertion over a discovery set that quietly narrowed. Three consecutive units of one plan (`docs/plans/2026-08-09-001-feat-failed-recording-retry-plan.md`, U1 / U2 / U5) each shipped one of these; all three were caught at review, and the mutation probe is the step that would have caught them a stage earlier. The catalogue of shapes lives in [source-scan guard fidelity](./source-scan-guard-fidelity-2026-07-25.md) — but it is a *review* instrument, so the habit belongs here.
- **Before writing a drift guard between two values, try to delete the drift instead.** `AppState.historyMirrorCap` and `HistoryStore.cap` were two hand-copied literals plus `XCTAssertEqual(AppState.historyMirrorCap, 10)` — an assertion that could only fail in the harmless direction, and was blind to the one that mattered (`HistoryStore.cap` moving under a stale mirror constant). Making `HistoryStore.cap` internal and deriving `historyMirrorCap = HistoryStore.cap` removed the drift outright and freed the test to aim at what can still break: both trim *implementations*, driven past the cap, survivors compared. A guard is what you write when the invariant cannot be made structural — not the first move.
- **Integration tests against the real Gemini API live behind env var `NOTYPE_INTEGRATION=1`**; they are not part of the default `NoTypeTests` run.

### SPM dependencies

- **Justify new dependencies in the PR description.**
- **Current SPM dependencies: Sparkle 2** (`from: 2.6.0`) for auto-updates — see `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md`. Otherwise the app builds against system frameworks only (`AVFoundation`, `CoreML`, `CoreAudio`, `AppKit`, `SwiftUI`, `Security`).
- **Planned acceptable:** `onnxruntime-swift` for Silero fallback if CoreML conversion fidelity becomes a problem — see `solutions/tooling-decisions/silero-vad-coreml-2026-05-15.md`.
- **Avoid:** HTTP libraries (we use `URLSession`), JSON libraries (`Codable` is enough), DI containers, reactive frameworks.

### Comments

- **Comments explain *why*, not *what*.** The code says what.
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
- `docs/build.md` — release workflow that depends on these conventions.
- `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md` — the only current SPM dep.
- `docs/conventions.md` — legacy index, redirects here.
