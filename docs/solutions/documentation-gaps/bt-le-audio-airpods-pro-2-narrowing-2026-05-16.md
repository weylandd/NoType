---
title: Narrow BT-input avoidance to classic BT once LE Audio is reliably HFP-free
date: 2026-05-16
category: documentation-gaps
module: Recording
problem_type: documentation_gap
component: tooling
severity: low
applies_when:
  - User reports the BT-avoidance fallback misfires on an AirPods Pro 2 / LE Audio device
  - Apple expands LE Audio mic support across more hardware (post-macOS 15)
tags: [audio, bluetooth, ble-audio, lc3, airpods-pro-2, tech-debt]
---

# Narrow BT-input avoidance to classic BT once LE Audio is reliably HFP-free

## Context

The BT-input-avoidance fallback ([architecture-patterns/bluetooth-input-avoidance-2026-05-16.md](../architecture-patterns/bluetooth-input-avoidance-2026-05-16.md)) currently treats `kAudioDeviceTransportTypeBluetooth` and `kAudioDeviceTransportTypeBluetoothLE` symmetrically — both transports trigger the fallback to the built-in mic.

The symmetry is conservative: classic BT (BR/EDR) forces the A2DP→HFP profile switch as documented Apple behaviour, but BLE Audio / LE Audio (LC3 codec, isochronous channels) does *not* require that switch on hardware that fully supports it. On AirPods Pro 2 with macOS 14.3+ and LE Audio active, mic input can happen alongside hi-fi music playback without the HFP fallback — the feature's whole motivation doesn't apply.

ce-adversarial-reviewer flagged this in PR #40's review (anchor 50, P2). The PR description called it out as a deferred open question:

> BLE Audio / LC3 path (Apple AAC LC + LC3) when more users have macOS 15 + AirPods Pro 2 + LE Audio devices. The transport-type detection already handles `...BluetoothLE` symmetrically; revisit whether the fallback should narrow to classic BT only when LE Audio stops forcing the profile switch.

Worst case for AirPods Pro 2 users on macOS 14.3+ today: they get the built-in mic instead of the AirPods mic. **This isn't actively harmful** — the built-in mic is array-beamformed and the user can pin the AirPods explicitly in the picker — but they're losing the feature's main benefit (BT mic without breaking music) for no compensating gain.

## Guidance

**Hold off on narrowing until we have hardware to measure.** The decision space is:

1. **Keep BLE in the fallback** (current). Conservative, costs AirPods Pro 2 users some quality but never makes things worse.
2. **Drop BLE from the fallback.** Risks regressing for any LE Audio device that *does* still force HFP-style behaviour (older firmware, intermittent LE Audio link, third-party LE Audio headsets that fall back to HFP).
3. **Gate on a runtime probe** — open a tiny mic stream first, check whether the device's `kAudioDevicePropertyActualSampleRate` drops to telephony (8/16 kHz), and only avoid if it did. Adds latency at session start, but tests reality.

Option 3 is the principled answer but adds non-trivial complexity. Defer until users report enough cases to make the trade-off worthwhile.

## Why This Matters

- AirPods Pro 2 + macOS 14.3+ is a growing cohort, especially among Apple-ecosystem-first users — exactly the audience that's most likely to use NoType.
- Wrong narrowing direction is invisible: users who lose A2DP can hear it; users who get built-in mic when they wanted AirPods mic just see "transcription works but mic isn't AirPods" and may not realise it's a choice.

## When to Apply

- 3+ user reports of AirPods Pro 2 / LE Audio mic being unexpectedly bypassed.
- We acquire test hardware (AirPods Pro 2 + a Mac on macOS 14.3+) to measure whether opening the mic stream actually triggers HFP fallback or not.
- Either trigger lands → implement option 3 (runtime probe) or option 2 (drop BLE) based on measurement.

## Examples

Runtime probe sketch:

```swift
nonisolated static func opensWithoutHFP(_ device: Device) -> Bool {
    // Open a 100 ms throwaway stream, read actual sample rate, close.
    // If it stays at 48 kHz / 16 kHz hi-fi → BLE is HFP-free. If it
    // drops to 8 kHz → still HFP, treat as classic BT.
    ...
}
```

## Related

- [architecture-patterns/bluetooth-input-avoidance-2026-05-16.md](../architecture-patterns/bluetooth-input-avoidance-2026-05-16.md) — the feature this gap belongs to.
- Apple's [LE Audio support timeline](https://support.apple.com/en-us/108987) — which hardware / OS combinations support LC3 mic input.
- PR #40 — original BT-avoidance landing; PR description already calls this out as a follow-up.
