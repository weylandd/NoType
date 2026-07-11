---
title: Gemini response finishReason is decoded but never inspected
date: 2026-07-10
category: documentation-gaps
module: Gemini
problem_type: documentation_gap
component: tooling
severity: low
---

# Gemini response finishReason is decoded but never inspected

## Context

The Gemini REST response's `Candidate` type (`NoType/Gemini/Models.swift:132`)
carries an optional `finishReason: String?`. The client decodes it but
never reads it. A response that Gemini truncated (`finishReason ==
"MAX_TOKENS"`) or stopped for a content reason (`"SAFETY"`,
`"RECITATION"`) arrives with whatever partial `text` it has and is
treated as a normal success — the transcript is stitched and pasted as
though complete.

Two existing mechanisms cover most of the risk:

- `HallucinationLengthGate` (`NoType/Recording/`) drops responses whose
  length is disproportionate to the audio duration — it catches over-long
  junk, but not a *short* truncation.
- Prompt-level blocks surface via `promptFeedback.blockReason` →
  `GeminiClient.GeminiError.blocked` (terminal).

The gap is the middle case: a silently truncated transcript
(`finishReason == "MAX_TOKENS"` with partial text) passes through as if
it were the whole utterance. Flagged during the 2026-07-10 code-review
remediation (R21, PLAUSIBLE-low) — no repro, so deferred to a note rather
than a code change.

## Guidance

Leave as-is unless a repro appears (a user reporting mid-word cutoffs
that aren't network failures). When addressed:

- Inspect `candidate.finishReason` in the response parser.
- Route a `MAX_TOKENS`-truncated response into the existing
  partial-recovery marker path so the user sees a visible `[…]` gap
  rather than a silently cut sentence.
- Keep truncation **out** of `RecordingSession.isTerminal(_:)` — a cut
  response is recoverable, not an auth/blocked failure.
- At minimum, log a non-`STOP` finish reason so the condition is
  diagnosable in production.

Do not touch `GeminiClient.swift` speculatively — the cache-prefix and
request-shape contract there is load-bearing (`GeminiRequestBuilderTests`).

## Why This Matters

Transcription requests map short audio to short text, so `MAX_TOKENS`
truncation is rare and `SAFETY` blocks already surface via
`blockReason`. The exposure is narrow — but when it does happen, a silent
cut is a confusing user experience compared to a visible gap marker.

## When to Apply

- A repro of truncated transcripts appears.
- The Gemini response parser is being touched for another reason.

## Examples

```swift
// Models.swift:130 — finishReason is decoded, then ignored:
struct Candidate: Decodable {
    let content: Content?
    let finishReason: String?   // "STOP" | "MAX_TOKENS" | "SAFETY" | ...
}
```

## Related

- `NoType/Gemini/Models.swift` (`Candidate.finishReason`)
- `NoType/Gemini/GeminiClient.swift` (response parsing — do not touch prompt shape)
- `NoType/Recording/RecordingSession.swift` (`isTerminal`, partial-recovery markers)
- `docs/solutions/architecture-patterns/partial-recovery-with-markers-2026-05-16.md`
- Source plan: `docs/plans/2026-07-10-001-fix-code-review-remediation-plan.md` (R21 / U22)
