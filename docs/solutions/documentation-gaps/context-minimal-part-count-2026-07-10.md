---
title: ContextSnapshot.minimal drops instruction/dictionary parts on a fast utterance
date: 2026-07-10
category: documentation-gaps
module: Recording
problem_type: documentation_gap
component: tooling
severity: low
---

# ContextSnapshot.minimal drops instruction/dictionary parts on a fast utterance

## Context

On a quick-release final batch where the detached context task hasn't
produced a snapshot yet, `RecordingSession.snapshotForChunk(allowMinimalFallback:)`
falls back to `ContextSnapshot.minimal(activeApp:userLanguages:)`
(`NoType/Context/ContextSnapshot.swift:595`). `minimal(...)` carries an
empty AX tree, an empty insertion target, empty `userInstruction`, and
`nil` `categoryInstruction` — so the Gemini cache-prefix `User instruction:`
and `Category instruction:` sections are omitted for that request, and the
`User dictionary:` section renders empty.

The **lite** path (`buildLiteSnapshot`) already threads
`instructionsFrozen` + `dictionaryFrozen`, so single-chunk short sessions
keep their instructions. The gap is only the **non-lite** minimal
fallback: a short-but-not-lite final batch that beat the context task
ships without the user's per-app instructions and personal dictionary
that a full snapshot would carry.

Flagged during the 2026-07-10 code-review remediation (R21 / OQ4,
PLAUSIBLE-low). Deferred to a note — no repro, low impact.

## Guidance

Leave as-is. If it ever matters, thread `instructionsFrozen` /
`dictionaryFrozen` into `ContextSnapshot.minimal` (mirroring what
`buildLiteSnapshot` already does) so the minimal fallback also carries
the user/category instructions and dictionary. That would keep the
cache-prefix part count identical to a full snapshot and apply the user's
instructions even on the quick-release fallback.

## Why This Matters

The minimal fallback only fires on a quick release where the context task
lost the race — a narrow window on short utterances, exactly the case
where on-screen context rarely helps transcription anyway (the same
rationale that justifies the lite path). The cost is: that one request
transcribes without the user's per-app instruction/dictionary bias, and
pays a first-request cache miss it would pay regardless. Both are minor.

## When to Apply

- A user reports that their per-app instruction or dictionary bias is
  inconsistently applied on very short dictations.
- `ContextSnapshot.minimal` or the quick-release fallback path is being
  reworked anyway.

## Examples

```swift
// ContextSnapshot.swift:595 — minimal() takes no instructions/dictionary:
static func minimal(activeApp: AppInfo, userLanguages: [String] = []) -> ContextSnapshot

// buildLiteSnapshot (RecordingSession) already threads them — the
// non-lite minimal fallback does not.
```

## Related

- `NoType/Context/ContextSnapshot.swift` (`minimal(activeApp:userLanguages:)`)
- `NoType/Recording/RecordingSession.swift` (`snapshotForChunk`, `buildLiteSnapshot`)
- `NoType/Gemini/CLAUDE.md` (cache-prefix shape — `User instruction:` / `Category instruction:` omission rules)
- Source plan: `docs/plans/2026-07-10-001-fix-code-review-remediation-plan.md` (R21 / U22, OQ4)
