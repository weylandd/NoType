---
title: Prove a no-leak rule by indistinguishability, not by a list of forbidden words
date: 2026-08-11
category: conventions
module: cross-cutting
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - "Writing a test for \"X must not appear in Y\" where X ranges over user content, a secret, or anything unbounded"
  - "Reviewing a redaction, masking, logging, or telemetry guard whose assertions are all `XCTAssertFalse(out.contains(…))`"
  - "A rendered surface is handed a whole model object in order to read one field from it"
  - "A change legitimately adds a dependency to a surface that carried a no-leak property"
tags: [testing, privacy, no-leak, property-testing, guard-fidelity, needle-list, redaction]
related_components: [UI, AppState, Context, History]
---

# Prove a no-leak rule by indistinguishability, not by a list of forbidden words

## Context

R29 of the dictation-delivery plan: the withheld-paste notice must carry no transcript content in its title or description. The reason is concrete — that panel renders over whatever application the user moved to, which may be a screen share or a call, so every word it draws is potentially published to a room.

The first guard was needle-shaped. `test_neitherTitleNorDescription_carriesAnyTranscriptContent` (`NoTypeTests/AppStateFocusNoticeTests.swift:260`) builds one fixture transcript — `"my account password is hunter2 and the wire clears friday"` — and asserts that the whole string and four distinctive words (`password`, `hunter2`, `wire`, `friday`) are absent from both rendered strings.

The realistic regression is not the whole transcript; it is a **preview**. The first twelve characters of that fixture are `my account p`, which is neither the whole string nor any of the four needles. A twelve-character preview rendered into the description satisfies every assertion in the test. (The commit that closed this reports having demonstrated the green; not re-run here — see [`verify-subagent-test-reports`](./verify-subagent-test-reports-2026-05-18.md). The arithmetic above is checkable by reading the fixture, which is the part that matters.)

The needle list was not badly chosen. It was the wrong *kind* of instrument: the forbidden set is "any function of the transcript" — a preview, a length, a word count, a first-letter hint, a hash prefix — and that set is not enumerable, so any list samples it.

## Guidance

**State the rule as information flow, then assert it as indistinguishability.**

"No transcript content in the notice" is a sentence about forbidden *values*, and it invites a list. The same requirement restated as a sentence about *inputs* is directly testable: the payload is a function of the summary alone. The entry rides along for the Copy action; it must not influence what is rendered.

That form needs no needle guessed in advance:

```swift
// AppStateFocusNoticeTests.swift:291 — two entries sharing no field.
XCTAssertEqual(
    NoTypeErrorKind.pasteWithheld(entry: a, summary: summary).payload,
    NoTypeErrorKind.pasteWithheld(entry: b, summary: summary).payload,
    "The notice's payload varies with the entry, so something about the transcript reaches the panel."
)
```

A preview fails it. A word count fails it. A length, a hash, an "it starts with…" hint all fail it. None of them had to be anticipated.

**Two preconditions, both worth checking before reaching for the shape:**

- **The output has an equality total over what a leak could change.** Here `ErrorPayload` is already `Equatable` (`NoType/UI/ErrorHUD.swift:90`) over every rendered string, so the property costs one assertion and no new machinery. A type whose `==` ignores the field a leak would land in gives a green that means nothing.
- **The two inputs genuinely share no field.** A fixture pair differing in one field proves only that one field is unread. The pairs above differ in text, source app, and failed-chunk count simultaneously.

**When the output legitimately gains a dependency, widen the property — do not drop it.**

The 2026-08-11 ruling made the notice's Copy affordance conditional on whether the history row it points at offers one, so `payload` now does read the entry. The property was not abandoned; it was restated one bit weaker: *two entries agreeing on that bit and sharing no other field render an equal payload* — and asserted on **both sides** of the bit, because a gate that leaked content only on the no-copy arm would otherwise sweep past the fixtures.

**The widening is only defensible because the new channel is provably content-free**, and that argument belongs in writing next to the property. Here the channel is a `Bool` (`NoTypeErrorKind.withheldNoticeOffersCopy(for:)`, `NoType/AppState.swift:2721`): one bit cannot carry a word of what was said. Without that argument, "widen the property" is indistinguishable from relaxing it once per change until it holds vacuously. The structural half is to read the permitted bit through a single named helper and never touch the input again, so "reads exactly one bit off the entry" is checkable by reading the arm rather than trusted.

**Keep the needle test anyway.** It costs nothing, it names in prose what a leak looks like, and its failure message is the one a reader understands. Just do not count it as the coverage — the comment above the property test says so explicitly, which is what stops the next maintainer from deleting one as redundant.

## Why This Matters

The failure is asymmetric in the usual direction: a needle list that has stopped covering the rule is **green**, and stays green while the leak ships. Worse, the belief that the rule is mechanically enforced is exactly what makes reviewers stop reading the rendered strings by hand.

A sampling guard also decays without anyone touching it. Every copy change is an opportunity for the leak to enter through a channel no needle names, and the list is never revisited because it never fails. The property has the inverse maintenance profile: it constrains the *shape* of the function, so it survives arbitrary rewording of the strings and only fails when a new input starts being read — which is precisely the review moment you want.

The move generalises past privacy. Any requirement of the form **"A must not influence B"** — a masked field must not change a log line, a user's locale must not change a cache key, a debug flag must not change a rendered result — is an indistinguishability property, and asserting it directly is both cheaper and stronger than enumerating what B must not contain.

## When to Apply

- **Any "X must not appear in Y" test where X ranges over user content or a secret.** Ask what the enumerable set is. If the answer is "any function of X", a needle list cannot close it.
- **Reviewing a guard made entirely of `XCTAssertFalse(…contains…)`.** Ask what a *preview* or a *derived summary* of the forbidden input would do to it.
- **Whenever a surface takes a whole model object to read one field.** That is the shape where a later edit reaches for a second field without anyone noticing the rule.
- **When a change adds a legitimate dependency** to a surface that carried this kind of property: widen and re-assert on both sides of the new input, and record why the new channel cannot carry the forbidden content.
- **Not** where the rule is about a *known* pattern being transformed. `SecureFieldMaskerTests` asserts that a specific input shape produces a specific redaction label, which is a positive assertion about an enumerable set and the right instrument for that job — its own failure mode is a fixture caught by a broader rule than the one named (see [source-scan guard fidelity](./source-scan-guard-fidelity-2026-07-25.md), hook-guard section).
- **Not the same as sweeping a bounded value space.** Guard-fidelity's third shape replaces an enum-case enumeration with a `0...599` sweep — still an enumeration, just a complete one. Here the space is unbounded, and the property replaces enumeration entirely.

## Examples

**Before — samples the forbidden set:**

```swift
let secret = "my account password is hunter2 and the wire clears friday"
for word in ["password", "hunter2", "wire", "friday"] {
    XCTAssertFalse(payload.description.lowercased().contains(word))
}
// Green on a description ending "…: my account p…"
```

**After — constrains the function:**

```swift
let pairs: [(HistoryEntry, HistoryEntry)] = [
    (entry(text: "the wire clears friday", sourceApp: "Slack"),
     entry(text: "ship it monday", sourceApp: "Mail", failedChunkCount: 2)),
    // …and the same on the other side of the one permitted bit.
    (entry(text: marker, sourceApp: "Slack", failedChunkCount: 1),
     entry(text: "", sourceApp: "Mail", failedChunkCount: 2)),
]
for (a, b) in pairs {
    XCTAssertEqual(kind(a).payload, kind(b).payload)
}
```

**The requirement itself, rewritten.** Worth doing at the plan stage, not only at the test:

> R29. Neither the notice's title nor its description contains transcript content.

→ *The notice's payload is a function of the session summary, plus one Boolean read off the entry; nothing else about the entry reaches the panel.*

The second sentence is what the test asserts, and it is also the sentence a reviewer can check against the source arm in ten seconds.

## Related

- [`conventions/source-scan-guard-fidelity-2026-07-25.md`](./source-scan-guard-fidelity-2026-07-25.md) — the catalogue of guards that are green for the wrong reason. Checklist item 1 (needle-list rot) is the lexical cousin of this entry; the third shape's value-space sweep is the bounded-space cousin. This entry is the case where neither applies because the space cannot be enumerated at all.
- [`conventions/testing-spm-and-git-2026-05-15.md`](./testing-spm-and-git-2026-05-15.md) — where the authoring-time test habits live (prove the guard red; a fixture must be able to express the failure). This entry is the shape to reach for when the probe shows the needle list cannot.
- [`documentation-gaps/positive-spelling-ax-fixture-2026-05-18.md`](../documentation-gaps/positive-spelling-ax-fixture-2026-05-18.md) — the prompt-eval anti-leak test, still a needle-shaped negative assertion with no positive complement. The clearest open instance in the repo.
- [`conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`](./no-telemetry-with-statsstore-carveout-2026-05-15.md) — the privacy posture R29 serves.
- `NoType/UI/CLAUDE.md` invariant 8 — the notice's contract, including the widened property and the one permitted bit.
- Commits `9761252` (U4 implementation — the notice, with the needle-list guard), `9e51ffe` (review remediation: the indistinguishability property replaces the needle list as the coverage) and `a86195f` (the 2026-08-11 ruling: the property widened by one bit and asserted on both sides). Unit U4 of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`. All three SHAs are branch-local to `refactor/structural-gap-tracking` at time of writing and will be rewritten if that branch squash-merges; the plan path is the stable reference.
