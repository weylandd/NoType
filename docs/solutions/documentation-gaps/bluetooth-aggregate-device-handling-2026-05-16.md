---
title: Aggregate-device handling in the BT-input-avoidance policy
date: 2026-05-16
category: documentation-gaps
module: Recording
problem_type: documentation_gap
component: tooling
severity: low
applies_when:
  - User reports the BT avoidance fires (or fails to fire) for an aggregate / virtual audio device
  - Expanding `AudioDeviceManager.Device.transportType` handling
tags: [audio, bluetooth, aggregate-device, core-audio, hal, tech-debt]
---

# Aggregate-device handling in the BT-input-avoidance policy

## Context

The BT-input-avoidance fallback ([architecture-patterns/bluetooth-input-avoidance-2026-05-16.md](../architecture-patterns/bluetooth-input-avoidance-2026-05-16.md)) classifies devices via `kAudioDevicePropertyTransportType` and only recognises `kAudioDeviceTransportTypeBuiltIn`, `kAudioDeviceTransportTypeBluetooth`, `kAudioDeviceTransportTypeBluetoothLE`. Aggregate devices (created in Audio MIDI Setup or by third-party drivers like Loopback / BlackHole / Rogue Amoeba's tooling) report `kAudioDeviceTransportTypeAggregate` (or sometimes the catch-all `Unknown`) and bypass both branches.

Net effect: if a user's system default input is an aggregate device that contains a built-in mic alongside other inputs, the avoidance won't apply. If it contains a BT mic under the hood, the avoidance ALSO won't apply — and the user gets the same A2DP→HFP profile-switch surprise the feature exists to fix.

ce-adversarial-reviewer flagged this in the PR #40 review (anchor 75, P2). The fix is non-trivial: aggregate devices expose their sub-device list via `kAudioAggregateDevicePropertyFullSubDeviceList`, and we'd have to recursively classify the underlying transports plus invent a policy for mixed aggregates (one BT sub-device + one built-in: avoid? honour aggregate?). Without real-world data on which aggregate topologies users actually create, picking the right policy is speculation.

## Guidance

**Leave as-is until users report it.** The aggregate case is rare in practice (users who build aggregate devices are usually power users who explicitly chose the routing they want), and the avoidance off-switch in Settings is a clean escape hatch.

If reports come in, the fix shape is:

1. Add an `isAggregate` helper on `Device` (`transportType == kAudioDeviceTransportTypeAggregate`).
2. Read the sub-device list via `kAudioAggregateDevicePropertyFullSubDeviceList` on aggregate devices and classify recursively.
3. Decide the mixed-aggregate policy: probably "any BT sub-device → treat aggregate as BT for avoidance purposes" but verify against user reports first.

Pinned with new `AudioDeviceManagerTests` cases against synthetic aggregate fixtures.

## Why This Matters

- The avoidance feature's premise is "don't open mic input on a BT device unless the user explicitly asked for it". An aggregate that wraps a BT device is essentially a user explicitly asking for that BT mic (they built the aggregate), but the failure mode (HFP profile switch) is identical regardless of intent.
- Picking the wrong policy here without data risks regressing the explicit-pin behaviour for the entire aggregate cohort.

## When to Apply

- A user reports either: avoidance fires unexpectedly for their aggregate setup, OR music quality drops during dictation despite avoidance being on (indicating a BT mic snuck through an aggregate).
- We start surveying real-world aggregate topologies (e.g., via a one-time anonymous opt-in telemetry — but [no-telemetry-with-statsstore-carveout-2026-05-15.md](../conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md) currently forbids that).

## Examples

Synthetic aggregate fixture (when the time comes):

```swift
let aggregate = makeDevice(uid: "AggMix", name: "BlackHole + AirPods", transport: kAudioDeviceTransportTypeAggregate)
let subDevices = [btHeadset, virtualLoopback]
// Policy: aggregate.containsBluetoothSubDevice → treat as BT for avoidance.
```

## Related

- [architecture-patterns/bluetooth-input-avoidance-2026-05-16.md](../architecture-patterns/bluetooth-input-avoidance-2026-05-16.md) — the feature this gap belongs to.
- Apple's [Core Audio Aggregate Devices Reference](https://developer.apple.com/documentation/coreaudio/audiohardware/aggregate-devices) — `kAudioAggregateDevicePropertyFullSubDeviceList`.
- PR #40 — original BT-avoidance landing; this entry tracks the deferred adversarial finding.
