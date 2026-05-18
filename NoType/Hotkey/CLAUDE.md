# Hotkey module

Detects the global push-to-talk hotkey. Default: **Right Option** (held), user-rebindable.

## Files

- `HotkeyBinding.swift` — `struct` value type with a JS-style `code: String` (`AltRight`, `KeyR`, `F12`, …). Persisted in `UserDefaults` under `notype.hotkey.bindingCode`. Owns the static `modifierBits` / `virtualKeyCodes` / display tables and the two allowlists: `isAllowedAsHotkey` (recording binding — rejects Escape, Power, CapsLock) and `isAllowedAsCancelBinding` (cancel binding — non-modifier keys only, permits Escape).
- `HotkeyMonitor.swift` — primary `CGEventTap`, dedicated runloop, press / release dispatch, cancel-binding-driven abort. Parametrised on both a recording `HotkeyBinding` and a `cancelBinding: HotkeyBinding` (default Escape). `.listenOnly` — never consumes.
- `SpacebarLockMonitor.swift` — secondary `.defaultTap` CGEventTap installed by AppState for the duration of an active session. Listens for keycode 49 (Space) and consumes it iff the Hold+Space predicate is true (recording hotkey held, session in `.recording`, not already locked, recording hotkey ≠ Space). Fires `handleSpacebarLockTrigger()` on consume.

## Invariants

1. **Detection routing.** Modifier bindings (Option/Control/Shift/Command, L+R split, Fn) drive via `flagsChanged` and the device-side bit returned by `HotkeyBinding.modifierBit` — Right Option = `0x40` (`NX_DEVICERALTKEYMASK`), Left Option = `0x20`, full table in `HotkeyBinding.modifierBits`. Press = bit transitions 0→1, release = 1→0. We track `previousFlags` ourselves because `flagsChanged` doesn't tell us *which* flag changed. Non-modifier bindings (letters, digits, F-row, Space, …) drive via `keyDown`/`keyUp` and virtual-key matching on `HotkeyBinding.virtualKeyCode`; auto-repeated `keyDown` is collapsed by `nonModifierHeld`.
2. **Primary tap is `.listenOnly`.** We don't consume the recording hotkey or the cancel key; both pass through to the OS for normal use. **Narrow-scope weakening — the secondary `SpacebarLockMonitor` tap is `.defaultTap` and consumes exactly one keycode (49 = Space) under one predicate (recording hotkey held + session active + not yet locked + hotkey ≠ Space).** This is the only `.defaultTap` in the project; the consumption window is bounded by session lifetime + held state. See `SpacebarLockMonitor.swift` for the rationale.
3. **Tap lives on a dedicated `Thread` with its own `RunLoop`** named `"app.notype.hotkey"`, `qualityOfService = .userInteractive`. Never on the main runloop. `runLoopReady` (DispatchSemaphore) publishes the runloop reference to the main actor before `start()` returns; `stop()` schedules teardown via `CFRunLoopPerformBlock` on that runloop and the thread exits when `CFRunLoopRun()` returns.
4. **`tapDisabledByTimeout` / `tapDisabledByUserInput` must re-enable** AND reset `nonModifierHeld` + `previousFlags`. Skipping the state reset would silently strand a non-modifier hotkey held during the disabled window (stuck `nonModifierHeld == true`).
5. **Cancel binding cancels** when `recordingState` is `.recording` or `.sending`. Stray cancel-key press when `.idle` is a harmless no-op. The cancel binding is rebindable (Settings → Shortcuts) under `notype.cancelHotkey.bindingCode`; default is Escape. `HotkeyMonitor` resolves the cancel keycode once at init from `cancelBinding.virtualKeyCode`, falling back to 53 (Escape) on a malformed binding. AppState's `applyCancelHotkeyBinding(_:)` enforces "cancel ≠ recording" so the user can't pick a key that would shadow the recording-hotkey path; `HotkeyBinding.isAllowedAsHotkey` rejects Escape/Power/CapsLock so a user can't pick those as the recording binding either.
6. **`AppState.cancelRecording()` is the single cancellation entry point** for both Esc and the recording-HUD close button.
7. **`AppState` watches `permissions.accessibility`** and installs / uninstalls the tap on transition. Accessibility revoke mid-session is supported (`uninstallHotkey()` calls `monitor.stop()` to invalidate the tap + stop the runloop; polling notices when re-granted).
8. **Rebinds (`AppState.applyHotkeyBinding(_:)`) are refused while `recordingState != .idle`.** Tearing the monitor down mid-session would drop the release event for the previously-held key and orphan the session.

## Hard rules

- **Don't install the tap on the main runloop.** Main-runloop busy (UI animation, file pickers, modal sheets) stalls the tap and drops events.
- **Modifier detection uses the device-side bit, not the keycode field.** `HotkeyBinding.modifierBit` returns the `NX_DEVICE*KEYMASK` to mask against `event.flags.rawValue`. Reading `event.getIntegerValueField(.keyboardEventKeycode)` is allowed only in the `keyDown`/`keyUp` branches (Escape detection + non-modifier binding match) — it costs a syscall, so don't add it back to the `flagsChanged` branch.
- **Always re-enable on `tapDisabledByTimeout` AND reset `nonModifierHeld` + `previousFlags`.** Log the disable / re-enable cycle in production to surface flaky behaviour.
- **`finalizeRecording` keeps `currentSession` non-nil during `.sending`** so the Esc cancellation path can reach the session. The completion `Task` uses `currentSession === session` identity guards to avoid a late-arriving result clobbering a replaced session.
- **Dispatched press/release `Task`s check `isActive`** before invoking the callback. Without this, a press queued microseconds before `stop()` could fire `onPress` against a being-torn-down monitor or, during rebind, against the new monitor's wiring.
- **`runLoopReady` must always be signalled** — the `defer { if !setupCompleted { readySignal.signal() } }` in the thread closure covers the early-exit case so an unexpected guard-fail can't deadlock the main actor's `start()` waiter.

## Cancellation flow

1. Tap callback sees `.keyDown` with keycode 53 → `Task { @MainActor in onEscape() }`.
2. `AppState.cancelRecording()`:
   - drops `currentSession`,
   - resets `recordingState` to `.idle`,
   - hides recording / transcribing HUDs (both calls idempotent),
   - fires `session.cancel()` on a detached task — installs a `CancellationError` so the racing `stop()` path (during `.sending`) bails cleanly without pasting.

Recording HUD's `DSCloseButton` calls the same path, with an `Esc` keycap chip next to the X for discoverability. Transcribing HUD's X is dismiss-only by design — Esc is the only path for actually aborting in-flight transcription.

## Detection helper (testable, pure)

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

## Testing

- The bit-math helper as a pure function (`HotkeyMonitor.detectTransition(prev:curr:bit:)`). The single-arg overload is kept for backwards compatibility with `HotkeyMonitorTests` and defaults to `rightOptionBit`.
- The state machine with synthetic event sequences.
- `CGEventTap` itself is system-level — not unit-testable.

Manual smoke tests before each release:
- Default (Right Option): hold in Mail / Slack / Xcode / Safari / Terminal and verify press / release fire.
- **Rebind round-trip**: Settings → change to a letter key → press it, verify session starts/stops. Change back to Right Option, verify only one session per press (not two — that's the rebind-leak regression).
- **Rebind during recording**: hold the hotkey to start a session, attempt rebind via the onboarding remap UI. `applyHotkeyBinding` should refuse with a log warning (`recordingState != .idle`).

## Pointers

- Why Right Option via `CGEventTap` → `solutions/design-patterns/right-option-cgeventtap-2026-05-15.md`.
- Why Accessibility is needed (and why it's "free" here) → `NoType/Context/CLAUDE.md`.
- The same `CGEvent` API on the output side → `NoType/Injection/CLAUDE.md`.
