# History module

Two siblings: the rolling **last-10** transcript window (`HistoryStore`) and the **lifetime** usage aggregate (`StatsStore`). Both are plain JSON, no encryption. Different files; the cap on history doesn't bound stats.

## Files

- `HistoryStore.swift` — `actor` for the last-10 transcript JSON. FIFO eviction.
- `HistoryEntry.swift` — `Codable` model shared by both stores.
- `StatsStore.swift` — `actor` for `stats.json`: totals + per-day + per-app aggregates.

## Invariants

1. **`HistoryStore` cap = 10.** Append at the cap drops the oldest.
2. **`allEntries()` returns oldest-first**; popover and `HomeView` sort newest-first for display.
3. **`remove(id:)` is a no-op if the id isn't present.** Drives the popover's per-row trash button through `AppState.deleteHistoryEntry(id:)`: optimistic in-memory update + fire-and-forget disk write.
4. **No audio retention** (architecture invariant I4) — only `text` is stored.
5. **`StatsStore` keeps derived counts only — no transcripts.** Honours the no-audio-retention + history-cap=10 privacy posture; a user who clears history doesn't have transcripts hiding in stats either.
6. **Local-TZ day keys** (`Calendar.autoupdatingCurrent`) — a session at 23:45 May 11 local lands in the May 11 bucket, not May 12 UTC.
7. **Last-seen display name wins** in `appBuckets[bundleID].name`. App renames pick up without manual reconciliation.
8. **`StatsStore.record` is NOT idempotent.** Callers must not call it twice for the same session.

## Hard rules

- **`StatsSnapshot.init(from:)` is a tolerant decoder** — every field is `decodeIfPresent` with a default. v1 files (no `dayAppBuckets`) load with `[:]`. v2 files are healed on read via `healIfPreV3` (duration fields zeroed, version → 3). Text totals are preserved.
- **Don't decrement counts on `deleteHistoryEntry`.** Deleting a history row removes the transcript preview but leaves aggregate counts alone — treating the per-row trash as "redact from analytics too" would let a user silently zero out yesterday's word count, which is more confusing than helpful.
- **Two independent wipe paths.** `HistoryStore.deleteAll()` (driven by `AppState.deleteAllHistory()`, Settings → "Delete all transcripts") clears the last-10 transcripts but leaves `StatsStore` alone. `StatsStore.deleteAll()` (driven by `AppState.deleteAllStats()`, Settings → "Delete all analytics") clears every aggregate but leaves the transcripts alone. Don't combine them — the explicit two-button UX is the contract.
- **Don't backfill stats from existing `history.json`.** No de-duplication metadata. Stats start accumulating from the first session under the StatsStore-aware build.
- **`stats.json` never leaves the device.** No network call touches this file. Local-only carve-out documented in `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.

## Schema

**`HistoryEntry`:**

```swift
struct HistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let sourceAppName: String      // "Slack"
    let sourceBundleID: String     // "com.tinyspeck.slackmacgap"
    let timestamp: Date
    let durationSeconds: Double    // press → release; 0 for pre-duration rows (tolerant decode)
}
```

Storage: `~/Library/Application Support/NoType/history.json`, top-level array of `HistoryEntry`.

**`StatsSnapshot` (v5):**

```swift
struct StatsSnapshot: Codable, Sendable, Equatable {
    var version: Int                                    // current 5
    var totalWords: Int
    var totalSessions: Int
    var totalDurationSeconds: Double                    // measured sessions
    var totalDurationWords: Int                         // word count for the same sessions
    var dayBuckets:    [String: DayBucket]              // dayKey → totals across all apps
    var appBuckets:    [String: AppBucket]              // bundleID → lifetime per-app totals
    var dayAppBuckets: [String: [String: DayBucket]]    // dayKey → bundleID → bucket
}
```

`DayBucket { words, sessions, durationSeconds, durationWords, tokenInput, tokenOutput, tokenCached, tokensByModel }`. The flat `tokenInput/Output/Cached` are the **cross-model aggregate** (drive the Input/Output count cells + v4-reader downgrade safety); `tokensByModel: [String: ModelTokens]` (keyed by `GeminiModel.rawValue`, `ModelTokens { input, output, cached }`) is the **per-model split** the cost cell prices each slice with. The sum across `tokensByModel` equals the flat fields (pinned by `test_record_dualWrite_flatEqualsSumOfPerModel`). `AppBucket { name, words, sessions }`. Storage: `~/Library/Application Support/NoType/stats.json`.

**Migration:**
- v3→v4 via `healIfPreV4` — purely additive (flat token fields default to 0 via tolerant decode).
- v4→v5 via `healIfPreV5` — adds `tokensByModel`; for buckets carrying flat tokens but no per-model split it **attributes them to Flash-Lite** (the only model that existed pre-v5), on both `dayBuckets` and `dayAppBuckets`, so historical cost still prices correctly. Idempotent (`guard version < 5` + per-bucket `tokensByModel.isEmpty` short-circuit; pinned by `test_migration_v5File_isIdempotent`). Flat fields preserved verbatim — a v4 reader of a v5 file drops `tokensByModel` via `decodeIfPresent ?? [:]`, so downgrade stays safe.

**Wiring:** the single write point for stats is `AppState.finalizeRecording()`'s success arm, calling `await statsStore.record(entry, tokens: session.summary.tokens, model: session.summary.model)`. `record` increments both the flat aggregate and `tokensByModel[model]`. The `model:` parameter defaults to `.flashLite` for the legacy `record(entry:)` / `record(entry, tokens:)` shims used by the test surface. The API & Usage cost cell sums per-model via `GeminiPricing.cost(perModel: tokenTotalsByModel(...))`. See `NoType/Gemini/CLAUDE.md` for how `TokenUsage` flows out of `GeminiClient.transcribeWithUsage*` overloads.

## Failure modes (both stores)

| Situation | Behaviour |
|---|---|
| File doesn't exist | Empty list / snapshot. Create on first write. |
| File is corrupt JSON | Log + rename to `<name>.json.corrupt-{ts}` + start fresh. |
| Disk full on write | Log. In-memory state stays accurate until next launch. |
| Concurrent writes from two app instances | Not supported — NoType is effectively single-instance via `LSUIElement`. No defensive PID-lock today. |

## Wiring

`AppState` (`@MainActor @Observable`) owns the SwiftUI-facing mirrors `history: [HistoryEntry]` and `statsSummary: StatsSnapshot`. Single write point for stats is `AppState.finalizeRecording()`'s success arm: after `history.append(entry)` succeeds, a detached `Task` calls `await statsStore.record(entry)` and assigns the returned snapshot back.

`HomeView` reads `statsSummary` (windowed by `HomeRange`: 7D / 30D / 90D / All); only the bottom "Recent transcripts" list reads `history`. The popover reads `history` for the last-10 list.

## Testing

- `NoTypeTests/HistoryStoreTests` — round-trip, FIFO eviction at the 10-entry boundary, corruption recovery (garbage JSON → renamed → empty list).
- `NoTypeTests/StatsStoreTests` — empty-state, single record, accumulation across sessions / days / apps, last-seen-name wins, empty-bundle skip, disk persistence round-trip, corruption recovery, day-key format. Per-test temp directory — no shared state.
- No integration test against the real filesystem — use a temp directory.

## Pointers

- Why JSON + last-10 (not SQLite, not encrypted) → `solutions/architecture-patterns/json-history-store-2026-05-15.md`.
- Why StatsStore is local-only (no-telemetry carve-out) → `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
- Home tab's data flow (`statsSummary`, `HomeRange`, top-apps) → `NoType/UI/CLAUDE.md`.
