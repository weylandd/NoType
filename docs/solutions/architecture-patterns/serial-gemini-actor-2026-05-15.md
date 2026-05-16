---
title: Serial Gemini actor — one request in flight per session
date: 2026-05-15
category: architecture-patterns
module: Gemini
problem_type: architecture_pattern
component: tooling
severity: critical
applies_when:
  - Touching the Gemini request scheduling path
  - Considering parallel chunk dispatch
  - Auditing implicit-cache hit rate regressions
tags: [actor, concurrency, gemini, implicit-cache, batching, ordering]
---

# Serial Gemini actor — one request in flight per session

## Context

A recording session emits N audio chunks (one per VAD pause, plus the final on release). Each chunk's transcript depends on the cached prefix containing prior chunks' transcripts — so the order in which Gemini sees requests determines whether implicit caching hits.

Two scheduling shapes were considered:

1. **Serial** — at most one in-flight `generateContent` call per session; new chunks queue.
2. **Concurrent** — fire each chunk independently as soon as it's encoded.

## Guidance

**`GeminiClient` is a serial actor.** At most one request is outstanding within a session at any moment. New chunk boundaries that fire during a request **queue behind it**; when the sender wakes with multiple chunks queued, it issues a single batched `transcribeBatch` call instead of N round-trips.

The unit of work is a **batch** — but the global rule is still "one in-flight HTTP request per session at a time".

## Why This Matters

- **Eliminates response-ordering bugs.** With concurrent dispatch, chunk 3's response can race chunk 2's; we'd need explicit ordering hooks to keep the local `transcripts[]` in dispatch order. Serial scheduling makes that impossible by construction.
- **Keeps the implicit-cache prefix deterministic.** Chunk N's cached prefix is exactly `chunk_1...chunk_{N-1}` transcripts. With concurrent requests, chunk 3 might race chunk 2 and miss the cache hit. The cache discount is ~90% on prefix tokens (see `solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md`), so cache misses are real money.
- **Simplifies error handling.** There is always exactly one in-flight thing to cancel; on failure we know precisely which chunk was lost. The partial-recovery layer in `RecordingSession` builds on this — when a batched call fails recoverably, the sender splits it into N sequential `transcribe` calls (still serial; still one in-flight) and the surviving chunks become priors for the rest. See `NoType/Recording/CLAUDE.md` "Partial recovery".
- **Batching recovers throughput.** When Gemini is slow (or the user has talked through several VAD pauses), the queued chunks coalesce into one batched call. The release path benefits most: any non-final chunks queued behind the in-flight request get drained alongside the final chunk in one call.

## When to Apply

- Always for chunked transcription within a session.
- Reconsider if: the worst-case latency on the final chunk (= round-trip of last in-flight chunk + round-trip of final chunk) starts drawing complaints. The next step would be streaming responses (see `solutions/design-patterns/no-streaming-gemini-2026-05-15.md` for why we said no in v1) before parallel dispatch.

## Examples

**The actor's two transcription methods** (`NoType/Gemini/GeminiClient.swift`):

```swift
actor GeminiClient {
    /// Single chunk — used when nothing is queued behind the in-flight call.
    func transcribe(audio: Data, ..., chunkIndex: Int, isFinal: Bool, ...) async throws -> String

    /// 2..N chunks in one round-trip. Used when chunks pile up behind a slow request.
    func transcribeBatch(audios: [(data: Data, mimeType: String)], ..., chunkIndices: [Int], isFinal: Bool, ...) async throws -> String
}
```

**Trade-off accepted:** Worst-case latency on the final chunk equals (round-trip of last in-flight chunk) + (round-trip of final chunk). Measured in practice this is fine; if it becomes a complaint, revisit with streaming.

## Related

- `NoType/Gemini/CLAUDE.md` "Serial execution + batching" — implementation detail.
- `docs/decisions.md` ADR-006 — legacy index entry, redirects here.
- `solutions/design-patterns/no-streaming-gemini-2026-05-15.md` — the related decision against streaming.
- `solutions/design-patterns/local-chunk-concatenation-2026-05-15.md` — the local-concat invariant that depends on serial dispatch.
- `architecture.md` invariant I1 — the "one Gemini request in flight" rule formalized.
