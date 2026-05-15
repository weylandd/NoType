# Architecture

**This file is an index.** The current-state snapshot lives in [`docs/architecture/overview.md`](architecture/overview.md); the rationale (why each piece exists, what was rejected, what we tried) lives in [`docs/solutions/`](solutions/).

The old monolithic `architecture.md` (long-form data-flow + invariants + history + non-goals) was split per the compound-engineering convention:

| Old section | Now at |
|---|---|
| ASCII data-flow diagram | [`architecture/overview.md`](architecture/overview.md) "Data flow" (Mermaid) |
| Module list | [`architecture/overview.md`](architecture/overview.md) "Modules" |
| External integrations | [`architecture/overview.md`](architecture/overview.md) "External integrations" |
| Threading model | [`architecture/overview.md`](architecture/overview.md) "Threading model" |
| Invariants I1–I7 | [`architecture/overview.md`](architecture/overview.md) "Invariants" — each links to the per-decision file in `docs/solutions/` |
| Sequence of one push-to-talk session | (current behaviour — derive from code; see per-module `CLAUDE.md`s) |
| Error & cancellation paths | (current behaviour — see per-module `CLAUDE.md`s) |
| "What's NOT in this diagram (and why)" | individual entries in [`docs/solutions/`](solutions/) under design-patterns / architecture-patterns |

When a section in `overview.md` drifts from the code, **regenerate the snapshot** rather than editing it for accuracy:

> Regenerate `docs/architecture/overview.md` with a current Mermaid diagram, module table, external-integrations list, threading model, and invariants — no history, only current state.

That keeps the snapshot honest and the rationale + history in `docs/solutions/` where it survives drift.
