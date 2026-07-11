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

**Done — implemented.** Closed on branch
`remediation/pr-f-techdebt-followups` (PR-F tech-debt follow-ups). The
change is **response-parsing only** — it does not touch the request shape
or cache prefix, so `GeminiRequestBuilderTests` is untouched.

What shipped:

- A pure `GeminiClient.finishReasonError(_ finishReason: String?) ->
  GeminiError?` maps the candidate's `finishReason`:
  - `STOP` / absent / blank / unrecognised (`OTHER`, `LANGUAGE`, …) →
    `nil` — keep the text (we don't reject a usable transcript over a
    reason we don't recognise).
  - `MAX_TOKENS` → a new `GeminiError.truncated` case.
  - `SAFETY` / `RECITATION` / `PROHIBITED_CONTENT` / `BLOCKLIST` / `SPII`
    / `IMAGE_SAFETY` → `.blocked(reason)` — same terminal treatment as a
    prompt-level `promptFeedback.blockReason`, surfacing the reason
    instead of silently pasting the empty/partial candidate.
- `sendRequest` inspects `candidates.first.finishReason` right after the
  prompt-level block check: it throws the mapped error, and logs any
  other non-`STOP` reason (`log.notice`) while keeping the text.
- `GeminiError.truncated` is classified **recoverable** in
  `RecordingSession.isTerminal(_:)` (grouped with `.empty` / `.decoding`)
  → a `MAX_TOKENS` chunk becomes a `[…]` gap marker instead of a
  silently-cut sentence, exactly as this note asked. It is **not** in the
  terminal set (auth / blocked / cancel). `retryDecision` gives it no
  HTTP-level retry (re-issuing identical audio truncates the same way);
  recovery is the gap marker one layer up.
- `AppState.payloadForSessionFailure`, `GeminiKeyRow.errorMessage`, and
  `OnboardingAPIKeyStep` gained a `.truncated` arm (the last two only for
  exhaustiveness — validation is a GET and never truncates).

The mapping is pinned by `NoTypeTests/GeminiFinishReasonTests.swift`
(`STOP`/nil/blank/unknown → keep text; `MAX_TOKENS` → `.truncated`;
`SAFETY`/`RECITATION`/… → `.blocked` carrying the trimmed reason;
case-insensitive + whitespace-trimmed).

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
- `NoTypeTests/GeminiFinishReasonTests.swift` (the mapping test added on close)
- `docs/solutions/architecture-patterns/partial-recovery-with-markers-2026-05-16.md`
- Source plan: `docs/plans/2026-07-10-001-fix-code-review-remediation-plan.md` (R21 / U22)
- **Closed by:** `feat(gemini): inspect finishReason to surface blocked/truncated responses (tech-debt)` on branch `remediation/pr-f-techdebt-followups`.
