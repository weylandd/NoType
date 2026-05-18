---
title: No telemetry in v1 (with local-only StatsStore carve-out)
date: 2026-05-15
category: conventions
module: privacy
problem_type: convention
component: tooling
severity: high
applies_when:
  - Adding any new outbound network call
  - Considering crash reporting, analytics, or usage metrics
  - Reviewing whether a "local only" feature actually stays local
tags: [telemetry, privacy, oss, statsstore, no-analytics, no-crash-reporting]
---

# No telemetry in v1 (with local-only StatsStore carve-out)

## Context

NoType ships open-source and privacy-respecting. Anything that leaves the device — telemetry, analytics, crash reporting — invites a "what does it send?" question that erodes the trust the product is built on.

But the Home tab does need usage stats (total words, time saved, per-day buckets, top apps). Those need to persist somewhere.

## Guidance

**Zero telemetry, zero analytics, zero crash reporting in v1. No data about the user or their dictation behavior leaves the device.**

**Local-only carve-out:** `StatsStore` (`~/Library/Application Support/NoType/stats.json`) keeps lifetime aggregates that drive the Home tab — total words, session count, per-day buckets, per-app totals. **It never leaves the device.** No network call ever touches this file. It's derived counts only — no transcripts, no audio, no PII.

**Token-usage extension (v4 schema, added by plan 2026-05-18-001 / U5):** the same `DayBucket` shape now also carries `tokenInput / tokenOutput / tokenCached` — Gemini's per-response token billing folded per local-calendar day. Same carve-out rules apply unchanged: token aggregates are local-only, never sent to Gemini, never persisted anywhere outside `stats.json`, and **never decremented on `deleteHistoryEntry`** (matches the long-standing rule for word counts — per-row history deletion is a transcript-preview redaction, not an analytics rewrite; a user who clears history doesn't accidentally zero out yesterday's billing summary). The Settings tab's API section reads these via `StatsSnapshot.tokenTotals(overLastDays:)` for the Today / 7d / 30d / All windows + derived cache hit rate; that read stays inside the process boundary.

## Why This Matters

- **OSS positioning.** A user can `nettop -p NoType` and see exactly what we send; the answer should be "API calls to Gemini, that's it, nothing else".
- **Crash reports can come later as opt-in.** Sentry or similar — but only when a real "we couldn't reproduce this" pattern emerges, and only with explicit user consent.
- **The carve-out is necessary because StatsStore looks like analytics from the outside.** Without explicit documentation, a security-minded reviewer would read "writes per-day buckets to disk" and assume it phones home. The carve-out paragraph in this file is the contract that says no.

## When to Apply

- Adding any outbound network call: it must go to Gemini (or the appcast feed); anything else needs a fresh discussion.
- Adding any persistent counter / aggregate: confirm explicitly that it never leaves the device, and add a similar carve-out paragraph if it could be misread.
- Reconsider the no-telemetry stance when: actual stability complaints arrive that we can't reproduce. Then add **opt-in** crash reporting only.

## Examples

**The carve-out in code:** `StatsStore` doesn't import `URLSession`, doesn't import `Network`, has no networking surface. It's pure file I/O + in-memory aggregation. The only writers are `AppState.finalizeRecording` (post-session) and the read path is the Home tab's `appState.statsSummary` mirror.

**StatsSnapshot schema** (no transcripts, derived counts only — `NoType/History/StatsStore.swift`, v4):

```swift
struct StatsSnapshot: Codable, Sendable, Equatable {
    var version: Int            // current 4 — v3 → v4 migration is purely additive
    var totalWords: Int
    var totalSessions: Int
    var totalDurationSeconds: Double
    var totalDurationWords: Int
    var dayBuckets:    [String: DayBucket]   // DayBucket carries tokenInput/Output/Cached in v4
    var appBuckets:    [String: AppBucket]
    var dayAppBuckets: [String: [String: DayBucket]]
}
```

**Related local-only state:**

- `HistoryStore` (last 10 transcripts) — see `solutions/architecture-patterns/json-history-store-2026-05-15.md`.
- `InstructionsStore` (per-app categorization) — see `solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md`.
- `DictionaryStore` (personal dictionary) — see `solutions/architecture-patterns/personal-dictionary-2026-05-15.md`.
- Keychain (Gemini API key) — see `solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md`.

All of the above are local-only by construction.

## Related

- `NoType/History/CLAUDE.md` "Lifetime stats" — StatsStore implementation.
- `docs/decisions.md` ADR-013 — legacy index entry, redirects here.
- `solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md` — the BYOK decision that makes "no billing relationship" feasible.
