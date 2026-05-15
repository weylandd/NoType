---
title: No streaming responses from Gemini in v1
date: 2026-05-15
category: design-patterns
module: Gemini
problem_type: design_pattern
component: tooling
severity: medium
applies_when:
  - Considering switching to streamGenerateContent for transcription
  - Evaluating mid-response paste UX
  - Receiving complaints about release-to-paste latency
tags: [gemini, streaming, latency, ux]
---

# No streaming responses from Gemini in v1

## Context

Gemini supports both `generateContent` (full response) and `streamGenerateContent` (token-by-token). For transcription, streaming would let us start displaying / pasting partial text before the model finished.

## Guidance

**Use `generateContent`. Wait for full responses.**

## Why This Matters

The latency win from streaming would be on intermediate chunks — but **NoType doesn't display intermediate transcripts**. The user only sees the menu-bar timer while the hotkey is held; they see text only after release, when everything is stitched and pasted. Streaming intermediate chunks earns nothing user-visible.

The final chunk **is** user-visible latency, and streaming there would help by ~100–300 ms. But it adds:

- Mid-response reconciliation logic.
- Partial-paste UX: do we paste as text streams in (jittery), or wait for the stream to end (no win)?
- Boundary-normalisation logic (`finalizeForInsertion`) would need to run incrementally instead of once.

Net: complexity cost > 100–300 ms latency win for v1.

## When to Apply

- Default: keep `generateContent`.
- Reconsider when: users complain about perceived latency between releasing the hotkey and seeing pasted text, AND we've already exhausted the cheaper wins (faster encoding, lite-path coverage, prompt trimming).

## Examples

**The actor uses `generateContent` exclusively** — `NoType/Gemini/GeminiClient.swift` `sendRequest`. No `streamGenerateContent` callsites.

## Related

- `NoType/Gemini/CLAUDE.md` "Serial execution + batching".
- `docs/decisions.md` ADR-007 — legacy index entry, redirects here.
- `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md` — the serial scheduling that streaming would complicate.
- `solutions/design-patterns/local-chunk-concatenation-2026-05-15.md` — the local-concat path that streaming would also complicate.
