---
title: In-memory AAC encoding for audio chunks (planned)
date: 2026-05-15
category: documentation-gaps
module: Recording
problem_type: documentation_gap
component: tooling
severity: low
applies_when:
  - Profiling per-chunk encode overhead
  - Considering a CoreAudio-level rewrite of ChunkBuilder.encodeAAC
tags: [chunkbuilder, aac, performance, coreaudio, tech-debt]
---

# In-memory AAC encoding for audio chunks (planned)

## Context

`ChunkBuilder.encodeAAC` (`NoType/Recording/ChunkBuilder.swift`) round-trips PCM through an `AVAudioFile` written to a temp file, then reads the file back into `Data`. The temp file lives in `NSTemporaryDirectory()` (disk-backed on macOS) and adds ~20–50 ms of syscall overhead per chunk on Apple Silicon SSDs.

## Guidance

**Leave the encoder as-is.** Don't switch to a custom in-memory path without explicit justification — the rewrite is non-trivial and the current overhead is masked by Gemini round-trip time.

## Why This Matters

None of Apple's high-level APIs (`AVAudioFile`, `AVAssetWriter`) support memory-only sinks. An in-memory path would require:

- `AudioFile` + `AudioFileInitializeWithCallbacks` with a custom byte-sink callback.
- `AudioConverter`-based PCM → AAC.
- A hand-built M4A container.

~150–200 LOC of CoreAudio plumbing plus a fixture-encoded test set. The 20–50 ms penalty is real but doesn't dominate a session's wall-clock — Gemini's round-trip is 500–1500 ms.

## When to Apply

- Reconsider if profiling shows chunk encoding becoming user-visible (e.g. a 10-chunk session adds 200–500 ms of pure-encoding overhead).
- Reconsider if the temp-file path itself starts failing (disk full, sandboxing change).

## Examples

Current pipeline at `NoType/Recording/ChunkBuilder.swift` — `encodeAAC` opens `AVAudioFile`, writes through, closes, reads back into `Data`, deletes the temp file.

Approximate effort to fix: **L** (~150–200 LOC + tests).

## Related

- `NoType/Recording/CLAUDE.md` "Encoding to AAC" — current pipeline detail.
- `docs/TECHDEBT.md` — legacy index entry, redirects here.
