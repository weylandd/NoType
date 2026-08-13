---
title: Write the stop condition before the measurement, and vary what the field held constant
date: 2026-08-13
category: conventions
module: cross-cutting
problem_type: convention
component: tooling
severity: high
applies_when:
  - "A plan defers a numeric constant to \"measure it during implementation\""
  - "A field sample is being used to decide which of two co-varying inputs drives a cost"
  - "Choosing a timeout, a budget, a batch size, or a threshold from observed data"
  - "A measurement comes back near the value that would invalidate the approach"
tags: [measurement, timeouts, calibration, stop-condition, confounding, planning, budgets]
related_components: [Gemini, Recording, AppState]
---

# Write the stop condition before the measurement, and vary what the field held constant

## Context

R20 of the dictation-delivery plan asked to cut a flat request timeout: a stalled transport cost about sixty seconds — a 30 s inactivity budget plus one retry — and the user's hotkey was dead for all of it. A field sample taken on 2026-08-11 showed healthy requests answering in 0.88–6.05 s, with a note that the tail "tracks payload size". Both `URLSession` timers were flat 30 s constants.

The plan (KTD2) did two things before any code changed. It named the two request shapes the field sample lacked — a large batch, and a maximum-length single chunk — and it wrote a **stop condition**: *measure the two missing shapes, set the budget above the measured maximum with margin, record the arithmetic beside the constant, and **stop if the measurement lands near 30 s**.*

It landed at 26.85 s. Everything that followed came out of taking that seriously.

## Guidance

### 1. A field sample cannot separate inputs that co-vary in the field

Four repetitions of each shape, against the live API with the real request shape and real AAC encoding (2026-08-13, one machine, one network):

| shape | audio | bytes | max idle | max total |
|---|---|---|---|---|
| 4-part batch | 159 s | 653 KB | 26.85 s | 27.16 s |
| 1-part 180 s force-cut | 180 s | 735 KB | 7.62 s | 7.81 s |

**Latency tracks the number of audio parts — not the byte size and not the audio duration.** The batch carries *less* audio and *fewer* bytes than the single-part force-cut and takes three and a half times as long by the clock, for four times the audio parts; per part the two shapes agree (5.1–7.6 s observed). (The code's doc-comment rounds this to "roughly four times" — the part ratio; the totals ratio is a little lower because of the model's fixed term, which is exactly what makes it two terms.)

The field reading had not been careless. It was unidentifiable: in ordinary use a request with more parts also carries more bytes, so part count and payload size moved together in every sample, and no amount of additional field data would have told them apart. **The measurement's design is what did the work** — deliberately building a shape where the two candidate explanations point in *opposite* directions. A confirmation run over more of the same shapes would have re-confirmed the wrong axis.

So: before measuring, name the variables that might drive the cost, and construct a shape that breaks their correlation. If every planned data point has them moving together, the measurement is a sample, not an experiment.

### 2. Write the stop condition into the plan, and treat it firing as a success

KTD2's *"stop if the measurement lands near 30 s"* was written when nobody knew the answer, which is the only time such a rule can be written honestly. When it fired, the response was not to tune the number down anyway, and not to conclude that nothing could be done — it was to **escalate**: the maintainer, as product owner, ruled that the inactivity budget becomes a function of the audio-part count. The requirement's *approach* was replaced; the Key Decision above it (give up quickly, hand recovery to the user) was never reopened. What changed was only how many seconds "quickly" is for a request shape that decision had never been measured against.

The stop condition is what converted "the data contradicts the plan" from an argument into a procedure. Without it, the same 26.85 s reading arrives as an inconvenience next to a requirement that says *cut the timeout*, and the cheap resolution — pick 20 s, ship, and lose the occasional batch — is available to whoever is holding the branch.

### 3. A calibration measurement is also an audit of the value already shipping

The measured max *total* for a 4-part batch was 27.16 s against a shipped 30 s whole-transfer ceiling. Extrapolating the fitted line, a 5-part batch was already exceeding it — killing a legitimate request and producing a silent gap in text the user had already had pasted, where no retry reaches it. That is a **live shipped defect the measurement uncovered**, not a risk the change introduced, and it retired a technical decision (KTD1's "leave the whole-transfer budget at 30 s") that had been made on reasoning rather than data.

State the extrapolation as an extrapolation. The 5-part batch was never itself measured; the argument runs from the 4-part number along the fitted slope, and the repo's own wording keeps that distinction.

The same data also closed a second open question for free — *which timer produces the stalls*. Upload measured 0.06–0.31 s in every row, under 1.5 % of the total, and the response is not streamed, so essentially the whole wall-clock is the inactivity window. The inactivity timer is therefore a direct cap on how long a chunk may take rather than merely a stall detector, and the whole-transfer ceiling can only bind on a trickling upload. A separate task-metrics capture had been planned and was not needed.

### 4. Carry the measurement into the code and the tests, as data

Two habits make the derivation checkable rather than merely asserted:

- **The arithmetic lives beside the constant.** The budget function's doc-comment carries the table above, the two-term fit (~1.4 s fixed, ~6.5 s per part), the safety factor applied to it, and what the user actually pays in the common case. The constants themselves are `2` and `10` — meaningless without it.
- **The tests assert against the table, not against the literals.** `GeminiRetryPolicyTests` carries `measuredMaxima` as a fixture and asserts the budget clears every measured maximum with margin, so a future re-tune has to argue with the data rather than edit a number. It stores the max **total**, a stricter denominator than the idle window the timer actually bounds.

Add one assertion that makes the *model* falsifiable rather than just fitted: `test_requestBudget_safetyFactorIsUniformAcrossTheMeasuredShapes` pins that the margin does not spread across the measured shapes, because *"a budget generous at one part count and tight at another is not a model of the latency, it is a coincidence."* Collapsing the fixed term into the slope, or vice versa, skews it and the test fails.

**Be precise about which factor is which.** 1.5× is applied to the fitted model; ~1.55× is what results after rounding to whole seconds; 1.4× is the minimum the suite enforces, plus a uniformity spread below 0.25. Saying "they chose 1.55×" inverts cause and effect, and saying "1.55× is pinned" overstates the tests — the looser floor is deliberate, so the budget can be re-tuned without editing the fixture.

**Size the margin by the asymmetry of being wrong, not by taste.** Four runs per shape on one machine is a sample, not a distribution. Too generous and the user waits; too tight and a legitimate request is killed, which becomes a gap in text already pasted into their document. The costs are not symmetric, so the factor should not be centred.

## Why This Matters

The failure this avoids is quiet and durable: a constant chosen against the median of the data you happened to have. It ships, it looks fine, and it converts a class of slow-but-successful requests into failures at a rate nobody measures — here, into gap markers in text the user has already received, which no retry can remove.

The confounding half generalises past timeouts. Any cost attributed to "size" — payload, rows, records, files — is worth checking against "count", because in production traffic those two almost always move together and the fix that follows from each is different. Here the wrong axis had already propagated into a *different module's* design: the adaptive pause ladder's rungs were partly justified as keeping chunks small enough to fit a network budget, and the measurement showed a shorter chunk buys no network headroom at all. The ladder survives on its audio-quality merits; the justification did not.

And the planning half is what makes the correction cheap. The stop condition made "this measurement kills the approach" a named, expected outcome with a defined next step, rather than a discovery that arrives after the code is written and is therefore expensive to act on.

## When to Apply

- **Any plan that defers a constant to "measure during implementation".** Write, at the same time, the reading that would mean the approach is wrong and what happens then.
- **Before designing the measurement.** List the candidate explanatory variables and check that at least one planned data point makes them disagree. If they always move together, you are sampling, not measuring.
- **After any calibration measurement**, evaluate the *currently shipping* value against the new data before evaluating the proposed one. That comparison is free and it is where shipped defects surface.
- **When recording the result**, put the table and the arithmetic next to the constant and make the tests consume the table. A constant with no derivation beside it is a number the next person will change on intuition.
- **When a measurement contradicts a requirement's approach**, check whether the decision *above* it survives. Usually it does, and the change is smaller than it first looks — here KD7 ("give up quickly, hand recovery to the user") was untouched.
- **Say what is still unpinned.** Of the three platform facts recorded beside these constants, one is verified in-suite against a stalling loopback socket; the other two — the narrowing direction, and that the whole-transfer timer has no per-request counterpart — are recorded in prose only. The second of those is the fact that forces the ceiling to be a single flat value, so it is worth knowing it rests on a measurement nobody can re-run from the repo.

## Examples

**The stop condition, written before the answer was known** (`docs/plans/2026-08-11-001-…-plan.md`, KTD2):

> The mandate was: measure the two shapes the field sample lacked, set the budget above the measured maximum with margin, record the arithmetic beside the constant, and **stop if the measurement lands near 30 s**.

**What replaced the flat cut:**

```swift
nonisolated static func requestInactivityBudget(audioPartCount: Int) -> TimeInterval {
    let derived = requestBudgetFixedOverhead
        + requestBudgetPerAudioPart * TimeInterval(max(0, audioPartCount))
    return min(requestBudgetCeiling, max(requestBudgetFloor, derived))
}
```

`2 s + 10 s × parts`, clamped to `[10 s, 90 s]`; applied per request via `URLRequest.timeoutInterval` at the point the part count is known. The whole-transfer ceiling moved to `requestBudgetCeiling + uploadAllowance` and stays flat, because the platform offers no per-request counterpart for it.

**A test that refutes the retired approach out loud**, rather than leaving it to be rediscovered:

```swift
func test_stalledBatchRequest_costsMoreThanASingleChunk_deliberately() { … }
// "The flat cut is exactly what KTD2's stop condition rejected."
```

## Related

- [`design-patterns/adaptive-pause-threshold-2026-05-16.md`](../design-patterns/adaptive-pause-threshold-2026-05-16.md) — the worked downstream casualty, amended by this measurement: the ladder's network justification was struck through and its "measure before you anchor a ladder to a network budget" bullet is the scoped restatement of this entry.
- [`runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`](../runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md) — the repo's other investigation that refuted the hypothesis it was run to confirm, and kept the disproven rule on its own merits. Same move, different domain.
- [`architecture-patterns/serial-gemini-actor-2026-05-15.md`](../architecture-patterns/serial-gemini-actor-2026-05-15.md) — the batching decision that creates multi-part requests, i.e. the axis this measurement found.
- [`conventions/cited-invariant-must-cover-the-population-2026-08-11.md`](./cited-invariant-must-cover-the-population-2026-08-11.md) — the sibling from the same unit, on evidence that moves from something the repo can check to something it can only cite. The two prose-only platform facts above are an instance.
- `NoType/Gemini/CLAUDE.md` "Request budgets" and `GeminiClient.requestInactivityBudget(audioPartCount:)`'s doc-comment — the table, the fit, the safety factor, and the answer to which timer is the right control. `NoTypeTests/GeminiRetryPolicyTests.swift` carries the measurement as a fixture.
- Commit `42d2dc4` (U1 of the plan). Branch-local to `refactor/structural-gap-tracking`; the plan and the doc-comment are the stable references.
