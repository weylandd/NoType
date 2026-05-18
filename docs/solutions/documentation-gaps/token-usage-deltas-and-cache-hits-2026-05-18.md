---
slug: token-usage-deltas-and-cache-hits
created: 2026-05-18
status: open
size: M
category: documentation-gaps
---

# Token usage panel — period-over-period deltas + cache-hits indicator

## Context

The redesigned Settings → API & Usage pane (plan
`2026-05-18-003-feat-settings-redesign-plan.md`) renders Input / Output
/ Cost cells over a `TokenStatsRange` picker (Today / 7d / 30d / All).

The source design (`app/settings.html`) also shows:

1. A sub-caption beneath each numeric cell with a per-period delta
   (`+18% vs prev. 30d`, `+12% vs prev. 30d`, `Flash-Lite · cache-read`).
2. A right-aligned header indicator next to the range picker
   (`Cache hits · 71%`).

Both were intentionally omitted in v1 to avoid shipping placeholder
numbers (user-confirmed during planning).

## Guidance

Add the deltas and cache-hits in a follow-up PR. Two surface-level
gaps to close first:

1. **StatsStore — prior-period rollup.** `tokenTotals(overLastDays:)`
   currently returns one snapshot. Add a companion
   `tokenTotalsWithPriorPeriod(overLastDays:)` that returns the
   `(current, prior)` pair so the panel can render the delta without
   a second pass.
2. **Per-call cache-hit count.** Gemini's response carries cache-read
   token counts in `UsageMetadata`; `StatsStore.record(_:tokens:)`
   already accepts a `TokenUsage` value but doesn't yet store the
   cached fraction separately as a hit count. Surface
   `dayBuckets[d].tokenCached / dayBuckets[d].tokenInput` ratio in
   the same call site, then expose a `cacheHitRate(overLastDays:)`
   accessor.

UI-side, the `TokenStatsPanel` already exposes
`currentRangeScope` — wire the range scope into the parent card's
meta and add a small inline pill rendering the cache-hit percentage
to the right of the range picker.

## Why This Matters

The current panel reads as informational rather than diagnostic.
Period-over-period deltas turn it into a feedback loop — users notice
when their usage jumps (a setting change, a new app, a chunking
regression) instead of having to do mental math against last week.
Cache-hit % is the single metric that tells a user "is your prompt
shape good?" — surfacing it next to cost makes the connection
visible.

## When to Apply

Add the deltas + cache-hits whenever:

- StatsStore prior-period rollup is being touched anyway (e.g. another
  feature needs week-over-week comparison).
- A user reports unexplained billing drift.
- Performance tuning of the cache-prefix shape lands; verifying the
  hit rate in production is otherwise blind.

## Examples

Reference design (from the design handoff bundle):

```html
<div class="usage-cell">
  <div class="usage-label">Input</div>
  <div class="usage-value">3,184,920 <span class="unit">tok</span></div>
  <div class="usage-sub">+18% vs prev. 30d</div>
</div>
...
<span>Cache hits · 71%</span>
```

## Related

- `NoType/UI/Settings/TokenStatsPanel.swift`
- `NoType/History/StatsStore.swift` (`tokenTotals(overLastDays:)`)
- `NoType/Gemini/GeminiClient.swift` (`UsageMetadata` parsing)
- Source plan: `docs/plans/2026-05-18-003-feat-settings-redesign-plan.md`
