# Recording module

**Most complex part of the project.** Owns audio capture, voice activity detection, and chunk slicing.

## Files

- `AudioRecorder.swift` — Core Audio HAL `AudioDeviceCreateIOProcIDWithBlock` capture path; async stream of VAD windows; wraps `PCMRingBuffer`. Bypasses `AVAudioEngine` deliberately — `engine.start()` implicitly opens an aggregate input+output device that stutters BT-headphone playback for ~1 s on every hotkey press; pure HAL captures input only.
- `PCMRingBuffer.swift` — fixed-capacity wrap-around ring with absolute sample indexing. O(1) discard.
- `AudioDeviceManager.swift` — Core Audio HAL wrapper for input-device discovery + HAL-property listeners. Owns `inputStreamFormat(for:)` and `avAudioFormat(from:)` — the helpers `AudioRecorder` uses to size its `AVAudioConverter` per session.
- `SileroVAD.swift` — CoreML wrapper around the unified-256 ms Silero v6 model.
- `PauseDetector.swift` — turns Silero frame probabilities into chunk boundaries.
- `ChunkBuilder.swift` — encodes PCM slices to AAC-in-M4A blobs.
- `RecordingSession.swift` — orchestrates the above; owns session lifecycle; drives the batched sender.
- `HallucinationLengthGate.swift` — pure post-response sanity check. Drops transcripts whose word AND char rate exceed plausible dictation speed for the audio duration (4 wps / 18 cps, AND-mode, floor 4w / 18c). Catches Gemini Lite's conversational-fallback hallucinations on short low-info audio (BT-HFP mic). Wired into `RecordingSession.processBatch` and `splitRetry` success arms. Lives here (not in `NoType/Gemini/`) because the gate is a post-response policy with no Gemini API coupling — its domain is "did the audio duration justify this transcript length?" against `AudioRecorder.outputSampleRate`.
- `Resources/SileroVAD.mlmodelc` — compiled CoreML model (FluidInference/silero-vad-coreml repack).

## Invariants

1. **Audio = 16 kHz mono float32.** Resampled from the HAL device's native stream format via `AVAudioConverter`. Silero requires 16 kHz. The HAL IOProc receives input in whatever shape the device exposes (typically 44.1 / 48 kHz float32; built-in mics are mono, USB / aggregates may be stereo) — `AVAudioConverter` handles both sample-rate and channel downmix to mono.
2. **VAD window = 4096 samples (256 ms).** Matches Silero v6 unified `chunkSize`. Don't change without re-fixturing `PauseDetectorTests`.
3. **Pre-roll = 4800 samples (300 ms).** Every chunk's start is rewound by this much to capture leading consonants lost to VAD onset latency. Constant in `PauseDetector.init`.
4. **Adaptive pause threshold.** Base = 16 000 samples (1.0 s) for chunks under 20 s; steps down to 11 200 (700 ms) for 20–40 s, 8 000 (500 ms) at and beyond 40 s. The ladder lives in `PauseDetector.pauseThresholdSamples(forChunkLength:)`. The early step-down keeps chunks small enough that each Gemini request fits inside the 30 s `timeoutIntervalForResource` budget in `GeminiClient` — chunks after the 20 s rung typically clock 20–40 s of audio, well under the network ceiling. 500 ms is the floor on purpose — at ~300 ms stop-consonant closures and inter-phrase micropauses start producing false cuts.
5. **Max chunk size = 180 s** (`PauseDetector.maxChunkSamples`). Continuous monologue force-cuts at this boundary, but in practice the adaptive threshold (#4) catches the first ≥500 ms breath long before this fires. If you ever observe a 180 s chunk hitting Gemini, revisit the resource timeout in `GeminiClient.init` first.
6. **PCM ring capacity = 190 s** (3 040 000 samples ≈ 12 MB at 16 kHz). Comfortably above the 180 s force-cut; overflow drops oldest silently as last-resort.
7. **Min chunk for upload = 150 ms** (`pcm.count >= 2400`). Below this, the chunk is skipped (accidental tap).
8. **Silero is stateful.** `hiddenState`, `cellState`, and a 64-sample `carriedContext` look-back persist across calls. Reset all three at session start via `vad.reset()`.
9. **First chunk waits for context snapshot.** Sender `await`s `contextTask.value` before issuing the first Gemini call. Audio capture itself starts immediately on hotkey press.
10. **`RecordingSession` is a value, not a global.** Created on press, dropped on release. There is no "current session" singleton.
11. **Lite-path discriminator:** `isFinalBatch && priorTranscriptCount == 0 && totalAudio < 32 000 samples (2.0 s) && batchChunkCount == 1`. Pure function `shouldUseLitePath` (params `isFinalBatch`, `priorTranscriptCount`, `totalBatchSamples`, `batchChunkCount`), pinned by `RecordingSessionShortPathTests`. The call site passes `currentPriors().count` for the prior count and the post-encode chunk count (`encoded.count`) for `batchChunkCount`; only chunks whose Gemini call *succeeded* contribute to the prior count. Recoverable failures (markers) don't disqualify the lite path because the prior section would render `(none yet)` either way. The `batchChunkCount == 1` term is load-bearing: the lite dispatch ships `encoded[0]` only (`transcribeShort` is single-audio by construction), so a ≥2-chunk short final batch must take the batched path or every chunk after the first would be silently dropped.
12. **Partial recovery.** A recoverable Gemini failure on one chunk (network blip, 5xx, decoding, mid-session empty) appends a `text: nil` response and `failureMarker` ("[…]") appears in its slot at stitch time. The session aborts only on terminal errors (auth, blocked, encode, cancellation — see `RecordingSession.isTerminal(_:)`). A batched call that fails recoverably is split into N independent `transcribe` calls; one bad chunk no longer poisons the others. When every dispatched chunk fails, `stop()` throws `lastRecoverableError` so the AppState error catalog surfaces the real cause (offline / 5xx / …) rather than the generic `noSpeech`.

## Hard rules

- **`AVAudioConverter` must return `.noDataNow`, not `.endOfStream`, when each input buffer is exhausted.** End-of-stream per buffer corrupts the filter state across IOProc invocations. See `ConverterFeed` doc-comment in `AudioRecorder.swift`.
- **Mid-session input-device swap is supported.** `AudioRecorder` installs a HAL property listener on `kAudioHardwarePropertyDefaultInputDevice` for the session's lifetime; on fire it tears down the IOProc, rebuilds the `AVAudioConverter` against the new device's stream format, and reopens against the new effective device — without ending the session. PCM buffer is preserved; splice = a few ms of silence. `teardownHAL` drains `ioQueue` between `AudioDeviceStop` and `AudioDeviceDestroyIOProcID` so a late-enqueued IOProc block can't alias the new `inputFormat` against the old device's bytes (which the HAL may have already reclaimed).
- **No `AVAudioEngine` in the recording path.** The legacy `AVAudioEngine` + `installTap` + `AVAudioEngineConfigurationChange` shape kicks an output-side aggregate device on `engine.start()` and stutters BT-headphone playback. Pure HAL via `AudioDeviceCreateIOProcIDWithBlock` is input-only and avoids the aggregate. If a future refactor reintroduces `AVAudioEngine` here, document why and benchmark against AirPods + Apple Music first — see plan 2026-05-18-001 §31–37 and the SuperMegaUltraGroovy / AudioKit links there.
- **Default-input picking avoids Bluetooth mics.** When `AudioDeviceManager.preferBuiltInOverBluetooth` is on (default ON) and the user hasn't pinned a device, the recorder falls back to the built-in mic if the system default is a BT headset — keeps the headphones in A2DP and stops the HFP/SCO profile switch from breaking music ducking. Explicit pin via the picker overrides. Policy lives in the pure `AudioDeviceManager.pickEffectiveDevice`; rationale in `solutions/architecture-patterns/bluetooth-input-avoidance-2026-05-16.md`.
- **Lite path bypasses the full prompt entirely.** Different system prompt (`systemPromptLite`), different cache-prefix shape, different namespace at Gemini. By construction single-audio — `precondition(audios.count == 1)` in the Gemini client.
- **`PCMRingBuffer` is `@unchecked Sendable` with NO internal lock.** Contract: only `AudioRecorder`'s lock-guarded IOProc path mutates in production (the IOProc block dispatched onto `ioQueue`); tests drive it single-threaded. If a multi-actor use ever appears, wrap it in a lock first.
- **Don't write tests against live mic input.** Use fixtures. Unit tests must be deterministic.

## VAD threshold

`voicedFrameThreshold = 0.5`. Lower (0.3) is more sensitive in noisy environments; higher (0.7) reduces false starts on coughs. **Not exposed in Settings yet.** Bump `minVoicedRunForChunkStart` from 1 to 2 if false starts on coughs / sniffs become a problem.

## Partial recovery

The session stitches `responses: [ChunkResponse]` rather than the old `transcripts: [String]`. Each `ChunkResponse` carries the chunk indices it covers, whether it's the final chunk, and a `text: String?` — `nil` when the Gemini call failed recoverably. At `stop()` we map `text ?? failureMarker` per response and stitch the result, giving the user a complete transcript with `[…]` placeholders where chunks dropped.

Error classification lives in `RecordingSession.isTerminal(_:)`:

| Error | Class | Behaviour |
|---|---|---|
| `CancellationError` | terminal | abort, no paste |
| `GeminiError.missingKey` | terminal | abort, surface "add API key" |
| `GeminiError.blocked(_)` (prompt-level block **or** candidate-level `finishReason` content block) | terminal | abort, surface block reason |
| Any other `Error` (e.g. encoder, `AVFAudio`) | terminal | abort, surface as-is |
| `GeminiError.http(_, _)` (any status) | recoverable | marker, continue |
| `GeminiError.empty` | recoverable | marker, continue |
| `GeminiError.decoding(_)` | recoverable | marker, continue |
| `GeminiError.truncated` (`finishReason == MAX_TOKENS`) | recoverable | marker, continue |

A batched call (`transcribeBatch`) failing recoverably triggers `splitRetry` — each chunk re-issued as an independent `transcribe`. Each independent call has its own retry budget inside `GeminiClient.sendRequest` (HTTP-class-based, see "Retry policy" in the Gemini module). Markers in the priors list are *not* sent back to Gemini — `currentPriors()` filters them out so the model never sees its own failure placeholders.

`AppState.finalizeRecording` reads `session.summary` after `stop()` returns; when `hasFailures` is true it surfaces a neutral "Pasted with gaps" HUD telling the user how many chunks ended up as markers.

## Post-response hallucination gate

After a successful Gemini call returns, `processBatch` and `splitRetry` pass `result.text` through `HallucinationLengthGate.apply(...)` (sibling file in this module). When the gate fires it returns `""` and that `""` is stored as `text: ""` (not `nil`) in `ChunkResponse`. This is **a third state** alongside the partial-recovery contract above:

| `text` value | Source | `hasFailures` impact | Stitch behaviour |
|---|---|---|---|
| `"<real text>"` | Gemini returned text that passed the gate | none | concatenated normally |
| `nil` | Recoverable Gemini failure (`recordRecoverableFailure`) | `+1` | replaced with `failureMarker` (`[…]`) |
| `""` | Gate fired on disproportionate length | none | stitched as empty (no marker) |

The empty-string state is deliberate: a gate-drop is not a recovery failure (Gemini answered, we filtered it), so it doesn't count toward "Pasted with gaps". In a single-chunk session the stitched result becomes `""` → `stop()` throws `SessionError.noSpeech` → AppState surfaces the standard "no speech" Error HUD. In a multi-chunk session where one chunk gate-drops and others succeed, the user gets the surviving text with no marker for the dropped chunk — by design, since the empty string is the gate's "this is hallucination noise, not real speech" verdict.

Gate behaviour and threshold rationale live in `HallucinationLengthGate.swift` doc-comment. Wire-in happens at the success arms of `processBatch` (uses sum of all encoded chunk samples as duration denominator) and `splitRetry` (uses per-chunk samples). For batched calls covering N chunks, the gate sees the joined transcript against summed duration — by construction less likely to fire than on lite-path single-chunk calls.

## Quick-release optimisation

Mid-session batches `await contextTask.value` fully — the user is clearly speaking, richer context = better. **Final** batches consult `cachedContext` (the main-actor mirror) and ship with `ContextSnapshot.minimal(activeApp:)` if not ready, rather than blocking the user behind a slow OCR cap. The lite path layers on top — see invariant 11.

## Lifecycle

Three sibling tasks run in the context phase: `AccessibilityTree.snapshot()`, `InsertionTarget.capture()`, `ScreenCaptureContext.capture(...)` (only when Screen Recording permission is granted). Each under its own wall-clock cap; partial results survive. See `NoType/Context/CLAUDE.md` "Deadline contract".

## SleepAssertion integration

`AppState` owns a single `activeSleepAssertion: SleepAssertion?` (`@MainActor`-isolated, `final class` RAII wrapper around `IOPMAssertionCreateWithName`). Acquisition is gated by the `notype.preventSleepDuringRecording` toggle.

- **Acquire** — `AppState.handleHotkeyPress` calls `acquireSleepAssertionIfNeeded()` after a successful `session.start()`. No-op when the toggle is off OR when an assertion already exists.
- **Release** — `AppState.releaseSleepAssertion()` is wired into the three terminal session-end paths inside `finalizeRecording`/`cancelRecording`:
  1. `finalizeRecording` success arm (after paste).
  2. `finalizeRecording` catch arm (terminal error from `RecordingSession.stop()`).
  3. `cancelRecording` (Esc / cancel binding / HUD close).
- **Recoverable failures do NOT release** — partial-recovery flows (chunk markers, split-retry) keep the session alive, so the assertion survives until a terminal end path fires. The `CancellationError` catch arm of `finalizeRecording` deliberately doesn't double-release: `cancelRecording` already did it synchronously.

The class is `final` for the deinit safety net only — `IOPMAssertionRelease` runs via `deinit` if the explicit `release()` was skipped (programmer mistake; the production paths always call `release()` first). Ownership lives on `AppState` rather than on the `RecordingSession` value type to avoid double-release if a session copy gets dropped during partial recovery — plan §304 / §314.

## Testing

- `NoTypeTests/PauseDetectorTests.swift` — state-machine fixtures (synthetic VAD probability sequences, adaptive-threshold ladder mapping, long-monologue cuts, 180 s force-cut).
- `NoTypeTests/ChunkBuilderTests.swift` — PCM → AAC round-trip (valid `ftyp` container, decodable, no tmp-file leaks).
- `NoTypeTests/RecordingSessionShortPathTests.swift` — pins the lite-path discriminator.
- `NoTypeTests/RecordingSessionOCRGateTests.swift` — pins the pure `shouldRunOCR` gate (fallback toggle × Screen Recording permission × pid).
- `NoTypeTests/HallucinationLengthGateTests.swift` — pins the pure `HallucinationLengthGate` decision (word/char ceilings, AND-mode, floor, edges) against representative fixture transcripts.
- `NoTypeTests/AudioDeviceManagerTests.swift` — pins the pure `pickEffectiveDevice` policy (pin-wins, BT-classic / BLE-Audio fallback, no-built-in graceful degrade, off-switch honoured), the `Device.isBluetooth` / `isBuiltIn` transport-type matrix, and the HAL stream-format helpers (`avAudioFormat(from:)` round-trip for built-in 44.1 kHz mono, USB 48 kHz mono, aggregate 48 kHz stereo shapes).
- `NoTypeTests/AudioRecorderHALTests.swift` — `AudioRecorder.AudioError` `errorDescription` contract (no-input-device / stream-format-unavailable / converter-create / IOProc-create / IOProc-start surfaces consumed by `AppState.surfaceError`) plus the load-bearing constants `outputSampleRate = 16 000` and `frameSize = 4 096`. Live-mic behaviour is out of scope per the hard rule — see hardware-smoke protocol in plan 2026-05-18-001 §85–88.
- `SileroVADTests` — planned (see `solutions/documentation-gaps/silero-vad-reference-test-2026-05-15.md`).

## Pointers

- Why Silero CoreML (not Apple SpeechDetector) → `solutions/tooling-decisions/silero-vad-coreml-2026-05-15.md`.
- One Gemini request in flight (the sender contract) → `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`.
- Partial recovery via gap markers (what `processBatch`'s catch-block does, why every classifier branch is what it is) → `solutions/architecture-patterns/partial-recovery-with-markers-2026-05-16.md`.
- Post-response hallucination gate (threshold rationale, AND-mode, out-of-scope sub-classes) → `solutions/architecture-patterns/hallucination-length-gate-2026-05-20.md`.
- Cache-prefix shape (what the sender ships) → `NoType/Gemini/CLAUDE.md`.
- Context snapshot lifecycle → `NoType/Context/CLAUDE.md`.
- Bluetooth input avoidance (built-in mic fallback) → `solutions/architecture-patterns/bluetooth-input-avoidance-2026-05-16.md`.
- AAC encoding tech debt → `solutions/documentation-gaps/in-memory-aac-encoding-2026-05-15.md`.
