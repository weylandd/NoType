---
title: A fixture must carry information the production path cannot regenerate
date: 2026-08-13
category: conventions
module: cross-cutting
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - "Writing a test whose expected value is computed rather than written down"
  - "Pinning a join, a mapping, or an agreement between two values that a fixture sets by hand"
  - "Building a fixture with a synthesized framework value (an `NSError`, a `URLError`, a default-initialized model)"
  - "Reviewing an assertion whose two sides go through the same function"
tags: [testing, fixtures, tautology, mutation-testing, guard-fidelity, joins, urlerror]
related_components: [History, Recording, UI, AppState, Gemini]
---

# A fixture must carry information the production path cannot regenerate

## Context

`testing-spm-and-git` already records two ways a fixture cannot express the failure it is named after: every element carrying the **same value** (so summing and overwriting agree), and a branch that is **unreachable** from the fixture's setup. The dictation-delivery arc produced a third, three times in three consecutive units, and it is the one hardest to see by reading:

**The expected side of the assertion is derivable from the input by the same rule the production code uses.** When that holds, a mutation that throws the real answer away and recomputes it passes — including an equality assertion, which is the shape most reviewers read as airtight.

Three instances:

- **U6 review (`1856453`).** `test_copyAction_placesTheSameStringTheRowsOwnButtonWould` asserted `HistoryText.rendered(entry, replacements: pairs) == HistoryText.rendered(entry, replacements: pairs)` — one producer compared with itself. True for every possible implementation, including one that returned `entry.text`.
- **U7 review (`2977bb2`).** Every test of the retry merge built `HistoryEntry.Segment.chunkIndices` and `RetainedRecording.Chunk.idx` **to agree, by hand**. `RetryMerge`'s type-level claim is that those are the same number *by construction* because the session records both from one `ChunkResponse` — and no test could see that join break, because every fixture constructed the agreement it was meant to verify.
- **U2 review (`e445949`).** Every R17 fixture built a synthesized `URLError(code)` with no `userInfo`, whose `localizedDescription` is Foundation's generic `"The operation couldn't be completed. (NSURLErrorDomain error -N.)"` — **re-derivable from the code alone**. So a mutation that ignored the sentence the producer embedded and re-synthesized one from the code passed the entire suite, while shipping `(NSURLErrorDomain error -1200.)` to a user. Not hypothetical: the commit records *"Verified: it did."*

## Guidance

**Ask of every assertion: could the production code compute the expected side from the input, using only what it already has?** If yes, the test constrains nothing. The fix is always the same in shape — put something in the fixture that the code under test has no way to reconstruct.

### Compare two producers, never one producer with itself

The degenerate case is easy to spot once named, and easy to write by accident when a helper is convenient:

```swift
// Nothing. True for every implementation.
XCTAssertEqual(HistoryText.rendered(entry, pairs), HistoryText.rendered(entry, pairs))
```

The repair is to make each side come from where that derivation actually lives — the notice's side from the handler's real clipboard write, the row's side from the property the row renders and copies. If both sides route through one function on purpose, the test's job is to pin *that they do*, which is a source-level claim, not an equality.

### Derive both sides of a join from one input, through the real functions

For a claim of the form "these two numbers agree by construction", the fixture must not perform the construction:

```swift
let responses: [RecordingSession.ChunkResponse] = [
    .init(chunkIndices: [0, 1], text: "Ship it by the tenth"),   // batched — ordinal 0, chunks 0 and 1
    .init(chunkIndices: [2], text: nil),
    .init(chunkIndices: [3], text: ""),      // R27's third state: gate-filtered, still text
    .init(chunkIndices: [4], text: nil),
    .init(chunkIndices: [5], text: "after."),
]
let segments = RecordingSession.historySegments(from: responses)
let payload  = RecordingSession.retainedPayload(inBatch: encoded, failedChunkIndices: …, …)
```

**The first response must be batched, and that is the whole design of the fixture.** With one response per chunk, a response's ordinal *equals* its chunk index and an ordinal-for-index substitution is numerically invisible. Batching the first response makes the two diverge from there on: the failing responses sit at ordinals 1 and 3 and carry chunk indices 2 and 4, so the assertion `Set(held.map(\.idx)) == [2, 4]` discriminates. The implementing commit reports the mutation — emitting ordinals from `historySegments` fails the test, and no other test in the suite. Its wording ("all four of its assertions") is itself slightly off, and instructively so: the test carries **five** assertions, and the one reading `Set(held.map(\.idx))` comes off the retention side alone, which that mutation cannot touch. Reported by its author and not re-run here — see [verify-subagent-test-reports](./verify-subagent-test-reports-2026-05-18.md).

Generalised: **a fixture pinning a mapping must be built so the two things being mapped are not numerically equal.** Identity fixtures — index 0→0, 1→1 — are the tautology in its arithmetic form.

### Give a synthesized framework value something the framework cannot re-derive

```swift
let sentence = "A TLS error caused the secure connection to fail."
let live = URLError(.secureConnectionFailed, userInfo: [NSLocalizedDescriptionKey: sentence])
```

The sentence was harvested from a real stall and is unreachable from the code. Anything built by `URLError(code)` alone carries only what the code implies, so it cannot tell "rendered what the producer embedded" from "re-synthesized from the code".

The same trap sits in every default-initialized model, every `NSError(domain:code:nil)`, every `.zero` — a value with no independent content cannot witness whether the content was used.

### Ship the fixture's own self-check

Each of the three repairs also asserts that the fixture is still able to discriminate, which is what stops it decaying later:

```swift
XCTAssertNotEqual(
    live.localizedDescription, URLError(.secureConnectionFailed).localizedDescription,
    "This fixture is only meaningful while the two differ — if Foundation starts giving synthesized URLErrors real sentences, re-derive a different discriminator."
)

XCTAssertNotEqual(
    whatTheRowShows, entry.text,
    "fixture no longer diverges from the legacy mirror — a handler reading `entry.text` would pass"
)
```

That is the same self-check discipline as a source scan asserting its discovery set is non-empty: a test that has quietly stopped discriminating is indistinguishable from one that passes.

### Say what the repaired fixture still cannot see

The join test derives both sides through real production functions, but its `failedChunkIndices` **argument** is still hand-computed as `responses.filter { $0.text == nil }.flatMap(\.chunkIndices)`. Production builds that set differently — accumulating per failing chunk from `shouldRetain(error)` — so a mutation in *that* accumulation escapes the test. The two functions are exercised; the accumulation between them is not. Writing the residual down is what keeps the next reader from over-trusting the green.

## Why This Matters

This family fails in the direction that carries no signal: the test is **green**, and its name promises exactly the property that is unpinned. Worse, two of the three shapes look like the strongest kind of test. An `XCTAssertEqual` between two computed values reads as a round-trip proof, and a fixture built from a real framework type reads as realistic. Neither reviewer nor author is looking for "could the code have made this number up".

It is also not caught by the habit that catches most of the others. `testing-spm-and-git` prescribes breaking the thing on purpose and watching the test go red — and that probe *was* performed and reported in this arc, and a mutant still survived, because the fixture could not answer the probe at all. A probe is a question; a fixture that cannot express the failure returns "green" to every question you ask it.

The cost was real in one case and latent in two. The `URLError` blind spot was shipping `(NSURLErrorDomain error -1200.)` onto a user's screen — the exact raw-diagnostic leak R17 exists to remove — with a full suite of R17 tests passing over it.

## When to Apply

- **Whenever the expected value is computed rather than typed.** Ask whether the production path could compute the same thing from the same input.
- **Whenever a test's two sides go through one function.** Either they should not, or the real claim is "there is one derivation" and belongs as a source assertion.
- **Whenever a fixture sets up an agreement** between two fields, two collections, two identifiers. Build the agreement from one input through the real producers, and choose values that make the two numerically distinct.
- **Whenever a fixture is a synthesized framework value.** Give it content the framework cannot regenerate, and assert it still differs from the synthesized-only variant.
- **After a repair**, record what the fixture still cannot see. A repaired fixture invites more trust than it earns.
- **Not** an argument for real data everywhere. Synthetic AX trees and synthetic audio buffers stay the rule (`testing-spm-and-git` > Testing); what has to be real is the *discriminating* content, not the whole input.

## Examples

**Before / after, the degenerate case:**

```swift
// Before — one producer, twice.
XCTAssertEqual(HistoryText.rendered(e, replacements: p), HistoryText.rendered(e, replacements: p))

// After — the notice's own derivation (the handler's clipboard write)
// against the row's, with a fixture that provably diverges from the
// legacy mirror a lazy handler would read.
let whatTheRowShows = HistoryText.rendered(entry, replacements: pairs)
XCTAssertNotEqual(whatTheRowShows, entry.text, "fixture must diverge or neither side proves anything")
let handler = try XCTUnwrap(NoTypeErrorKind.pasteWithheld(…).retryHandler)
handler(nil)
// …then compare the pasteboard's contents against `whatTheRowShows`.
```

**The arithmetic form**, stated as a checklist line: if your fixture maps `0→0, 1→1, 2→2`, it cannot tell a mapping from an enumeration. Make at least one element's key differ from its position.

## Related

- [`conventions/testing-spm-and-git-2026-05-15.md`](./testing-spm-and-git-2026-05-15.md) — the parent family. Its "a fixture must be able to express the failure" bullet covers the uniform-value and unreachable-branch shapes and the earlier tautological boundary fixture (`beg.example`, which never contained the pattern it claimed to pin); this entry is the re-derivable-expectation shape, plus the fixture-self-check habit.
- [`conventions/source-scan-guard-fidelity-2026-07-25.md`](./source-scan-guard-fidelity-2026-07-25.md) — the review-time catalogue of guards green for the wrong reason, including the `nil == nil` degeneration, which is this shape's closest cousin (an assertion both sides of which collapse to the same thing).
- [`conventions/prove-absence-by-indistinguishability-2026-08-11.md`](./prove-absence-by-indistinguishability-2026-08-11.md) — the complementary move: when the *forbidden* set is unbounded, constrain the function instead of enumerating values. Note the pairing — that entry makes an equality assertion the strong instrument; this one is the case where an equality assertion is the weak one. The difference is whether the two sides share a producer.
- [`conventions/verify-subagent-test-reports-2026-05-18.md`](./verify-subagent-test-reports-2026-05-18.md) — why "mutation-checked red" in a commit message is a claim, and the qualification each mutation report above carries.
- Commits `1856453` (U6 review), `2977bb2` (U7 review), `e445949` (U2 review) of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`. Branch-local to `refactor/structural-gap-tracking`; the plan path and the named test functions are the stable references.
