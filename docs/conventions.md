# Coding conventions

Living rules for NoType's code. Each convention lives as a per-topic file under [`docs/solutions/conventions/`](solutions/) following the compound-engineering knowledge-track shape (`Context → Guidance → Why This Matters → When to Apply → Examples → Related`). This file is the index.

> **Migration note:** the long-form rules previously inlined in this file moved to `docs/solutions/conventions/` PR-by-PR. The split files are the authoritative source; this index just routes to them.
>
> **Adding a new convention?** Write a new file in `docs/solutions/conventions/<slug>-<YYYY-MM-DD>.md` and add a one-line link below.

## Current conventions

- [Swift 6 strict concurrency and async](solutions/conventions/swift-6-concurrency-and-async-2026-05-15.md) — strict mode on; actor / `@MainActor` / `@unchecked Sendable` rules; `async`/`await` style; cancellation.
- [Module architecture, DI, and naming](solutions/conventions/module-architecture-and-naming-2026-05-15.md) — MVVM with `@Observable`; initializer-only DI; module-owned errors; one type per file.
- [Force-unwrap, error handling, and logging](solutions/conventions/force-unwrap-error-and-logging-2026-05-15.md) — no force-unwrap policy; error model (recoverable / programming / user-facing); `os.Logger` rules and privacy annotations.
- [Testing, SPM dependency, and Git/PR hygiene](solutions/conventions/testing-spm-and-git-2026-05-15.md) — unit-test expectations; security / Gemini hard-rule tests; SPM allow-list; Conventional Commits; comments explain *why*.
- [Guard scope must match invariant scope](solutions/conventions/guard-scope-must-match-invariant-scope-2026-08-09.md) — a check at the site that produces the state enforces only that site's extent; a session/object-wide invariant belongs on the shared latch every terminal path already passes through. The tell: a local boolean (`didFail`, `isCancelled`) deciding something whose contract is written in wider terms.
- [Reconcile an optimistic mirror by union, not replace](solutions/conventions/reconcile-optimistic-mirror-by-union-2026-08-09.md) — an in-memory mirror updated synchronously ahead of a fire-and-forget write is deliberately ahead of its store; a cleanup keyed on "what the source of truth currently says" destroys pending state. Union both views. Cleanups bite hardest because their failure mode is deletion.
- [Gate an irreversible action on the outcome, not the input that predicts it](solutions/conventions/gate-irreversible-actions-on-the-outcome-2026-08-09.md) — releasing the only copy of something on "the call returned text" rather than "the text landed" destroys it silently. The tell: a boolean whose *name* describes the input, gating an action whose correctness depends on the output. Make the operation report its own effect instead of letting the caller re-derive it.
- [Source-scan guard fidelity](solutions/conventions/source-scan-guard-fidelity-2026-07-25.md) — a guard that only asserts absence stays green when the feature is dead; pin the destination too; needle-list rot, identifier boundaries, transitive depth, stored-property defaults, and the scan's own discovery set (default arguments are invisible to an init-body walk); the same trap in hook-install, fixture-shape and step-ordering guards; prove the guard red.

## Related conventions (treated as decisions, not conventions)

A handful of policies that read as conventions but are actually load-bearing product decisions — they live in `docs/solutions/` under other categories:

- [No telemetry in v1 (with local-only StatsStore carve-out)](solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md) — privacy stance, lifetime stats exception.
- [BYOK Gemini API key, stored in Keychain](solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md) — credentials handling decision.
