---
title: Consuming CGEventTap teardown — strand a `.defaultTap` and you strand the key OS-wide
date: 2026-05-18
category: design-patterns
module: Hotkey
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - Installing a `.defaultTap` CGEventTap that consumes events (returns `nil` from the callback)
  - Adding a secondary CGEventTap subordinate to an existing primary one
  - Wiring lifecycle for any tap that holds state beyond a single keystroke
tags: [hotkey, cgeventtap, defaulttap, event-tap-teardown, ax-revoke, lifecycle]
---

# Consuming CGEventTap teardown — strand a `.defaultTap` and you strand the key OS-wide

## Context

NoType's primary `HotkeyMonitor` CGEventTap is installed with `.listenOnly` — it never consumes events. This is `Hotkey/CLAUDE.md` invariant 2 and is safe by default: a tap that only observes can be stranded without user-visible consequence (events still reach their destinations regardless of whether the tap is running).

The Hold+Space recording-lock feature introduced `SpacebarLockMonitor`, a **secondary** `.defaultTap` CGEventTap that **consumes** keycode 49 (Space) when the recording hotkey is held and the session is active. This is the only `.defaultTap` in the project. The narrow predicate — gated on hold state, session phase, and a `hotkeyCode != "Space"` carve-out — keeps the consumption window tight during normal operation.

Code review on PR #49 caught a missing teardown path: `AppState.uninstallHotkey()`, called on Accessibility-permission revoke, tore down the primary monitor but did **not** call `uninstallSpacebarLockTap()`. If Accessibility was revoked mid-session (the user toggling it off in System Settings while a recording was in flight), the primary tap was correctly torn down, but the secondary `.defaultTap` remained resident on its dedicated runloop. From that point until process death, every Space keypress was silently consumed — the user could not type a space character in any app on the system.

The fix is one line. The failure mode is OS-wide and invisible during normal testing.

## Guidance

> **Any `.defaultTap` CGEventTap that consumes events MUST be torn down on every disable path of the feature subsystem that installed it.**

A `.listenOnly` tap stranded by a missing teardown is harmless — events still pass through to their destinations. A `.defaultTap` stranded by a missing teardown continues to run its callback on its own thread, and any event for which it returns `nil` is permanently swallowed from the OS event stream, affecting every running application.

The rule in practice:

1. **Map every install path to a symmetric teardown.** If a tap is installed in `installFoo()`, the teardown call must appear in **every** path that disables or tears down the parent feature: explicit uninstall, permission revoke, rebind, app quit, session end.
2. **Make the teardown idempotent.** Guard on `guard let monitor = fooMonitor else { return }` so repeated calls from multiple paths are safe.
3. **Tear down child taps inside the parent's uninstall.** A subordinate tap (like `SpacebarLockMonitor` under `HotkeyMonitor`) has no reason to outlive its parent. Wiring teardown into the parent's `uninstall()` covers the catch-all paths (AX revoke, rebind) that don't end the session cleanly.
4. **Leave a comment explaining why.** The stranded-Space failure mode is non-obvious. Document it at the call site so the next editor doesn't remove the "redundant-looking" call.

Post-fix `AppState.uninstallHotkey()`:

```swift
private func uninstallHotkey() {
    guard let monitor = hotkeyMonitor else { return }
    monitor.stop()
    hotkeyMonitor = nil
    // The secondary Hold+Space tap has no reason to outlive the
    // primary monitor — without an active recording-hotkey tap the
    // predicate can never become true. Tearing it down here covers
    // the AX-revoke-mid-session path explicitly: a stranded
    // `.defaultTap` consuming Space across the OS would be worse
    // than the recording outage itself. The call is idempotent.
    uninstallSpacebarLockTap()
    Self.log.info("hotkey uninstalled")
}
```

The pre-fix version contained only `monitor.stop()` and `hotkeyMonitor = nil`. `uninstallSpacebarLockTap()` was called from the three session-end paths (finalize success, finalize error, cancel) but **not** from `uninstallHotkey()` itself — so the AX-revoke path, which calls `uninstallHotkey()` without ending the session through a normal path, left the secondary tap installed.

`uninstallSpacebarLockTap()` is idempotent by construction:

```swift
private func uninstallSpacebarLockTap() {
    guard let monitor = spacebarLockMonitor else { return }
    monitor.stop()
    spacebarLockMonitor = nil
    spacebarLockEnabled.withLock { $0 = false }
    Self.log.info("hold+space lock tap uninstalled")
}
```

## Why This Matters

A stranded `.defaultTap` is an OS-wide input failure, not an application-local bug:

- The tap thread stays alive on its dedicated runloop after its parent feature is disabled. The kernel doesn't know the feature is gone.
- Every Space keypress hits the orphaned callback. The callback reads its lock-protected predicate — but with the session torn down, the predicate's source-of-truth state can be inconsistent (a `true` left in `spacebarLockEnabled` at the moment of revoke is the regression vector). When the predicate returns `true`, the tap returns `nil` and the OS swallows the event.
- The user cannot type a space character in Mail, Slack, Xcode, Safari, or any other app. There is no recovery short of killing the NoType process. macOS does not surface "an event tap consumed your keystroke" to the user.
- This failure mode is invisible in standard testing because "user revokes Accessibility while holding the hotkey" is not a happy-path scenario, and a manual test that simply toggles permissions outside an active recording session never observes the bug.

The asymmetry between `.listenOnly` and `.defaultTap` is easy to miss reading the `CGEventTap` documentation: both are described as "event taps," but only `.defaultTap` gives the callback the power to silently swallow events. The blast-radius difference between leaving each kind stranded is enormous.

## When to Apply

Whenever you install a `.defaultTap` CGEventTap (or any event-consuming tap with `options: .defaultTap`):

- Enumerate **all** lifecycle paths that disable the feature subsystem: explicit uninstall, permission revoke (TCC re-check), app suspension, rebind, session-end paths, deinit.
- Add a `stop()` call on each path, not just the "normal" session-end paths.
- If the consuming tap is logically subordinate to a parent tap (as `SpacebarLockMonitor` is to `HotkeyMonitor`), hook its teardown into the parent's `stop()` / `uninstall()` as well as the feature's own session-end paths. The redundancy is the point — every path is covered.
- Audit the `kCGEventTapDisabledByTimeout` / `kCGEventTapDisabledByUserInput` re-enable callback: re-enabling a tap that should already be torn down is also a bug. Confirm the re-enable only runs while the parent feature is still active (`SpacebarLockMonitor.handle` already guards this via `isActive`).
- Pre-flight the failure scenario by mentally walking the AX-revoke / rebind paths. If the answer to "what disables this consuming tap?" is shorter than the answer to "what installs this consuming tap?", the rule is being violated.

## Examples

**Before (PR #49 review finding):**

```swift
// uninstallHotkey() — missing secondary tap teardown
private func uninstallHotkey() {
    guard let monitor = hotkeyMonitor else { return }
    monitor.stop()
    hotkeyMonitor = nil
    // ← no call to uninstallSpacebarLockTap()
    // If called via AX-revoke path, SpacebarLockMonitor stays
    // resident and may consume Space OS-wide.
    Self.log.info("hotkey uninstalled")
}
```

**After (PR #49 fix):**

```swift
private func uninstallHotkey() {
    guard let monitor = hotkeyMonitor else { return }
    monitor.stop()
    hotkeyMonitor = nil
    // Tear down the secondary Hold+Space tap. Without this,
    // AX-revoke mid-session leaves a stranded .defaultTap
    // consuming Space across the entire OS. Idempotent.
    uninstallSpacebarLockTap()
    Self.log.info("hotkey uninstalled")
}
```

**Install / teardown symmetry checklist for `SpacebarLockMonitor`:**

| Path | Install call | Teardown call |
|---|---|---|
| Session start | `installSpacebarLockTapIfNeeded()` | — |
| Session finalize (success) | — | `uninstallSpacebarLockTap()` |
| Session finalize (error) | — | `uninstallSpacebarLockTap()` |
| `cancelRecording()` | — | `uninstallSpacebarLockTap()` |
| `uninstallHotkey()` (AX revoke / rebind) | — | `uninstallSpacebarLockTap()` ← **this was the gap** |

## Related

- [Right Option as push-to-talk via CGEventTap](right-option-cgeventtap-2026-05-15.md) — the primary `.listenOnly` tap's design rationale. This new doc is its consuming-tap companion. That doc's `## When to Apply` could gain a sub-bullet about secondary `.defaultTap` teardown — flagged as a refresh candidate.
- `NoType/Hotkey/SpacebarLockMonitor.swift` — full lifecycle of the secondary tap, including the `isActive` re-enable guard.
- `NoType/Hotkey/CLAUDE.md` — invariant 2 (the `.listenOnly` rule) and the narrow-scope-weakening rationale documenting why this exception was accepted.
- [Swift 6 strict concurrency and async](../conventions/swift-6-concurrency-and-async-2026-05-15.md) — relevant to the broader PR #49 context (the `@MainActor SleepAssertion` isolation bundled in the same fix PR), tangential to this specific learning.
