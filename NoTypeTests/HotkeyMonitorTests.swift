import XCTest
@testable import NoType

/// Pins the pure helpers backing `HotkeyMonitor`. The `CGEventTap`
/// itself is system-level and not unit-testable (`NoType/Hotkey/CLAUDE.md`
/// "CGEventTap itself is system-level — not unit-testable"), but the
/// bit-math and keycode-resolution that drive the tap callback are
/// pure functions that pay for themselves under test.
///
/// **Why this file exists.** The hotkey detection path is the entry
/// point for every recording session — a regression in
/// `detectTransition` silently breaks the "Hold Right Option to
/// record" experience until somebody notices in production. The
/// existing `NoType/Hotkey/CLAUDE.md` "Testing" block names
/// `detectTransition(prev:curr:bit:)` as the primary testable seam,
/// but no test file existed before this one.
final class HotkeyMonitorTests: XCTestCase {

    // MARK: - detectTransition — Right Option (default bit)

    func test_detectTransition_pressed_whenRightOptionBitTurnsOn() {
        // prev had no Right Option flag → curr has it → press.
        let result = HotkeyMonitor.detectTransition(prev: 0, curr: 0x40)
        XCTAssertEqual(result, .pressed)
    }

    func test_detectTransition_released_whenRightOptionBitTurnsOff() {
        let result = HotkeyMonitor.detectTransition(prev: 0x40, curr: 0)
        XCTAssertEqual(result, .released)
    }

    func test_detectTransition_none_whenRightOptionBitStaysOff() {
        let result = HotkeyMonitor.detectTransition(prev: 0, curr: 0)
        XCTAssertEqual(result, .none)
    }

    func test_detectTransition_none_whenRightOptionBitStaysOn() {
        // Key still held — repeated flagsChanged from unrelated bits
        // shouldn't emit a duplicate press.
        let result = HotkeyMonitor.detectTransition(prev: 0x40, curr: 0x40)
        XCTAssertEqual(result, .none)
    }

    func test_detectTransition_ignoresOtherFlagBits() {
        // prev: Cmd held, no Right Option. curr: Cmd held + Right Option.
        // Default bit is Right Option → press; the Cmd bit is irrelevant.
        let cmdBit: UInt64 = 0x100008
        let result = HotkeyMonitor.detectTransition(
            prev: cmdBit,
            curr: cmdBit | 0x40
        )
        XCTAssertEqual(result, .pressed)
    }

    // MARK: - detectTransition — explicit bit parameter (e.g. Left Option)

    func test_detectTransition_customBit_leftOption_pressed() {
        // Left Option bit = 0x20 per IOKit (NX_DEVICELALTKEYMASK).
        let leftOptionBit: UInt64 = 0x20
        let result = HotkeyMonitor.detectTransition(
            prev: 0,
            curr: leftOptionBit,
            bit: leftOptionBit
        )
        XCTAssertEqual(result, .pressed)
    }

    func test_detectTransition_customBit_leftOption_released() {
        let leftOptionBit: UInt64 = 0x20
        let result = HotkeyMonitor.detectTransition(
            prev: leftOptionBit,
            curr: 0,
            bit: leftOptionBit
        )
        XCTAssertEqual(result, .released)
    }

    func test_detectTransition_customBit_ignoresOtherBits() {
        // With `bit = 0x20`, the Right Option bit (0x40) flipping
        // independently must not emit a press/release on the
        // left-option monitor.
        let leftOptionBit: UInt64 = 0x20
        XCTAssertEqual(
            HotkeyMonitor.detectTransition(
                prev: 0x40,
                curr: 0,
                bit: leftOptionBit
            ),
            .none
        )
        XCTAssertEqual(
            HotkeyMonitor.detectTransition(
                prev: 0,
                curr: 0x40,
                bit: leftOptionBit
            ),
            .none
        )
    }

    // MARK: - Single-arg overload defaults to Right Option

    func test_detectTransition_singleArgOverload_usesRightOptionBit() {
        // Backwards-compat shim — the two-argument overload defaults
        // `bit` to `rightOptionBit`. Pin so a refactor that changes
        // the default is caught.
        let withDefault = HotkeyMonitor.detectTransition(prev: 0, curr: 0x40)
        let explicit    = HotkeyMonitor.detectTransition(
            prev: 0,
            curr: 0x40,
            bit: HotkeyMonitor.rightOptionBit
        )
        XCTAssertEqual(withDefault, explicit)
        XCTAssertEqual(withDefault, .pressed)
    }

    // MARK: - Cancel keycode resolution (transitively via HotkeyBinding)

    func test_escapeKeyCode_isHardware53() {
        // Documented invariant — `HotkeyMonitor.escapeKeyCode == 53`
        // is what the cancel-keycode resolution falls back to on a
        // malformed cancel binding. Pin so a typo in the constant
        // is caught.
        XCTAssertEqual(HotkeyMonitor.escapeKeyCode, 53)
    }

    func test_cancelBindingResolution_escapeBinding_resolvesTo53() {
        // Default cancel binding ships as Escape. The init resolution
        // is `cancelBinding.virtualKeyCode ?? escapeKeyCode`, so we
        // verify Escape's `virtualKeyCode` is the actual hardware
        // code rather than relying on the fallback to mask a bug.
        let escape = HotkeyBinding(code: "Escape")
        XCTAssertEqual(escape.virtualKeyCode, 53)
    }

    func test_cancelBindingResolution_malformedBinding_fallsBackToEscape() {
        // A binding whose `code` doesn't match any known table entry
        // returns `nil` from `virtualKeyCode`. The init expression
        // `cancelBinding.virtualKeyCode ?? escapeKeyCode` then falls
        // back to 53 — defensive guard so a malformed UserDefaults
        // value can never strand the cancel path.
        let bogus = HotkeyBinding(code: "NotARealKey_______")
        XCTAssertNil(bogus.virtualKeyCode)
        // Simulate the init-site fallback `cancelBinding.virtualKeyCode
        // ?? Self.escapeKeyCode` in homogeneous Int64 space — matches
        // `HotkeyMonitor.cancelKeyCode`'s declared type and avoids the
        // Int64-init overload ambiguity that bites mixed-type literals.
        let resolved: Int64 = bogus.virtualKeyCode ?? HotkeyMonitor.escapeKeyCode
        XCTAssertEqual(resolved, HotkeyMonitor.escapeKeyCode)
    }
}
