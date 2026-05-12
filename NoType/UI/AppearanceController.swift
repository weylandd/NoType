import AppKit
import Observation
import SwiftUI

/// User-selectable theme. `.system` follows the macOS Appearance setting;
/// `.light`/`.dark` force one regardless of system preference.
enum AppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "Adaptive"     // matches the user's brief — adaptive is default
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    /// `nil` means "let the system choose"; otherwise the explicit
    /// `NSAppearance` we pin onto `NSApp.appearance`.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
    }
}

/// Owns the user's theme preference (persisted in `UserDefaults`) and
/// applies it to `NSApp.appearance`. Setting `mode` writes to defaults
/// and re-applies in one step.
///
/// `DS.Color` tokens are dynamic colors driven by `NSAppearance`, so
/// flipping `NSApp.appearance` cascades through the entire UI without
/// any additional plumbing.
@MainActor
@Observable
final class AppearanceController {
    static let userDefaultsKey = "notype.appearanceMode"

    var mode: AppearanceMode {
        didSet { persistAndApply() }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.userDefaultsKey)
        self.mode = AppearanceMode(rawValue: raw ?? "") ?? .system
        apply()
    }

    private func persistAndApply() {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.userDefaultsKey)
        apply()
    }

    private func apply() {
        // `NSApp` is an implicitly-unwrapped global (`NSApplication!`).
        // In the regular launch path it's always non-nil by the time
        // SwiftUI scenes build, but xctest-host launches the app binary
        // differently and can reach `AppearanceController.init` before
        // `NSApplication.shared` has been registered as `NSApp`. Guard
        // explicitly so unit tests don't crash on import. Skipping the
        // apply in that window is harmless — when the real app run
        // resumes it picks up the appearance again on the next mode
        // mutation, and unit tests never need the side effect at all.
        guard let app: NSApplication = NSApp else { return }
        app.appearance = mode.nsAppearance
    }
}
