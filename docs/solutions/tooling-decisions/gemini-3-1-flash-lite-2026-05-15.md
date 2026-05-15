---
title: Gemini 3.1 Flash-Lite for transcription
date: 2026-05-15
category: tooling-decisions
module: Gemini
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - Picking a transcription model for a new audio path
  - Evaluating cost / quality / latency trade-offs against alternative LLMs
  - Considering a swap to Whisper, Gemini Pro, or OpenAI Realtime
tags: [gemini, llm, transcription, multimodal, cost, implicit-caching]
---

# Gemini 3.1 Flash-Lite for transcription

## Context

NoType needs a transcription engine that:

- Accepts audio directly (multimodal — no separate ASR step).
- Is cheap enough to be sustainable on the user's own API key (BYOK; see ADR-011).
- Lets us inject on-screen context to disambiguate proper nouns and jargon.
- Returns fast enough for "release hotkey → text appears" to feel snappy.

## Guidance

**Use `gemini-3.1-flash-lite` (post-GA)** as the single transcription model id. Configure with:

- `thinkingLevel: "minimal"` — transcription isn't a reasoning task.
- `top_p: 0.2` — tight nucleus, no determinism artefacts of `temperature=0`.
- `responseMimeType: "text/plain"`.

The same model is also used for the one-shot app classifier (with web-search tool enabled — see ADR-015). One model id, one pricing surface, simpler operational story.

## Why This Matters

- **Multimodal** — accepts audio inline, no separate ASR pipeline. Whisper would force a two-step path (audio → text → context-aware reformat), losing the prosody / disambiguation the LLM can do natively.
- **Cheap** — $0.25/1M input tokens, $1.50/1M output. Audio = 25 tokens/sec. A 10-second utterance is ~250 input tokens (~$0.0001) plus a small output bill.
- **Implicit caching** gives ~90% discount on cached prefix tokens automatically — the load-bearing reason the request shape (ADR-006, ADR-008, ADR-014, ADR-015, ADR-016) goes to such lengths to keep the prefix byte-stable across chunks of one session. See `NoType/Gemini/CLAUDE.md` "Why this order".
- **Context window is 1M tokens** — far more than NoType ever needs.
- **`thinking` levels** let us pick "minimal" for transcription latency; the heavier modes exist for other use cases.

## When to Apply

- Default for every new transcription request.
- Reconsider when: users complain that quality is too low for accents / jargon / specific languages, OR Google ships a successor model with a meaningfully different shape.

## Examples

**The pin in code:** `NoType/Gemini/GeminiClient.swift:15` — single constant.

**Alternatives that were rejected:**

- **Whisper (local).** Rejected — pure ASR, can't do AX-context-aware reformatting that the LLM provides. NoType explicitly accepts the internet dependency (see project non-goals).
- **Gemini 3 Flash.** Rejected — overkill for dictation; cost would be ~3× higher with no quality win we can detect.
- **OpenAI Realtime API.** Viable alternative; revisit if Gemini quality disappoints. Higher cost.

## Related

- `NoType/Gemini/CLAUDE.md` — the request shape that exploits implicit caching.
- `docs/decisions.md` ADR-003 — legacy index entry, redirects here.
- ADR-011 (BYOK) — why the per-user cost matters.
- `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md` — the actor that issues these requests.
