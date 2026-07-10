---
title: Testing, SPM dependency, and Git/PR hygiene conventions
date: 2026-05-15
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
- **A boundary / over-match regression fixture must embed the exact pattern flanked by adjacent word-characters, or it silently tests nothing.** PR-DICT found a tautological test: the fixture `beg.example` never contains the substring `e.g.`, so it passed under both the old `\b` idiom and the new Unicode look-around — pinning nothing. `code.g.example` (embeds `e.g.` with a word-char on each side) actually exercises the boundary. When a test guards a "must NOT over-match across a boundary" rule, verify the target string genuinely contains the pattern at a boundary the old code would have mishandled.
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

- `docs/build.md` — release workflow that depends on these conventions.
- `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md` — the only current SPM dep.
- `docs/conventions.md` — legacy index, redirects here.
