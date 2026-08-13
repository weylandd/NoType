---
title: A hotkey press during transcription is refused silently, and no second recording may start
date: 2026-08-13
category: documentation-gaps
module: AppState
problem_type: documentation_gap
component: tooling
severity: medium
---

# A hotkey press during transcription is refused silently, and no second recording may start

## Context

While a dictation is transcribing, the hotkey does nothing at all. Press it
and there is no session, no sound, no HUD, and no log line — the app is
indistinguishable from one whose push-to-talk has broken.

The refusal is one line in `AppState.handleHotkeyPress`:

```swift
guard case .idle = recordingState else { return }
```

**It is the only refusal in that handler with no signal of any kind.** The four
others all surface something: the onboarding observer runs the wizard's own UI,
a missing microphone raises a permission HUD, a locked session finalizes, and
the double-tap arm logs `hotkey double-tap → locked recording`. This one is a
bare `return`.

Two separable things sit behind it, and they are worth keeping separable:

1. **The interaction gap** — a user who has just finished one thought is
   stopped from starting the next until the network answers.
2. **The feedback gap** — even granting the refusal, the user is told nothing.
   The second is much cheaper than the first and does not depend on it.

This mattered more before the request budget was cut. A stalled transport used
to hold the hotkey for ~60.5 s; it is now bounded by
`GeminiClient.requestInactivityBudget(audioPartCount:)` plus one retry, which
for the common single-part request is well under half of that. Shortening the
wait was the cheaper half of the same pain, and it is what shipped.

## Guidance

**Leave the refusal in place; consider the feedback half on its own.** They are
independent changes and the second is the one with no design questions attached.

For the feedback half: the press already reaches an `@MainActor` method with a
`HUDController` in hand, and the transcribing HUD is on screen for the whole
window in which this can happen. A `.notice` log line costs nothing and would
have made this diagnosable from a user's Console output; an on-screen signal —
a pulse on the transcribing HUD, or a brief neutral line on it — needs a
product call about tone, because "your press was ignored" is a message no other
refusal in this app has to send.

For the interaction half, the ordering questions are the work:

- Where does the second session's transcript go? The first session's paste is
  gated on the process the user stopped in; a second session overlapping it
  produces two transcripts racing for one cursor.
- What is the prior-chunk context of the second session while the first is
  still open? Priors are per-session today and the cache prefix is frozen at
  session start.
- What does invariant I1 mean with two sessions live? "One Gemini request in
  flight **per session**" is per-session by wording, so two sessions would put
  two requests in the air — which is legal by the letter and unmeasured in
  practice.
- What does the recording HUD show, and what does the menu-bar icon show?

## Why This Matters

The failure presents as breakage. A user pressing the hotkey and getting
nothing does not think "it must still be transcribing"; they think the app
stopped working, and there is no artefact — not even a log record — that
contradicts them or lets a maintainer confirm what happened after the fact.

## When to Apply

- A user reports that push-to-talk "randomly stops working", and the report
  cannot be resolved from logs. The absence of a record here is the reason.
- The transcribing wait grows again for any reason, which widens the window.
- Someone is reworking `handleHotkeyPress`'s guard ladder anyway.

## Examples

```swift
// NoType/AppState.swift — handleHotkeyPress, the five refusal arms.
if let observer = onboardingHotkeyPressObserver { observer(); return }  // wizard UI
if !permissions.microphone.isGranted { hud.presentMissing([.microphone]); return }  // HUD
if lockedRecording { … finalizeRecording(); return }                    // acts
if awaitingSecondTap { … Self.log.info("hotkey double-tap → locked recording"); return }
guard case .idle = recordingState else { return }                       // ← silent
```

## Related

- Source plan: `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`
  — "Deferred to Follow-Up Work", and KD10, which put concurrent sessions out of
  scope as a product decision ("shortening the wait is the cheaper half of the
  same pain, and concurrent sessions raise their own ordering questions").
- `NoType/Gemini/CLAUDE.md` "Request budgets" — what bounds the window today.
- `docs/architecture/overview.md` invariant 1 (one request in flight per
  session) and invariant 6 (`RecordingSession` is a value, not a global) — the
  two the interaction half would have to be re-read against.
- `NoType/Hotkey/CLAUDE.md` — the press/release contract this guard sits behind.
