# Hotkey module

Detects the global push-to-talk hotkey. Default: **Right Option** (held).

## Files

- `HotkeyMonitor.swift` — `CGEventTap`, dedicated runloop, press / release dispatch, Escape cancellation.

The v1 binding is hard-coded to Right Option inside `HotkeyMonitor`. The "v2 customization" subsection below sketches the planned `HotkeyConfig` / `HotkeyBinding` shape — those types don't exist yet, introduce them when the feature lands.

## Invariants

1. **Right Option bit = `0x40`** (`NX_DEVICERALTKEYMASK`); left Option bit = `0x20`. Press = bit transitions 0 → 1, release = 1 → 0. We track `previousFlags` ourselves because `flagsChanged` doesn't tell us *which* flag changed.
2. **`.listenOnly`, not `.defaultTap`.** We don't consume the event; Right Option / Escape pass through to the OS for normal use.
3. **Tap lives on a dedicated `Thread` with its own `RunLoop`** named `"app.notype.hotkey"`, `qualityOfService = .userInteractive`. Never on the main runloop.
4. **`tapDisabledByTimeout` / `tapDisabledByUserInput` must re-enable.** macOS disables our tap if we're slow (>1 s); if we don't re-enable, the app silently stops responding to the hotkey.
5. **Escape (keycode 53) cancels** when `recordingState` is `.recording` or `.sending`. Stray Esc when `.idle` is a harmless no-op.
6. **`AppState.cancelRecording()` is the single cancellation entry point** for both Esc and the recording-HUD close button.
7. **`AppState` watches `permissions.accessibility`** and installs / uninstalls the tap on transition. Accessibility revoke mid-session is supported (tap goes down, polling notices when re-granted).

## Hard rules

- **Don't install the tap on the main runloop.** Main-runloop busy (UI animation, file pickers, modal sheets) stalls the tap and drops events.
- **Don't read `event.getIntegerValueField(.keyboardEventKeycode)` for Option detection.** Bit-mask on `event.flags.rawValue` is sufficient and avoids a syscall.
- **Always re-enable on `tapDisabledByTimeout`.** Log the disable / re-enable cycle in production to surface flaky behaviour.
- **`finalizeRecording` keeps `currentSession` non-nil during `.sending`** so the Esc cancellation path can reach the session. The completion `Task` uses `currentSession === session` identity guards to avoid a late-arriving result clobbering a replaced session.

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

- The bit-math helper as a pure function (`HotkeyMonitor.detectTransition(prev:curr:)`).
- The state machine with synthetic event sequences.
- `CGEventTap` itself is system-level — not unit-testable.

Manual smoke test before each release: hold Right Option in Mail / Slack / Xcode / Safari / Terminal and verify press / release fire.

## v2 customization (not yet built)

When configurable hotkeys land:

- Introduce `HotkeyConfig` + `HotkeyBinding` enum (`.rightOption`, `.leftOption`, `.fnKey`, `.custom(modifiers, keyCode)`).
- `HotkeyMonitor` switches detection logic on the binding.
- Non-modifier-only bindings (e.g. `⌃⇧Space`) subscribe to `keyDown`/`keyUp` instead of `flagsChanged`. The dedicated-thread `CGEventTap` structure stays.

## Pointers

- Why Right Option via `CGEventTap` → `solutions/design-patterns/right-option-cgeventtap-2026-05-15.md`.
- Why Accessibility is needed (and why it's "free" here) → `NoType/Context/CLAUDE.md`.
- The same `CGEvent` API on the output side → `NoType/Injection/CLAUDE.md`.
