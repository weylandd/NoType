---
title: Silero VAD via CoreML (not Apple SpeechDetector)
date: 2026-05-15
category: tooling-decisions
module: Recording
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - Adding or replacing voice-activity detection
  - Considering Apple's Speech / SpeechAnalyzer stack for any audio path
  - Evaluating whether to drop the bundled Silero CoreML model
tags: [vad, silero, coreml, speech-detection, language-agnostic, apple-speech]
---

# Silero VAD via CoreML (not Apple SpeechDetector)

## Context

NoType needs voice-activity detection on the captured mic stream to decide where to slice phrase boundaries (≥1 s of silence triggers a chunk). The detector runs on every 256 ms window of audio, so it must be cheap and behave deterministically across noisy environments and any spoken language Gemini supports. Three candidates were on the table:

1. **Apple's `SpeechDetector` / `SpeechAnalyzer`** — first-party, on-device.
2. **Silero VAD via CoreML** — open-source ML model, language-agnostic.
3. **RMS-energy threshold** — naive amplitude-based detection.

## Guidance

**Use Silero VAD via CoreML** (`NoType/Recording/SileroVAD.swift`, model bundled at `NoType/Recording/Resources/SileroVAD.mlmodelc`). Do not adopt Apple's `SpeechDetector` for this purpose. Do not fall back to RMS-energy thresholds.

## Why This Matters

**Apple's path is locked behind a locale-dependent transcriber.** `SpeechDetector` is acoustically locale-free in its initializer, but Apple explicitly requires it be paired with a transcriber module in the same `SpeechAnalyzer`. The only available transcriber, `SpeechTranscriber`, is `LocaleDependentSpeechModule` and requires a locale from `SpeechTranscriber.supportedLocales` (~38 locales). NoType's whole pitch is "any language Gemini supports" — pinning the VAD to one of 38 locales is unacceptable.

Additional Apple-side costs:

- Language-model assets must be downloaded via `AssetInventory` — another failure mode at first launch.
- As of macOS 26.0 / 26.1 SDK, `SpeechDetector` doesn't formally conform to `SpeechModule`, requiring `as!` workarounds (Apple Forums threads 794510, 797544).
- `SpeechDetector.results` stream has been observed to silently not emit events in some configurations.

**RMS-energy can't distinguish speech from steady noise.** Café / open-office hum, music, or HVAC sustains amplitude — an RMS detector would classify it as voice and never trigger a pause. Silero is an ML model trained to discriminate speech specifically.

**Silero is cheap and stable.** ~2 MB model, ~1–2 ms per 256 ms window on Apple Silicon (unified-256 ms variant). Trained on 6000+ languages. MIT-licensed, mature, broadly used in production.

## When to Apply

- Adding any new voice-activity / pause-detection path — use Silero, don't introduce a second VAD stack.
- Auditing the Recording module for "could we drop the bundled CoreML model?" — the answer is no; the dep is load-bearing.
- Reconsider only if: Apple ships a standalone, locale-free `SpeechDetector` that doesn't require a transcriber pair AND drops the asset-download requirement, OR the Silero CoreML conversion fidelity ever diverges from upstream ONNX (see `NoType/Recording/CLAUDE.md` for the planned fallback to `onnxruntime-swift`).

## Examples

**The path in code:**

```swift
// NoType/Recording/SileroVAD.swift — actor wrapping the CoreML model
let probability = try await vad.probability(window: pcmWindow)
// PauseDetector consumes the probability stream and emits chunk boundaries.
```

**Alternatives that were rejected:**

- **RMS-energy VAD.** Rejected — would falsely classify ambient sound as voice, never detect pauses.
- **Apple `SpeechDetector` + transcriber for VAD only.** Rejected — locale lock-in, asset download, SDK bugs (above).

## Related

- `NoType/Recording/CLAUDE.md` — implementation details (model contract, pre-roll buffer, pause threshold).
- `docs/decisions.md` ADR-002 — legacy index entry, redirects here.
- `solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md` — the transcription model that consumes Silero's chunk boundaries.
