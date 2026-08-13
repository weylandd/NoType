---
title: A value frozen at the start of an interaction encodes an assumption about the interaction's shape
date: 2026-08-11
category: conventions
module: Recording
problem_type: convention
component: tooling
severity: high
applies_when:
  - "Freezing a value at the start of a long-running operation whose result addresses a destination — a window, a document, a recipient, a file"
  - "Adding a second interaction mode to a flow that already has one (hold vs. lock, foreground vs. background, immediate vs. deferred)"
  - "Reviewing a capture site whose justification is a sentence about what the user is doing rather than a constraint the code enforces"
  - "A feature works in one mode and silently does nothing in another"
  - "Deciding whether a fact belongs in the one start-of-operation snapshot or needs its own capture moment"
tags: [frozen-state, capture-moment, interaction-modes, product-decision, silent-failure, session-lifecycle, review]
related_components: [Recording, Context, AppState, Injection]
---

# A value frozen at the start of an interaction encodes an assumption about the interaction's shape

## Context

U3 of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md` added a guard that withholds the paste when the transcript would land somewhere the user has left: `stop()` re-reads the frontmost process at the last synchronous instruction before ⌘V and compares it against the session's frozen paste destination (`RecordingSession.shouldWithholdPaste(destinationPID:currentPID:)`, `NoType/Recording/RecordingSession.swift:197`).

It shipped with the destination frozen **at session start** (`95c0a66`). Nothing about that looked like a decision. The session already captures a great deal at start — the app, the accessibility tree, the insertion target, the instructions and dictionary — so one more identifier in that snapshot read as housekeeping, and freezing early even had a defensible-sounding rationale: it avoids re-deriving the pid from an `NSRunningApplication` that answers `-1` once the process exits.

Review found it broke hands-free dictation outright. A NoType session can be **locked** — by a second hotkey press inside a short double-tap window, or by Hold+Space (`AppState.handleSpacebarLockTrigger`, `NoType/AppState.swift:1973`; see `NoType/Hotkey/CLAUDE.md`) — after which the user stops talking, walks to another application, and taps to stop there. Under a start-time freeze the gate compared the application they walked *to* against the one they started in, saw a genuine mismatch, and withheld. Every single time. The entire point of the mode is that start and stop happen in different places, so a whole hands-free dictation delivered nothing.

The maintainer ruled as product owner: the transcript belongs wherever the cursor was when stop was pressed — *"там, где курсор стоял в момент нажатия стоп, туда и нужно записывать"*. The freeze moved to `AppState.finalizeRecording`'s first statement after the session guard (`NoType/AppState.swift:1604`, `43f7c0a`), which is the single funnel all three stop paths reach without an intervening suspension. A follow-up ruling then also discarded the *start* application's cursor context for cross-application pastes (`7d46a0c`), because the same stale-moment problem had a second victim.

## Guidance

**Freezing a value asserts that it cannot change over the window between capture and use. Nothing in the code enforces that assertion.** It rests on the shape of the user interaction — and it is almost always recorded as a parenthetical rather than as a constraint, because at the time it was written there was only one shape.

Three rules follow.

### 1. Each frozen fact has its own correct capture moment, set by the question it answers

The fix here was *not* "freeze later." Some of this session's start-frozen facts were right where they were, and the arc deliberately left them:

| Fact | Question it answers | Correct moment |
|---|---|---|
| `HistoryEntry.sourceAppName` / `sourceBundleID` | *Where did this dictation happen?* (feeds lifetime per-app statistics) | **start** — unchanged |
| the paste destination | *Where is this transcript going?* | **stop** |
| the prompt's cache prefix (instructions, dictionary, AX context) | *What should the model know?* | **start** — frozen by construction; re-reading mid-session breaks implicit caching |

The tell is what kind of fact it is. A fact that **describes** the interaction (a duration, a source, a hash) is naturally start-shaped. A fact that **addresses** something — a window, a document, a recipient, a file — is a claim about the world at the moment of use, and its capture moment is whatever moment the address has to be true at. Bundling both kinds into one "snapshot at start" is a convenience that silently assigns the same moment to facts that answer different questions.

### 2. A frozen value never fails — it answers confidently with a stale truth

There is no error state to observe. The predicate consuming it was working exactly as specified; its unit table was fully green under every mutation, before and after the ruling, because the defect was in the *input*, not the logic. That is why the failure surfaced as a product report ("hands-free delivers nothing") rather than anything a test could see: no test enumerated the flow, and no test that examines the gate in isolation ever could.

So the review question is not *is this predicate right* but **over what window is each of its arguments still true, and does any interaction mode exceed that window?**

### 3. The tell is a capture site justified by a parenthetical about user behaviour

The justification is the artifact that rots. Look for a comment or invariant that reads *"…because the user holds / stays / doesn't move / has only one of these."* That is a premise about interaction shape wearing the clothes of a constraint.

This repo has two instances of the identical parenthetical, and **only one of them has been dealt with**:

- The destination freeze — reversed by the 2026-08-11 ruling, above.
- `NoType/Context/CLAUDE.md:24`, invariant 6: *"`InsertionTarget` is captured once at session start; cursor doesn't move during a session **(user holds the hotkey)**."* Lock mode falsified that parenthetical the day it shipped. U3 contained the **consequence** — `shouldDiscardInsertionContext(sourcePID:destinationPID:)` (`RecordingSession.swift:270`) substitutes `InsertionTarget.unknown` when the start and destination processes positively differ, so `TextInjector.finalizeForInsertion` stops correcting the paste against another document's text. But the invariant's stated **premise** was never amended: it still teaches the next reader that the cursor cannot move because the user is holding the key. Fixing the behaviour and leaving the false reason in place is the shape [`cited-invariant-must-cover-the-population`](./cited-invariant-must-cover-the-population-2026-08-11.md) is about — the next reader reasons from the justification, not from the fix.

## Why This Matters

**The capture moment was a product decision that nobody made.** "Freeze at start" reads as an implementation detail — cheap, race-free, the value is right there. What it actually encoded was a policy: *the transcript belongs where the dictation began.* Nobody chose that policy; it fell out of a mental model in which hold-to-talk was the only mode, where start and stop are the same place and the distinction has no observable consequence. The moment a second mode made the two differ, the unmade decision became the shipped behaviour — and when the product owner was finally asked, the answer was the opposite one.

Generalised: **whenever a captured value names a place, a person, a document, or a target, its capture moment belongs to whoever owns the behaviour, not to whoever is writing the capture.** If you cannot say which of two moments the product wants, you have found a question for the product owner, not a detail to settle by convenience.

**The blast radius is a whole mode, and it is silent.** Not a degraded result — nothing at all was delivered, with the transcript surviving only on a history row the user had no reason to look at. A mode-scoped total failure is the hardest kind to notice from the inside: every ordinary hold-to-talk dictation kept working perfectly, which is exactly the population a developer exercises by habit.

**Adding an interaction mode is a re-read trigger, not just a feature.** Lock mode's own implementation was fine. What it did was invalidate a premise held by code written elsewhere, months earlier, that never mentioned it. There is no mechanical guard for this: a frozen value has no wrong-looking type, no failing assertion, and the freeze in U3's case even had a *source guard around it* — `RecordingSessionFocusGuardTests` pinned the freeze's position rigorously while the freeze was in the wrong place entirely. A guard proves the code does what its author intended; it cannot notice that the intent was scoped to one mode.

## When to Apply

- **Adding a second interaction mode to an existing flow** — hold vs. lock/toggle, foreground vs. background, immediate vs. deferred, one-shot vs. resumable. Enumerate every value the flow freezes and ask which ones the new mode's start and end no longer agree about.
- **Reviewing any `let x = <read the world>` at the start of a long operation** whose result addresses a destination. Ask what makes it still true at the end.
- **Reviewing a capture site whose comment justifies it with user behaviour.** Treat the parenthetical as the claim under review.
- **Triaging "it does nothing" for exactly one mode.** Suspect a value frozen at a moment that mode moved.
- **Designing a start-of-operation snapshot.** Sort the facts into *describes* and *addresses* before deciding they share a capture moment. Both kinds are legitimate; the mistake is not noticing there are two.
- **When a behaviour fix lands but the invariant that justified the old behaviour is in a different file.** Amend the premise too, or the next reader re-derives the bug.

## Examples

**Before** (`95c0a66`) — one identifier, captured in the session's start-time snapshot, doing both jobs. The name is the whole story: the field and the parameter were called `sourcePID`, and the gate compared *the source* against the frontmost process at paste time.

```swift
// RecordingSession.start() — the session's only process identity
sourcePID = pid

nonisolated static func shouldWithholdPaste(sourcePID: pid_t, currentPID: pid_t) -> Bool {
    guard sourcePID > 0, currentPID > 0 else { return false }
    return sourcePID != currentPID
}
```

Under hold-to-talk *where you started* and *where it goes* are the same fact, so one field with one name is not obviously wrong. Under a locked session they are two facts, the code had a word for only one of them, and the one it had was the wrong one to paste against.

**After** (`43f7c0a`) — the destination read at the stop, from the single funnel all three stop paths reach (`NoType/AppState.swift:1604`):

```swift
let destinationName = session.freezePasteDestination(NSWorkspace.shared.frontmostApplication)

recordingState = .sending
```

The gate now takes `destinationPID` (`NoType/Recording/RecordingSession.swift:197`). `sourcePID` came back later, in `7d46a0c`, for a different question — *was the cursor context read somewhere else* — and the two identifiers finally name two facts instead of one.

**The parenthetical, still open** (`NoType/Context/CLAUDE.md:24`):

```
6. **`InsertionTarget` is captured once at session start; cursor doesn't
   move during a session** (user holds the hotkey).
```

The premise is false for a locked session. The consequence is handled; the sentence is not.

## Related

- [`conventions/guard-scope-must-match-invariant-scope-2026-08-09.md`](./guard-scope-must-match-invariant-scope-2026-08-09.md) — the closest sibling and the reason this is a separate entry. That one is about a **check** whose extent is narrower than the invariant it enforces; this one is about a **captured value** whose validity window is narrower than the interaction that consumes it. Neither tell finds the other: there is no local boolean here, and no check in the wrong place — the check was correct and correctly placed, and its input described the wrong moment.
- [`conventions/cited-invariant-must-cover-the-population-2026-08-11.md`](./cited-invariant-must-cover-the-population-2026-08-11.md) — the same arc's sibling failure about justifications. That one is a citation whose *population* is too narrow; this one is a premise whose *lifetime* ran out. The open `Context/CLAUDE.md` invariant above is where the two meet.
- [`conventions/source-scan-guard-fidelity-2026-07-25.md`](./source-scan-guard-fidelity-2026-07-25.md) — the guard that pinned the freeze's position, and (after this arc) the ordering/occurrence and comment-stripping amendments it needed. Worth reading beside this entry for the sharpest illustration of its last point: that guard was rigorous, green, and defending the wrong moment.
- `NoType/Recording/CLAUDE.md` "Destination guard" — the shipped contract: what is frozen at stop, what deliberately stays frozen at start, and why the two gates are not the same gate.
- `NoType/Context/CLAUDE.md` invariant 6 — the open instance named above.
- `NoType/Hotkey/CLAUDE.md` — `SpacebarLockMonitor` and the lock predicate; the mode whose existence falsified the premise.
- Commits `95c0a66` (U3 implementation — destination frozen at session start), `43f7c0a` (the 2026-08-11 product ruling — freeze moves to the stop), `f8ee2c2` (the transcribing HUD relabelled from the same read), and `7d46a0c` (the second victim — the start application's cursor context discarded for a cross-application paste). Unit U3 of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`. All SHAs are branch-local to `refactor/structural-gap-tracking` at time of writing and will be rewritten if that branch squash-merges; the plan path is the stable reference.
