import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// TCC wrapper for the **Screen Recording** privacy permission.
///
/// Used by the optional screenshot + OCR fallback in `NoType/Context/ScreenCapture/`.
/// Unlike Microphone and Accessibility this permission is NOT required for
/// the app to function — `PermissionsViewModel.recordingReady` / `.allGranted`
/// deliberately exclude it. If the user skips it, the AX tree remains the
/// sole source of on-screen context (today's behaviour).
///
/// macOS TCC for Screen Recording has no native `notDetermined` state —
/// `CGPreflightScreenCaptureAccess()` returns Bool. We emulate the missing
/// state with a `UserDefaults` flag so the onboarding card can show a
/// proper "Grant" button on first run (which triggers the registration)
/// vs. "Open Settings" after the registration is on record.
enum ScreenRecordingPermission {
    private static let hasAskedKey = "notype.permissions.screenRecording.hasAsked"

    static func current() -> PermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        // First-launch state: we've never called `request()`, the TCC
        // database has no record of us. Surfacing this as `.notDetermined`
        // makes the onboarding card show a "Grant" button (which runs the
        // real registration flow); collapsing to `.denied` would show
        // "Open Settings" and the user would land on an empty list (the
        // app shows up only after a registration call).
        let hasAsked = UserDefaults.standard.bool(forKey: hasAskedKey)
        return hasAsked ? .denied : .notDetermined
    }

    /// Trigger the TCC registration flow:
    /// 1. Mark "we have asked" so subsequent `current()` calls return
    ///    `.denied` rather than `.notDetermined` (the user has now seen
    ///    the prompt at least once).
    /// 2. Call `CGRequestScreenCaptureAccess()` — on macOS 14+ this both
    ///    prompts the user AND registers the app with TCC so it shows up
    ///    in System Settings → Privacy & Security → Screen Recording.
    /// 3. Belt-and-braces: also attempt `SCShareableContent.current`. On
    ///    macOS 26 this is what actually surfaces the app in the Settings
    ///    list if step 2's prompt was suppressed (which can happen if the
    ///    user dismissed the dialog elsewhere). The call throws when
    ///    denied — we ignore the error; the side effect is what we want.
    /// 4. Re-check via `CGPreflightScreenCaptureAccess()` and return.
    static func request() async -> PermissionStatus {
        UserDefaults.standard.set(true, forKey: hasAskedKey)

        // Step 2 — synchronous, but wrapped in a detached task so we don't
        // block @MainActor while the system shows its dialog.
        let directGrant = await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value

        if directGrant {
            return .granted
        }

        // Step 3 — registration probe. Result is discarded; the side
        // effect (TCC adds us to the Settings list) is the whole point.
        _ = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        // Step 4 — re-check. The user may have moved to System Settings
        // and flipped the switch during the async hop above; in practice
        // they usually haven't, so this returns `.denied` and the UI
        // should follow up by opening the Settings pane.
        return CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
