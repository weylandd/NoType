# Hand-off round checklist — executor-corruption fix (build 16)

Operational companion to
[`2026-07-26-001-fix-swallowed-exception-executor-corruption-plan.md`](./2026-07-26-001-fix-swallowed-exception-executor-corruption-plan.md),
**Step 9 / U9**. Everything Step 9 asks a human to do is here, in order, so
the round can be run without re-reading the plan. The plan stays the
decision artifact; this file is the runbook.

Mechanism, ranked suspects and history:
[`docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`](../solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md).

**Status when this file was written:** nothing below has been run. No
tester round has happened, no result has been recorded, and
[issue #82](https://github.com/weylandd/NoType/issues/82) still has zero
comments.

---

## 0. What is being tested, in one paragraph

An Objective-C exception raised inside a `Task { @MainActor }` unwinds
through `libswift_Concurrency`, whose `ExecutorTrackingInfo` is a
stack-allocated node with no unwind landing pad. That leaves the main
thread's executor identity pointing at a dead stack slot. AppKit swallows
the exception and execution resumes; the **next** executor check SIGSEGVs,
hundreds of milliseconds and one unrelated user action later. **The crash
site is incidental** — `TimelineView`, `.onHover` and a stock SwiftUI
`Button` were three witnesses, not three causes.

That mechanism is proven end to end (reproduced locally, 2026-07-26).
**Which of NoType's calls throws is not.** `MicProbe`'s tap format,
`HUDPanel`'s geometry, the fixed-size window lock and the SileroVAD /
CoreML load are **ranked suspects** — none has been observed firing in the
wild, and there may be more than one. Build 16 closes the checkable ones
and ships an interceptor that names whatever still fires.

---

## 1. Retrieving the breadcrumb log — the one command

```bash
/usr/bin/log show --last 30m \
  --predicate 'subsystem == "app.notype" AND category == "exception"' \
  --style compact
```

- **Absolute path is required.** A bare `log` is shadowed by a shell
  profile on the maintainer's machine.
- Records are written at **`.fault`** on purpose — `.info` is not
  persisted to the log store, so it could not be retrieved after the fact.
- Widen `--last 30m` if the app has been running longer than the window.
  The armed line is written **once, at startup**, so on a copy that has
  been up all day it has already aged out — quit and relaunch first.

What the lines mean:

| Line | Meaning |
|---|---|
| `EXC BREADCRUMB armed cap=20 frames=… chained=true` | The interceptor installed and chained to the preprocessor it replaced. This is the "it ran" proof. |
| `EXC BREADCRUMB armed … chained=false` | Installed, but nothing was chained. Investigate — chaining is a correctness requirement, not hygiene. |
| `EXC BREADCRUMB unavailable` | The `dlsym` lookup returned nil. The interceptor is **not** installed; any silence afterwards means nothing. |
| `OBJC THROW …` | An Objective-C exception was raised. Carries the name, the scrubbed reason, `isMainThread`, and the throwing stack. **This is the target.** |
| `EXC BREADCRUMB further exceptions not logged` | The 20-record-per-launch cap was reached. |

---

## 2. Pre-flight — maintainer, before anything is handed to anyone

This is the Step 2 verification that is still outstanding. Do it on the
build that is going out, not on a scratch build.

- [ ] `CFBundleShortVersionString` is `0.1.13-rc1` and `CFBundleVersion`
      is **16**. (Already committed — re-confirm in the built bundle's
      `Info.plist`, not just in the repo.)
- [ ] Launch the build. Run the command in §1. Confirm **exactly one**
      `EXC BREADCRUMB armed` record for that launch, and that it says
      **`chained=true`**.
- [ ] Confirm there is **no** `EXC BREADCRUMB unavailable` record.
- [ ] Raise a deliberate `NSException` (a throwaway debug affordance is
      fine — do not commit it) and confirm an `OBJC THROW` record appears
      at `.fault` and is retrievable by the same command. Without this,
      "the log was silent" is not evidence of anything.
- [ ] Quit, relaunch, re-run the command: exactly one *new* armed record.
      One per launch, not one per session-of-use.
- [ ] Cut the signed artefact with `scripts/release.sh` — **human only**,
      never an agent; it talks to Apple's notary service and ships a real
      binary.
- [ ] Confirm the rc did **not** reach `docs/appcast.xml` (KD5). A
      hand-off build is never published — it would serve an unfinished
      diagnostic build to every installed copy.
- [ ] After the release flow, sweep `build/export/NoType.app` (Launchpad
      duplicate trap — see `docs/build.md`).

---

## 3. Per-tester round — run this **twice**, once per tester

Two affected users, run independently: the issue #82 reporter, and the
second user whose build did not work. **Do not collapse them into one
result**, and do not treat the second as a fallback. Every conclusion in
this crash family so far has rested on n=1.

### 3a. Before they start — tell them these three things

- [ ] **Both arms happen in one sitting.** It costs one extra launch of a
      build they already have installed.
- [ ] **If the mic-check spectrum meter stays flat, that is the new format
      guard declining an unsafe tap — not a broken microphone.** Continue
      through onboarding and send the log either way. Without this warning
      the most likely success case reads to them as a failure.
- [ ] **Read the log output before posting it.** It is scrubbed for
      key- and password-shaped tokens, but the text is authored by macOS,
      not by NoType, and issue #82 is a public, search-indexed page.
      Anything they would rather not publish goes to
      **kopachevmail@gmail.com** instead, with a note on the issue saying
      one was sent.

### 3b. Arm 1 — the baseline (KTD8). Do this FIRST.

- [ ] Tester re-launches their **currently-installed pre-fix build** and
      tries to reproduce the crash on their **current** macOS.
- [ ] Record the pre-fix build string and the macOS build.
- [ ] **If it still crashes** — good, the baseline holds. Continue to
      arm 2.
- [ ] **If it no longer crashes** — that tester's round is **VOID as fix
      evidence**. Record it on #82 as a suspected OS-side change and stop;
      do not run arm 2 as if it proved anything. The other tester's round
      is unaffected.

Why this arm exists: Apple is actively tracking the non-exception-safe
`ExecutorTrackingInfo` pop. If a tester's macOS moved, an OS-side change
looks *identical* to this plan's fix — and a tester's round is the only
kind of evidence this plan has.

### 3c. Arm 2 — the hand-off build

- [ ] Install build 16. Confirm the tester sees **0.1.13-rc1 (16)**.
- [ ] Complete onboarding end to end.
- [ ] Exercise buttons across the main window and the popover.
- [ ] Run the §1 command **whether or not it crashed**. This is not
      optional — a clean session reported without the log is an
      **incomplete round**, not a pass.
- [ ] Collect the `.ips` too if it crashed.

### 3d. Record on issue #82 — one entry per tester, both outcomes

Every entry carries all of:

- [ ] macOS build (e.g. `26.4.1 / 25E253`).
- [ ] **Both** app build strings — the pre-fix build from arm 1, and
      `0.1.13-rc1 (16)` from arm 2.
- [ ] Arm 1 result: still crashes / no longer crashes.
- [ ] Arm 2 result: crashed / clean.
- [ ] The `log show` output, **regardless of outcome**, including
      "armed line only, nothing else".
- [ ] Their onboarding step at the time, and their audio device list.

A tester who never replies is **recorded as such and blocks nothing**.
Steps 2–5 are on `main` on their own merits and were never gated on a
confirmation.

---

## 4. Reading the result — the falsifier

This table is the point of the whole round. It is what stops the next
round repeating the superseded plan's failure.

| | interceptor **silent** | interceptor **logged an `OBJC THROW`** |
|---|---|---|
| **no crash** | Plan confirmed → §5. | **AE3** — issue still closes, *and* a thrower survives that this plan did not enumerate. Name it and extend the audit in `NoType/UI/CLAUDE.md`. |
| **crash** | **AE4 — THIS PLAN IS WRONG.** See below. | **R3** — completed round, negative result. The log names the next target. Do not retry the same round in variations. |

> **ID note.** The plan's summary table (`…-plan.md` §26) once put the `AE4`
> label on the crash + *logged* cell, disagreeing with its own normative `AE4`
> block (§139, "Covers R3, R4a") and its Step 9 text (§445), which both put it
> on crash + *silent* — the falsifier — and assign `R3` to crash + logged. That
> table has since been corrected to match this one; all four plan locations now
> agree. The four branches themselves were never in dispute.

**Crash + silent interceptor is the falsifier.** Handle it in this order:

1. **Check the R4a armed line first.** It separates *"the interceptor
   never installed"* from *"it installed and nothing threw"*.
2. **Armed line absent** → the round is **void**, not negative. The
   interceptor never installed. Re-run before drawing any conclusion.
3. **Armed line present, no `OBJC THROW`** → no Objective-C exception was
   raised in that process, so a swallowed exception does **not** explain
   that machine's crash. **This plan's central premise is wrong.** Record
   it as such on #82, treat the containment shapes (KTD5) as inapplicable
   rather than as the next move, and **reopen diagnosis from the `.ips`**.
   **Do not add a fifth suspect** — enumerating one more thrower is the
   exact failure mode that cost the superseded plan three months.

One more branch worth naming: an `OBJC THROW` record naming a **CoreML /
Espresso** exception re-arms Step 6 immediately, and **both** SileroVAD
load sites move off the main actor, not just `prime()`'s.

---

## 5. On confirmation only — closeout (R18)

Do **none** of this until a tester's round actually lands clean.

- [ ] Remove the `## Known issues` block from `README.md` — **and move**
      the `log show` recipe plus its read-before-posting note into a
      short standing `## Reporting a crash` section. The interceptor is
      permanent and that command stays its only surface (KD6); do not
      substitute an in-app affordance on the way out. Naming the
      destination matters, because the recipe currently lives *inside*
      the block being deleted.
- [ ] Rewrite the family entry's *"Suspected throwers — NOT confirmed"*
      section into the **named cause**, keeping the ranked list as
      history. Deleting it is how the next investigation re-runs it.
- [ ] Cross-link the closing commit.
- [ ] Close issue #82.
- [ ] **State the limits in the closing note**, plainly:
      - The maintainer's machine does not reproduce the crash; local
        gates proved only that behaviour did not regress.
      - The evidence is at most two testers, one session each.
      - That one-session bar is the *same* bar that pronounced each of
        the three prior call-site fixes successful, each time before the
        crash reappeared at the next reader — and this crash is latent,
        arbitrary in where it lands, and device-set dependent.
      - **What is different now is that the build is instrumented.**
        Because the log is collected in both outcomes, a
        silently-still-broken result is visible inside the same session,
        and a thrower that fires days later still leaves a `.fault`
        record the user can send without reproducing anything. That is
        the mitigation the three prior rounds did not have, and it is
        why a one-session bar is a measurement here rather than a repeat.

---

## 6. Explicitly not part of this round

- **Do not publish the rc to `docs/appcast.xml`** (KD5). Merging to
  `main` and cutting the next ordinary release are separate and wait on
  nobody (KD8, R22).
- **Do not hold #82 open for a soak window.** One sitting is the agreed
  bar (KD7), with its risk accepted on the record.
- **Do not retry a crashing round in variations.** A crash is a completed
  round with a negative result (R3).
- **Step 1** (the zero-build reporter diagnosis) was **cancelled** at the
  owner's decision and will not happen. **Step 6** (SileroVAD off the
  main actor) is **deferred pending evidence**, not rejected — see the
  re-arm condition in §4.
- Agents must not launch the app, must not run `scripts/release.sh`, and
  must not post to or close issue #82.
