# Storage module

Shared file-IO plumbing for the four JSON-backed actor stores
(`HistoryStore`, `StatsStore`, `InstructionsStore`, `DictionaryStore`).
The stores still own their actors, schemas, and business APIs — only the
boilerplate moved here.

## Files

- `JSONFileStorage.swift` — `enum` namespace. Five static helpers:
  `appSupportURL(filename:)`, `makeEncoder()`, `makeDecoder()`,
  `read(from:as:decoder:log:)`, `write(_:to:encoder:log:)`.

## Invariants

1. **Atomic write.** Every `write(_:to:encoder:log:)` uses
   `[.atomic]` so a crash mid-write can't leave a half-written file.
2. **Corruption recovery.** On decode failure, the corrupt file is
   renamed to `<name>.json.corrupt-<unix-ts>` and `nil` is returned;
   the caller substitutes its own "empty" snapshot. The rename is
   best-effort — a same-second double-corruption silently fails the
   second `moveItem`. Accepted (rare).
3. **iso8601 dates.** `makeEncoder()` / `makeDecoder()` both pin
   `.iso8601`. Stores that round-trip `Date` values rely on this.
4. **Sorted-keys + pretty-printed output.** `makeEncoder()` enables
   both so diffs against checked-in fixture files stay readable.
5. **No shared state.** Helpers are static; each caller constructs its
   own `JSONEncoder` / `JSONDecoder` instances and passes them in.
   Concurrency-safe by construction under Swift 6 strict mode.
6. **Logger category from the caller.** Each store passes its own
   `Logger(category: "...")`. The helpers don't prefix module names
   into the log message — Console.app's `category` column already
   identifies the source.

## Hard rules

- **Don't add a fifth store without considering the cap.** Four stores
  is the entire population; if you need a fifth, audit whether the new
  store's lifecycle / retention rules really match this helper's
  one-file-per-snapshot model, or whether it needs a different shape
  (e.g., SQLite, append-only log).
- **Don't add per-store branching here.** If a store needs different
  encoder strategy, atomic-write policy, or recovery behaviour, build
  it on top of these helpers — don't push the variation into the
  shared layer.
- **Don't widen the `Logger` injection into a string-tag fallback.**
  The whole point of dropping the `storeName:` parameter (see git
  log) was eliminating the second source of truth.

## Testing

No dedicated `JSONFileStorageTests.swift` today. Each store's existing
"corruption recovery" test exercises the helper transitively. Worth
pinning the `.corrupt-<unix-ts>` filename format in a unit test if it
ever needs to round-trip across a renamed-file boundary.

## Pointers

- Consumers (which store does what) → `NoType/History/CLAUDE.md`,
  `NoType/Instructions/CLAUDE.md`, `NoType/Dictionary/CLAUDE.md`.
- Privacy posture (these stores never leave the device) →
  `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
