# History module

Two siblings: the rolling **last-10** transcript window (`HistoryStore`) and the **lifetime** usage aggregate (`StatsStore`). Both are plain JSON, no encryption. Different files; the cap on history doesn't bound stats.

## Files

- `HistoryStore.swift` — `actor` for the last-10 transcript JSON. FIFO eviction.
- `HistoryEntry.swift` — `Codable` model shared by both stores.
- `StatsStore.swift` — `actor` for `stats.json`: totals + per-day + per-app aggregates.
- `RetainedAudioStore.swift` — `@MainActor` in-memory holder for a broken row's failed-chunk audio, keyed by `HistoryEntry.id`. Never serialized; eviction mirrors the ten-entry cap via `retain(only:)`.
- `RetryMerge.swift` — pure gap-slot merge: how a retry's per-chunk results land back in the row they were re-sent from. Consumed by `AppState.retryEntry(id:)` / `settleRetry`.

## Invariants

1. **`HistoryStore` cap = 10.** Append at the cap drops the oldest.
2. **`allEntries()` returns oldest-first**; popover and `HomeView` sort newest-first for display.
3. **`remove(id:)` is a no-op if the id isn't present.** Drives the popover's per-row trash button through `AppState.deleteHistoryEntry(id:)`: optimistic in-memory update + fire-and-forget disk write. **`update(_:)` shares that contract** — it replaces the row with the matching id **in place** and no-ops when absent. In place, not remove-then-append: a retry rewrites a broken row's text and failure count without changing what the row *is*, and re-appending would reorder the last-10 list and move the trim onto a different victim.
4. **Nothing audio-shaped is ever persisted** (architecture invariant I4). `history.json` stores `text` and `failedChunkCount` — never audio. The one carve-out is `RetainedAudioStore`, which holds a broken row's failed-chunk audio **in memory only, for the lifetime of the process**, keyed by that row's id. It is never serialized: not into `history.json` beside the entry, not into a side-car, not into a crash-recovery cache. That is why a row whose process died comes back **dead** (rendered as broken, minus the retry action) — the audio being gone is the designed outcome, not a gap to fill. Adding `Codable` to `RetainedRecording`, or persisting the holder, is a scope violation rather than a refactor; `RetainedRecordingTests.test_retainedRecording_isNotSerializable` is the mechanical half of that guard. Release triggers and the single eviction point (`retain(only:)`) are documented on `RetainedAudioStore` itself.
5. **`StatsStore` keeps derived counts only — no transcripts.** Honours the nothing-audio-on-disk + history-cap=10 privacy posture; a user who clears history doesn't have transcripts hiding in stats either.
6. **Local-TZ day keys** (`Calendar.autoupdatingCurrent`) — a session at 23:45 May 11 local lands in the May 11 bucket, not May 12 UTC.
7. **Last-seen display name wins** in `appBuckets[bundleID].name`. App renames pick up without manual reconciliation.
8. **`StatsStore.record` is NOT idempotent.** Callers must not call it twice for the same session. **`recordTokens(_:model:timestamp:bundleID:appName:)` is the token-only sibling** for callers that must record spend *without* counting a session: it folds usage into the day and day×app buckets and touches neither `totalSessions`, `totalWords`, nor the duration fields. **The two are exclusive per retry run, and that is what makes R15 hold.** `settleRetry` reaches `record` at most once per history entry — on the first retry that recovers text for a row lifetime stats never counted (`isBroken && text.isEmpty`) — and takes `recordTokens` on every other arm, including the ones that recovered nothing or settled onto a deleted row. Never both: `record` folds the same usage itself, so calling `recordTokens` beside it would double-count the spend. Read "a retry records its tokens every time" as a statement about the *spend*, not about which method runs. (`recordRetryTokens` additionally no-ops on `.zero`, so a run that spent nothing writes nothing.) Both write the flat aggregate and the per-model split through one `addTokens` helper so they cannot drift.

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
    let failedChunkCount: Int      // chunks pasted as "[…]"; 0 for pre-retry rows (tolerant decode)
    var isBroken: Bool { failedChunkCount > 0 }   // computed — never encoded
}
```

`failedChunkCount` mirrors `SessionSummary.failedChunkCount`. **Only the count is
persisted** — the audio those chunks would need for a re-send lives in memory
(`NoType/Recording/RetainedRecording.swift`) and is deliberately not part of the
entry. `isBroken` is the single predicate for "this row is broken"; call sites
read it rather than re-deriving `failedChunkCount > 0`.

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

**Wiring:** the primary write point for stats is `AppState.finalizeRecording()`'s success arm, calling `await statsStore.record(entry, tokens: session.summary.tokens, model: session.summary.model)`. `record` increments both the flat aggregate and `tokensByModel[model]`. **A retry is the second write point** — `AppState.settleRetry` records the run's spend whatever its outcome, through `recordTokens(...)` on every arm except the one that counts the session, which reaches `record` and folds the same usage itself. `record` is reached at most once per history entry, per invariant 8. Sessions and words are therefore still counted exactly once per entry across both paths. The `model:` parameter defaults to `.flashLite` for the legacy `record(entry:)` / `record(entry, tokens:)` shims used by the test surface. The API & Usage cost cell sums per-model via `GeminiPricing.cost(perModel: tokenTotalsByModel(...))`. See `NoType/Gemini/CLAUDE.md` for how `TokenUsage` flows out of `GeminiClient.transcribeWithUsage*` overloads.

## Failure modes (both stores)

| Situation | Behaviour |
|---|---|
| File doesn't exist | Empty list / snapshot. Create on first write. |
| File is corrupt JSON | Log + rename to `<name>.json.corrupt-{ts}` + start fresh. |
| Disk full on write | Log. In-memory state stays accurate until next launch. |
| Concurrent writes from two app instances | Not supported — NoType is effectively single-instance via `LSUIElement`. No defensive PID-lock today. |

## Wiring

`AppState` (`@MainActor @Observable`) owns the SwiftUI-facing mirrors `history: [HistoryEntry]` and `statsSummary: StatsSnapshot`. The primary stats write point is `AppState.finalizeRecording()`'s success arm: after `history.append(entry)` succeeds, a detached `Task` calls `await statsStore.record(entry, tokens: session.summary.tokens, model: session.summary.model)` and assigns the returned snapshot back to `statsSummary` on the main actor. `AppState.settleRetry` is the second (see Schema → Wiring).

`HomeView` reads `statsSummary` (windowed by `HomeRange`: 7D / 30D / 90D / All); only the bottom "Recent transcripts" list reads `history`. The popover reads `history` for the last-10 list.

**Broken rows and retry.** A session that lost chunks in the recoverable class writes a broken row (`failedChunkCount > 0`) rather than being discarded, and `AppState` stores that session's `SessionSummary.retained` payload in `RetainedAudioStore` under the new row's id. `AppState.retryEntry(id:)` re-sends the payload's chunks one at a time and `settleRetry` lands the results through `RetryMerge`; `retryingEntryID` is the single in-flight slot both the popover and the Home tab read, so a retry started in either surface shows as busy in both. Two rules the mirror imposes on this module:

- **The optimistic mirror is part of the eviction input.** `refreshHistory` calls `retainedAudio.retain(only: liveHistoryIDs.union(mirrored))` — reloading from disk alone would evict the audio of a row appended into the mirror whose persist `Task` hasn't run yet, leaving a retry button with nothing behind it.
- **`RetainedAudioStore.take` hands out the only copy.** Every exit from a retry must re-put what it did not recover, including the recovered-nothing exit. Nothing else holds a reference and no test can observe the loss.

## Testing

- `NoTypeTests/HistoryStoreTests` — round-trip, FIFO eviction at the 10-entry boundary, corruption recovery (garbage JSON → renamed → empty list), plus `update(_:)`'s in-place / no-op-when-absent contract and `failedChunkCount`'s tolerant decode.
- `NoTypeTests/StatsStoreTests` — empty-state, single record, accumulation across sessions / days / apps, last-seen-name wins, empty-bundle skip, disk persistence round-trip, corruption recovery, day-key format. Per-test temp directory — no shared state.
- `NoTypeTests/RetainedAudioStoreTests` — put / peek / take / remove, `retain(only:)` as the single eviction path, and the non-serializability guard behind invariant 4.
- `NoTypeTests/RetryMergeTests` — the pure gap-slot merge: positional marker substitution, what counts as a recovery (`nil` and whitespace-only do not), the `placed` flags the release path reads, and the degrade-safely branches.
- `NoTypeTests/AppStateRetentionTests` / `AppStateRetryTests` — broken-row recording, mirror-union eviction, the `canRetry` predicate, and the retry run's settle arms.
- No integration test against the real filesystem — use a temp directory.

## Pointers

- Why JSON + last-10 (not SQLite, not encrypted) → `solutions/architecture-patterns/json-history-store-2026-05-15.md`.
- Why StatsStore is local-only (no-telemetry carve-out) → `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
- Home tab's data flow (`statsSummary`, `HomeRange`, top-apps) → `NoType/UI/CLAUDE.md`.
- What produces a retained payload, and the classifier that decides → `NoType/Recording/CLAUDE.md` "Retention for retry".
- Why every retry exit must re-put what it didn't recover (the destructive `take`) → `solutions/conventions/gate-irreversible-actions-on-the-outcome-2026-08-09.md`.
- Why eviction reconciles disk ∪ mirror rather than disk alone → `solutions/conventions/reconcile-optimistic-mirror-by-union-2026-08-09.md`.
