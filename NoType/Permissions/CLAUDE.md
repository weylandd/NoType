# Permissions module

Wraps the OS permission request APIs and exposes a single `ObservableObject` view-model for the UI.

For high-level rationale and the list of permissions, see `docs/permissions.md`. This file is the implementation guide.

Files:
- `PermissionStatus.swift` — the shared enum.
- `MicrophonePermission.swift`
- `AccessibilityPermission.swift`
- `ScreenRecordingPermission.swift` — **optional**, gates the screenshot + OCR fallback in `NoType/Context/ScreenCapture/` (ADR-014).
- `PermissionsViewModel.swift` — the aggregate observable.

There is **no** `SpeechRecognitionPermission.swift` — NoType uses Silero (CoreML) for VAD, not Apple's speech stack, and `AVAudioEngine` does not trigger that TCC prompt on the supported macOS versions (15+) with our entitlements. The key is not in `Info.plist`. If a future change re-introduces the need, restore the file and the `Info.plist` key together.

Screen Recording is the only permission that is **not** part of `allGranted` / `recordingReady`. Skipping it doesn't prevent recording — it just turns off the OCR limb of the context snapshot. The polling tick (`tick()`) refreshes it alongside the other two; the `needsPolling` predicate keeps polling alive while screenRecording is unresolved even if mic + ax are granted, so the user can grant it later from System Settings and have it picked up without restart.

---

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
- `static func request() async -> PermissionStatus` (microphone) / `static func request()` (accessibility — it's not async-style)
- `static func openSystemSettings()` — deep link to the relevant pane

---

## Microphone

```swift
import AVFoundation

enum MicrophonePermission {
    static func current() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:           return .granted
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .notDetermined
        @unknown default:           return .unknown
        }
    }

    static func request() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
```

---

## Accessibility

There is no async-style request API. Calling `AXIsProcessTrustedWithOptions` with `AXTrustedCheckOptionPrompt = true` shows the system prompt (once per launch); the user has to flip the switch in Settings afterwards. We poll `AXIsProcessTrusted()` to detect the change (see `PermissionsViewModel`).

```swift
enum AccessibilityPermission {
    static func current() -> PermissionStatus {
        // The literal "AXTrustedCheckOptionPrompt" is stable across macOS releases —
        // we inline it because the C global is flagged as non-concurrency-safe by Swift 6.
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": kCFBooleanFalse as Any] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts) ? .granted : .denied
    }

    static func request() {
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue as Any] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
```

---

## PermissionsViewModel

```swift
@MainActor
@Observable
final class PermissionsViewModel {
    private(set) var microphone:      PermissionStatus = .unknown
    private(set) var accessibility:   PermissionStatus = .unknown
    private(set) var screenRecording: PermissionStatus = .unknown  // optional

    var allGranted: Bool { microphone.isGranted && accessibility.isGranted }
    /// Alias used by recording-path callers.
    var recordingReady: Bool { allGranted }

    func refresh()
    func requestMicrophone() async
    func requestAccessibility()
    func requestScreenRecording() async
    func openMicrophoneSettings()
    func openAccessibilitySettings()
    func openScreenRecordingSettings()
}
```

Internal behaviour:
- Refreshes on `NSApplication.didBecomeActiveNotification` and `NSWorkspace.didActivateApplicationNotification` (the second is needed because LSUIElement apps don't always get the AppKit one when returning from System Settings).
- Polls every 1 second while any permission is not `granted`. Stops polling once `allGranted` is true.

`AppState` observes `permissions.accessibility` and `.microphone` via a `withObservationTracking` loop (`observePermissions`) rather than Combine, since the view-model is `@Observable` and no longer exposes `$published` Combine publishers.

---

## Testing

- Permission APIs cannot be unit-tested directly (system-level). What we can test:
  - The TCC status → `PermissionStatus` mapping helper.
  - `PermissionsViewModel.allGranted` logic against synthetic state.
- Neither of these tests exists yet under `NoTypeTests/`; tracked alongside the broader test-debt backlog.
- Manual smoke test on a fresh user account before each release.
