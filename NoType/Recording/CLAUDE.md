# Recording module

This module owns audio capture, voice activity detection, and chunk slicing. It is the **most complex part of NoType** — read this whole file before changing anything here.

Files:
- `AudioRecorder.swift` — `AVAudioEngine` setup, async-stream of VAD windows, wraps `PCMRingBuffer`.
- `PCMRingBuffer.swift` — fixed-capacity wrap-around ring with absolute sample indexing. O(1) discard.
- `AudioDeviceManager.swift` — Core Audio HAL wrapper for input-device discovery and HAL-property listeners.
- `SileroVAD.swift` — CoreML wrapper around the unified-256 ms Silero v6 model.
- `PauseDetector.swift` — turns Silero frame probabilities into chunk boundaries.
- `ChunkBuilder.swift` — encodes PCM slices to AAC-in-M4A blobs for upload.
- `RecordingSession.swift` — orchestrates the above, owns session lifecycle, drives the batched sender.
- `Resources/SileroVAD.mlmodelc` — compiled CoreML model (repackaged from FluidInference/silero-vad-coreml).

---

## Audio capture

Use `AVAudioEngine`, not `AVCaptureSession`:

- Tap the input node at its **hardware-native** sample rate (Macs usually 44.1 or 48 kHz, BT headsets 16 or 24 kHz).
- Resample to **16 kHz mono float32** in software using an `AVAudioConverter`. Silero requires 16 kHz; the converter's filter state is preserved across taps by returning `.noDataNow` (not `.endOfStream`) once each input buffer has been consumed — signalling end-of-stream per buffer corrupts audio. See the doc-comment on `ConverterFeed` in `AudioRecorder.swift`.
- VAD window size: **4096 samples (256 ms)** — matches the unified Silero v6 model's `chunkSize` (see below). Each window yielded by `AudioRecorder`'s `AsyncStream<[Float]>` is exactly this size.

```swift
let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
)!
```

---

## PCM buffer

`AudioRecorder` keeps resampled PCM in a `PCMRingBuffer` — a fixed-capacity wrap-around ring guarded by `AudioRecorder.lock`. Capacity is 35 s @ 16 kHz (560 000 samples ≈ 2.24 MB), comfortably above `PauseDetector.maxChunkSamples = 30 s`.

Why a ring (and not a plain `[Float]`):

1. **Pre-roll** for VAD onset latency (see below).
2. **Chunk slicing** — when a pause is detected, we slice `[lastChunkEnd … pauseStart]` from the buffer and ship it for encoding.
3. **Bounded memory** — `RecordingSession.processBatch` calls `recorder.discardSamples(beforeAbsolute:)` after each successful chunk ship. On the ring this is O(1) — it just advances the `head` index. The previous linear `[Float]` implementation paid an O(N) `memmove` on every discard, which compounded badly on continuous-speech sessions.

Callers (`PauseDetector`, `RecordingSession`) work in **absolute sample indices** counted from session start. The ring exposes the same contract: `pcm.samples(from:to:)`, `pcm.discard(beforeAbsolute:)`, `pcm.totalSamples`. Internally the ring carries `head` (absolute index of the oldest valid sample) and a `count`, and computes storage slots via `abs % capacity`.

**Overflow policy:** if the producer ever fills the 35 s ring (i.e. the consumer fell behind for that long and no `discardSamples` ran), the oldest samples are silently overwritten and `head` advances to compensate. With the 30 s force-cut in `PauseDetector` this should never happen in normal sessions — it's a defensive fallback rather than a behaviour we rely on.

---

## Silero VAD via CoreML

**Model.** Unified-256 ms variant of Silero v6 — repackaged from FluidInference/silero-vad-coreml as `SileroVAD.mlmodelc`, bundled in `NoType/Recording/Resources/`. **No conversion script lives in the repo today** — if we ever need to re-generate the model (e.g. upstream bug fix), the conversion path is `coremltools` against Silero's published ONNX.

**Why CoreML and not ONNX Runtime:**
- Native; the 256 ms model lands on the Apple Neural Engine on M-series chips.
- One fewer dependency (ONNX Runtime for Swift is ~10 MB, fiddly to vendor).
- CoreML model load is faster than ONNX init.

**Trade-off:** if the conversion ever loses fidelity on an updated Silero version, we may need to fall back to onnxruntime-swift. **Verify conversion quality before v1** by running a fixture-based test that compares CoreML output to reference ONNX output across known voiced/unvoiced clips.

**Tensor contract** (from the bundled `metadata.json`):

| Direction | Name | Shape | Notes |
|---|---|---|---|
| input | `audio_input` | `[1, 4160]` | 64 ctx + 4096 new samples (16 kHz float32) |
| input | `hidden_state` | `[1, 128]` | LSTM hidden, zeros on first call |
| input | `cell_state` | `[1, 128]` | LSTM cell, zeros on first call |
| output | `vad_output` | `[1, 1, 1]` | Speech probability ∈ [0, 1] |
| output | `new_hidden_state` | `[1, 128]` | Feed back next call |
| output | `new_cell_state` | `[1, 128]` | Feed back next call |

The model is **stateful**: `SileroVAD` (an `actor`) carries `hiddenState`, `cellState`, and a 64-sample look-back (`carriedContext`) across calls. Reset all three at session start via `vad.reset()`.

**Speech threshold.** Default 0.5 in `PauseDetector.voicedFrameThreshold`. Lower (e.g. 0.3) makes the detector more sensitive for noisy environments; higher (0.7) reduces false starts on coughs. Not exposed in Settings yet.

---

## Pre-roll buffer (CRITICAL — solves "Silero cuts the start")

Any windowed VAD has onset latency: it needs at least one window of evidence before it confidently classifies "speech started". By the time `isVoiced` flips from false to true, the *actual* speech started up to one window earlier — 256 ms with the unified model.

If we naively slice chunks from the moment Silero says "voiced," we lose leading consonants of every phrase after a pause. Unacceptable.

**Solution:** every chunk's start is rewound by **300 ms** before encoding. Concretely:

- When a chunk boundary is decided, the slice range is `[chunkStart - 300 ms … chunkEnd]`, clamped at 0.
- For chunks 2..N this means a small overlap with the *gap* before the chunk (silence/breath). That's fine — Gemini handles it. We do *not* overlap with the previous chunk's audio.
- For chunk 1 (very start of session), the rewind still applies — captures the first phoneme if the user started talking the instant they pressed the hotkey.

Constants (in `PauseDetector.init`):
```swift
voicedFrameThreshold     = 0.5           // Silero probability cutoff
minVoicedRunForChunkStart = 1            // 1 voiced window = 256 ms — already plenty
pauseThresholdSamples    = 16_000        // 1.0 s @ 16 kHz
preRollSamples           = 4_800         // 300 ms @ 16 kHz
```

Bump `minVoicedRunForChunkStart` to 2 (≈ 512 ms) if false starts on coughs/sniffs become a problem.

---

## Chunk decision logic

State machine inside `PauseDetector`:

```
                ┌──────────┐
                │   Idle   │  no chunk in progress
                └────┬─────┘
                     │ ≥ minVoicedRunForChunkStart voiced frames
                     ▼
                ┌──────────┐
                │ Speaking │  recording into current chunk
                └────┬─────┘
                     │ unvoiced run starts
                     ▼
                ┌──────────┐
                │  Pausing │  unvoiced for < 1.0 s
                └─┬─────┬──┘
        unvoiced │     │ voiced frame
        ≥1.0 s   │     └─────▶ back to Speaking
                 ▼
        emit Chunk(start: chunkStart - 300ms, end: pauseStart)
        reset chunkStart = 0
        ▼ (back to Idle until next voiced run)
```

`pauseStart` is the timestamp of the *first* unvoiced frame in the run, not the last. This way the chunk boundary is at the natural end-of-phrase, not 1 second past it.

`PauseDetector.finalize(currentEnd:)` force-emits whatever chunk is in progress when the session ends (called from `RecordingSession.emitFinalChunkIfAny()`). Returns `nil` only if the user released without producing any voiced frames.

---

## Encoding to AAC

`ChunkBuilder.encodeAAC(_:)` round-trips PCM through `AVAudioFile` on a temp m4a file (then reads back into `Data` and deletes the file). The encoder writes the m4a `moov` atom on `AVAudioFile.deinit`, so the scope of the file variable is load-bearing — reading earlier yields a truncated file.

Settings:
```swift
[
    AVFormatIDKey:         kAudioFormatMPEG4AAC,
    AVSampleRateKey:       16_000,
    AVNumberOfChannelsKey: 1,
    AVEncoderBitRateKey:   32_000,  // 32 kbps is plenty for speech at 16 kHz
]
```

Output is an AAC-in-M4A blob (~4 KB/s of speech). MIME for the Gemini request is `audio/mp4` — see `NoType/Gemini/CLAUDE.md` for the request shape.

The temp-file round-trip costs ~20–50 ms per chunk on Apple Silicon SSDs. Tracked as a perf improvement: switch to in-memory encoding via `AudioConverter` / `ExtAudioFile`.

---

## Lifecycle

`RecordingSession` is created on hotkey press, destroyed on release.

Init flow:
1. Capture `NSWorkspace.frontmostApplication` synchronously on `@MainActor` (also grabs its `processIdentifier` for the optional OCR limb).
2. Launch a detached `Task` that builds `ContextSnapshot` from three siblings running in parallel, **each under its own wall-clock safety cap** (no joint deadline):
   - `AccessibilityTree.snapshot()` — always; 1500 ms cap.
   - `InsertionTarget.capture()` — always; uncapped (synchronous, fast).
   - `ScreenCaptureContext.capture(activeApp:pid:)` — **only when** `ScreenRecordingPermission.current() == .granted` (ADR-014); 2500 ms cap. The result is included in the final `ContextSnapshot.screenText` **only if** the AX dump for the active app's bundle id came back contentless (`tree.hasContent(for:) == false`); otherwise it's dropped. One log line per session: `ocr=on (reason)` / `ocr=off (reason)`.
3. Start `AudioRecorder` — this returns an `AsyncStream<[Float]>` of VAD windows. The PCM buffer fills immediately.
4. Spawn the VAD consumer (a detached task that pulls frames, calls `SileroVAD.probability`, drives `PauseDetector`, and forwards chunk boundaries back to the `@MainActor` session via `enqueueChunk`).
5. **Today** the VAD consumer starts as soon as `recorder.start()` returns; the "first chunk waits for context" invariant is enforced downstream in `processBatch`, which `await`s the `contextTask` before sending. For most sessions the first audio chunk can't arrive until ≥1 s after press (VAD pause threshold), so OCR latency is masked by speech time. The per-task caps are safety belts against wedged AX / Vision, not perceived-latency budgets — see `NoType/Context/CLAUDE.md` "Deadline contract".

Press → release flow:
1. VAD consumer emits chunks; each goes into `pending`.
2. A single sender task drains `pending`, encoding the queued chunks and issuing either `transcribe` (single) or `transcribeBatch` (multiple) on the Gemini client.
3. On release: `recorder.stop()` finishes the async stream → VAD consumer drains and exits → `emitFinalChunkIfAny()` queues the tail chunk with `isFinal=true`. The sender drains this batch (final + anything queued behind a slow in-flight call) in one round-trip.
4. Await the sender. Run `TextInjector.stitchChunks(transcripts)` to join chunks, inserting a space between non-whitespace neighbors at the seam unless the next chunk starts with glue punctuation or the prior chunk ends with a left-ambiguous symbol (see `NoType/Injection/CLAUDE.md`). Then `finalizeForInsertion(stitched, textBefore:, textAfter:)` → `TextReplacementEngine.apply(_:replacements:)` to apply user-defined word replacements (see `NoType/Dictionary/CLAUDE.md` / ADR-016) → paste → append to history.
5. Tear down: stop engine, drop the recorder, clear context snapshot.

### Quick-release optimisation (final-batch only)

Mid-session batches (VAD-pause-triggered) `await` the `contextTask` fully — the user is clearly speaking and richer context = better transcription. **Final** batches (user release) skip the await: the sender consults `cachedContext` (the main-actor mirror of `contextTask`'s eventual value), and if context isn't ready yet, ships the chunk with `ContextSnapshot.minimal(activeApp:)`. Rationale: a fast tap-and-release session shouldn't sit blocked behind the 2.5 s OCR cap. The `insertion target` read in `stop()` follows the same rule for the same reason — empty target means `finalizeForInsertion` skips its boundary-punctuation patching (acceptable degradation; tests pin both branches).

Discriminator: `batch.contains { $0.isFinal }`. Only the final chunk arrives via user-release; mid-session chunks come from `PauseDetector`.

If the release happens during silence (no audio since last chunk), `PauseDetector.finalize` returns `nil` → no final Gemini request → `finalizeForInsertion` cleans up any stranded terminal punctuation from the last non-final chunk on the client.

---

## Hard caps

- **No hard session cap on wall-clock time.** A held hotkey can record indefinitely; RAM stays bounded *as long as the user pauses occasionally* because `discardSamples` runs after each shipped chunk. A continuous monologue without pauses still grows linearly — see the "PCM buffer" section above.
- **Min chunk duration: 150 ms** (`pcm.count < 2_400` in `RecordingSession.processBatch`). Below this we skip the Gemini call. Edge case: user taps Right Option briefly by accident → no-op.

---

## Testing

Tests live in `NoTypeTests/`. Present today:

- `GeminiRequestBuilderTests.swift` — prompt-assembly path; pins the cached-prefix shape.
- `InsertionTargetTests.swift` — UTF-16 slicing logic.
- `TextInjectorTests.swift` — `finalizeForInsertion` branches.
- `SecureFieldMaskerTests.swift` — security-boundary masker (skip rules + content patterns + idempotence).
- `PauseDetectorTests.swift` — state-machine fixtures driving synthetic VAD probability sequences, including the 30 s force-cut.
- `ChunkBuilderTests.swift` — round-trip PCM → AAC-in-M4A: valid `ftyp` container, decodable by `AVAudioFile`, no tmp-file leaks, short-input handling.

Still missing (tracked):
- `SileroVADTests` — CoreML output vs reference ONNX (gated, needs fixture clips).

Do not write tests against live mic input — non-deterministic. Use fixtures.

---

## Known sharp edges

- **Bluetooth headsets** can introduce 200–500 ms of input latency that varies per device. Pre-roll covers most cases; if it doesn't, the 300 ms is a constant in `PauseDetector` (not user-settable yet).
- **Mid-session input-device swap.** Handled: `AudioRecorder` observes `AVAudioEngineConfigurationChange`, tears down the tap, and rebuilds against the new input format without ending the session. The accumulated PCM buffer is preserved; the splice is a few ms of silence at most.
- **Manual device selection.** `AudioDeviceManager` (Core Audio HAL wrapper) lists every input device on the system and pins the user's choice via `kAudioOutputUnitProperty_CurrentDevice` on `engine.inputNode.audioUnit`. Selection persists across launches (`UserDefaults` key `notype.selectedInputDeviceUID`); the popover footer is the picker. `nil` = follow system default.
- **Accents / non-English speech in noisy environments.** Silero is multilingual, but performance varies. If complaints arrive, expose `voicedFrameThreshold` in Settings.
