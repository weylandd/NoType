---
title: SileroVAD CoreML vs ONNX reference test (planned)
date: 2026-05-15
category: documentation-gaps
module: Recording
problem_type: documentation_gap
component: testing_framework
severity: medium
applies_when:
  - Swapping or updating the bundled SileroVAD CoreML model
  - Investigating a regression in pause-detection quality
tags: [silero, vad, coreml, onnx, regression-test, tech-debt]
---

# SileroVAD CoreML vs ONNX reference test (planned)

## Context

`NoType/Recording/CLAUDE.md` asks us to verify the CoreML conversion of Silero v6 unified-256 produces the same outputs as the reference ONNX model within tolerance. The Recording module has fixture-driven tests for `PauseDetector` and `ChunkBuilder` but **not for `SileroVAD` itself**.

## Guidance

When swapping or re-converting the model, add a fixture-based regression test that compares the CoreML output to a pinned ONNX reference across a set of voiced / unvoiced clips. Until then, monitor user reports of "cut-off start syllables" as the leading-indicator signal.

## Why This Matters

The model has been stable in production — no user reports of degraded VAD quality. A regression would manifest as users reporting cut-off start syllables, which is visible quickly. But a pinned fixture comparison would catch silent drift on a future model swap without waiting for user feedback.

## When to Apply

- Any PR that touches `NoType/Recording/Resources/SileroVAD.mlmodelc` or its conversion script.
- Any PR that touches `SileroVAD.swift`'s tensor contract (hidden state shape, `audio_input` length, threshold logic).

## Examples

The test would need:

- Short voiced / unvoiced WAV fixtures committed to the repo (a few KB each).
- A reference-output JSON generated once from the ONNX model and committed.
- A `SileroVADTests.swift` that loads the fixture, runs CoreML, asserts probability ∈ reference ± tolerance.

Approximate effort: **M**.

## Related

- `NoType/Recording/CLAUDE.md` "Silero VAD via CoreML" — model contract.
- `solutions/tooling-decisions/silero-vad-coreml-2026-05-15.md` — the underlying decision.
- `docs/TECHDEBT.md` — legacy index entry, redirects here.
