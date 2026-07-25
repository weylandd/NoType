# Permissions module

Wraps the OS permission request APIs and exposes a single `@Observable` view-model. For high-level rationale and the list of permissions, see `docs/permissions.md`. This file is the implementation guide.

## Files

- `PermissionStatus.swift` — the shared enum (`unknown`, `notDetermined`, `denied`, `granted`).
- `SystemSettingsPane.swift` — shared deep-link helper. `x-apple.systempreferences:` URL pattern + `Privacy_*` enum; each permission file delegates `openSystemSettings()` here.
- `MicrophonePermission.swift` — `AVCaptureDevice` + delegates to `SystemSettingsPane.microphone`.
- `AccessibilityPermission.swift` — `AXIsProcessTrustedWithOptions` + delegates to `SystemSettingsPane.accessibility`. Emulates the missing `.notDetermined` state via a `notype.permissions.accessibility.hasAsked` UserDefaults flag (same shape as `ScreenRecordingPermission`).
- `ScreenRecordingPermission.swift` — **optional**; gates the OCR fallback (`NoType/Context/ScreenCapture/`).
- `PermissionsViewModel.swift` — `@MainActor @Observable` aggregate.

There is **no** `SpeechRecognitionPermission.swift` — NoType uses Silero (CoreML) for VAD, not Apple's speech stack, and `AVAudioEngine` does not trigger that TCC prompt on macOS 15+ with our entitlements. The key is **not** in `Info.plist`. If a future change re-introduces the need, restore the file and the `Info.plist` key together.

## Invariants

1. **`allGranted` / `recordingReady` = mic AND accessibility.** Screen Recording is NOT part of this — skipping it doesn't prevent recording, just turns off the OCR limb.
2. **Polling tick refreshes Screen Recording alongside mic + ax.** `needsPolling` keeps polling alive while Screen Recording is unresolved even if mic + ax are granted — user can grant later from System Settings without restart.
3. **Polling every 1 s while any permission is not `granted`.** Stops once `allGranted` is true.
4. **Refresh on `NSApplication.didBecomeActiveNotification` AND `NSWorkspace.didActivateApplicationNotification`** — the second is needed because LSUIElement apps don't always get the AppKit one when returning from System Settings.
5. **`AppState` observes `permissions.accessibility` and `.microphone` via `withObservationTracking`**, not Combine. The view-model is `@Observable` and no longer exposes `$published` Combine publishers.
6. **Accessibility and Screen Recording emulate `.notDetermined` via a UserDefaults `hasAsked` flag.** Both system APIs return `Bool` only, so a fresh install is indistinguishable from an explicit denial — without the flag the onboarding row would render red "DENIED" before the user has refused anything. Each module owns its own key (`notype.permissions.accessibility.hasAsked`, `notype.permissions.screenRecording.hasAsked`); `current()` returns `.notDetermined` until the flag is set, which happens when the user clicks Grant (via `request()`). `AccessibilityPermission.current()` additionally backfills the flag on first call if `notype.onboarding.complete` is already `true`, preserving the correct "DENIED + Open Settings" surface for users who explicitly refused under an older build. **`OnboardingState.resetWizardDefaults` clears both `hasAsked` keys** so a user who re-opens the wizard via Settings → Reset Onboarding sees the neutral "REQUIRED" surface again, not the leftover red "DENIED" from their pre-reset state.
7. **`init()` is inert; `prime()` does the first read.** The initializer sets nothing and starts nothing — every status stays `.unknown` until `prime()` runs. `PermissionsViewModel` is the first object `NoTypeApp.init()` constructs, and that runs *before* `NSApplicationMain` has started the app; the old `init` → `refresh()` → `startPollingIfNeeded()` chain scheduled a `Task` there on every ungranted permission. `AppState.prime()` calls it (from `applicationDidFinishLaunching(_:)`), then applies accessibility state synchronously — see `NoType/UI/CLAUDE.md` "Launch ordering". `prime()` is idempotent via a `didPrime` latch. Note the latch guards `prime()` only — `refresh()` stays public and is still called directly by `HistoryPopover` and the onboarding permissions step, so a status can resolve before `prime()` runs. Pinned by `NoTypeTests/LaunchOrderingTests.swift` + `LaunchPrimingTests.swift`.

*(Invariant 7 was appended rather than inserted: five call-sites across the repo cite "Permissions/CLAUDE.md invariant 6" for the `hasAsked` pattern.)*

## Hard rules

- **Don't add a new permission without adding it to `PermissionsViewModel`** (request method + open-settings method) AND deciding whether it gates `allGranted` / `recordingReady`. Screen Recording is the only one that doesn't.
- **`AXTrustedCheckOptionPrompt` literal is inlined**, not read from the C global — Swift 6 flags the global as non-concurrency-safe. The literal is stable across macOS releases.
- **`Accessibility.request()` is sync, not async.** Accessibility has no async-style request API; calling it just shows the system prompt once per launch — the user has to flip the switch in Settings, so we poll to detect the change.
- **`AccessibilityPermission.request()` must set the `hasAsked` flag BEFORE calling `AXIsProcessTrustedWithOptions`.** macOS only shows the system prompt once per launch lifetime and only when no prior decision is on record — if `request()` set the flag *after* the syscall, an existing-denial state could silently regress to `.notDetermined` on the first call after upgrade (the syscall returns `false` but writes nothing to TCC, and a missing flag would surface as `.notDetermined`). Same ordering rule applies to `ScreenRecordingPermission.request()`.
- **Open-Settings deep links use `x-apple.systempreferences:com.apple.preference.security?Privacy_<Pane>`.** Don't substitute `applewebdata://` or any other scheme — the documented URL form is what survives macOS updates.

## Status enum

```swift
enum PermissionStatus: Equatable, Sendable {
    case unknown        // not yet checked
    case notDetermined  // user hasn't been asked (emulated for Accessibility + Screen Recording via the hasAsked flag — see invariant 6)
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
- `NoTypeTests/AccessibilityPermissionTests.swift` — pins the pure `mapStatus(isAxGranted:hasAsked:)` truth table and the `migrateHasAskedIfNeeded(defaults:)` backfill rule, against a suite-isolated `UserDefaults`. `request()` itself is not tested — its `prompt: true` syscall opens a system dialog on a fresh TCC database, which is disruptive on dev / CI machines. The flag-write ordering inside `request()` is enforced by the Hard rule above and verified manually.
- Manual smoke test on a fresh user account before each release.

## Pointers

- High-level rationale + `Info.plist` keys + onboarding flow → `docs/permissions.md`.
- OCR fallback that consumes Screen Recording → `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` + `NoType/Context/CLAUDE.md`.
- Tap installation / uninstallation on accessibility transition → `NoType/Hotkey/CLAUDE.md`.
