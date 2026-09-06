---
title: A mic-picker change during a recording session does not reach AudioRecorder
date: 2026-08-13
last_updated: 2026-08-13
category: documentation-gaps
module: Recording
problem_type: documentation_gap
component: audio
severity: low
applies_when:
  - "Changing the input device from the popover footer or Settings → Recording while a dictation is running"
  - "Adding a second trigger for AudioRecorder's mid-session device rebuild"
  - "Auditing whether a device-selection change reaches every consumer"
symptoms:
  - "A device pinned mid-session keeps recording from the previous microphone until the session ends"
tags: [audio, device-selection, techdebt, mid-session]
related_components: [Recording, UI]
---

# A mic-picker change during a recording session does not reach `AudioRecorder`

**Size: S.** Found while fixing [issue #86](https://github.com/weylandd/NoType/issues/86); deliberately scoped out of that PR.

## Context

`AudioRecorder` supports mid-session input-device swaps: it installs a HAL
property listener for the session's lifetime, and on fire tears down the
IOProc, rebuilds the `AVAudioConverter` against the new device's stream
format, and reopens — preserving the PCM buffer.

That listener is on **`kAudioHardwarePropertyDefaultInputDevice`**: the
*system* default changing. The mic picker does not change the system
default. It writes `AudioDeviceManager.selectedUID`, and nothing on the
recording path observes it.

So a user who starts dictating, then pins a different microphone from the
popover footer or Settings → Recording, keeps being recorded by the
previous device until that session ends. The rebuild machinery would
honour the new pick — `openAndStartHAL` calls `resolveEffectiveDevice()`,
which reads `effectiveDevice` and therefore `selectedUID` — it simply is
never triggered.

This is the same shape as issue #86 in `MicProbe`: a selection that does
not reach a rebuild path. It is recorded separately because the impact is
different in the way that decides priority.

## Guidance

**Leave it as-is until someone reports it.** Three reasons, in order of
weight:

1. **Nothing lies to the user.** What made #86 worth fixing on sight was
   not the stale device — it was that the spectrum meter kept moving, so
   the screen actively asserted the switch had worked while the user
   confirmed the wrong microphone. There is no such surface here. The
   recording HUD shows a level meter fed by the stream that is actually
   being captured, so it stays truthful; the dictation completes and
   pastes normally, on the device it began on.
2. **The window is small and the action is unusual.** It requires changing
   devices *during* a dictation. Under push-to-talk the user is holding a
   key; it is really only reachable in a locked session, and even then the
   next dictation picks up the new device.
3. **The listed fix is not free.** The natural shape — a
   `withObservationTracking` loop on `selectedUID`, mirroring
   `MicProbe.start()`'s — is exactly the `MainActor` plumbing the current
   doc-comment says the HAL listener exists to avoid, and it adds a second
   trigger into `handleConfigurationChange()`, whose `stopped`-latch and
   `ioQueue`-drain ordering already carry a documented near-miss
   (`docs/solutions/documentation-gaps/device-swap-rebuild-orphan-2026-07-10.md`).
   A second, differently-timed producer into that path deserves its own
   review, not a drive-by.

**If it is fixed**, the trigger belongs beside the HAL listener with the
same session lifetime, and it must go through `handleConfigurationChange()`
rather than calling `openAndStartHAL()` directly — that is where the
late-callback guard lives.

## Why This Matters

The generalisable point is the audit question, not this instance: **a
device selection has more than one consumer, and each consumer subscribes
to a different signal.** `MicProbe` watched `selectedUID` but pinned only
on one of its two setup paths (#86). `AudioRecorder` re-resolves on every
rebuild but subscribes to a signal the picker never sends. Both are "the
pick doesn't arrive", reached from opposite directions.

When adding a third consumer, ask both halves explicitly: *what triggers a
re-resolve*, and *does every setup path re-resolve*.

## When to Apply

- A user reports that changing the microphone mid-dictation did nothing.
- Any change that adds a consumer of `AudioDeviceManager.effectiveDevice`.
- Any change that adds a producer into `AudioRecorder.handleConfigurationChange()`.

## Examples

Current triggers for a mid-session rebuild, and what each one does *not*
cover:

| Trigger | Fires on | Misses |
|---|---|---|
| HAL listener on `kAudioHardwarePropertyDefaultInputDevice` | system default changes (device unplugged, headset connects, user changes it in System Settings) | the app's own picker |
| *(none)* | — | `AudioDeviceManager.selectedUID` writes |

## Related

- [`issue #86`](https://github.com/weylandd/NoType/issues/86) — the `MicProbe` half, fixed in 0.1.14.
- [`device-swap-rebuild-orphan-2026-07-10.md`](./device-swap-rebuild-orphan-2026-07-10.md) — the existing race note on the same rebuild path; read before adding a second producer into it.
- `NoType/Recording/CLAUDE.md` — "Mid-session input-device swap is supported" hard rule.
