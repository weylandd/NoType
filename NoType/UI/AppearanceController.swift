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

    /// Reads the persisted mode only. The `NSApp.appearance` write lives in
    /// `apply()`, called from `applicationDidFinishLaunching(_:)` — no
    /// launch-path initializer may touch `NSApp` before
    /// `NSApplicationMain` has started the application. See
    /// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`
    /// and `NoTypeTests/LaunchOrderingTests.swift`.
    init() {
        let raw = UserDefaults.standard.string(forKey: Self.userDefaultsKey)
        self.mode = AppearanceMode(rawValue: raw ?? "") ?? .system
    }

    private func persistAndApply() {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.userDefaultsKey)
        apply()
    }

    /// Pushes the current mode onto `NSApp`. Called once at launch, then
    /// by `mode`'s `didSet` on every later user change. Idempotent.
    func apply() {
        // `NSApp` is an implicitly-unwrapped global (`NSApplication!`).
        // In the app it is always non-nil here — this runs from
        // `applicationDidFinishLaunching(_:)`, by which point
        // `NSApplicationMain` has registered it. The guard covers the
        // xctest host, which launches the binary differently and can
        // reach this without an `NSApp`. Skipping the write in that
        // window is harmless: unit tests never need the side effect.
        guard let app: NSApplication = NSApp else { return }
        app.appearance = mode.nsAppearance
    }
}
