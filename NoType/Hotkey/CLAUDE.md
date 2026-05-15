# Hotkey module

Detects the global push-to-talk hotkey. Default binding: **Right Option** (held).

Files:
- `HotkeyMonitor.swift` — `CGEventTap`, runloop, press/release dispatch.

The v1 binding is hard-coded to Right Option inside `HotkeyMonitor`. The "v2 customization" section below sketches the planned `HotkeyConfig` / `HotkeyBinding` shape but those types don't exist yet — introduce them when the feature lands, not earlier.

---

## Why CGEventTap (not NSEvent)

Modifier-only hotkeys (Right Option, no other key) can't be reliably caught by `NSEvent.addGlobalMonitorForEvents`. The system delivers `flagsChanged` events through there inconsistently — works for some users, fails for others, depends on focus state.

`CGEventTap` is the only stable path. The trade-off is that it requires Accessibility permission. We need that anyway for the AX tree, so it's free for us.

---

## Distinguishing Right vs Left Option

We distinguish the two Options purely by the **per-side modifier bits** in `event.flags.rawValue`:

- Right Option bit: `0x40` (`NX_DEVICERALTKEYMASK` in IOKit terms).
- Left Option bit: `0x20`.

Press = right-Option bit transitions 0 → 1. Release = 1 → 0. We track `previousFlags` ourselves because `flagsChanged` doesn't tell us *which* flag changed in a multi-modifier scenario.

```swift
static let rightOptionBit: UInt64 = 0x40

static func detectTransition(prev: UInt64, curr: UInt64) -> Transition {
    let p = (prev & rightOptionBit) != 0
    let c = (curr & rightOptionBit) != 0
    switch (p, c) {
    case (false, true):  return .pressed
    case (true,  false): return .released
    default:             return .none
    }
}
```

We do **not** read `event.getIntegerValueField(.keyboardEventKeycode)` — the bit-mask approach is sufficient and simpler. The keyCode constants (61 = right Option `kVK_RightOption`, 58 = left Option `kVK_Option`) are recorded here only for reference.

---

## Runloop & threading

`CGEventTap` requires a runloop. **Do not** install on the main runloop — when the main runloop is busy (UI animation, file pickers, modal sheets), the tap stalls and events are dropped.

Pattern:
1. Create the tap with `CGEvent.tapCreate`.
2. Wrap as a `CFRunLoopSource`.
3. Spawn a dedicated `Thread`, store the source on its runloop, run the loop forever.

```swift
let thread = Thread { [weak self] in
    guard let tap = self?.tap else { return }
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopRun()
}
thread.name = "app.notype.hotkey"
thread.qualityOfService = .userInteractive
thread.start()
```

Cross from this thread to `@MainActor` for press/release dispatch:

```swift
let callback: CGEventTapCallBack = { _, _, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleEvent(event)  // schedules @MainActor work internally
    return Unmanaged.passUnretained(event)
}
```

`HotkeyMonitor.handleEvent` does the bit math and then `Task { @MainActor in delegate?.onPress() }`.

---

## Tap restoration

macOS may **disable our tap** if the system thinks we're slow to process events (>1 s). When that happens we get a `tapDisabledByTimeout` event type. Handle:

```swift
if event.type == .tapDisabledByTimeout || event.type == .tapDisabledByUserInput {
    CGEvent.tapEnable(tap: tap, enable: true)
    return Unmanaged.passUnretained(event)
}
```

We must always re-enable. If we don't, the app silently stops responding to the hotkey — one of the worst possible UX failures for a dictation app.

In production, log every disable/re-enable to surface flaky behavior.

---

## Event mask

We care about `flagsChanged` (Right Option press/release) **and** `keyDown` (Escape, for cancelling an in-flight session):

```swift
let mask = CGEventMask(
    (1 << CGEventType.flagsChanged.rawValue) |
    (1 << CGEventType.keyDown.rawValue)
)
```

Importantly: we use `.listenOnly`, **not** `.defaultTap`. We do not consume the event; the user's Right Option and Escape keystrokes still pass through to the OS for normal use (typing accented characters, dismissing popups, etc.). The trade-off is that holding Right Option while typing other keys may produce special characters; users who type a lot of `™` and `©` should rebind their hotkey post-v1.

The keyDown mask increases the volume of callbacks we see (one per keystroke globally), but we filter to keycode 53 (Escape) inside the tap callback and dispatch only that to the main actor. The bit-mask check is cheap; this is fine.

### Escape cancellation

Pressing Escape while a session is active aborts it without sending to Gemini (during `.recording`) or while the post-release Gemini call + paste are in flight (during `.sending`). The flow:

1. Tap callback sees `.keyDown` with keycode 53 → schedules `onEscape()` on the main actor.
2. `AppState.cancelRecording()` gates on `recordingState` being `.recording` or `.sending` (a stray Esc when idle is a harmless no-op) and:
   - Drops the session reference.
   - Resets recording state to `.idle`.
   - Hides whichever HUD is up (recording or transcribing — both calls are idempotent).
   - Spawns a fire-and-forget `Task` that calls `session.cancel()` — which installs a synthetic `CancellationError` so the racing `stop()` path (already running during `.sending`) bails cleanly without pasting.

`finalizeRecording` deliberately keeps `currentSession` non-nil while the state is `.sending` so this path can reach the session. Its `Task` completion uses a `currentSession === session` identity guard so a late-arriving result for a session the user has since cancelled (and replaced) can't clobber the new one.

The recording HUD's close button (`DSCloseButton`) calls the same `cancelRecording()` path, and visually carries an `Esc` keycap chip next to the X so the affordance is discoverable. The transcribing HUD's X is still dismiss-only by design (hides the HUD without cancelling the call) — Esc is the path for actually aborting in-flight transcription.

---

## Permission gating

On startup, check `AXIsProcessTrusted()`:
- If trusted → install tap.
- If not → don't install. Surface in menu bar with a yellow dot. Onboarding flow handles the request.

If the user grants Accessibility while the app is running, we don't get a notification. `PermissionsViewModel` polls `AXIsProcessTrusted()` every 1 second when any permission is not yet `granted`; once all are granted, polling stops. `AppState` watches `permissions.$accessibility` and installs/uninstalls the tap on transition.

---

## v2 customization

Out of scope for v1, but the design accommodates it:
- `HotkeyConfig` will hold a `HotkeyBinding` enum: `.rightOption`, `.leftOption`, `.fnKey`, `.custom(modifiers, keyCode)`.
- `HotkeyMonitor` switches its detection logic on the binding.
- For non-modifier-only bindings (e.g. `⌃⇧Space`), we'd subscribe to `keyDown`/`keyUp` instead of `flagsChanged`.

---

## Testing

Hard to unit-test directly — `CGEventTap` is system-level. We test:
- The bit-math helper as a pure function (`HotkeyMonitor.detectTransition(prev:curr:)`).
- The state machine with synthetic event sequences.

Manual smoke test before each release: hold Right Option in 5 different apps (Mail, Slack, Xcode, Safari, Terminal) and verify press/release fire correctly.
