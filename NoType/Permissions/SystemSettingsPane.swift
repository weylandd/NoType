import AppKit
import Foundation

/// Deep-link helper for opening a specific Privacy & Security pane in
/// System Settings.
///
/// Centralises the `x-apple.systempreferences:` URL pattern so we
/// don't hand-craft it three times across the three permission files.
/// When wiring up a new TCC permission, add a case + its `Privacy_*`
/// suffix here instead of repeating the URL.
enum SystemSettingsPane: String {
    case microphone    = "Privacy_Microphone"
    case accessibility = "Privacy_Accessibility"
    case screenCapture = "Privacy_ScreenCapture"

    private static let baseURL = "x-apple.systempreferences:com.apple.preference.security"

    /// Open the pane in System Settings. No-op if the URL won't build
    /// (would be a programming error — the constants are compile-time
    /// literals).
    func open() {
        guard let url = URL(string: "\(Self.baseURL)?\(rawValue)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
