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

## Related conventions (treated as decisions, not conventions)

A handful of policies that read as conventions but are actually load-bearing product decisions — they live in `docs/solutions/` under other categories:

- [No telemetry in v1 (with local-only StatsStore carve-out)](solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md) — privacy stance, lifetime stats exception.
- [BYOK Gemini API key, stored in Keychain](solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md) — credentials handling decision.
