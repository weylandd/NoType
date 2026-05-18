---
title: Verify subagent test reports by running the full suite yourself
date: 2026-05-18
category: conventions
module: cross-cutting
problem_type: convention
component: development_workflow
severity: medium
applies_when:
  - Dispatching a subagent (e.g., review-fixer, ce-work) that applies fixes and reports build/test status
  - About to commit + push code changes the agent (or a subagent) produced
  - The subagent's task included running tests but only named the affected suites
tags: [subagent, orchestration, testing, xcodebuild, verification, pre-push]
---

# Verify subagent test reports by running the full suite yourself

## Context

Multi-agent flows (e.g., `/ce-code-review` walk-through that ends in a `review-fixer` subagent, or `/ce-work` dispatching unit subagents) routinely produce summary reports like:

> Build status: `xcodebuild ... build` → **BUILD SUCCEEDED**, no warnings.
> Test status: `NoTypeTests/AXNoiseFilterTests` → **59/59 passed**, `NoTypeTests/AccessibilityTreeTests` → **25/25 passed**, `NoTypeTests/InsertionTargetTests` → **21/21 passed**.

The subagent typically ran **only the targeted test suites it touched** — not the full `xcodebuild test`. The orchestrator that trusts this report verbatim is taking on a hidden assumption: *that no other suite in the project regressed*.

This burns when:

1. The subagent's fix touches a shared module (e.g., `NoType/Context/` is consumed by `Recording/`, `Gemini/`, `Injection/`).
2. The subagent legitimately couldn't run the full suite (sandbox restrictions, time budget, didn't think to).
3. The subagent over-summarised and conflated "targeted suites green" with "full project green."

In all three cases, the orchestrator emitting "✓ tests passed" without independent verification has shipped a probable untruth to the user.

## Guidance

**Before any commit + push that includes work produced by a subagent, the orchestrator runs the full test suite itself:**

```bash
xcodebuild -project NoType.xcodeproj -scheme NoType test -destination 'platform=macOS'
```

Two outcomes:

- **All pass (or only known pre-existing failures persist):** proceed to commit + push.
- **New failures vs the pre-PR baseline:** stop. The subagent's report was incomplete or wrong. Investigate before push.

For NoType specifically, the pre-PR baseline as of 2026-05-18 is **552 unit-test cases passing + 2 known live-API `PromptEvalTests` failures** (`test_silenceOnly_full` silence-hallucination + `test_longMonologueEN_full` number-normalisation — both documented in `docs/solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md` Tier 4). The 10-assertion summary line from `xcodebuild` collapses into those two failed test cases. Re-baseline whenever the prompt audit ships a fix.

The orchestrator must not rely on the subagent's word for "full suite green." If the subagent's report names specific suites, treat that as a hint about what changed — not as the definition of "tested."

## Why This Matters

The empirical incident that motivated this entry: PR #47's review-fixer applied 13 code-review fixes and reported "`AXNoiseFilterTests` 59/59, `AccessibilityTreeTests` 25/25, `InsertionTargetTests` 21/21." I trusted it and pushed. The user asked "ты уверен, что тесты прошли?" — I ran full `xcodebuild test` and saw `10 failures`. Two test cases, both pre-existing live-API failures, zero regressions from the fix pass — but I learned that *after* pushing, not before. The right answer to "уверен?" is "yes, I ran the full suite myself," not "the subagent said so."

Generalised: any reporting boundary where a subagent summarises a partial action as a complete one is a place where the orchestrator owes the user independent verification. Subagents are useful for parallel context isolation and bounded work; they are not authoritative on what they didn't actually do. "Targeted suites passed" is a *true* fact about what the subagent ran; "the project still passes tests" is a *different* fact that requires running the project's full test suite.

A pushed commit that turns out to have regressed a test on `main` is harder to fix than a 60-second `xcodebuild test` run before push. The asymmetry favours always running.

## When to Apply

- **Always** before a commit + push that includes subagent-produced Swift source changes (production or test files).
- **Always** when the work touched a shared module — `Context/` (security-adjacent), `Gemini/` (prompt-contract pins), `Recording/` (audio pipeline), `Injection/` (cross-app paste).
- **Always** when the user asks "are the tests passing?" — answer with output you just ran, not output a subagent claimed.
- **Skip** for pure documentation changes (`docs/**`, `*.md`, `CHANGELOG.md`) that don't touch Swift source.
- **Skip** for project.yml-only changes that don't affect compilation (`xcodegen generate` is enough sanity).

The discriminator is whether the change could plausibly affect test outcomes elsewhere in the project. Markdown and JSON-fixture-only changes can't; anything that compiles into the test binary can.

## Examples

**Wrong — trusting the subagent's targeted report:**

```
Subagent return:
  Build: BUILD SUCCEEDED
  Tests: AXNoiseFilterTests 59/59, AccessibilityTreeTests 25/25, InsertionTargetTests 21/21

Orchestrator: "✓ Build clean, 105/105 tests pass. Pushing."
git push  # might be pushing regressions in untouched suites
```

**Right — orchestrator re-verifies:**

```
Subagent return:
  Build: BUILD SUCCEEDED
  Tests: AXNoiseFilterTests 59/59, AccessibilityTreeTests 25/25, InsertionTargetTests 21/21

Orchestrator: xcodebuild ... test
  Output: Executed 554 tests, with 2 failures (0 unexpected)
  Failures: test_silenceOnly_full (pre-existing, Tier 4)
            test_longMonologueEN_full (pre-existing, Tier 4)

Orchestrator: "✓ 552/552 unit pass, 2 known live-API fails unchanged. Pushing."
git push
```

The cost is one `xcodebuild test` run (~60s on this project). The benefit is that the orchestrator's "tests pass" claim is a thing the orchestrator actually observed.

## Related

- `docs/solutions/conventions/testing-spm-and-git-2026-05-15.md` — the existing testing convention (unit-test expectations, SPM allow-list, Conventional Commits); this convention complements it for the orchestrator-subagent boundary.
- `docs/solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md` Tier 4 — defines the 2 known live-API `PromptEvalTests` failures that make up the current baseline.
- `docs/build.md` "Hard rules" — the build-then-cleanup recipe; this convention adds the test-then-verify step before push.
- Project memory `feedback-test-ui-before-push.md` (Claude Code) — sibling principle for SwiftUI visual changes: `BUILD SUCCEEDED` ≠ layout correct; the same shape extends here to `subagent reported tests passed` ≠ full suite passed.
