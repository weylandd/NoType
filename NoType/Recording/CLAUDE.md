# Recording module

**Most complex part of the project.** Owns audio capture, voice activity detection, and chunk slicing.

## Files

- `AudioRecorder.swift` — `AVAudioEngine` setup; async stream of VAD windows; wraps `PCMRingBuffer`.
- `PCMRingBuffer.swift` — fixed-capacity wrap-around ring with absolute sample indexing. O(1) discard.
- `AudioDeviceManager.swift` — Core Audio HAL wrapper for input-device discovery + HAL-property listeners.
- `SileroVAD.swift` — CoreML wrapper around the unified-256 ms Silero v6 model.
- `PauseDetector.swift` — turns Silero frame probabilities into chunk boundaries.
- `ChunkBuilder.swift` — encodes PCM slices to AAC-in-M4A blobs.
- `RecordingSession.swift` — orchestrates the above; owns session lifecycle; drives the batched sender.
- `Resources/SileroVAD.mlmodelc` — compiled CoreML model (FluidInference/silero-vad-coreml repack).

## Invariants

1. **Audio = 16 kHz mono float32.** Resampled from hardware-native rate via `AVAudioConverter`. Silero requires 16 kHz.
2. **VAD window = 4096 samples (256 ms).** Matches Silero v6 unified `chunkSize`. Don't change without re-fixturing `PauseDetectorTests`.
3. **Pre-roll = 4800 samples (300 ms).** Every chunk's start is rewound by this much to capture leading consonants lost to VAD onset latency. Constant in `PauseDetector.init`.
4. **Adaptive pause threshold.** Base = 16 000 samples (1.0 s) for chunks under 20 s; steps down to 11 200 (700 ms) for 20–40 s, 8 000 (500 ms) at and beyond 40 s. The ladder lives in `PauseDetector.pauseThresholdSamples(forChunkLength:)`. The early step-down keeps chunks small enough that each Gemini request fits inside the 30 s `timeoutIntervalForResource` budget in `GeminiClient` — chunks after the 20 s rung typically clock 20–40 s of audio, well under the network ceiling. 500 ms is the floor on purpose — at ~300 ms stop-consonant closures and inter-phrase micropauses start producing false cuts.
5. **Max chunk size = 180 s** (`PauseDetector.maxChunkSamples`). Continuous monologue force-cuts at this boundary, but in practice the adaptive threshold (#4) catches the first ≥500 ms breath long before this fires. If you ever observe a 180 s chunk hitting Gemini, revisit the resource timeout in `GeminiClient.init` first.
6. **PCM ring capacity = 190 s** (3 040 000 samples ≈ 12 MB at 16 kHz). Comfortably above the 180 s force-cut; overflow drops oldest silently as last-resort.
7. **Min chunk for upload = 150 ms** (`pcm.count >= 2400`). Below this, the chunk is skipped (accidental tap).
8. **Silero is stateful.** `hiddenState`, `cellState`, and a 64-sample `carriedContext` look-back persist across calls. Reset all three at session start via `vad.reset()`.
9. **First chunk waits for context snapshot.** Sender `await`s `contextTask.value` before issuing the first Gemini call. Audio capture itself starts immediately on hotkey press.
10. **`RecordingSession` is a value, not a global.** Created on press, dropped on release. There is no "current session" singleton.
11. **Lite-path discriminator:** `isFinalBatch && transcripts.isEmpty && totalAudio < 32 000 samples (2.0 s)`. Pure function `shouldUseLitePath`, pinned by `RecordingSessionShortPathTests`.

## Hard rules

- **`AVAudioConverter` must return `.noDataNow`, not `.endOfStream`, when each input buffer is exhausted.** End-of-stream per buffer corrupts the filter state across taps. See `ConverterFeed` doc-comment in `AudioRecorder.swift`.
- **Mid-session input-device swap is supported.** `AudioRecorder` observes `AVAudioEngineConfigurationChange`, tears down the tap, and rebuilds against the new input format without ending the session. PCM buffer is preserved; splice = a few ms of silence.
- **Default-input picking avoids Bluetooth mics.** When `AudioDeviceManager.preferBuiltInOverBluetooth` is on (default ON) and the user hasn't pinned a device, the recorder falls back to the built-in mic if the system default is a BT headset — keeps the headphones in A2DP and stops the HFP/SCO profile switch from breaking music ducking. Explicit pin via the picker overrides. Policy lives in the pure `AudioDeviceManager.pickEffectiveDevice`; rationale in `solutions/architecture-patterns/bluetooth-input-avoidance-2026-05-16.md`.
- **Lite path bypasses the full prompt entirely.** Different system prompt (`systemPromptLite`), different cache-prefix shape, different namespace at Gemini. By construction single-audio — `precondition(audios.count == 1)` in the Gemini client.
- **`PCMRingBuffer` is `@unchecked Sendable` with NO internal lock.** Contract: only `AudioRecorder`'s lock-guarded tap path mutates in production; tests drive it single-threaded. If a multi-actor use ever appears, wrap it in a lock first.
- **Don't write tests against live mic input.** Use fixtures. Unit tests must be deterministic.

## VAD threshold

`voicedFrameThreshold = 0.5`. Lower (0.3) is more sensitive in noisy environments; higher (0.7) reduces false starts on coughs. **Not exposed in Settings yet.** Bump `minVoicedRunForChunkStart` from 1 to 2 if false starts on coughs / sniffs become a problem.

## Quick-release optimisation

Mid-session batches `await contextTask.value` fully — the user is clearly speaking, richer context = better. **Final** batches consult `cachedContext` (the main-actor mirror) and ship with `ContextSnapshot.minimal(activeApp:)` if not ready, rather than blocking the user behind a slow OCR cap. The lite path layers on top — see invariant 11.

## Lifecycle

Three sibling tasks run in the context phase: `AccessibilityTree.snapshot()`, `InsertionTarget.capture()`, `ScreenCaptureContext.capture(...)` (only when Screen Recording permission is granted). Each under its own wall-clock cap; partial results survive. See `NoType/Context/CLAUDE.md` "Deadline contract".

## Testing

- `NoTypeTests/PauseDetectorTests.swift` — state-machine fixtures (synthetic VAD probability sequences, adaptive-threshold ladder mapping, long-monologue cuts, 180 s force-cut).
- `NoTypeTests/ChunkBuilderTests.swift` — PCM → AAC round-trip (valid `ftyp` container, decodable, no tmp-file leaks).
- `NoTypeTests/RecordingSessionShortPathTests.swift` — pins the lite-path discriminator.
- `NoTypeTests/AudioDeviceManagerTests.swift` — pins the pure `pickEffectiveDevice` policy (pin-wins, BT-classic / BLE-Audio fallback, no-built-in graceful degrade, off-switch honoured) and the `Device.isBluetooth` / `isBuiltIn` transport-type matrix.
- `SileroVADTests` — planned (see `solutions/documentation-gaps/silero-vad-reference-test-2026-05-15.md`).

## Pointers

- Why Silero CoreML (not Apple SpeechDetector) → `solutions/tooling-decisions/silero-vad-coreml-2026-05-15.md`.
- One Gemini request in flight (the sender contract) → `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`.
- Cache-prefix shape (what the sender ships) → `NoType/Gemini/CLAUDE.md`.
- Context snapshot lifecycle → `NoType/Context/CLAUDE.md`.
- Bluetooth input avoidance (built-in mic fallback) → `solutions/architecture-patterns/bluetooth-input-avoidance-2026-05-16.md`.
- AAC encoding tech debt → `solutions/documentation-gaps/in-memory-aac-encoding-2026-05-15.md`.
