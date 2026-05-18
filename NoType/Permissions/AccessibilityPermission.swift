import AppKit
import ApplicationServices
import Foundation

/// TCC wrapper for the **Accessibility** privacy permission.
///
/// macOS TCC for Accessibility has no native `notDetermined` state —
/// `AXIsProcessTrustedWithOptions` returns `Bool`, so a fresh install is
/// indistinguishable from an explicit denial. We emulate the missing
/// state with a `UserDefaults` flag (same shape as
/// `ScreenRecordingPermission`) so the onboarding card can show a proper
/// yellow "REQUIRED" + Grant button on first run, rather than scaring
/// the user with a red "DENIED" pill before they've refused anything.
///
/// Existing users whose onboarding already completed under an older
/// build never set the flag. The lazy migration inside `current()` reads
/// `notype.onboarding.complete` and backfills `hasAsked = true` on first
/// call, preserving the correct "DENIED + Open Settings" surface for
/// users who actually refused.
enum AccessibilityPermission {
    /// Internal (no access modifier) so `OnboardingState.resetWizardDefaults`
    /// and unit tests can reference the canonical key string —
    /// `@testable import` elevates internal symbols to the test target but
    /// does NOT elevate `private`, which is why the visibility intentionally
    /// differs from a fully-encapsulated module-private constant. Matches
    /// `ScreenRecordingPermission.hasAskedKey`.
    static let hasAskedKey = "notype.permissions.accessibility.hasAsked"

    static func current(defaults: UserDefaults = .standard) -> PermissionStatus {
        // Prefer the WithOptions variant — historically more reliable at
        // returning fresh state than the bare `AXIsProcessTrusted()` call.
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": kCFBooleanFalse as Any] as CFDictionary
        let isGranted = AXIsProcessTrustedWithOptions(opts)
        if isGranted { return .granted }

        migrateHasAskedIfNeeded(defaults: defaults)
        let hasAsked = defaults.bool(forKey: hasAskedKey)
        return mapStatus(isAxGranted: false, hasAsked: hasAsked)
    }

    /// Shows the system Accessibility prompt (once per launch). The user must
    /// flip the switch in System Settings before `current()` returns `.granted`,
    /// so callers should poll afterwards.
    ///
    /// The `hasAsked` flag is set **before** the syscall: macOS may suppress
    /// the prompt if a prior decision is already on record, but the user has
    /// now seen our Grant UI, so subsequent `current()` calls must treat the
    /// state as `.denied` (not `.notDetermined`) until they grant.
    static func request(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: hasAskedKey)

        // The C global `kAXTrustedCheckOptionPrompt` is a CFStringRef and Swift 6
        // flags it as non-concurrency-safe. The value is documented and stable
        // across macOS releases, so we inline the literal.
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue as Any] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openSystemSettings() {
        SystemSettingsPane.accessibility.open()
    }

    // MARK: - Internals (exposed for tests)

    /// Pure mapping of (AX state, asked-yet) → `PermissionStatus`. Granted
    /// always wins; otherwise the `hasAsked` flag distinguishes first-run
    /// (`.notDetermined`) from explicit refusal (`.denied`).
    static func mapStatus(isAxGranted: Bool, hasAsked: Bool) -> PermissionStatus {
        if isAxGranted { return .granted }
        return hasAsked ? .denied : .notDetermined
    }

    /// One-shot lazy migration: users who already completed onboarding under
    /// an older build never set the `hasAsked` flag. Backfilling it here
    /// preserves their correct "DENIED + Open Settings" CTA — without this
    /// they'd see yellow "REQUIRED" + a Grant button that silently no-ops
    /// because macOS only prompts once per launch lifetime.
    static func migrateHasAskedIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: hasAskedKey) else { return }
        guard defaults.bool(forKey: OnboardingState.completeKey) else { return }
        defaults.set(true, forKey: hasAskedKey)
    }
}
