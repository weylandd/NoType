---
title: Mid-session device-swap rebuild could orphan an IOProc in a narrow race
date: 2026-07-10
category: documentation-gaps
module: Recording
problem_type: documentation_gap
component: tooling
severity: low
---

# Mid-session device-swap rebuild could orphan an IOProc in a narrow race

## Context

`AudioRecorder` supports mid-session input-device swaps: it installs a
HAL listener on `kAudioHardwarePropertyDefaultInputDevice`, and on fire
`handleConfigurationChange()` (`NoType/Recording/AudioRecorder.swift:442`)
calls `teardownHAL()` then `openAndStartHAL()` to rebuild the IOProc
against the new device without ending the session.

A code review (2026-07-10, R21 PLAUSIBLE-low) raised the theoretical
concern that a rebuild racing a concurrent `stop()` / teardown could
momentarily leave an orphaned IOProc, or that a mid-rebuild failure could
strand the session.

In practice the code already guards the two known windows:

- `handleConfigurationChange` latches `stopped` under `lock` and
  short-circuits when the recorder is stopped (`:444-449`), so a
  property-change callback already queued on `DispatchQueue.main` can't
  spawn an orphan IOProc after `stop()`.
- The rebuild-failure arm finishes the async stream under `lock`
  (`:456-465`) so the session sees the tail and can paste what it has.
- `teardownHAL` drains `ioQueue` between `AudioDeviceStop` and
  `AudioDeviceDestroyIOProcID` (documented in `NoType/Recording/CLAUDE.md`
  "Mid-session input-device swap").

## Guidance

Leave as-is. No repro exists and the existing `stopped`-latch + queue
drain cover the documented races. If a repro appears — a stuck/hot mic
or a doubled IOProc after a mid-session device change — add a
rebuild-generation token so a late `openAndStartHAL` from a superseded
change is discarded before it opens a second IOProc.

## Why This Matters

Mid-session device swap is a rare event intersected with a narrow timing
window, and the current guards make it benign. Adding speculative
generation-token state to the HAL rebuild path would complicate the most
concurrency-sensitive code in the recorder for a race no one has
observed.

## When to Apply

- A repro of a stuck mic or duplicated IOProc after a mid-session default-
  input change (unplug headphones, swap default input in System Settings
  mid-hold).
- The HAL rebuild path is being reworked for another reason.

## Examples

```swift
// AudioRecorder.swift:442 — the guarded rebuild:
private func handleConfigurationChange() {
    lock.lock(); let isStopped = stopped; lock.unlock()
    if isStopped { return }              // latch closes the stop() race
    teardownHAL()
    do { try openAndStartHAL() }
    catch { /* finish stream so the tail still pastes */ }
}
```

## Related

- `NoType/Recording/AudioRecorder.swift` (`handleConfigurationChange`, `teardownHAL`, `stop`)
- `NoType/Recording/CLAUDE.md` ("Mid-session input-device swap")
- `docs/solutions/architecture-patterns/bluetooth-input-avoidance-2026-05-16.md`
- Source plan: `docs/plans/2026-07-10-001-fix-code-review-remediation-plan.md` (R21 / U22, OQ4)
