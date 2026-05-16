---
title: `JSONFileStorage` — shared file-IO helper for the four actor stores
date: 2026-05-16
category: architecture-patterns
module: Storage
problem_type: architecture_pattern
component: persistence
severity: medium
applies_when:
  - Adding a fifth JSON-backed actor store
  - Considering inlining the shared file-IO helpers back into a store
  - Auditing how stores recover from corrupt or missing files
tags: [storage, json, actor, atomic-write, corruption-recovery, dedup]
---

# `JSONFileStorage` — shared file-IO helper for the four actor stores

## Context

NoType has four JSON-backed actor stores, each living in its feature module:

| Store | File | Lives under |
|---|---|---|
| `HistoryStore` | `history.json` (last-10 transcripts) | `NoType/History/` |
| `StatsStore` | `stats.json` (lifetime aggregate) | `NoType/History/` |
| `InstructionsStore` | `instructions.json` (user / category instructions + app assignments) | `NoType/Instructions/` |
| `DictionaryStore` | `dictionary.json` (canonical spellings + replacements) | `NoType/Dictionary/` |

Each store originally owned an identical-shape implementation of five concerns:

1. Resolve `~/Library/Application Support/NoType/<name>.json`, creating the directory if needed.
2. Configure a `JSONEncoder` / `JSONDecoder` with `dateEncodingStrategy = .iso8601` and `outputFormatting = [.prettyPrinted, .sortedKeys]`.
3. Tolerant read: file-doesn't-exist → `nil`, corrupt JSON → rename to `<name>.json.corrupt-<unix-ts>` and return `nil`.
4. Atomic write: `try data.write(to: url, options: [.atomic])` with errors swallowed and logged.
5. Per-store `os.Logger(category: "<store>")` for the corruption and write-failure log lines.

The same ~25 lines of boilerplate shipped four times. The business logic on top (FIFO eviction, version healing, per-source mutation rules) was genuinely store-specific and stayed in each module.

Two shapes were considered for the dedup:

1. **Shared base actor** — a protocol or generic actor that stores would inherit from / conform to.
2. **Enum namespace of static helpers** — each store keeps its own actor, owns its own business API, and calls into shared free functions for the file-IO step.

## Guidance

**Use the enum-namespace static-helpers shape (`NoType/Storage/JSONFileStorage.swift`).** Five public helpers:

```swift
enum JSONFileStorage {
    static func appSupportURL(filename:) -> URL
    static func makeEncoder() -> JSONEncoder
    static func makeDecoder() -> JSONDecoder
    static func read<T: Decodable>(from:as:decoder:log:) -> T?
    static func write<T: Encodable>(_:to:encoder:log:)
}
```

Each store still owns its own `actor`, its own `URL`, its own `Encoder`/`Decoder` instances, and its own `Logger`. Only the file-handling step delegates to the helper.

## Why This Matters

- **Correctness invariants now have one home.** Atomic-write, corruption-rename, and the `.corrupt-<unix-ts>` suffix format used to live in four files. A bug in one (or, more commonly, a fix in only one) drifted silently. Centralising means a single change covers all four stores.
- **The shape is honest about what it is.** An enum-namespace of static helpers names itself as "a bag of related functions, no state." A shared base actor or protocol would have implied inheritance / polymorphism that doesn't exist — each store's business API is genuinely different.
- **Stores stay independent.** `HistoryStore` doesn't import anything from `DictionaryStore`; both just call into `JSONFileStorage`. No transitive coupling between feature modules.
- **The Logger category is the single source of truth for store identity in logs.** Each store passes its own `Logger(category: "history" | "stats" | "instructions" | "dictionary")`. The helpers don't prefix the category name into the log message — Console.app's `category` column already surfaces it. The earlier shape took a redundant `storeName: String` parameter alongside the Logger; dropping it eliminated the "two sources of truth" drift risk.

## When to Apply

- **A fifth JSON-backed store.** If it shares the one-file-per-snapshot model (read entire file, decode, mutate in memory, write entire file back, with atomic+corruption-recovery semantics), wire it through `JSONFileStorage` and add a row to `Storage/CLAUDE.md`'s Files block.
- **Reconsider** when:
  - The store needs an append-only log instead of a single snapshot file.
  - The store needs a non-JSON encoding (SQLite, binary plist, protobuf).
  - The store needs a different recovery policy (e.g., keep the corrupted file in place for forensic review instead of renaming).
  In those cases build a separate helper rather than overloading `JSONFileStorage` with branching parameters.

## Examples

**Caller shape** (`HistoryStore.swift`, after the refactor):

```swift
actor HistoryStore {
    private static let log = Logger(subsystem: "app.notype", category: "history")
    private let url: URL
    private let encoder = JSONFileStorage.makeEncoder()
    private let decoder = JSONFileStorage.makeDecoder()

    init(url: URL? = nil) {
        self.url = url ?? JSONFileStorage.appSupportURL(filename: "history.json")
    }

    func allEntries() -> [HistoryEntry] {
        JSONFileStorage.read(
            from: url, as: [HistoryEntry].self,
            decoder: decoder, log: Self.log
        ) ?? []
    }

    private func write(_ entries: [HistoryEntry]) {
        JSONFileStorage.write(entries, to: url, encoder: encoder, log: Self.log)
    }
}
```

**Trade-off accepted:** Cross-module physical coupling. Four stores from four sibling feature modules (`History/`, `Instructions/`, `Dictionary/`) now all import / compile against `NoType/Storage/`. The original per-module ownership was simpler in that sense; the dedup wins on correctness invariants having one home.

**Rejected alternative — shared base actor / protocol:** would have implied polymorphism that doesn't exist (each store's business API is bespoke) and would have entangled actor isolation between sibling modules. The enum-namespace shape keeps each store's actor independent — only the file-handling functions are shared, by composition not inheritance.

**Rejected alternative — `storeName: String` parameter alongside `Logger`:** the first cut of the helpers took the store name as a second parameter for the log message prefix. Each caller then passed the same identity string twice (once as `Logger(category:)`, once as `storeName:`). Dropped — `Logger`'s `category` already surfaces in Console.app, and a second source of truth is drift waiting to happen.

## Related

- `NoType/Storage/CLAUDE.md` — invariants and hard rules of the helper module.
- `NoType/History/CLAUDE.md` — `HistoryStore` + `StatsStore` consumers.
- `NoType/Instructions/CLAUDE.md` — `InstructionsStore` consumer.
- `NoType/Dictionary/CLAUDE.md` — `DictionaryStore` consumer.
- `solutions/architecture-patterns/json-history-store-2026-05-15.md` — the design rationale for one of the consumers (last-10 transcript JSON).
- `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md` — privacy posture that these stores never leave the device.
