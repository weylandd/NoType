import Foundation

/// User-tunable knobs for the paste pipeline. Stored in `UserDefaults`
/// so they persist across launches without inflating the secret-bearing
/// Keychain item or the history JSON.
///
/// Read directly by `TextInjector.paste(_:)` at call time — settings
/// changes take effect on the very next paste, without any restart or
/// observation plumbing. The Settings sheet writes via the static
/// setter; the slider is a `@State`-backed control that mirrors the
/// stored value.
enum PasteSettings {
    /// Lower / upper bounds advertised to the UI. Inside this range
    /// values are honoured as-is; outside, `restoreDelayMs` clamps.
    static let restoreDelayRange: ClosedRange<Int> = 50...500
    /// Default restore delay when the user hasn't picked a value.
    /// Empirically a safe number — works for AppKit, Slack, Discord,
    /// Terminal. Heavy Electron apps may want higher. See
    /// `NoType/Injection/CLAUDE.md`.
    static let defaultRestoreDelayMs: Int = 150

    private static let restoreDelayKey = "notype.pasteRestoreDelayMs"

    /// Current value, clamped into `restoreDelayRange`. Reading a missing
    /// or out-of-range value returns the default.
    static var restoreDelayMs: Int {
        get {
            let raw = UserDefaults.standard.object(forKey: restoreDelayKey) as? Int
            guard let raw else { return defaultRestoreDelayMs }
            return min(max(raw, restoreDelayRange.lowerBound), restoreDelayRange.upperBound)
        }
        set {
            let clamped = min(max(newValue, restoreDelayRange.lowerBound), restoreDelayRange.upperBound)
            UserDefaults.standard.set(clamped, forKey: restoreDelayKey)
        }
    }
}
