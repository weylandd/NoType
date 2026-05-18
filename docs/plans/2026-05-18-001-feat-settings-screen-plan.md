---
title: Settings Screen — Remaining Work
type: feat
status: active (U4 + U8 manual smoke remain)
date: 2026-05-18
last_updated: 2026-05-18 (minimal trim — only what's left to do)
origin: docs/brainstorms/2026-05-17-settings-screen-requirements.md
progress: docs/plans/2026-05-18-001-feat-settings-screen-progress.md
---

# Settings Screen — Remaining Work

> The original 8-unit plan shipped 7 of its units in this branch
> (U1, U2, U3, U5, U6, U7, U8 code-wiring — commits `511b941`,
> `8610f8a`, `290cb5e`, `c5ff2ef`, `1f71aa6`, `e579b7e`, `700f6bf`,
> plus the post-review-fixes commit). Decisions, deviations, and
> test inventories for those units live in the
> **[progress doc](2026-05-18-001-feat-settings-screen-progress.md)**.
> This file keeps only the work that is **still active** — U4 and
> the U8 manual smoke verification.

## Active scope

| Item | Owner | Why it's still here |
|---|---|---|
| **U4** — Microphone & Audio (Core Audio HAL rewrite) | — | Substantial rewrite of `AudioRecorder` from `AVAudioEngine` to pure HAL. Requires hardware smoke on AirPods + Apple Music. |
| **U8 smoke** — manual verification of Sparkle `.skip` persistence | — | Two `NoType/Updates/CLAUDE.md` "Hard rules pending smoke verification" stay in place until an EdDSA-signed staged release confirms `SPUUserUpdateChoice.skip` persists under our custom `SPUUserDriver`. |

---

## U4 — Microphone & Audio + Core Audio HAL rewrite

**Goal.** Fill the Microphone & Audio section (Mic picker + BT toggle — trivial UI) **and** rewrite `AudioRecorder` from `AVAudioEngine` + `installTap` to pure Core Audio HAL (`AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`) to eliminate the recording-start music glitch on BT headphones.

The glitch's root cause: on macOS, `AVAudioEngine.start()` implicitly creates an aggregate input+output device, which kicks the output side and stutters BT-headphone playback for ~1s. There is no public API to disable the output side. Pure HAL bypasses the aggregate. Background: [SuperMegaUltraGroovy](https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/) · [AudioKit #2130](https://github.com/AudioKit/AudioKit/issues/2130).

**R16 reframe.** The origin requirement was "Music interruption picker (None / Mute via AVAudioSession.duckOthers)". Two problems: (1) the real user pain is the glitch, not the lack of ducking — Mute solves the wrong thing; (2) `AVAudioSession` is `API_UNAVAILABLE(macos)`. The HAL rewrite solves the actual pain. Mute toggle deferred post-v1 as a separate nice-to-have.

**Requirements:** R14 (Mic picker dup), R15 (BT toggle), R16-reframed (audio continuity, covers AE8-reframed).

### Files

- Modify (substantial rewrite): `NoType/Recording/AudioRecorder.swift` — replace `AVAudioEngine` + `installTap` + `AVAudioEngineConfigurationChange` with pure HAL. Keep `PCMRingBuffer`, `AVAudioConverter`, and the `AsyncStream<[Float]>` API unchanged — `RecordingSession` should NOT see a consumer-side change.
- Modify: `NoType/Recording/AudioDeviceManager.swift` — `apply(_:to:)` is no longer needed in its current form. Add `openIOProc(on:format:callback:)` helper or return the HAL device id for `AudioRecorder` to consume directly.
- Modify (minimal): `NoType/Recording/RecordingSession.swift` — consumer-side unchanged.
- Modify: `NoType/UI/Settings/SettingsTabView.swift` — replace the `sectionPlaceholder()` "Coming soon." block with Mic picker + BT toggle.
- Create: `NoTypeTests/AudioRecorderHALTests.swift` — start/stop lifecycle parity with the old path, format conversion (44.1k → 16k mono float32), device-change handling.
- Manual: hardware smoke protocol (AirPods + Apple Music → recording-start glitch test).

### Approach — HAL rewrite

`AudioRecorder.start()`:
1. Pick effective input device via existing `AudioDeviceManager.shared.effectiveDevice` (unchanged).
2. Read device's native format via `AudioObjectGetPropertyData(kAudioDevicePropertyStreamFormat, …)`.
3. Build `AVAudioConverter(input → 16kHz mono float32)` — `AVAudioConverter` works standalone, no engine needed.
4. `AudioDeviceCreateIOProcIDWithBlock(deviceID, dispatchQueue, ioBlock)` — `ioBlock` receives input `AudioBufferList` in real-time (same role as today's tap callback).
5. Inside ioBlock: copy input samples → run `AVAudioConverter` → append to `PCMRingBuffer` → emit VAD windows via the existing `AsyncStream` continuation.
6. `AudioDeviceStart(deviceID, ioProcID)`.

`AudioRecorder.stop()`:
1. `AudioDeviceStop(deviceID, ioProcID)`.
2. `AudioDeviceDestroyIOProcID(deviceID, ioProcID)`.
3. Existing `continuation.finish()` etc.

**Device-change handling.** `AudioDeviceManager` already owns HAL listeners for `kAudioHardwarePropertyDevices` + `kAudioHardwarePropertyDefaultInputDevice`. Hook `AudioRecorder` into them — on change: stop+destroy current ioproc, recompute effective device, recreate ioproc on the new device. Same UX as today's `AVAudioEngineConfigurationChange` handler.

**Hard rule still pending review.** `NoType/Recording/CLAUDE.md` lists "Mid-session input-device swap is supported" under `AVAudioEngineConfigurationChange`. The HAL rewrite preserves this behaviour via the HAL listener path — update the doc once the rewrite lands.

### Approach — Settings UI (trivial)

- BT-avoidance: `Toggle("Prefer built-in over Bluetooth", isOn: $audioDeviceManager.preferBuiltInOverBluetooth)` — exact reuse of the existing pattern.
- Mic picker: instantiate `MicInputPicker()` inline.
- No Music-interruption picker in v1.

### Test scenarios

- Happy: built-in mic at 44.1kHz → 30s session → PCM stream yields correct sample count + correctly resampled 16kHz mono frames (byte-for-byte parity vs the existing `AVAudioEngine` path on a recorded fixture).
- Happy: USB mic plugged in at session start → format conversion produces 16kHz mono float32 frames.
- Edge (smoke, **release-blocker for R16-reframed**): AirPods + Apple Music playing → press hotkey → music continues without glitch / dropout. Manual hardware test — not unit-testable.
- Edge: mid-session USB unplug → HAL device-list listener fires → ioproc stops+destroys cleanly → reopens on new effective device → session continues without crash.
- Edge: mid-session AirPods pair AND `preferBuiltInOverBluetooth == true` → HAL listener fires → `pickEffectiveDevice` returns built-in → ioproc rebuilds on built-in (no surprise BT switch).
- Edge: device disappears with no fallback → ioproc fails to reopen → AsyncStream finishes cleanly → user gets partial transcript.
- Integration: 5-chunk session with VAD pause detection → `ChunkBuilder` + `PauseDetector` + Silero work identically (no consumer-side regression).

### Verification

- Build succeeds; PCM byte-for-byte parity against fixture; existing `PauseDetectorTests` / `ChunkBuilderTests` / `AudioDeviceManagerTests` pass; new `AudioRecorderHALTests` pass.
- **Manual hardware smoke** confirms no audio glitch when starting recording with BT headphones + music playing. This is the primary R16-reframed success criterion.

### Execution note

**Characterization-first.** Substantial rewrite of a load-bearing class. Before deleting `AVAudioEngine` code, write integration tests that snapshot the current behaviour (start/stop lifecycle, format conversion contract, device-change handling). Then rewrite. Then verify byte-for-byte PCM parity on a fixture. Only after that is it safe to remove the old code path. HAL ioproc runs on Core Audio's real-time render thread — `PCMRingBuffer`'s short-hold `NSLock` should be OK under HAL dispatch, but hardware-validate before merging; if underruns appear, switch to a lock-free ring (atomic indices).

---

## U8 smoke — manual verification of Sparkle `.skip` persistence

**Goal.** Confirm that `SPUUserUpdateChoice.skip` dispatched through our custom `SPUUserDriver` actually persists in `SUSkippedVersion` `UserDefaults` (i.e., Sparkle's per-version skip works for us, not just for the `SPUStandardUserDriver` we bypass). If it does, remove the two preamble Hard rules in `NoType/Updates/CLAUDE.md`. If it doesn't, add a fallback `notype.update.skippedVersion` `UserDefaults` filter in `UpdateUserDriver.showUpdateFound(...)` so the banner doesn't re-appear for an already-skipped version.

The code wiring shipped in `700f6bf` (`UpdateController.checkForUpdates()` + `.skipThisVersion()` + the X-chip on `AvailableBannerCard`). All that remains is the end-to-end smoke.

### Smoke recipe

1. Cut an EdDSA-signed staged release `v0.0.1-rc1` (CI workflow or `scripts/release.sh` + `scripts/publish_release.sh`).
2. Install `rc1`. Wait for the in-sidebar banner. Click the X chip.
3. Wait for the next scheduled Sparkle check. (Override `SUScheduledCheckInterval` to ~60 s in a debug Info.plist if you don't want to wait the default 24 h.)
4. Confirm **no** re-show for `rc1`.
5. Publish `v0.0.1-rc2`. Confirm the banner reappears for `rc2`.

### Pass path

Delete the two "Hard rules pending smoke verification" plus the preamble block from `NoType/Updates/CLAUDE.md`.

### Fail path

- Create `NoType/Updates/SkippedVersionStore.swift` (or inline in `UpdateUserDriver`) wrapping `notype.update.skippedVersion: String` in `UserDefaults`.
- `UpdateController.skipThisVersion()` writes `update.versionString` to the new flag before dispatching `.skip` to Sparkle.
- `UpdateUserDriver.showUpdateFound(...)` reads the flag and filters out matching versions before publishing `.available(update)` to the controller.
- Extend `UpdateControllerStateTests` to assert the `UserDefaults` write happens on `skipThisVersion()`.
- Smoke again. On pass, delete the two preamble Hard rules.

### Execution note

End-to-end Sparkle behaviour is opaque to unit tests — `UpdateControllerStateTests` covers the controller↔driver synthetic-closure boundary, but the actual `.skip` persistence path is below that surface. The documented manual smoke is the only way to verify.

---

## Risks (active items only)

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| HAL rewrite regression in core recording path | High (rewrite) | High | Characterization tests pin `AVAudioEngine` behaviour BEFORE rewrite; PCM byte-for-byte parity on a fixture; manual smoke across built-in mic, USB mic, BT headphones, system speakers, AirPods. |
| HAL ioproc real-time thread contention with `PCMRingBuffer`'s `NSLock` | Low | Medium | Existing lock is short-hold and should be fine, but hardware-validate. Fallback: lock-free atomic-index ring. |
| Sparkle `.skip` doesn't persist under our custom `SPUUserDriver` | Medium | Medium | Manual smoke verifies end-to-end before removing the preamble Hard rules; documented fallback (`notype.update.skippedVersion` `UserDefaults` filter) is ready to ship if needed. |

---

## Pointers

- **Origin requirements:** [docs/brainstorms/2026-05-17-settings-screen-requirements.md](../brainstorms/2026-05-17-settings-screen-requirements.md)
- **Progress doc (shipped state, decisions, test inventories):** [2026-05-18-001-feat-settings-screen-progress.md](2026-05-18-001-feat-settings-screen-progress.md)
- **Active learnings:**
  - [Bluetooth input avoidance](../solutions/architecture-patterns/bluetooth-input-avoidance-2026-05-16.md) — pure-HAL `pickEffectiveDevice`, load-bearing for U4
  - [Swift 6 concurrency](../solutions/conventions/swift-6-concurrency-and-async-2026-05-15.md) — HAL ioproc runs on Core Audio's real-time render thread
  - [Sparkle 2 custom banner UI](../solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md) — Check + Skip reconsideration trigger
- **Still-open tech-debt (NOT closed by this plan):** [screen-capture-settings-section](../solutions/documentation-gaps/screen-capture-settings-section-2026-05-15.md)
- **External docs:**
  - [`AudioDeviceCreateIOProcIDWithBlock`](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock)
  - ["It's over between us, AVAudioEngine"](https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/)
  - [Sparkle 2 `SPUUserUpdateChoice`](https://sparkle-project.org/documentation/)
