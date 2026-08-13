# History module

Two siblings: the rolling **last-10** transcript window (`HistoryStore`) and the **lifetime** usage aggregate (`StatsStore`). Both are plain JSON, no encryption. Different files; the cap on history doesn't bound stats.

## Files

- `HistoryStore.swift` — `actor` for the last-10 transcript JSON. FIFO eviction.
- `HistoryEntry.swift` — `Codable` model shared by both stores.
- `StatsStore.swift` — `actor` for `stats.json`: totals + per-day + per-app aggregates.
- `RetainedAudioStore.swift` — `@MainActor` in-memory holder for a broken row's failed-chunk audio, keyed by `HistoryEntry.id`. Never serialized; eviction mirrors the ten-entry cap via `retain(only:)`.
- `HistoryText.swift` — the row's one string: `assemble(_:)` renders the stored sequence (each gap as `[…]`) through `TextInjector.stitchChunks`, and `rendered(_:replacements:)` applies the user's *current* dictionary pairs on top. Display, copy and word-count all call it, which is what makes them agree by construction.
- `RetryMerge.swift` — pure gap-slot merge: how a retry's per-chunk results land back in the row they were re-sent from, **written into the gap segment covering each chunk's own index**. Consumed by `AppState.retryEntry(id:)` / `settleRetry`.

## Invariants

1. **`HistoryStore` cap = 10.** Append at the cap drops the oldest.
2. **`allEntries()` returns oldest-first**; popover and `HomeView` sort newest-first for display. **It decodes the array row-by-row: a row that cannot be decoded is dropped and the rest load.** `history.json` is a bare top-level array, so decoding it as `[HistoryEntry]` meant one unreadable row threw for the whole file, `JSONFileStorage` renamed it aside, and the user's history came back empty — ten transcripts lost to one bad field. Per-row tolerance was the maintainer's product ruling, made knowing the trade: the renamed file was a complete, hand-recoverable copy, and **a dropped row has no copy anywhere**. Two boundaries hold it in place — damage that can't be split into rows at all (truncated write, non-JSON, top-level object) still takes the whole-file rename path, and nothing is defaulted into existence, so a row missing its `id` or `timestamp` is dropped rather than fabricated. A drop is logged at `.error` (persisted; count and positions only, never the transcript) — the only trace it leaves.
3. **`remove(id:)` is a no-op if the id isn't present.** Drives the popover's per-row trash button through `AppState.deleteHistoryEntry(id:)`: optimistic in-memory update + fire-and-forget disk write. **`update(_:)` shares that contract** — it replaces the row with the matching id **in place** and no-ops when absent. In place, not remove-then-append: a retry rewrites a broken row's response sequence — writing recovered text into the gaps that recovered — without changing what the row *is*, and re-appending would reorder the last-10 list and move the trim onto a different victim. (The failure count is not rewritten; it is derived from the sequence, so it falls out of the same write.)
4. **Nothing audio-shaped is ever persisted** (architecture invariant I4). `history.json` stores a row's **response sequence** — per segment, the chunk positions it covered and either the model's raw text or a gap — plus the two legacy mirrors `text` and `failedChunkCount` (KTD10, see Schema). Never audio, and the sequence is the field a future change is most likely to reach for: a segment carries the *positions* a re-send would need, deliberately not the bytes. The one carve-out is `RetainedAudioStore`, which holds a broken row's failed-chunk audio **in memory only, for the lifetime of the process**, keyed by that row's id. It is never serialized: not into `history.json` beside the entry, not into a side-car, not into a crash-recovery cache. That is why a row whose process died comes back **dead** (rendered as broken, minus the retry action) — the audio being gone is the designed outcome, not a gap to fill. Adding `Codable` to `RetainedRecording`, or persisting the holder, is a scope violation rather than a refactor; `RetainedRecordingTests.test_retainedRecording_isNotSerializable` is the mechanical half of that guard. Release triggers and the single eviction point (`retain(only:)`) are documented on `RetainedAudioStore` itself.
5. **`StatsStore` keeps derived counts only — no transcripts.** Honours the nothing-audio-on-disk + history-cap=10 privacy posture; a user who clears history doesn't have transcripts hiding in stats either.
6. **Local-TZ day keys** (`Calendar.autoupdatingCurrent`) — a session at 23:45 May 11 local lands in the May 11 bucket, not May 12 UTC.
7. **Last-seen display name wins** in `appBuckets[bundleID].name`. App renames pick up without manual reconciliation.
8. **`StatsStore.record` is NOT idempotent.** Callers must not call it twice for the same session. **`recordTokens(_:model:timestamp:bundleID:appName:)` is the token-only sibling** for callers that must record spend *without* counting a session: it folds usage into the day and day×app buckets and touches neither `totalSessions`, `totalWords`, nor the duration fields. **The two are exclusive per retry run, and that is what makes R18 hold.** `settleRetry` reaches `record` at most once per history entry — on the first retry that recovers text for a row lifetime stats never counted — and takes `recordTokens` on every other arm, including the ones that recovered nothing or settled onto a deleted row. Never both: `record` folds the same usage itself, so calling `recordTokens` beside it would double-count the spend. Read "a retry records its tokens every time" as a statement about the *spend*, not about which method runs. (`recordRetryTokens` additionally no-ops on `.zero`, so a run that spent nothing writes nothing.) Both write the flat aggregate and the per-model split through one `addTokens` helper so they cannot drift. **"Lifetime stats never counted this session" is `HistoryEntry.isEntirelyLost`: every segment in the row's sequence is a gap (R18 / KTD11).** Structural, not a reading of the `text` mirror's emptiness — and the distinction it rests on is that a segment holding `""` is *text*: the hallucination gate's `""` means Gemini answered and we filtered the answer, so a row that pasted `[…]` beside one of those took the success arm and *was* counted. Read the predicate's own doc-comment before touching it; the looser "no segment carries characters" reading double-counts exactly that row.

## Hard rules

- **`StatsSnapshot.init(from:)` is a tolerant decoder** — every field is `decodeIfPresent` with a default. v1 files (no `dayAppBuckets`) load with `[:]`. v2 files are healed on read via `healIfPreV3` (duration fields zeroed, version → 3). Text totals are preserved.
- **Don't decrement counts on `deleteHistoryEntry`.** Deleting a history row removes the transcript preview but leaves aggregate counts alone — treating the per-row trash as "redact from analytics too" would let a user silently zero out yesterday's word count, which is more confusing than helpful.
- **Two independent wipe paths.** `HistoryStore.deleteAll()` (driven by `AppState.deleteAllHistory()`, Settings → "Delete all transcripts") clears the last-10 transcripts but leaves `StatsStore` alone. `StatsStore.deleteAll()` (driven by `AppState.deleteAllStats()`, Settings → "Delete all analytics") clears every aggregate but leaves the transcripts alone. Don't combine them — the explicit two-button UX is the contract.
- **Don't backfill stats from existing `history.json`.** No de-duplication metadata. Stats start accumulating from the first session under the StatsStore-aware build.
- **`allEntries()` must not heal the file on read.** Rewriting the survivors during a read is the tidier-looking option and was considered and rejected — the argument is in `HistoryStore.swift` under "Heal-on-write". Short version: the dropped row's bytes are the only copy in existence, a read runs at launch before anyone knows a row was lost, and the likeliest real cause of a drop is version skew (a future build's required field seen by an older decoder), which an eager rewrite makes permanently destructive instead of survivable by upgrading again. The survivors *are* written back by the next `append` / `update` / `remove`, which is incidental and documented, not a guarantee. Both halves are pinned — `test_allEntries_droppingARow_doesNotRewriteTheFile`, `test_append_afterADrop_rewritesTheArrayWithoutTheDroppedRow`.
- **Per-row tolerance stays in `HistoryStore`, not `JSONFileStorage`.** `NoType/Storage/CLAUDE.md`'s "don't add per-store branching here" rule decides it: the other three stores are single-object snapshots with nothing to split into rows. `LossyHistoryArray` / `LossyRow` are built on top of the shared `read`, which is generic over `Decodable` and needed no change.
- **`stats.json` never leaves the device.** No network call touches this file. Local-only carve-out documented in `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.

## Schema

**`HistoryEntry`:**

```swift
struct HistoryEntry: Codable, Identifiable, Sendable {
    struct Segment: Codable, Sendable, Equatable {
        let chunkIndices: [Int]    // the positions this one Gemini answer covered; never empty
        let text: String?          // raw, pre-replacement; `nil` IS the gap
        var isGap: Bool { text == nil }
    }

    let id: UUID
    let text: String               // legacy mirror (KTD10): the string that was pasted
    let sourceAppName: String      // "Slack"
    let sourceBundleID: String     // "com.tinyspeck.slackmacgap"
    let timestamp: Date
    let durationSeconds: Double    // press → release; 0 for pre-duration rows (tolerant decode)
    let segments: [Segment]        // the row's source of truth; absence on disk = migrate (R12)

    var failedChunkCount: Int      // derived; also encoded as the second legacy mirror
    var isBroken: Bool             // segments.contains(where: \.isGap)   — computed, never encoded
    var isEntirelyLost: Bool       // segments.allSatisfy(\.isGap)        — the never-counted signal
}
```

**A gap is a position, not a character (R1).** The row's structure lives in
`segments`; a lost chunk is a segment whose `text` is `nil`, and the `[…]` the
user sees is produced at render time by `HistoryText.assemble`. The
distinction that costs the most to get wrong is `nil` vs `""`: a segment
holding the empty string is **text** (R27) — that is the hallucination gate
saying *Gemini answered and we filtered the answer* — so it makes no row
broken and keeps `isEntirelyLost` honest. Same three-state table as
`NoType/Recording/CLAUDE.md` "Post-response hallucination gate", carried onto
disk unchanged.

**Segment text is stored raw, before any dictionary replacement pair (R2).**
The pairs are applied on the *assembled* string at display and copy time
(`HistoryText.rendered`, KD2), which is what lets editing a pair change how
rows already on disk read (R5 / AE7) and what lets a pair whose phrase spans a
chunk seam still match. It also means `history.json` holds pre-replacement
text (R31) — presentation-only substitution removes nothing from disk, and the
file is unencrypted.

**`text` and `failedChunkCount` are write-only legacy mirrors (KTD10).** They
are still emitted on every row this build writes, because a rollback to a
pre-sequence build decodes `text` non-optionally and would otherwise throw on
the whole array — costing the user all ten transcripts rather than one field.
Nothing in this build reads them back except `init(from:)`'s migration arm,
where a row carrying no sequence is reconstructed from exactly that pair.
`failedChunkCount` is *derived* from the sequence here and still mirrors
`SessionSummary.failedChunkCount` by construction. `isBroken` remains the
single predicate for "this row is broken"; call sites read it rather than
re-deriving anything.

The audio a gap would need for a re-send is **not** in the entry — it lives in
memory (`NoType/Recording/RetainedRecording.swift`, `RetainedAudioStore`) and
dies with the process, which is why a row read off disk comes back dead.

Storage: `~/Library/Application Support/NoType/history.json`, top-level array of `HistoryEntry`.

**Migration (R12 / KTD10):** the file is a bare top-level array with no version
envelope, so **absence of `segments`** is the discriminator — the precedent
`durationSeconds` and `failedChunkCount` already set. A legacy row is
reconstructed by `migratedSegments(text:failedChunkCount:)`, and its one rule
is that **the stored count decides brokenness while the text only supplies
positions**: count zero → one text segment holding the text verbatim (a `[…]`
the user *dictated* must not turn the row broken); count non-zero → split on
whatever markers survive and append gaps until the gap count equals the count
(a replacement pair may have erased some — that row must stay broken). Those
positions are **ordinal, not recovered**, and nothing may depend on them; a
row read off disk outlived the process that held its audio, so no retry can
reach it. A row this build wrote carries a sequence, which makes the marker
parser structurally unreachable for it.

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
| One `history.json` row won't decode | Log at `.error` + drop that row; the others load. No rename, and **no `.corrupt-` copy of the dropped row** — see invariant 2. |
| Disk full on write | Log. In-memory state stays accurate until next launch. |
| Concurrent writes from two app instances | Not supported — NoType is effectively single-instance via `LSUIElement`. No defensive PID-lock today. |

## Wiring

`AppState` (`@MainActor @Observable`) owns the SwiftUI-facing mirrors `history: [HistoryEntry]` and `statsSummary: StatsSnapshot`. The primary stats write point is `AppState.finalizeRecording()`'s success arm: after `history.append(entry)` succeeds, a detached `Task` calls `await statsStore.record(entry, tokens: session.summary.tokens, model: session.summary.model)` and assigns the returned snapshot back to `statsSummary` on the main actor. `AppState.settleRetry` is the second (see Schema → Wiring).

`HomeView` reads `statsSummary` (windowed by `HomeRange`: 7D / 30D / 90D / All); only the bottom "Recent transcripts" list reads `history`. The popover reads `history` for the last-10 list.

**Broken rows and retry.** A session that lost chunks in the recoverable class writes a broken row (a sequence carrying at least one gap segment — `isBroken`) rather than being discarded, and `AppState` stores that session's `SessionSummary.retained` payload in `RetainedAudioStore` under the new row's id. `AppState.retryEntry(id:)` re-sends the payload's chunks one at a time and `settleRetry` lands the results through `RetryMerge`; `retryingEntryID` is the single in-flight slot both the popover and the Home tab read, so a retry started in either surface shows as busy in both.

**The merge writes by index; it does not scan.** `RetryMerge.merge(into:outcomes:)` joins `HistoryEntry.Segment.chunkIndices` against `RetainedRecording.Chunk.idx` — the same number, recorded from one `ChunkResponse` — and writes each recovery into the gap covering **that chunk's own position** (R7). A gap spanning several indices splits when only some of them recover; the unrecovered positions on either side stay grouped, because `HistoryText.assemble` emits one `[…]` per gap *segment* and splitting a run that did not recover would multiply the markers the user sees. Remaining gaps are therefore read from the per-chunk results, never by decrementing a count (R11), and the priors sent back to Gemini are the row's text-carrying segments — raw, with a gap contributing nothing (R10).

That replaced a left-to-right scan for the *i*-th `[…]` in `HistoryEntry.text`, and both reasons are worth keeping in view because they are the shape of the bug rather than one instance of it. The mirror is *post-replacement*, so a user pair as ordinary as `…` → `...` left a row that was still broken and still held audio but carried no marker to substitute into — every retry on it billed and recovered nothing. And rebuilding the row from the merged string baked that substitution into storage, after which the raw text was gone from disk and the *current* pairs were re-applied on top of an old one. `settleRetry` uses the `segments:` producing initializer for exactly that reason; the `failedChunkCount:` reconstruction initializer is a migration rule and no in-process producer may reach for it.

**Placement is still reported, never re-derived.** `Merged.placed` says which outcomes' text actually reached the row, and that — not "did Gemini return text" — is what licenses releasing a chunk's audio. Writing by index makes a mismatch rare rather than impossible: a recovery aimed at an index no gap covers (a second run against a row a first already recovered) is reported unplaced and keeps its audio.

Two rules the mirror imposes on this module:

- **The optimistic mirror is part of the eviction input.** `refreshHistory` calls `retainedAudio.retain(only: liveHistoryIDs.union(mirrored))` — reloading from disk alone would evict the audio of a row appended into the mirror whose persist `Task` hasn't run yet, leaving a retry button with nothing behind it.
- **`RetainedAudioStore.take` hands out the only copy.** Every exit from a retry must re-put what it did not recover, including the recovered-nothing exit. Nothing else holds a reference and no test can observe the loss.

## Testing

- `NoTypeTests/HistoryStoreTests` — round-trip, FIFO eviction at the 10-entry boundary, corruption recovery (garbage JSON → renamed → empty list), plus `update(_:)`'s in-place / no-op-when-absent contract and `failedChunkCount`'s tolerant decode. **Per-row tolerance** is pinned against the corpus a full-depth review of U5 measured as file-destroying: each shape as row 2 of 3, plus bad-row-first / last / middle (the first-row case is what proves the element cursor advances past a failure at all), two bad rows, every row bad, an empty array, non-object elements, and the truncated file still taking the whole-file path. Every per-row case also asserts **no `history.json.corrupt-*` sibling appears** — without that half it is a parsing test, not a data-loss test.
- `NoTypeTests/StatsStoreTests` — empty-state, single record, accumulation across sessions / days / apps, last-seen-name wins, empty-bundle skip, disk persistence round-trip, corruption recovery, day-key format. Per-test temp directory — no shared state.
- `NoTypeTests/RetainedAudioStoreTests` — put / peek / take / remove, `retain(only:)` as the single eviction path, and the non-serializability guard behind invariant 4.
- `NoTypeTests/RetryMergeTests` — the pure gap-slot merge: the index write (including a gap segment splitting when only some of its positions recover, and order-independence of the outcomes array), what counts as a recovery (`nil` and whitespace-only do not), the `placed` flags the release path reads, `priors(from:)`, and the degrade-safely branches.
- `NoTypeTests/HistoryTextTests` — `assemble` (gap → `[…]`, the `stitchChunks` seam rule, end-trimming) and `rendered` (current pairs applied *after* assembly, so a pair on the ellipsis restyles a gap without moving it), plus display ≡ copy.
- `NoTypeTests/AppStateRetentionTests` / `AppStateRetryTests` — broken-row recording, mirror-union eviction, the `canRetry` predicate, and the retry run's settle arms.
- No integration test against the real filesystem — use a temp directory.

## Pointers

- Why JSON + last-10 (not SQLite, not encrypted) → `solutions/architecture-patterns/json-history-store-2026-05-15.md`.
- Why StatsStore is local-only (no-telemetry carve-out) → `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
- Home tab's data flow (`statsSummary`, `HomeRange`, top-apps) → `NoType/UI/CLAUDE.md`.
- What produces a retained payload, and the classifier that decides → `NoType/Recording/CLAUDE.md` "Retention for retry".
- Why every retry exit must re-put what it didn't recover (the destructive `take`) → `solutions/conventions/gate-irreversible-actions-on-the-outcome-2026-08-09.md`.
- Why eviction reconciles disk ∪ mirror rather than disk alone → `solutions/conventions/reconcile-optimistic-mirror-by-union-2026-08-09.md`.
