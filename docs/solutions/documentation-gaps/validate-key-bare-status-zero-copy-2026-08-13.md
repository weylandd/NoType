---
title: A network failure on the API-key screens still reads "Gemini error 0."
date: 2026-08-13
category: documentation-gaps
module: Gemini
problem_type: documentation_gap
component: tooling
severity: low
---

# A network failure on the API-key screens still reads "Gemini error 0."

## Context

`GeminiClient.validateKey(_:)` guards its response with

```swift
guard let http = resp as? HTTPURLResponse else {
    throw GeminiError.http(status: 0, body: "no HTTPURLResponse")
}
```

a **bare** status-0 error — no `URLError code=` prefix. `GeminiError`'s
`errorDescription` has a status-0 arm, but it is deliberately gated on that
prefix, so a bare one falls into the generic branch and renders as literally
**"Gemini error 0."** That string reaches two user-facing surfaces:
`GeminiKeyRow.errorMessage` (Settings → API & Usage) and
`OnboardingAPIKeyStep`. A user whose Wi-Fi is off while pasting their key is
told their key produced error zero.

**The transcription path's equivalent was fixed and this one deliberately was
not.** All three status-0 producers on that path now go through `wrapURLError`,
so the body always carries the prefix and the error is described by the OS's
own sentence (R17 / KTD12 of the dictation-delivery-reliability plan). The
maintainer, as product owner, ruled that this surface is a **separate copy
decision on a different screen** and filed it rather than folding it in:
onboarding's failure copy has its own tone, its own retry affordance, and its
own audience (someone who has not yet got the app working at all), and
inheriting the transcription HUD's five-way network vocabulary is a choice, not
a refactor.

The prefix gate is not an oversight either. It is what makes the status-0 arm
*provably* log-only on the transcription path — pinned by
`GeminiClientOfflineShortCircuitTests`, which asserts a bare status-0 still
renders "Gemini error 0." precisely so the gate cannot be widened by accident.
Widening it to `s == 0` alone would silently change what that suite proves.

## Guidance

Leave as-is until the copy decision is made. When it is, the fix has two
plausible shapes and they are not equivalent:

- **Wrap at the seam**, like the transcription path: give `validateKey`'s guard
  the same `wrapURLError` treatment, and it inherits the existing network
  sentences for free. Cheapest, and it makes the surfaces consistent — but it
  imports the transcription vocabulary onto onboarding wholesale, which is the
  decision that was deferred.
- **Own the copy at the screen**: let `GeminiKeyRow` / `OnboardingAPIKeyStep`
  recognise the no-response case and say something written for that context
  ("Couldn't reach Google — check your connection and try again"), leaving the
  error type alone.

Either way, do **not** widen `errorDescription`'s status-0 arm to fire on
`s == 0` without the prefix. That is the one move that quietly breaks the
guarantee the existing tests exist to hold.

## Why This Matters

It is the first thing a new user sees when their network is down, on the one
screen where they have no working app to fall back on and no history row to
recover from. "Gemini error 0." reads as a fault in the key they just pasted,
which sends them to regenerate a key that was fine.

Low severity only because it is bounded to one failure mode on two screens and
the recovery (try again on a working connection) is obvious once the user has
guessed the cause.

## When to Apply

- Any onboarding-copy pass, which is already flagged as engineer-grade in the
  project's open questions.
- A user report of a rejected-looking key that turns out to be a network
  failure.
- Someone touching `validateKey`'s response handling for another reason.

## Examples

```swift
// NoType/Gemini/GeminiClient.swift — the description arm and its gate.
case .http(let s, let body) where s == 0 && body.hasPrefix(urlErrorBodyPrefix):
    …the OS sentence…
// A bare `.http(status: 0, body: "no HTTPURLResponse")` misses that gate:
default:
    "Gemini error \(status)."      // → "Gemini error 0."
```

`classifyApp` has the same bare guard and is **not** part of this entry: it is
fire-and-forget and log-only, so no user ever reads its description.

## Related

- Source plan: `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`
  — R17 / KTD12 fixed the transcription path at the producing seam; this
  surface was ruled out of scope as a separate copy decision.
- `NoType/Gemini/CLAUDE.md` "Retry policy" — the paragraph naming
  `classifyApp` and `validateKey` as the deliberate remaining bare-status-0
  producers.
- `NoTypeTests/GeminiClientOfflineShortCircuitTests.swift` — pins that a bare
  status-0 renders "Gemini error 0.", which is what keeps the prefix gate
  honest. Changing this behaviour means changing that test on purpose.
- `NoType/UI/Settings/GeminiKeyRow.swift`, `NoType/Onboarding/Steps/OnboardingAPIKeyStep.swift`
  — the two surfaces.
