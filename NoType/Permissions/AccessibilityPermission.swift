import AppKit
import ApplicationServices
import Foundation

enum AccessibilityPermission {
    static func current() -> PermissionStatus {
        // Prefer the WithOptions variant — historically more reliable at
        // returning fresh state than the bare `AXIsProcessTrusted()` call.
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": kCFBooleanFalse as Any] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts) ? .granted : .denied
    }

    /// Shows the system Accessibility prompt (once per launch). The user must
    /// flip the switch in System Settings before `current()` returns `.granted`,
    /// so callers should poll afterwards.
    static func request() {
        // The C global `kAXTrustedCheckOptionPrompt` is a CFStringRef and Swift 6
        // flags it as non-concurrency-safe. The value is documented and stable
        // across macOS releases, so we inline the literal.
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue as Any] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openSystemSettings() {
        SystemSettingsPane.accessibility.open()
    }
}
