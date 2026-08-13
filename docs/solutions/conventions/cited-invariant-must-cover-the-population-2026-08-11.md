---
title: A correct call justified by the wrong invariant licenses the wrong change
date: 2026-08-11
category: conventions
module: Gemini
problem_type: convention
component: documentation
severity: medium
applies_when:
  - "A comment justifies mutating shared infrastructure (a connection pool, a cache, a global pasteboard, a process-wide hook) by citing an invariant about a narrower logical unit"
  - "Reviewing a diff whose comment reads \"X is safe because <named invariant>\""
  - "Choosing between adjacent APIs of different destructiveness, where the written justification is what decides which one the next maintainer picks"
  - "An invariant citation was written when one code path used a resource and several use it now"
tags: [invariants, scope, code-comments, review, shared-state, urlsession, justification]
related_components: [Gemini, Recording, AppState]
---

# A correct call justified by the wrong invariant licenses the wrong change

## Context

`GeminiClient` drops `URLSession`'s pooled connections before a network-class retry (R28 / KTD13 of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`). The failure that motivated it presented as a dead pooled *connection* rather than a dead network — a request stalled for the whole request budget — a flat 30 s at the time it was measured, since replaced by a per-request function of the audio-part count — while the same payload answered in 1.7 s on a new connection moments later — so re-issuing over the same socket re-inherits the fault and merely doubles the wait. `flushPooledConnections()` therefore runs mid-session, inside `sendRequest`'s retry loop, while other work may be in flight. Whether that is safe needs an argument. The shipped one was:

```swift
/// Safe to call mid-session because of invariant I1 — at most one
/// request is outstanding per session, so there is no sibling request
/// whose connection this could pull out from under.
```

The call is safe. The reason is wrong, and it is wrong in a way that reads as authoritative, because it cites a numbered architecture invariant by name.

I1 reads: **"One Gemini request in flight per session. New chunks queue and may batch into one round-trip."** (`docs/architecture/overview.md:111`; restated at `NoType/Gemini/CLAUDE.md:15`.) Its subject is one **recording** session's transcription traffic. The population `flush` touches is every connection on the client's single `URLSession` (`NoType/Gemini/GeminiClient.swift:196`), and two other methods use it: `classifyApp` (`:362`) and `validateKey` (`:502`) each issue their own `session.data(for:)` and bypass `sendRequest` — and its retry loop, and its reachability pre-check — entirely. `classifyApp` is worse than a hypothetical sibling: `AppState.handleHotkeyPress` (`NoType/AppState.swift:1363`) fires it into an unstructured `Task` immediately after `session.start(...)` (`:1487` → `:2321`), so a classifier request racing a transcription request is the *normal* shape of a first dictation in an unfamiliar app, not a corner.

Note the trap in the invariant's own wording. I1 says "per session", and the object a reader sitting in `GeminiClient` reaches for is `URLSession`. The word is doing double duty across two unrelated types, and the citation is exactly where that ambiguity gets to hide.

## Guidance

**For any claim of the form "X is safe because INVARIANT", check that the invariant's stated scope covers the population X actually touches — not the population you had in mind when you wrote it.** The two diverge whenever the invariant is scoped to a *logical* unit (a session, a request, a transaction) and the mechanism is scoped to a *physical* one (a connection pool, a URL cache, a file handle, a process-wide singleton). The invariant stays true; it simply is not about the thing being claimed.

The correct justification here is a property of the primitive, not of the traffic: `flush(completionHandler:)` clears the idle connection cache and affects only *future* requests — it does not cancel or disturb tasks already running. Its two neighbours do not share that property: `invalidateAndCancel()` cancels outstanding tasks outright, and `reset(completionHandler:)` tears down cookie, credential and cache state *underneath* running tasks, with a blast radius Foundation does not narrow — reason enough not to reach for it. Nothing in the file stops a maintainer substituting either (`NoType/Gemini/GeminiClient.swift:1140`). That primitive's contract is now the load-bearing term of the whole claim: if it were false the call would be unsafe, and I1 would not have saved it.

Note where that leaves the evidence. The justification moved from an invariant this repo owns and can check, to a framework contract it can only cite — which is a real trade, not a free win. It is the right trade here because the framework contract is the thing the safety actually depends on, but it means the claim is now only as good as the API documentation behind it, and no test in this repo will ever go red if that reading is wrong. Say so at the call site rather than letting the confident tone carry over from the invariant that was replaced.

**The substitution is why a wrong justification is not merely untidy.** A reader who believes "we are the only request in flight" has no reason to prefer `flush` over `reset` — under that premise both are safe, and `reset` is the more thorough-sounding one. The bad citation does not just fail to defend the call; it actively **licenses the more destructive API**. Generalised: *a correct conclusion resting on a wrong justification is a latent defect, because the next reader reasons from the justification, not from the conclusion.*

Two habits follow:

- **Name the mechanism first, the invariant second.** If the safety is a property of the API being called, say that; an invariant citation is then supporting context rather than the load-bearing term. If you cannot state the mechanism, the invariant is probably not carrying the claim either.
- **Write the negative explicitly.** The corrected comment names `reset` and `invalidateAndCancel` as forbidden substitutes. A justification that only explains why *this* call is fine leaves the boundary of "fine" undefined — and the next edit in this area is usually a substitution, not a deletion.

**Fix the upstream wording too, not only the citation.** The miscitation had a source: `serial-gemini-actor-2026-05-15.md` described I1 as "the **global** rule … one in-flight HTTP request per session at a time", which is a fair reading of the rule as originally written and is false of the shared `URLSession` today. A citation error whose premise is copied verbatim out of a solutions doc will be made again by the next reader; correcting only the comment leaves the generator in place. That entry now carries an explicit scope boundary naming `classifyApp` and `validateKey`.

## Why This Matters

Nothing was broken. That is the hazard: no failing test, no reproduction, no symptom, so the defect is reachable only by reading — and reading is exactly the activity a citation is designed to shorten. A numbered invariant with its own solution doc is the strongest available form of "you can stop thinking here" in this repo, which makes a mis-scoped one the most expensive kind of comment to get wrong.

The error is also self-concealing in review. `flushPooledConnections` sits inside `sendRequest`, whose entire concern *is* one recording session's traffic; from that vantage I1 is obviously the relevant invariant. Catching it needs the opposite question — not *what is this function about* but *what does this call reach* — and the answer was two greps away.

There is no mechanical guard for this class, and inventing one would be worse than the gap. A test that asserted "the comment cites the right invariant" would be a string match on prose, with every failure mode described in [`source-scan-guard-fidelity`](./source-scan-guard-fidelity-2026-07-25.md) and none of the value. This is a review question, and it stays one.

## When to Apply

- **Any comment justifying a mutation of shared infrastructure** — a connection pool, a URL cache, `NSPasteboard.general`, a Keychain item, a `UserDefaults` suite, a process-wide hook — by citing an invariant about a narrower logical unit.
- **Reviewing a diff that says "safe because &lt;invariant&gt;".** Read the invariant's own wording rather than the paraphrase, then enumerate the callers of the thing being mutated.
- **Choosing between adjacent APIs of different destructiveness** (`flush` / `reset` / `invalidateAndCancel`; `remove` / `deleteAll`; `cancel` / `invalidate`). The written justification is what decides which one the next maintainer picks.
- **Any invariant citation written when one path used a resource and several use it now.** The population widened underneath a claim nobody re-read.
- **When an invariant's subject noun is ambiguous across two types in scope** — "session", "request", "context", "client". Check which one the invariant means before citing it, and say which one in the citation.

## Examples

**Wrong** (`0bb8286`) — a true statement about the wrong population:

```swift
/// Safe to call mid-session because of invariant I1 — at most one
/// request is outstanding per session, so there is no sibling request
/// whose connection this could pull out from under.
```

`classifyApp` is one such sibling, launched fire-and-forget by the recording-start path itself.

**Right** (`NoType/Gemini/GeminiClient.swift:1140`) — the mechanism carries the claim, the invariant is explicitly demoted, and the boundary is named:

```swift
/// **Safe while a sibling request is outstanding — and invariant I1 is
/// not the reason.** I1 bounds one *recording* session's transcription
/// traffic to one in-flight request; it says nothing about
/// `classifyApp` and `validateKey`, which share this same `session` and
/// bypass `sendRequest` entirely. … What makes the call safe is the
/// primitive: `flush` clears the idle connection cache and affects only
/// *future* requests; it does not cancel or disturb tasks already
/// running. **Do not substitute `reset(completionHandler:)` or
/// `invalidateAndCancel()`** — those do disturb concurrent work, and
/// nothing in this file would stop them.
```

Note that the corrected form states the invariant it is *not* relying on. That is deliberate: the next reader's most likely move is to re-derive the original claim, so the entry has to be closed explicitly rather than merely left out.

## Related

- [`guard-scope-must-match-invariant-scope`](./guard-scope-must-match-invariant-scope-2026-08-09.md) — the sibling, and the reason this is a separate entry rather than an amendment to it. That one is about **where a check goes**: a guard at the producer site enforces only the producer's extent, so move it to the shared latch. This one is about **what a citation licenses**, with no check misplaced and no code to move. Its tell — "a local boolean is read to decide something whose contract is written in wider terms" — does not find this shape, because the mis-scoped term is in a comment.
- [`source-scan-guard-fidelity`](./source-scan-guard-fidelity-2026-07-25.md) — the same review posture applied to tests instead of comments: *would this be green under the worst outcome in this area?* Its "Documentation that licenses the blind spot back in" example is the closest prior statement of the harm this entry generalises. The other three learnings from this same unit landed there.
- [`testing-spm-and-git`](./testing-spm-and-git-2026-05-15.md) > Comments — the base rule this specialises: "a comment that asserts behaviour is a claim, and a false one is worse than no comment". The three instances collected there are claims that are simply false about local behaviour; this one invokes a real, correctly-stated invariant and misapplies its extent, which is why it reads as rigorous.
- [`architecture-patterns/serial-gemini-actor-2026-05-15.md`](../architecture-patterns/serial-gemini-actor-2026-05-15.md) — I1 itself, and what it is actually about. Read before citing it; its scope boundary was added by this learning.
- `NoType/Gemini/CLAUDE.md` "Retry policy" — carries the corrected claim as a module rule, alongside the twin-predicate note.
- Commits `0bb8286` (U1 implementation — introduced the flush and the I1 citation) and `68c67bf` (review remediation — corrected the justification and named the forbidden substitutes). Unit U1 of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`. Both SHAs are branch-local to `refactor/structural-gap-tracking` at time of writing and will be rewritten if that branch squash-merges; the plan path is the stable reference.
