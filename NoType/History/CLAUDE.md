# History module

Two siblings: the rolling **last-10** transcript window (`HistoryStore`) and the **lifetime** usage aggregate (`StatsStore`). Both are plain JSON, no encryption. They write to different files; the cap on history doesn't bound stats.

Files:
- `HistoryStore.swift` — `actor` for the last-10 transcript JSON. FIFO eviction.
- `HistoryEntry.swift` — `Codable` model shared by both stores.
- `StatsStore.swift` — `actor` for `stats.json`: totals + per-day + per-app aggregates. See "Lifetime stats" section below.

---

## Schema

```swift
struct HistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let sourceAppName: String       // "Slack"
    let sourceBundleID: String      // "com.tinyspeck.slackmacgap"
    let timestamp: Date
    /// Wall-clock time from hotkey press to release, in seconds.
    /// Defaulted to 0 for pre-duration rows via a tolerant
    /// `init(from:)`. Feeds `StatsSnapshot.totalDurationSeconds`
    /// which drives WPM + Time-saved on the Home tab.
    let durationSeconds: Double
}
```

Storage: `~/Library/Application Support/NoType/history.json`, top-level array of `HistoryEntry`.

---

## Behavior

- **Cap at 10.** When `append` is called and count is already 10, drop the oldest.
- **Order:** `allEntries()` returns entries in append order (oldest first); the popover and `HomeView` sort newest-first for display.
- **Manual delete.** `remove(id:)` strips a single entry by UUID and atomically rewrites the file. The popover's per-row trash button drives this through `AppState.deleteHistoryEntry(id:)` (optimistic in-memory update, then fire-and-forget disk write). No-op if the id isn't present.
- **No audio retention** — see invariant I4 in `docs/architecture.md`. Only `text` is stored.

---

## Concurrency

`HistoryStore` is an `actor`. All file I/O happens on its isolation domain. There is no dedicated `HistoryViewModel`; `AppState` (`@MainActor`) owns the SwiftUI-facing mirror directly:

```swift
@MainActor
@Observable
final class AppState {
    var history: [HistoryEntry] = []
    private let historyStore: HistoryStore
    ...
    func refreshHistory() async {
        history = await historyStore.allEntries()
    }
}
```

`RecordingSession.stop()` calls `await store.append(entry)` directly. The returned `HistoryEntry` is then appended to `AppState.history` on the main actor, with a defensive trim to 10 entries. The popover and `HomeView` observe `AppState.history` via `@Environment(AppState.self)`.

Per-row delete: the popover's trash button calls `AppState.deleteHistoryEntry(id:)`, which optimistically removes from the in-memory array and then fires a detached `Task` to persist via `store.remove(id:)`. The disk write is fire-and-forget — on disk-write failure (logged), the in-memory state still reflects the deletion until the next launch.

---

## File format & migration

v1 file is just `[HistoryEntry]`. If we ever need to add fields, wrap in a versioned envelope:

```json
{
  "version": 2,
  "entries": [...]
}
```

For now, the bare array is fine. When upgrading, read both shapes (try envelope first, fall back to bare array).

---

## Failure modes

| Situation | Behavior |
|---|---|
| File doesn't exist | Treat as empty list. Create on first write. |
| File is corrupt JSON | Log error, rename to `history.json.corrupt-{timestamp}`, start fresh. Don't lose user data silently. |
| Disk full on write | Log error. In-memory state is unchanged (so the user still sees their entry in the popover until the next launch). |
| Concurrent writes from two app instances | Not supported — NoType is effectively single-instance via `LSUIElement` and the app's normal scene-graph lifecycle. There is no defensive PID-lock today. |

---

## Testing

`HistoryTests/`:
- Round-trip a list through encode/decode.
- Verify FIFO eviction at exactly the 10-entry boundary.
- Corruption recovery: feed garbage JSON, assert it's renamed and we get an empty list.

No integration test against the real filesystem — use a temp directory.

---

## Lifetime stats (`StatsStore`)

The 10-entry cap on `HistoryStore` would make Home-tab totals (words / time saved) and the activity heatmap snap to "last 10" the moment a user dictates anything. `StatsStore` is the separate persistent aggregate so those surfaces accumulate over the whole install lifetime without retaining transcripts.

Storage: `~/Library/Application Support/NoType/stats.json`. One blob, atomic writes, corruption recovery (`stats.json.corrupt-{ts}` rename, start fresh) mirrors `HistoryStore`.

Schema (v3):

```swift
struct StatsSnapshot: Codable, Sendable, Equatable {
    var version: Int                                    // 3
    var totalWords: Int
    var totalSessions: Int
    var totalDurationSeconds: Double                    // sum of session durations for *measured* sessions
    var totalDurationWords: Int                         // matched word count for the same sessions
    var dayBuckets:    [String: DayBucket]              // dayKey → totals across all apps
    var appBuckets:    [String: AppBucket]              // bundleID → lifetime per-app totals
    var dayAppBuckets: [String: [String: DayBucket]]    // dayKey → bundleID → bucket
}

struct DayBucket: Codable, Sendable, Equatable {
    var words: Int                                      // every recorded word for the day
    var sessions: Int
    var durationSeconds: Double                         // sum from sessions with timing data
    var durationWords: Int                              // matched word count for those sessions
}
struct AppBucket: Codable, Sendable, Equatable {
    var name: String
    var words: Int
    var sessions: Int
}
```

`StatsSnapshot.init(from:)` is a **tolerant decoder** — every field is `decodeIfPresent` with a default. v1 files (no `dayAppBuckets`) load with that field defaulted to `[:]`. v2 files (no matched `durationWords`) are **healed** on first read via `healIfPreV3()`: all duration fields (top-level + day + day×app) are zeroed and `version` is bumped to 3. Text totals — `totalWords`, `totalSessions`, the `words` / `sessions` columns of day buckets, and `appBuckets` — are preserved, so the user keeps their lifetime word count and Top apps history; only the WPM / Time-saved metrics restart from the next session. Adding future fields = one more `decodeIfPresent` line; adding fields that need cross-field consistency = another `healIfPre*` step + version bump.

### Why this shape

- **No transcripts.** Stats are derived counts only — there is no audit trail of what was dictated. Honours the "no audio retention" + "history-cap=10" privacy posture: a user who clears history doesn't have transcripts hiding in stats either.
- **Bounded memory.** One row per calendar day + one row per distinct app. ~50 B/day + ~80 B/app. Ten years of daily use ≈ 40 KB total.
- **Local TZ keys.** Day keys use `Calendar.autoupdatingCurrent` so a session at 23:45 May 11 local lands in the May 11 bucket, not May 12 UTC. The user's screen shows their day, not a wall clock's.
- **Last-seen display name wins.** `appBuckets[bundleID].name` is overwritten on every `record(_:)` so a rename of the app picks up in the Top apps panel without manual reconciliation.

### Operations

- `summary() -> StatsSnapshot` — read-through with in-memory cache. First call loads from disk; subsequent calls serve cached snapshot.
- `record(_ entry: HistoryEntry) -> StatsSnapshot` — increments totals + the relevant day, app, and day×app bucket, persists atomically, returns the new snapshot. **Idempotency is not enforced** — callers must not call `record` twice for the same logical session.
- `StatsSnapshot.totals(overLastDays:)` and `.topApps(overLastDays:limit:)` — query helpers that window the lifetime data to the last N local days (`nil` → all-time). Drive the Home tab's `HomeRange` filter (7D / 30D / 90D / All).

### Wiring

`AppState` owns the SwiftUI-facing mirror (`statsSummary: StatsSnapshot`). On launch it loads the snapshot once. The single write point is `AppState.finalizeRecording()`'s success arm: after `history.append(entry)` succeeds, it fires a detached `Task` that calls `await statsStore.record(entry)` and assigns the returned snapshot back to `statsSummary` on the main actor. `HomeView` reads `appState.statsSummary` for the stats row, top-apps panel, and activity heatmap; only the bottom "Recent transcripts" list still reads `appState.history`.

### What's deliberately not done

- **No backfill from existing `history.json`.** Stats start accumulating from the first session under the StatsStore-aware build. The last-10 entries you had pre-upgrade won't show up in the totals or heatmap. Backfilling would need de-duplication metadata we don't carry today.
- **No decrement on `deleteHistoryEntry`.** Deleting a history row removes the transcript preview from the popover/Home list but leaves the aggregate counts alone. Treating the per-row trash as "redact this from analytics too" would let a user silently zero out yesterday's word count, which is more confusing than helpful.
- **No periodic compaction.** The day-bucket dictionary grows monotonically. At one row per day this is fine for decades; revisit if we ever start storing finer-grained buckets (e.g. hourly).

### Testing

`StatsStoreTests` covers: empty-state, single record, accumulation across sessions / days / apps, last-seen-name wins, empty-bundle skip, disk persistence round-trip, corruption recovery, and the day-key format. Per-test temp directory — no shared state.
