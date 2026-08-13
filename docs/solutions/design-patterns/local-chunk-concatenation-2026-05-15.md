---
title: Local concatenation of chunk transcripts (no model-side re-emit)
date: 2026-05-15
category: design-patterns
module: Gemini
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - Adding a new chunked-transcription path
  - Considering "ask the model to re-emit the full transcript on each chunk"
  - Auditing output-token cost for a session
tags: [chunking, transcription, output-tokens, cost, caching]
---

# Local concatenation of chunk transcripts (no model-side re-emit)

## Context

A multi-chunk session produces N partial transcripts. Two ways to assemble the final text:

1. **Local concat** — each Gemini call returns only its own chunk's text; the client joins them as `chunk_1.text + chunk_2.text + ... + chunk_N.text`.
2. **Model-side re-emit** — each call asks the model to re-emit the full transcript including prior chunks (so seam handling lives in the model).

## Guidance

**Local concat.** The client is the source of truth for assembly. The Gemini system prompt explicitly tells the model that prior chunks are "already transcribed" and shows them in the cached prefix — the model only has to produce the new chunk's text.

The seam-handling rules then live in two layers downstream:

1. `TextInjector.stitchChunks` — inserts a single space between chunk seams when neither side is glue/closing punctuation.
2. `TextInjector.finalizeForInsertion` — strips stranded terminal punctuation and inserts a leading space based on `Insertion target`.

## Why This Matters

**Output tokens are 6× the price of input tokens** (Gemini 3.x pricing). Asking the model to re-emit the entire transcript on every chunk would scale output cost linearly with chunk count for the same audio. A 10-chunk session would cost ~10× the output bill of a 1-chunk session for the same final text.

**Re-emission also defeats the caching strategy.** The implicit cache hit lives in the prefix; the response is uncached output by design. Padding output is the most expensive thing we could do.

## When to Apply

- Always — every Gemini transcription path uses local concat.
- The model **must not** be asked to re-emit. The "Don't ask Gemini to re-emit the full transcript" rule lives in `NoType/Gemini/CLAUDE.md` "What you must NEVER do" precisely because of this.

## Examples

**Trade-off accepted:** Slight risk of seam artefacts at chunk boundaries (capitalisation, punctuation). The system prompt instructs the model to handle these consistently; `stitchChunks` + `finalizeForInsertion` patch the residual cases deterministically. We may need to tune the prompt to reduce seams; that's prompt work, not architecture.

**The pattern in code** (`NoType/Recording/RecordingSession.swift::stop`):

```swift
// `responses` is the per-call outcome list — each entry is one of:
//   text: "<real>"  — Gemini returned, length-gate passed
//   text: nil       — recoverable failure; substituted with failureMarker ("[…]")
//   text: ""        — gate-emptied by HallucinationLengthGate; stitches as empty (no marker, by design)
let pieces   = responses.map { $0.text ?? Self.failureMarker }
let stitched = TextInjector.stitchChunks(pieces)
let final    = TextInjector.finalizeForInsertion(
    stitched,
    textBeforeCursor: target.textBefore,
    textAfterCursor:  target.textAfter
)
```

The three-state `text` contract is important: `nil` is "Gemini didn't respond for us — leave a visible gap"; `""` is "Gemini responded but we filtered the output as noise — leave nothing". The empty-string path is deliberately invisible (no marker), since the gate's job is to suppress the very content a marker would draw attention to.

**Assembly happens twice, over the same sequence, for two different destinations.** The block above is the *paste* path — the one that ends at the user's cursor and is final once it lands. The history row assembles the same per-call outcomes independently, via `HistoryText.assemble`, because a row stores the sequence rather than the pasted string:

```swift
// NoType/History/HistoryText.swift
TextInjector
    .stitchChunks(segments.map { $0.text ?? RecordingSession.failureMarker })
    .trimmingCharacters(in: .whitespacesAndNewlines)
```

Same `stitchChunks` rule, deliberately **not** `finalizeForInsertion`: that pass strips stranded terminal punctuation and inserts a leading space using the *cursor's surroundings*, which are a fact about the user's document and not about the transcript. So a row may legitimately keep a sentence-final period the paste trimmed. Both are whitespace splits, so word counts are unaffected. The client-owns-assembly rule is what makes two consumers of one sequence possible at all; a model-side re-emit would have left exactly one string, produced once, at paste time.

## Related

- `NoType/Injection/CLAUDE.md` — `stitchChunks` + `finalizeForInsertion` shapes.
- `NoType/Gemini/CLAUDE.md` "What you must NEVER do".
- `solutions/architecture-patterns/partial-recovery-with-markers-2026-05-16.md` — partial-recovery layer that rides on this assembly contract (markers stitched in place of failed chunks, never sent as priors), and why the marker is a *rendered* thing rather than the stored one.
- `NoType/History/CLAUDE.md` — the stored response sequence and the second assembly, `HistoryText`.
- `solutions/architecture-patterns/hallucination-length-gate-2026-05-20.md` — post-response gate that emits the third stitch state (`""`, no marker).
- `docs/decisions.md` ADR-008 — legacy index entry, redirects here.
- `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md` — the serial dispatch that makes "prior chunks are deterministic" true.
- `architecture.md` invariant I2 — the "local concatenation, never re-emit" rule.
