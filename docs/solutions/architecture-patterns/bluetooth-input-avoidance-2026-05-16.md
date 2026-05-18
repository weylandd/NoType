---
title: Bluetooth input avoidance — prefer built-in mic over BT default
date: 2026-05-16
last_updated: 2026-05-18
category: architecture-patterns
module: Recording
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - Choosing the input device for macOS audio capture (any API — AVAudioEngine, Core Audio HAL IOProc, AudioQueue)
  - Investigating "music got louder" or "ducking broken" reports
  - Considering BLE Audio / LC3 codec support
tags: [audio, bluetooth, a2dp, hfp, sco, ducking, ble-audio]
---

# Bluetooth input avoidance — prefer built-in mic over BT default

## Context

User-reported regression: holding the Right Option hotkey to dictate **with Bluetooth headphones connected and music playing**. Instead of macOS ducking the music for the recording, the music got *louder* and the audio quality of whatever was playing dropped.

The cause is well-documented macOS audio behaviour: classic Bluetooth headsets support two transport profiles for the same physical device.

- **A2DP** (Advanced Audio Distribution Profile) — output-only, hi-fi, used while you're just listening to music. macOS ducks A2DP-bound music when other audio sources play.
- **HFP / SCO** (Hands-Free Profile / Synchronous Connection-Oriented link) — bidirectional, telephony-quality mono codec (~8 kHz / 64 kbps). macOS forcibly switches the device to HFP the moment *any* app opens a microphone input stream from it.

When NoType opens an input stream against the default input device and that default is the BT headset, macOS:
1. Switches the device A2DP → HFP for the duration of the input stream.
2. Reroutes media output through the same HFP link (because HFP is mono telephony, music quality drops audibly).
3. Disables system ducking for HFP (it's a phone-call codec — ducking would mute the call).

This is API-agnostic — the codec switch is triggered by *any* app opening a microphone input from a BT device, not by `AVAudioEngine` specifically. The HAL rewrite of `AudioRecorder` (see [tooling-decisions/coreaudio-hal-ioproc-input-capture-2026-05-18.md](../tooling-decisions/coreaudio-hal-ioproc-input-capture-2026-05-18.md)) closes a *separate* stutter vector — the AVAudioEngine aggregate-device kick on `engine.start()` — but it does NOT change the BT codec-switch behavior. Both fixes are required and stack: BT avoidance prevents the codec switch when a BT mic would otherwise be selected; HAL prevents the aggregate-device kick on every recording start.

End result before BT avoidance shipped: music plays louder *and* worse for ~1 second after the user presses the hotkey. The hypothesis was confirmed by the (now obvious in hindsight) fact that the bug only repros with Bluetooth output devices that also expose an input stream.

BLE Audio (LE Audio / LC3) is the long-term fix on Apple's roadmap — same physical link, isochronous channels, no profile switch needed. But shipping BLE Audio requires AirPods Pro 2 + macOS 14.3+ + a runtime opt-in we don't have today, and lots of users are on classic Bluetooth headsets that will never get LE Audio firmware. The mitigation has to work at the device-selection layer.

## Guidance

**Default to recording from the built-in laptop microphone when the system's default input is a Bluetooth device.** Pinning a specific BT device in the picker still wins — power users who actually want their AirPods mic (loud office, walking around) keep that option.

Decision layered into `AudioDeviceManager.pickEffectiveDevice`:

1. **Explicit pin wins** — `selectedUID` is the user's deliberate choice; honour it.
2. **BT fallback** — when `preferBuiltInOverBluetooth` is on AND the system default is `kAudioDeviceTransportTypeBluetooth` / `kAudioDeviceTransportTypeBluetoothLE` AND a `kAudioDeviceTransportTypeBuiltIn` device exists, return the built-in instead.
3. **System default** — anything else (USB mic, built-in already default, no BT in play).
4. **Nil** — let `AVAudioEngine` pick.

Default for `preferBuiltInOverBluetooth` is **ON**. v1 of the Settings screen (plan 2026-05-18-001 / PR #50) deliberately removed the dedicated UI toggle — the default-ON behaviour is treated as the right answer for everyone, with explicit device pinning (Settings → Microphone → Change) covering the "I want my BT mic" case. The hidden escape hatch for the rare user who wants to disable the avoidance entirely without pinning is `defaults write app.notype notype.preferBuiltInOverBluetooth -bool false`. Mac mini / Mac Studio users without a built-in mic gracefully degrade — step 2's "a built-in device exists" guard fails and step 3 returns the system default unchanged.

Per-session `info`-level log fires from `AudioRecorder.start()` when the fallback engages, so "music got louder" reports can be correlated against `log show --predicate 'subsystem == "app.notype"'`.

## Why This Matters

- **Eliminates the ducking-breaks surprise** for the most common BT-headphones-while-dictating scenario, with no user configuration.
- **A2DP is non-trivially better than HFP** for any audio the user might be playing — keeping the headset in A2DP also keeps Spotify / podcasts / system sounds sounding right while NoType records.
- **Recording quality goes UP**, not down. The MacBook's built-in mic is array-beamformed, captures 16-bit 48 kHz natively (we resample to 16 kHz mono for Silero), and isn't bottle-necked through an 8 kHz telephony codec. HFP's mic stream would have been the worst of all worlds: low fidelity *and* breaks playback.
- **The classifier is pure** — `pickEffectiveDevice` is `nonisolated static` and takes its full state as parameters, so the BT-detection policy is unit-testable against synthetic `Device` fixtures with `kAudioDeviceTransportType*` codes. No need for real HAL hardware on CI.
- **One of two BT-stutter fixes** — this doc closes the HFP-codec-switch vector. The [Core Audio HAL IOProc rewrite](../tooling-decisions/coreaudio-hal-ioproc-input-capture-2026-05-18.md) closes the second vector (AVAudioEngine aggregate-device kick on `engine.start()`). Both ship; both are necessary; they're independent.

## When to Apply

- Always, by default. Off-switch lives in Settings for the edge cases.
- Reconsider if/when BLE Audio (LC3) becomes the dominant BT profile on user hardware AND macOS exposes it without forcing the HFP-style profile switch — at that point the fallback could be narrowed to "BT classic only" via `kAudioDeviceTransportTypeBluetooth` (excluding LE).
- The classifier should treat `kAudioDeviceTransportTypeUnknown` (aggregate devices, broken kexts) as neither built-in nor BT — pinned by `test_device_isNeither_forUnknownTransport`.

## Examples

The pure picker policy, called from `effectiveDevice`:

```swift
nonisolated static func pickEffectiveDevice(
    inputs: [Device],
    selectedUID: String?,
    systemDefault: Device?,
    preferBuiltInOverBluetooth: Bool
) -> Device? {
    if let uid = selectedUID, let pinned = inputs.first(where: { $0.uid == uid }) {
        return pinned          // explicit pin wins
    }
    if preferBuiltInOverBluetooth,
       let def = systemDefault,
       def.isBluetooth,
       let builtIn = inputs.first(where: { $0.isBuiltIn }) {
        return builtIn         // BT fallback to built-in
    }
    return systemDefault       // pass through
}
```

Transport-type detection (Core Audio HAL):

```swift
var address = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyTransportType,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var transport: UInt32 = 0
var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
// transport ∈ {kAudioDeviceTransportTypeBuiltIn, ...Bluetooth, ...BluetoothLE, ...USB, 0=Unknown}
```

`effectiveLabel` mirrors the policy decision so the picker dropdown honestly reflects what NoType is about to record from: `"MacBook Pro Microphone (avoiding AirPods Pro)"` when the fallback fires, plain device name when the user has pinned, `"\(name) (System)"` for straight pass-through.

## Related

- `NoType/Recording/AudioDeviceManager.swift` — pure `pickEffectiveDevice` + transport-type detection.
- `NoType/Recording/AudioRecorder.swift` — per-session log of the fallback firing (`AudioRecorder.resolveEffectiveDevice` post-HAL rewrite).
- [Core Audio HAL IOProc for input capture](../tooling-decisions/coreaudio-hal-ioproc-input-capture-2026-05-18.md) — companion fix that closes the second BT-stutter vector (AVAudioEngine aggregate-device kick).
- `NoTypeTests/AudioDeviceManagerTests.swift` — pins every relevant branch of the picker policy.
- [Aggregate-device handling](../documentation-gaps/bluetooth-aggregate-device-handling-2026-05-16.md) — known gap: BT mics wrapped in aggregate devices bypass this policy.
- [LE Audio narrowing](../documentation-gaps/bt-le-audio-airpods-pro-2-narrowing-2026-05-16.md) — open question on whether to narrow `BluetoothLE` out of the fallback once HFP-free LC3 becomes reliable.
- v1 toggle was removed from the UI in PR #50; the `notype.preferBuiltInOverBluetooth` UserDefaults key remains the hidden escape hatch.
- Apple's [Core Audio Constants Reference](https://developer.apple.com/documentation/coreaudio/audiohardware/transport-types-constants) — the `kAudioDeviceTransportType*` enum.
- Bluetooth SIG, A2DP vs HFP profile specs (external).
