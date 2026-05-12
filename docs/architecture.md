# Architecture

This document describes the runtime architecture of NoType — the data flow during a push-to-talk session and the invariants that hold the system together. For component-level detail, see the per-module `CLAUDE.md` files.

---

## High-level data flow

```
┌──────────────────────┐
│   Right Option key   │  CGEventTap monitors flagsChanged,
│   (push-to-talk)     │  detects right-Option via the per-side bit (0x40)
└──────────┬───────────┘
           │ press
           ▼
┌──────────────────────────────────────────────────────────────────┐
│                     Recording session                             │
│                                                                   │
│  AVAudioEngine ──▶ PCM buffer (16 kHz mono float32, in-memory)   │
│         │                │                                        │
│         │                ▼                                        │
│         │         Silero VAD (CoreML, unified-256 ms)             │
│         │         4096-sample windows, pre-roll 300 ms            │
│         │                │                                        │
│         │                │ pause ≥ 1.0 s detected                 │
│         │                ▼                                        │
│         │         ┌──────────────┐                                │
│         │         │ Chunk N      │  PCM since lastChunkEnd        │
│         │         │ (m4a/AAC)    │  encoded for upload            │
│         │         └──────┬───────┘                                │
│         │                │                                        │
│         │                ▼                                        │
│         │  ┌───────────────────────────────────────────┐          │
│         │  │ Context snapshot (3 parallel siblings,    │          │
│         │  │ each under its own wall-clock safety cap):│          │
│         │  │  • Active app bundle id + name            │          │
│         │  │  • Category = cached(bundleID) override-d │          │
│         │  │    to .search when AX focus looks search-y│          │
│         │  │  • User instruction + category instruction│          │
│         │  │    (frozen from AppState mirror)           │          │
│         │  │  • Insertion target — uncapped, sync      │          │
│         │  │    (text before/after cursor, ±500 chars) │          │
│         │  │  • FULL-SCREEN accessibility tree         │          │
│         │  │    1500 ms cap; secure fields masked      │          │
│         │  │  • Optional OCR of active window — only   │          │
│         │  │    when Screen Recording permission given │          │
│         │  │    2500 ms cap; Vision; scrubbed; included│          │
│         │  │    only when AX empty for active app      │          │
│         │  └───────────────────┬───────────────────────┘          │
│         │                      │                                  │
│         │                      ▼                                  │
│         │  ┌────────────────────────────────────────────┐         │
│         │  │ GeminiClient (actor — one in-flight HTTP   │         │
│         │  │ request at a time; chunks may batch):      │         │
│         │  │   model: gemini-3.1-flash-lite             │         │
│         │  │   prompt prefix (cached on subsequent      │         │
│         │  │   chunks of same session):                 │         │
│         │  │     system instruction                     │         │
│         │  │     + App + Category                       │         │
│         │  │     + User instruction      (if non-empty) │         │
│         │  │     + Category instruction  (if non-nil)   │         │
│         │  │     + User dictionary       (always; (empty)│        │
│         │  │       when no entries — ADR-016)           │         │
│         │  │     + Insertion target                     │         │
│         │  │     + AX tree                              │         │
│         │  │     + Prior chunks (this session)          │         │
│         │  │   prompt suffix (varies):                  │         │
│         │  │     + per-call instruction                 │         │
│         │  │     + audio inline_data (1..N)             │         │
│         │  └───────────────────┬────────────────────────┘         │
│         │                      │ partial transcript               │
│         │                      ▼                                  │
│         │              accumulated text buffer                    │
│         ▼ release                                                 │
│  ╔══════════════════════════════╗                                 │
│  ║ Final chunk (is_final=true)  ║──▶ Gemini ──▶ final transcript  │
│  ╚══════════════════════════════╝                                 │
│                                       │                           │
│                                       ▼                           │
│                  Local concat: chunk_1 + … + chunk_N              │
│                                       │                           │
│                                       ▼                           │
│           finalizeForInsertion(stitched, textBefore, textAfter)   │
│           (strips trailing terminal punct when next text          │
│            continues mid-sentence, inserts leading space when     │
│            textBefore ends non-whitespace — closes the "no final  │
│            chunk" gap deterministically on the client)            │
│                                       │                           │
│                                       ▼                           │
│           TextReplacementEngine.apply(final, replacements)        │
│           (user-defined "from → to" pairs; word-boundary,         │
│            ICU-aware, auto-capitalized variant when from starts   │
│            with a lowercase letter — see ADR-016)                 │
│                                       │                           │
│                                       ▼                           │
│                          Clipboard + ⌘V injector                  │
│                          (saves & restores user clipboard)        │
│                                       │                           │
│                                       ▼                           │
│                          History store (last 10, text only)       │
└──────────────────────────────────────────────────────────────────┘
```

---

## Sequence of a single session

1. **Idle.** Menu-bar icon is a monochrome microphone. `HotkeyMonitor` is running on its dedicated runloop, listening for `flagsChanged`.

2. **Press.** Right Option goes from 0 → 1.
   - `RecordingSession.start()` is invoked with a frozen `InstructionsContext` (global user instruction + per-category prompt overrides + cached `bundleID → category` lookup) AND a frozen `DictionaryContext` (active dictionary entries + replacement pairs) from `AppState`.
   - Menu-bar icon flips to recording state (mic + stopwatch).
   - `AudioRecorder.start()` opens `AVAudioEngine`, taps the input node, begins filling the PCM buffer immediately — we don't lose phonemes while context assembles.
   - In parallel, three independent sibling tasks each run under their own wall-clock safety cap: `AccessibilityTree.snapshot()` walks **all on-screen windows** (1500 ms cap; see `NoType/Context/CLAUDE.md`); `InsertionTarget.capture()` reads the focused field's value and selection range (uncapped, sync); **when Screen Recording permission is granted**, `ScreenCaptureContext.capture(activeApp:pid:)` screenshots the active window and runs local Vision OCR (2500 ms cap; ADR-014). No joint deadline — partial results survive (AX timeout doesn't discard OCR result, OCR timeout doesn't discard AX).
   - Inside the same context task, `CategoryResolver.resolveFromAX(stored:)` reads the system-wide focused element and flips the session category to `.search` when the field looks like a search/address bar — independent of bundle id. See `NoType/Instructions/CLAUDE.md` and ADR-015.
   - `ContextSnapshot` (AX tree + insertion target + app + category + user instruction + category instruction + active dictionary entries + frozen replacement pairs + optional OCR sub-block) is stashed on the session. The OCR sub-block is included **only** when AX returned contentless for the active app's bundle id (`tree.hasContent(for:) == false`); otherwise the OCR result is dropped. Replacement pairs are also mirrored to `RecordingSession.replacementsFrozen` so a quick-release fallback to `ContextSnapshot.minimal(activeApp:)` still applies them at paste time.
   - If the bundle has no cached assignment, `AppState` fires a fire-and-forget `AppCategorizer.classifyIfNeeded(...)` call. The current session uses `.uncategorized` plus base rules; the next session in the same app picks up the new category from cache.
   - **VAD chunk emission is gated on the snapshot being ready** — the first chunk never goes to Gemini without context. The first audio chunk can't be produced until VAD detects a ≥1 s pause OR the user releases, so for any session >1 s OCR latency is masked by speech time; only quick-release sessions feel the cap.

3. **Speech.** User talks. Silero classifies frames as voiced. The session accumulates voiced + brief unvoiced gaps.

4. **Pause detected (≥1s).**
   - `ChunkBuilder` slices PCM `[lastChunkEnd … pauseStart]` and encodes to m4a.
   - The chunk is appended to the session's `pending` queue with `isFinal=false`.
   - A single sender task drains `pending` — if a request is already in flight, the new chunk waits behind it. When the sender wakes with several chunks queued, it issues a single batched `transcribeBatch` request instead of one round-trip per chunk.
   - Response text is appended to the session's transcript buffer.

5. **More speech / more pauses.** Repeat step 4. Each request reuses the same prefix → implicit cache hits, ~90% discount on the prefix tokens.

6. **Release.** Right Option goes from 1 → 0.
   - Final PCM slice is built (whatever is between `lastChunkEnd` and now) and queued with `isFinal=true`. If the slice is < 150 ms (the encoder skip threshold) the final request is skipped entirely.
   - The sender drains anything queued behind the in-flight request alongside the final chunk in a single batched call. The per-call instruction tells the model to apply final punctuation taking `Text after cursor` into account.
   - When all in-flight responses have returned:
     - `stitched = chunk_1.text + … + chunk_N.text` (local concat, never asks the model to re-emit).
     - `final = finalizeForInsertion(stitched, textBeforeCursor, textAfterCursor)` — strips a stranded trailing `.`/`!`/`?` when `Text after cursor` continues mid-text, and inserts a leading space when `Text before cursor` ends non-whitespace. Source of truth is the client; this also catches the "no final chunk" path.
     - `withReplacements = TextReplacementEngine.apply(final, replacements: replacementsFrozen)` — applies user-defined `from → to` pairs (word-boundary, auto-capitalized variant when `from` starts lowercase; see ADR-016 and `NoType/Dictionary/CLAUDE.md`).
     - `TextInjector.paste(withReplacements)` — saves clipboard, sets ours, posts ⌘V, waits ~150 ms, restores clipboard.
     - `HistoryStore.append(entry)` — appends to JSON, evicts oldest if >10. The history entry stores the post-replacement text — history is the source of truth for "what was inserted".
     - `AppState.harvestDictionaryIfRoom` runs `DictionaryHarvester.harvest(...)` synchronously (pure client-side, <10 ms): intersects the just-pasted transcript with the on-screen context the model saw at session start (AX tree + OCR + insertion target). New auto-entries are persisted to `DictionaryStore` and mirrored back via `applyDictionarySnapshot`. Skipped only when `userEntryCount >= 100` (no room).
   - Menu-bar icon returns to idle.
   - `AudioRecorder.stop()`. All PCM in memory is discarded.

---

## Key invariants

These hold across the system. Code that violates them is a bug.

### I1 — One Gemini request in flight per session, but a request may carry several chunks

`GeminiClient` is an `actor` with two transcription methods: `transcribe(audio:…)` for a single chunk, `transcribeBatch(audios:…)` for several. The session's sender task drains a FIFO `pending` queue: whatever chunks have piled up while the previous request was in flight go out together as one batched call. So:

- One in-flight HTTP request per session at any moment.
- Chunks are dispatched in strict FIFO order — a chunk never overtakes one ahead of it.
- The cache prefix is deterministic per call — every textual section above the per-call instruction is byte-stable across chunks of the same session. Only the per-call instruction line + audio parts vary.

This eliminates out-of-order bugs while letting us spend one round-trip on N chunks when the user has talked through Gemini's slowness or paused often. The release path benefits most: any non-final chunks queued behind the in-flight request get drained alongside the final chunk in a single batched call, instead of N sequential round-trips.

### I2 — Local concatenation, never "re-emit everything"

Each Gemini call returns *only the text for the current chunk* (or one contiguous text spanning the chunks in a batched call). The full transcript is assembled on the client. Asking the model to re-emit the full transcript on every call would defeat caching and inflate output token costs (output is 6× input price).

### I3 — Cache-friendly part ordering is load-bearing

The order of `parts` in every Gemini request is:

```
system_instruction
  → App + Category
  → User instruction       (optional — omitted when empty)
  → Category instruction   (optional — omitted when nil, typical for .uncategorized)
  → User dictionary        (always present; body `(empty)` when no entries — ADR-016)
  → Insertion target
  → On-screen context
  → Prior chunks (this session)
  → per-call instruction
  → audio inline_data (1..N)
```

The two optional sections (User / Category instruction) are decided once at session start and frozen. The User dictionary section is always present but its body — including which auto entries appear — is also frozen at session start (captured into `ContextSnapshot.dictionary`). So the **part count is byte-stable within a session** — 6, 7, or 8 textual sections depending on which optionals fire — and the implicit-cache prefix matches chunk-to-chunk with ~90% discount.

Everything except the per-call instruction and the audio is identical across chunks of the same session. All non-optional sections are always present, with `(none yet)` / `(empty)` / empty-quoted bodies when empty. Removing, reordering, or rephrasing a label breaks the cache shape and the prompt contract. **Do not reorder these parts.** See `NoType/Gemini/CLAUDE.md`.

### I4 — No audio retention

Audio exists in the in-memory PCM buffer and in transient m4a blobs only. Nothing is written to disk. After session end (or release), the buffer is dropped along with the `AudioRecorder` instance. The history store contains only text.

### I5 — No injection mid-recording

Text is pasted exactly once, at the end of the session, after the final chunk's response arrives. Partial transcripts are visible only as internal state — never injected, never shown in a window.

### I6 — Session is a value, not a global

A `RecordingSession` is created on press and dropped on release. There is no "current session" singleton. This makes the lifecycle obvious and prevents leaks if the user mashes the hotkey rapidly.

### I7 — Secure fields are always masked

Anything that walks AX must go through `SecureFieldMasker`. There is no path that sends raw AX content to Gemini. This is enforced at the type level: `AccessibilityTree.snapshot()` returns a `RedactedAXSnapshot`, never raw text. See `NoType/Context/CLAUDE.md`.

---

## Threading model

| Component | Lives on |
|---|---|
| `HotkeyMonitor` | Dedicated `Thread` with its own `RunLoop` (required for `CGEventTap`) |
| `AudioRecorder` (engine) | `AVAudioEngine`'s render thread (managed by AVFAudio) |
| `AudioRecorder` (PCM storage) | `NSLock`-guarded array; producer = tap thread, consumer = VAD task / chunk builder |
| `SileroVAD` | `actor`; called from a detached `Task` consuming `AsyncStream<[Float]>` |
| `RecordingSession` | `@MainActor` (it owns UI-bound state) |
| `GeminiClient` | `actor` (its own isolation domain) |
| `HistoryStore` | `actor` |
| UI (`MenuBarExtra`, popover, HUDs) | `@MainActor` |

Crossing threads:
- AudioRecorder → VAD: `AsyncStream<[Float]>`.
- VAD → session: a detached task accumulates chunks and calls back into the `@MainActor` session.
- Session → Gemini: `await client.transcribe(...)` / `transcribeBatch(...)`.
- Gemini → session: return value of `await`.
- Session → UI: `@Published` / `@Observable` properties on `AppState`, observed by SwiftUI.

---

## Error & cancellation paths

- **No mic permission** at session start → don't start, surface a permission HUD card.
- **No internet** when chunk is sent → cancel session, surface error HUD ("NoType needs internet to transcribe"). Already-spoken audio is dropped.
- **Empty transcript at end of session** → `RecordingSession.stop()` throws `SessionError.noSpeech`; AppState surfaces a low-severity "no speech detected" HUD instead of pasting.
- **Gemini 4xx (bad key)** → error HUD, link to Settings. Future chunks of this session are not retried.
- **Gemini 5xx / timeout** → 1 retry with 500 ms delay, then drop session with error HUD.
- **User releases hotkey while a chunk is in flight** → final chunk is queued behind it; we wait for both before pasting.
- **User taps Right Option for <200 ms (accidental)** → arms the tap-toggle state machine in `AppState`; a second press inside 300 ms locks the session in toggle mode (next press ends it), otherwise the session finalizes after the timeout.

---

## What's NOT in this diagram (and why)

- **Streaming responses from Gemini.** Considered and rejected — see `docs/decisions.md` ADR-007.
- **Multiple simultaneous sessions.** Not supported. Pressing hotkey while a session is winding down is a no-op until the previous session is fully ejected.
- **Mid-recording app switch.** `ContextSnapshot.activeApp` is captured once at session start and not refreshed. The paste target is whichever app has focus *at release time* (since that's what receives ⌘V), but the prompt's `App:` / `Category:` lines reflect the app at press time. In practice the user holds the hotkey and doesn't switch apps mid-utterance.
