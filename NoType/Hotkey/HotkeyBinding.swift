import Foundation

/// User's chosen push-to-talk hotkey.
///
/// Identified by a stable `code` string that matches the JS-style
/// `KeyboardEvent.code` vocabulary used in the design's keyboard layout
/// (`AltRight`, `KeyR`, `F5`, `Space`, etc.). That way the keyboard
/// visualization on the onboarding screen, the binding stored in
/// `UserDefaults`, and the detection inside `HotkeyMonitor` all share
/// one identifier — no second source of truth.
///
/// **Detection routing.** A modifier-key binding (Option/Control/Shift/
/// Command, including L/R split) drives `HotkeyMonitor` via the
/// `flagsChanged` event and the bit returned by `modifierBit`. A
/// non-modifier binding (letters, digits, Fn-row, Space, etc.) drives
/// via `keyDown`/`keyUp` and the virtual key code returned by
/// `virtualKeyCode`. Escape is reserved for the in-flight session
/// cancellation hotkey and is rejected by `isAllowedAsHotkey`.
struct HotkeyBinding: Codable, Equatable, Sendable {
    let code: String

    static let `default` = HotkeyBinding(code: "AltRight")
    static let userDefaultsKey = "notype.hotkey.bindingCode"

    /// Read the persisted binding. Falls back to the default if nothing
    /// is stored or the stored value isn't a known code.
    static func load() -> HotkeyBinding {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
              !raw.isEmpty,
              HotkeyBinding(code: raw).isAllowedAsHotkey
        else {
            return .default
        }
        return HotkeyBinding(code: raw)
    }

    /// Persist this binding.
    func save() {
        UserDefaults.standard.set(code, forKey: Self.userDefaultsKey)
    }

    // MARK: - Detection

    /// True for L/R Option / Control / Shift / Command / Fn / CapsLock.
    /// These trigger via `flagsChanged` because macOS surfaces their
    /// press/release as device-side bit transitions in
    /// `CGEventFlags.rawValue`, not as ordinary keyDown/keyUp events.
    var isModifier: Bool { Self.modifierBits[code] != nil }

    /// `NX_DEVICE*KEYMASK` bit in `CGEventFlags.rawValue`. Returns nil
    /// for non-modifier keys (they use `virtualKeyCode` instead).
    var modifierBit: UInt64? { Self.modifierBits[code] }

    /// HIToolbox virtual key code (`kVK_*`) for non-modifier keys.
    var virtualKeyCode: Int64? {
        Self.virtualKeyCodes[code].map(Int64.init)
    }

    /// Some keys are reserved (Escape — used for cancellation) or
    /// don't have a sensible meaning as a hotkey (Power, CapsLock has
    /// its own latching behavior). Filter them out of the remap UI.
    var isAllowedAsHotkey: Bool {
        switch code {
        case "Escape", "Power", "CapsLock", "":
            return false
        default:
            return isModifier || virtualKeyCode != nil
        }
    }

    // MARK: - Display

    var displayWord: String {
        Self.displayWords[code] ?? defaultDisplay
    }

    var displayGlyph: String {
        Self.displayGlyphs[code] ?? defaultDisplay
    }

    /// L/R side indicator for split modifiers (Left/Right Option…).
    var sideIndicator: String? {
        if code.hasSuffix("Right") { return "R" }
        if code.hasSuffix("Left")  { return "L" }
        return nil
    }

    private var defaultDisplay: String {
        // KeyR → R, Digit5 → 5, F12 stays F12.
        if code.hasPrefix("Key"),   code.count == 4  { return String(code.last!) }
        if code.hasPrefix("Digit"), code.count == 6  { return String(code.last!) }
        return code
    }

    // MARK: - Static tables

    /// JS-style code → device-side modifier mask bit in `CGEventFlags`.
    /// Values come from IOKit's `NX_DEVICE*KEYMASK` constants.
    private static let modifierBits: [String: UInt64] = [
        "AltRight":     0x40,        // NX_DEVICERALTKEYMASK
        "AltLeft":      0x20,        // NX_DEVICELALTKEYMASK
        "ControlRight": 0x2000,      // NX_DEVICERCTLKEYMASK
        "ControlLeft":  0x0001,      // NX_DEVICELCTLKEYMASK
        "ShiftRight":   0x0004,      // NX_DEVICERSHIFTKEYMASK
        "ShiftLeft":    0x0002,      // NX_DEVICELSHIFTKEYMASK
        "MetaRight":    0x0010,      // NX_DEVICERCMDKEYMASK
        "MetaLeft":     0x0008,      // NX_DEVICELCMDKEYMASK
        "Fn":           0x800000     // NX_SECONDARYFNMASK
    ]

    /// JS-style code → HIToolbox virtual key code.
    /// (`kVK_*` from `Carbon/HIToolbox/Events.h`.)
    private static let virtualKeyCodes: [String: UInt16] = [
        // Letters
        "KeyA":  0,  "KeyS": 1,  "KeyD": 2,  "KeyF": 3,  "KeyH": 4,
        "KeyG":  5,  "KeyZ": 6,  "KeyX": 7,  "KeyC": 8,  "KeyV": 9,
        "KeyB": 11,  "KeyQ":12,  "KeyW":13,  "KeyE":14,  "KeyR":15,
        "KeyY":16,  "KeyT":17,  "KeyO":31,  "KeyU":32,  "KeyI":34,
        "KeyP":35,  "KeyL":37,  "KeyJ":38,  "KeyK":40,  "KeyN":45,
        "KeyM":46,
        // Digits
        "Digit1":18, "Digit2":19, "Digit3":20, "Digit4":21, "Digit5":23,
        "Digit6":22, "Digit7":26, "Digit8":28, "Digit9":25, "Digit0":29,
        // Punctuation
        "Equal":24, "Minus":27, "BracketRight":30, "BracketLeft":33,
        "Quote":39, "Semicolon":41, "Backslash":42, "Comma":43,
        "Slash":44, "Period":47, "Backquote":50,
        // Whitespace + edit
        "Enter":36, "Tab":48, "Space":49, "Backspace":51, "Escape":53,
        // Function keys
        "F1":122, "F2":120, "F3":99, "F4":118, "F5":96, "F6":97,
        "F7":98, "F8":100, "F9":101, "F10":109, "F11":103, "F12":111,
        // Arrows
        "ArrowLeft":123, "ArrowRight":124, "ArrowDown":125, "ArrowUp":126
    ]

    private static let displayWords: [String: String] = [
        "AltRight":     "Right Option",
        "AltLeft":      "Left Option",
        "ControlRight": "Right Control",
        "ControlLeft":  "Left Control",
        "ShiftRight":   "Right Shift",
        "ShiftLeft":    "Left Shift",
        "MetaRight":    "Right Command",
        "MetaLeft":     "Left Command",
        "Fn":           "Fn",
        "CapsLock":     "Caps Lock",
        "Enter":        "Return",
        "Tab":          "Tab",
        "Backspace":    "Delete",
        "Escape":       "Escape",
        "Space":        "Space",
        "ArrowLeft":    "Left Arrow",
        "ArrowRight":   "Right Arrow",
        "ArrowUp":      "Up Arrow",
        "ArrowDown":    "Down Arrow"
    ]

    private static let displayGlyphs: [String: String] = [
        "AltRight":     "⌥",
        "AltLeft":      "⌥",
        "ControlRight": "⌃",
        "ControlLeft":  "⌃",
        "ShiftRight":   "⇧",
        "ShiftLeft":    "⇧",
        "MetaRight":    "⌘",
        "MetaLeft":     "⌘",
        "Fn":           "🌐",
        "CapsLock":     "⇪",
        "Enter":        "↩",
        "Tab":          "⇥",
        "Backspace":    "⌫",
        "Escape":       "⎋",
        "Space":        "␣",
        "ArrowLeft":    "◀",
        "ArrowRight":   "▶",
        "ArrowUp":      "▲",
        "ArrowDown":    "▼"
    ]
}
