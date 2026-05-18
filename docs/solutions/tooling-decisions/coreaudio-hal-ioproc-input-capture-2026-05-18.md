---
title: Core Audio HAL IOProc for input capture (not AVAudioEngine) on macOS
date: 2026-05-18
category: tooling-decisions
module: Recording
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - Implementing macOS microphone capture in an app that coexists with other apps' audio output
  - Choosing between AVAudioEngine and Core Audio HAL for an input-only use case
  - Investigating "music stutters when I start recording" reports
  - Auditing AudioRecorder for a reintroduction of AVAudioEngine
symptoms:
  - "~1 s stutter / dropout in Bluetooth-headphone audio every time AVAudioEngine.start() is called"
  - Music quality drops or ducking behaves unexpectedly alongside an AVAudioEngine input tap
  - The stutter reproduces even with the built-in mic selected (i.e., distinct from the HFP-codec-switch vector)
root_cause: wrong_api
resolution_type: code_fix
tags: [audio, coreaudio, hal, avaudioengine, bluetooth, a2dp, aggregate-device, ioproc]
---

# Core Audio HAL IOProc for input capture (not AVAudioEngine) on macOS

## Context

NoType captures microphone audio for dictation. The most common use case: the user holds the recording hotkey while listening to music through Bluetooth headphones. When the recording path used `AVAudioEngine.installTap` + `engine.start()`, every hotkey press caused an audible ~1 s music dropout. The bug was not unique to Bluetooth mics — it reproduced even when `AudioDeviceManager`'s BT-avoidance fallback had already redirected capture to the built-in mic.

`bluetooth-input-avoidance-2026-05-16.md` documented and fixed the *first* stutter vector: opening an input stream from a Bluetooth mic forces macOS to switch the headset from A2DP to HFP/SCO, dropping music quality and disabling ducking. The BT-avoidance feature sidesteps that by recording from the built-in mic instead.

But the stutter persisted even with the built-in mic. A spike traced it to a *second* vector: `AVAudioEngine.start()` implicitly creates an aggregate input+output device regardless of whether the output side is used. Creating the aggregate wakes macOS's output routing and momentarily stutters whatever BT output device is active. There is no documented public API to open `AVAudioEngine` in input-only mode without this side effect.

The SuperMegaUltraGroovy "It's over between us, AVAudioEngine" post (2021-01-26) and AudioKit issue #2130 independently confirm this as a known platform-level gotcha with no first-party workaround. The only fix is to bypass `AVAudioEngine` entirely for the capture path and talk to Core Audio's Hardware Abstraction Layer directly.

## Guidance

> **When implementing macOS audio input capture in an app that coexists with other apps' audio output — especially with Bluetooth headphones in play — use Core Audio HAL (`AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`) instead of `AVAudioEngine.installTap`. HAL is input-only. `AVAudioEngine.start()` implicitly opens an aggregate device that touches output routing on every call, even when you never use the output side.**

`AVAudioEngine` remains the right choice when you actually need the output side: effects chains, `AVAudioUnit` graphs, `AVAudioNode` topologies, or an onboarding mic-check spectrum display (`MicProbe` stays on `AVAudioEngine` because the first-launch wizard isn't a scenario where the user is simultaneously pressing the hotkey with music playing).

### Concrete pattern for an input-only recorder

**1. Resolve the device via existing policy.**

```swift
// @MainActor — reads AudioDeviceManager's @MainActor-isolated state
guard let device = AudioDeviceManager.shared.effectiveDevice else {
    throw AudioError.noInputDevice
}
```

`effectiveDevice` already encodes the BT-avoidance fallback (pin wins → BT-avoidance → system default). No new device-selection logic needed here.

**2. Query the device's native stream format.**

```swift
// AudioDeviceManager.inputStreamFormat(for:) — nonisolated static, synchronous
guard let asbd = AudioDeviceManager.inputStreamFormat(for: device.id),
      let inFmt = AudioDeviceManager.avAudioFormat(from: asbd)
else {
    throw AudioError.streamFormatUnavailable
}
```

`inputStreamFormat(for:)` calls `AudioObjectGetPropertyData(kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeInput, ...)` — one synchronous HAL call that returns `nil` when the device is in an odd state (aggregate mid-reconfiguration, device just disappeared).

**3. Build the `AVAudioConverter` — standalone, no engine.**

`AVAudioConverter` does not require an `AVAudioEngine`. Build it from the device's native format to your target format (16 kHz mono float32 for Silero VAD):

```swift
guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: AudioRecorder.outputSampleRate,
                                  channels: 1,
                                  interleaved: false),
      let conv = AVAudioConverter(from: inFmt, to: outFmt)
else { throw AudioError.converterCreateFailed }
```

**4. Pre-allocate the output buffer once.**

```swift
guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt,
                                    frameCapacity: AudioRecorder.outputCapacityFrames)
else { throw AudioError.converterCreateFailed }
// outputCapacityFrames = 8_192 — generous upper bound for any hardware buffer size
```

Reset `outBuf.frameLength = 0` at the top of each IOProc invocation to reuse it without reallocating.

**5. Open the IOProc on a dedicated serial queue.**

```swift
private let ioQueue = DispatchQueue(
    label: "app.notype.recording.ioproc",
    qos: .userInteractive
)

var procID: AudioDeviceIOProcID?
let status = AudioDeviceCreateIOProcIDWithBlock(
    &procID,
    device.id,
    ioQueue                         // serial; NSLock is safe here
) { [weak self] _, inInputData, _, _, _ in
    self?.handleIOProc(inputData: inInputData)
}
guard status == noErr, let proc = procID else {
    throw AudioError.ioProcCreateFailed(status)
}
AudioDeviceStart(device.id, proc)
```

Passing a serial `DispatchQueue` instead of `nil` gives you the safety of `NSLock` at the cost of a few ms of added latency — irrelevant for chunked dictation uploads. If you pass `nil`, the IOProc runs on Core Audio's real-time render thread, where calling `NSLock.lock()` can invoke mach syscalls under contention and cause priority inversion.

**6. Inside the IOProc: alias, don't copy the HAL buffer.**

```swift
private func handleIOProc(inputData: UnsafePointer<AudioBufferList>) {
    // Snapshot shared state in one lock acquire — a concurrent
    // handleConfigurationChange can't swap these out mid-call.
    lock.lock()
    let inFmt = inputFormat; let conv = converter
    let outFmt = outputFormat; let outBuf = outputBuffer
    lock.unlock()
    guard let inFmt, let conv, let outFmt, let outBuf else { return }

    // bufferListNoCopy aliases HAL memory — no copy.
    // The alias is consumed synchronously inside conv.convert(...)
    // before this function returns, so the IOProc callback's
    // HAL-owned memory is never touched after it releases.
    guard let inBuffer = AVAudioPCMBuffer(
        pcmFormat: inFmt,
        bufferListNoCopy: inputData,
        deallocator: nil
    ) else { return }

    handleTap(inBuffer, converter: conv, outputFormat: outFmt, outputBuffer: outBuf)
}
```

**7. `teardownHAL` must drain `ioQueue` between Stop and Destroy.**

This is the most important correctness invariant. `AudioDeviceStop` halts *new* dispatches onto `ioQueue`, but blocks already enqueued can still run. If you destroy the IOProc and immediately swap `inputFormat` (config-change path), a queued block would read the new format against the old device's bytes — bytes the HAL may have already reclaimed. The drain makes that window zero:

```swift
// BEFORE (bare Stop + Destroy — unsafe on config-change rebuild):
AudioDeviceStop(deviceID, proc)
AudioDeviceDestroyIOProcID(deviceID, proc)   // ← late-queued block can still run here

// AFTER (Stop + sync drain + Destroy):
AudioDeviceStop(dev, proc)
ioQueue.sync {}         // drain: blocks until every enqueued IOProc block has run
AudioDeviceDestroyIOProcID(dev, proc)        // ← now truly safe
```

`ioQueue.sync {}` from `@MainActor` is deadlock-free because the IOProc body never bounces back to the main actor — it only acquires `lock`, writes to the ring buffer, and yields to the continuation.

**8. Add a `stopped` latch for late property-listener callbacks.**

`AudioObjectRemovePropertyListenerBlock` prevents *future* dispatches of the device-change listener but does not cancel blocks already queued on `DispatchQueue.main`. Without a latch, a late callback landing after `stop()` would call `openAndStartHAL()` and spawn an orphaned IOProc:

```swift
// In stop():
lock.lock()
stopped = true      // written before removeDefaultInputListener()
lock.unlock()
removeDefaultInputListener()
teardownHAL()

// In handleConfigurationChange():
lock.lock()
let isStopped = stopped
lock.unlock()
if isStopped { return }   // drop the late callback
```

**9. HAL property listener for mid-session device changes.**

Replace `AVAudioEngineConfigurationChange` (NotificationCenter) with a HAL listener scoped to the session's lifetime:

```swift
let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    MainActor.assumeIsolated { self?.handleConfigurationChange() }
}
AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject),
    &address,          // kAudioHardwarePropertyDefaultInputDevice
    DispatchQueue.main,
    block
)
```

Dispatching on `DispatchQueue.main` lets `handleConfigurationChange` read `AudioDeviceManager` (which is `@MainActor`-isolated) without an extra hop. `AudioDeviceManager` also listens on `DispatchQueue.main` for the same property at app startup — the ordering is serialised, so `AudioDeviceManager` refreshes its mirrors first, then the recorder's listener fires and reads them via `resolveEffectiveDevice()`. If that startup ordering ever changes, audit both listeners together.

## Why This Matters

The stutter happens on *every hotkey press*. Users dictate dozens of times per day. A ~1 s music dropout on each press is a high-frequency papercut for anyone who listens to music while working — exactly the population most likely to use a dictation tool. Neither unit tests nor CI catch this class of bug; it requires real hardware and real audio.

The fix does not improve input quality. HAL captures the same bytes as the `AVAudioEngine` tap and routes them through the same `AVAudioConverter` to the same `AsyncStream<[Float]>`. The recorder's public API (`start()`, `stop()`, `samples(from:to:)`, `discardSamples(beforeAbsolute:)`) is unchanged. `RecordingSession` has no consumer-side diff.

This rewrite closes the **second** BT-stutter vector. The first ([`bluetooth-input-avoidance-2026-05-16.md`](../architecture-patterns/bluetooth-input-avoidance-2026-05-16.md)) is still in place — both are required. The avoidance prevents the A2DP → HFP codec switch when a BT mic is the only device. The HAL rewrite prevents the aggregate-device kick on every `engine.start()` even with the built-in mic. The two are independent and stack.

## When to Apply

Whenever you're picking a macOS audio-input API:

- **Input-only capture alongside other apps' output:** use HAL.
- **Audio rendering, effects chains, or `AVAudioNode` graphs:** use `AVAudioEngine` — the aggregate is the point.
- **First-launch onboarding mic check (`MicProbe`):** `AVAudioEngine` is fine — the user is not pressing the hotkey while music plays in the first-launch wizard.

If a future refactor considers reintroducing `AVAudioEngine` in `AudioRecorder`: document why, benchmark against AirPods + Apple Music first, and read the SuperMegaUltraGroovy post and AudioKit #2130 before merging. The "No `AVAudioEngine` in the recording path" hard rule in `Recording/CLAUDE.md` exists for this reason.

## Examples

**Start/stop lifecycle — AVAudioEngine vs HAL IOProc:**

```swift
// BEFORE: AVAudioEngine
private let engine = AVAudioEngine()

func start() throws -> AsyncStream<[Float]> {
    let input = engine.inputNode
    let inFmt = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
        self?.handleTap(buf)
    }
    engine.prepare()
    try engine.start()                 // ← kicks the output-side aggregate
    configChangeObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, ...
    ) { ... }
    return stream
}

func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    NotificationCenter.default.removeObserver(configChangeObserver!)
}

// AFTER: Core Audio HAL
@MainActor
func start() throws -> AsyncStream<[Float]> {
    try openAndStartHAL()              // input-only; no aggregate
    installDefaultInputListener()
    return stream
}

@MainActor
func stop() {
    lock.lock(); stopped = true; lock.unlock()
    removeDefaultInputListener()
    teardownHAL()                      // Stop → drain → Destroy
}
```

**`teardownHAL` drain — bare Stop+Destroy vs Stop+drain+Destroy:**

```swift
// BEFORE (unsafe for config-change rebuild):
@MainActor
private func teardownHAL() {
    guard let proc = ioProcID else { return }
    AudioDeviceStop(deviceID, proc)
    AudioDeviceDestroyIOProcID(deviceID, proc)   // race window open
    ioProcID = nil
}

// AFTER (safe + instrumented):
@MainActor
private func teardownHAL() {
    guard let proc = ioProcID else { return }
    let dev = deviceID
    AudioDeviceStop(dev, proc)
    let drainStart = DispatchTime.now()
    ioQueue.sync {}                              // drain in-flight IOProc blocks
    let drainMs = Double(DispatchTime.now().uptimeNanoseconds
                        - drainStart.uptimeNanoseconds) / 1_000_000
    if drainMs > 5 {
        Self.log.warning("ioQueue drain took \(drainMs)ms — investigate IOProc body")
    }
    AudioDeviceDestroyIOProcID(dev, proc)        // now safe
    ioProcID = nil
    lock.lock(); outputBuffer = nil; lock.unlock()
}
```

The drain is instrumented — a `sync` that takes >5 ms means the IOProc body held the queue past `AudioDeviceStop`, which surfaces as a UI hitch on Esc-cancel. Production "Esc hangs" should look here first.

## Related

- `NoType/Recording/AudioRecorder.swift` — full HAL implementation.
- `NoType/Recording/AudioDeviceManager.swift` — `inputStreamFormat(for:)` + `avAudioFormat(from:)` HAL helpers.
- `NoType/Recording/CLAUDE.md` — updated invariants + "No `AVAudioEngine` in the recording path" hard rule.
- [Bluetooth input avoidance — first stutter vector](../architecture-patterns/bluetooth-input-avoidance-2026-05-16.md) — companion: closes the HFP-codec-switch vector when a BT mic is opened. The two docs together describe the full BT-audio-quality picture.
- [Consuming CGEventTap teardown](../design-patterns/consuming-cgeventtap-teardown-2026-05-18.md) — sibling teardown-discipline learning from the same branch's review pass.
- [Silero VAD via CoreML](silero-vad-coreml-2026-05-15.md) — adjacent tooling decision in the same Recording module.
- [Aggregate-device handling tech debt](../documentation-gaps/bluetooth-aggregate-device-handling-2026-05-16.md) — known gap; HAL changes the failure mode for malformed aggregates from "silently records wrong device" to "fast-fails with `streamFormatUnavailable`".
- `docs/plans/2026-05-18-001-feat-settings-screen-plan.md` §31–94 — failed-approach narrative + hardware smoke protocol.
- [SuperMegaUltraGroovy: "It's over between us, AVAudioEngine"](https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/) — platform-level documentation of the aggregate-device side effect.
- [AudioKit issue #2130](https://github.com/AudioKit/AudioKit/issues/2130) — independent confirmation.
- [Apple: `AudioDeviceCreateIOProcIDWithBlock`](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock).
