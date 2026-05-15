---
title: JSON file for transcript history, capped at 10 entries
date: 2026-05-15
category: architecture-patterns
module: History
problem_type: architecture_pattern
component: tooling
severity: medium
applies_when:
  - Adding any persistent state to the History module
  - Considering a database for transcript / session storage
  - Auditing the privacy posture of stored data
tags: [history, persistence, json, fifo, beta-scope]
---

# JSON file for transcript history, capped at 10 entries

## Context

NoType keeps the last few dictation transcripts in a popover so the user can re-copy or re-paste them. We needed a storage shape that fits a beta-scope product with one very small access pattern (read all + append + occasional delete), no querying, no sync.

## Guidance

**Use a single JSON file** at `~/Library/Application Support/NoType/history.json`, top-level array of `HistoryEntry`. **Cap at 10 entries** with FIFO eviction on `append`. **Plain text — not encrypted.**

The file is owned by the `HistoryStore` actor (`NoType/History/HistoryStore.swift`); all I/O happens on its isolation domain. Atomic writes; corruption recovery via `.corrupt-<ts>` rename.

## Why This Matters

- **Beta scope.** SQLite / CoreData is overkill for a 10-entry FIFO. The schema fits in 30 lines of `Codable`, the access pattern is "load all on launch, append on session end, delete by id occasionally". A DB would add dependencies, schema-migration ceremony, and a build-time cost for nothing the product asks for.
- **Privacy comes from OS file permissions.** Application Support is per-user; no other user account on the same Mac can read it. The threat model for beta doesn't include hostile local processes, so encryption-at-rest would only protect against an attacker who can already read the user's home folder — by which point we've lost.
- **No transcripts in the lifetime stats** (`StatsStore`). Deleting a history entry actually removes it; nothing else holds a copy.

## When to Apply

- Default for any state that lives within "small set, append-mostly, read-all".
- Reconsider when: the product asks for history > 100 entries, full-text search, or cross-device sync. Move to SQLite + a versioned schema then.

## Examples

**Schema** (`NoType/History/HistoryEntry.swift`):

```swift
struct HistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let sourceAppName: String
    let sourceBundleID: String
    let timestamp: Date
    let durationSeconds: Double
}
```

**Failure modes** (handled in `HistoryStore`):

- File doesn't exist → empty list, create on first write.
- File is corrupt JSON → log, rename to `history.json.corrupt-<ts>`, start fresh.
- Disk full on write → log, in-memory state stays accurate until next launch.
- Concurrent writes from two app instances → not supported (LSUIElement single-instance).

## Related

- `NoType/History/CLAUDE.md` — implementation detail (schema, behaviour, file format & migration).
- `docs/decisions.md` ADR-010 — legacy index entry, redirects here.
- `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md` — the related lifetime-stats decision (no transcripts there either).
