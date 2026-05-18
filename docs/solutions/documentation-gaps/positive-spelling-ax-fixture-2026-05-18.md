---
title: Positive-spelling AX fixture for prompt-eval
date: 2026-05-18
category: documentation-gaps
module: Context
problem_type: documentation_gap
component: prompt_eval_fixtures
severity: small
status: open
applies_when:
  - Validating that AX-supplied proper-noun context improves spelling
tags: [prompt-eval, ax, fixture, positive-spelling, audio-recording]
---

# Positive-spelling AX fixture for prompt-eval

## Context

The anti-leak test (`test_ax_antiLeak_aboveLineDoesNotPoisonTranscript`) shipped in PR #47 covers the negative case: an AX-supplied proper noun that the speaker does NOT say must not appear in the transcript. The positive complement — an AX-supplied proper noun that the speaker DOES say (phonetically) gets rendered in its canonical spelling rather than as a phonetic transliteration — requires a recorded audio fixture.

The scaffolded `test_ax_properNoun_positiveSpelling` was removed from `NoTypeTests/PromptEvalTests.swift` in PR #47. It was wrapped in an `XCTSkipUnless(audioFileExists(for: fx), …)` that would skip forever until someone recorded the audio. Permanently-skipping tests are not safety nets — they're checked-in TODO comments dressed up as tests, and they accumulate quietly. The compound-engineering convention is to track the gap here, in `docs/solutions/documentation-gaps/`, where it surfaces alongside other tech debt and gets prioritized against everything else.

## Guidance

To restore the positive-spelling defense:

1. **Record the audio fixture.** Speak a homophone-prone fabricated proper noun clearly (e.g., "Let me check BoominfoCO" — the same token the anti-leak test uses). Save as `NoTypeTests/Fixtures/Audio/ax_proper_noun.m4a` (~3 s, 16 kHz mono per the existing fixture format — see `NoTypeTests/Fixtures/README.md`).
2. **Add a fixture entry to `NoTypeTests/Fixtures/prompt_eval_fixtures.json`** with required tokens in `mustContain` (e.g., `BoominfoCO`) and likely phonetic mis-renderings in `mustNotContain` (e.g., `Boomy`, `BoomInfo`, `Boom Info`).
3. **Re-add the test from PR #47's git history.** The scaffolded function lived as `test_ax_properNoun_positiveSpelling` next to the anti-leak test; restore it without the `XCTSkipUnless` guard.

The `PromptEvalHarness.contextWithAX(properNoun:)` helper and the fails-OPEN guard added to the anti-leak test in PR #47 are the supporting infrastructure — the recorded audio is the only missing piece.

## Why This Matters

First-time-dictation disambiguation is the design goal that R6 stem preservation defends — when a user dictates a proper noun they've never said before, the canonical spelling on screen (via AX) should bias the transcription. We currently have a passive defense (anti-leak: "context tokens don't appear without audio"); the positive defense ("audio + AX agreement renders the AX spelling") remains unverifiable in CI.

Without the positive fixture, a regression that makes Gemini IGNORE AX context entirely would pass the anti-leak test and ship silently. The harm doesn't materialise until users notice their proper nouns transliterate wrong despite being on screen — weeks of user reports before the cause surfaces.

## When to Apply

Record the fixture before:

- The next prompt-section audit cycle (the audit covers section #9 `# Using on-screen context` — currently only one behavioural test, the anti-leak negative).
- Any change to `AXNoiseFilter` that touches `formattedForPrompt` rendering or the cache-prefix shape of the AX content block.
- Any change to the system prompt's "On-screen context" section.

## Examples

For the test shape, see the surviving anti-leak test:

```swift
// NoTypeTests/PromptEvalTests.swift
func test_ax_antiLeak_aboveLineDoesNotPoisonTranscript() async throws {
    try PromptEvalHarness.skipIfMissingKey()
    let leakToken = "BoominfoCO"
    let fx = try PromptEvalHarness.fixture("multi_sentence_en", in: fixtures)
    let context = PromptEvalHarness.contextWithAX(properNoun: leakToken)
    let res = try await PromptEvalHarness.transcribe(...)
    XCTAssertFalse(res.transcript.isEmpty, ...)  // fails-OPEN guard
    XCTAssertFalse(res.transcript.contains(leakToken), ...)
}
```

The positive variant should reuse `PromptEvalHarness.contextWithAX(properNoun:)` with the new audio fixture and assert `XCTAssertTrue(res.transcript.contains("BoominfoCO"))`.

For the removed scaffolding (helper signatures, JSON Fixture shape), see git history of PR #47.

## Related

- `docs/solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md` — section #9 `# Using on-screen context` flagged as "Not measurable" pre-PR #47; this fixture is the second behavioural test for the section.
- `docs/plans/2026-05-17-002-refactor-ax-tree-noise-filtering-plan.md` — U6 landed the first AX behavioural test (anti-leak); this is its positive sibling.
- `NoType/Context/CLAUDE.md` "Noise filtering" — R6 stem preservation is the noise-filter feature this fixture defends.
