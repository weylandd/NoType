# Permissions module

Wraps the OS permission request APIs and exposes a single `@Observable` view-model. For high-level rationale and the list of permissions, see `docs/permissions.md`. This file is the implementation guide.

## Files

- `PermissionStatus.swift` — the shared enum (`unknown`, `notDetermined`, `denied`, `granted`).
- `SystemSettingsPane.swift` — shared deep-link helper. `x-apple.systempreferences:` URL pattern + `Privacy_*` enum; each permission file delegates `openSystemSettings()` here.
- `MicrophonePermission.swift` — `AVCaptureDevice` + delegates to `SystemSettingsPane.microphone`.
- `AccessibilityPermission.swift` — `AXIsProcessTrustedWithOptions` + delegates to `SystemSettingsPane.accessibility`.
- `ScreenRecordingPermission.swift` — **optional**; gates the OCR fallback (`NoType/Context/ScreenCapture/`).
- `PermissionsViewModel.swift` — `@MainActor @Observable` aggregate.

There is **no** `SpeechRecognitionPermission.swift` — NoType uses Silero (CoreML) for VAD, not Apple's speech stack, and `AVAudioEngine` does not trigger that TCC prompt on macOS 15+ with our entitlements. The key is **not** in `Info.plist`. If a future change re-introduces the need, restore the file and the `Info.plist` key together.

## Invariants

1. **`allGranted` / `recordingReady` = mic AND accessibility.** Screen Recording is NOT part of this — skipping it doesn't prevent recording, just turns off the OCR limb.
2. **Polling tick refreshes Screen Recording alongside mic + ax.** `needsPolling` keeps polling alive while Screen Recording is unresolved even if mic + ax are granted — user can grant later from System Settings without restart.
3. **Polling every 1 s while any permission is not `granted`.** Stops once `allGranted` is true.
4. **Refresh on `NSApplication.didBecomeActiveNotification` AND `NSWorkspace.didActivateApplicationNotification`** — the second is needed because LSUIElement apps don't always get the AppKit one when returning from System Settings.
5. **`AppState` observes `permissions.accessibility` and `.microphone` via `withObservationTracking`**, not Combine. The view-model is `@Observable` and no longer exposes `$published` Combine publishers.

## Hard rules

- **Don't add a new permission without adding it to `PermissionsViewModel`** (request method + open-settings method) AND deciding whether it gates `allGranted` / `recordingReady`. Screen Recording is the only one that doesn't.
- **`AXTrustedCheckOptionPrompt` literal is inlined**, not read from the C global — Swift 6 flags the global as non-concurrency-safe. The literal is stable across macOS releases.
- **`Accessibility.request()` is sync, not async.** Accessibility has no async-style request API; calling it just shows the system prompt once per launch — the user has to flip the switch in Settings, so we poll to detect the change.
- **Open-Settings deep links use `x-apple.systempreferences:com.apple.preference.security?Privacy_<Pane>`.** Don't substitute `applewebdata://` or any other scheme — the documented URL form is what survives macOS updates.

## Status enum

```swift
enum PermissionStatus: Equatable, Sendable {
    case unknown        // not yet checked
    case notDetermined  // user hasn't been asked
    case denied         // user denied; needs Settings.app round-trip
    case granted
    var isGranted: Bool { self == .granted }
}
```

Each individual permission file exposes:

- `static func current() -> PermissionStatus`
- `static func request() async -> PermissionStatus` (microphone, screen recording) / `static func request()` (accessibility — sync)
- `static func openSystemSettings()` — deep link to the relevant pane

## Testing

- Permission APIs are system-level — not unit-testable directly. Plannable: TCC status → `PermissionStatus` mapping helpers, `PermissionsViewModel.allGranted` against synthetic state.
- Manual smoke test on a fresh user account before each release.

## Pointers

- High-level rationale + `Info.plist` keys + onboarding flow → `docs/permissions.md`.
- OCR fallback that consumes Screen Recording → `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` + `NoType/Context/CLAUDE.md`.
- Tap installation / uninstallation on accessibility transition → `NoType/Hotkey/CLAUDE.md`.
