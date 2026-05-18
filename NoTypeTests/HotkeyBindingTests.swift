import XCTest
@testable import NoType

/// Pins the predicate surface on `HotkeyBinding`:
///   - `isModifier` / `isModifierClass` (alias) — which keys route via
///     `flagsChanged` vs `keyDown`/`keyUp`.
///   - `isAllowedAsHotkey` — what the **recording** shortcut rebind UI
///     accepts.
///   - `isAllowedAsCancelBinding` — what the **cancel** shortcut rebind
///     UI accepts. Wider than recording (Escape is allowed) but narrower
///     in the modifier dimension (no modifier-only cancels).
final class HotkeyBindingTests: XCTestCase {

    // MARK: - Modifier classification

    func test_isModifier_trueForLeftAndRightOption() {
        XCTAssertTrue(HotkeyBinding(code: "AltLeft").isModifier)
        XCTAssertTrue(HotkeyBinding(code: "AltRight").isModifier)
    }

    func test_isModifier_trueForLeftAndRightCommand() {
        XCTAssertTrue(HotkeyBinding(code: "MetaLeft").isModifier)
        XCTAssertTrue(HotkeyBinding(code: "MetaRight").isModifier)
    }

    func test_isModifier_trueForFn() {
        XCTAssertTrue(HotkeyBinding(code: "Fn").isModifier)
    }

    func test_isModifier_falseForLetters() {
        for code in ["KeyA", "KeyS", "KeyR", "KeyZ"] {
            XCTAssertFalse(
                HotkeyBinding(code: code).isModifier,
                "Letter \(code) must not classify as modifier."
            )
        }
    }

    func test_isModifier_falseForFunctionRow() {
        for code in ["F1", "F5", "F12"] {
            XCTAssertFalse(HotkeyBinding(code: code).isModifier, "F-row \(code) is not a modifier.")
        }
    }

    func test_isModifier_falseForSpaceAndEnter() {
        XCTAssertFalse(HotkeyBinding(code: "Space").isModifier)
        XCTAssertFalse(HotkeyBinding(code: "Enter").isModifier)
    }

    func test_isModifierClass_isAliasForIsModifier() {
        // The alias exists for documentation at the call site
        // (`RecordingMode.effective`, Hold+Space picker gate). Pin
        // that the two predicates return the same value for every
        // key in the lookup tables so they can't drift.
        let representatives = [
            "AltRight", "AltLeft", "MetaRight", "Fn",
            "KeyA", "KeyS", "F5", "Space", "Enter", "ArrowLeft",
            "CapsLock", "Power", "Escape", ""
        ]
        for code in representatives {
            let b = HotkeyBinding(code: code)
            XCTAssertEqual(
                b.isModifier,
                b.isModifierClass,
                "isModifierClass must mirror isModifier for \(code)."
            )
        }
    }

    // MARK: - isAllowedAsHotkey (recording binding)

    func test_isAllowedAsHotkey_acceptsModifiersAndStandardKeys() {
        XCTAssertTrue(HotkeyBinding(code: "AltRight").isAllowedAsHotkey)
        XCTAssertTrue(HotkeyBinding(code: "KeyR").isAllowedAsHotkey)
        XCTAssertTrue(HotkeyBinding(code: "F5").isAllowedAsHotkey)
        XCTAssertTrue(HotkeyBinding(code: "Space").isAllowedAsHotkey)
    }

    func test_isAllowedAsHotkey_rejectsReservedKeys() {
        XCTAssertFalse(HotkeyBinding(code: "Escape").isAllowedAsHotkey)
        XCTAssertFalse(HotkeyBinding(code: "Power").isAllowedAsHotkey)
        XCTAssertFalse(HotkeyBinding(code: "CapsLock").isAllowedAsHotkey)
        XCTAssertFalse(HotkeyBinding(code: "").isAllowedAsHotkey)
    }

    // MARK: - isAllowedAsCancelBinding (cancel binding)

    func test_isAllowedAsCancelBinding_acceptsEscape() {
        // Escape is the default cancel — must always be permitted.
        XCTAssertTrue(HotkeyBinding(code: "Escape").isAllowedAsCancelBinding)
    }

    func test_isAllowedAsCancelBinding_acceptsNonModifierKeys() {
        for code in ["KeyR", "KeyA", "F5", "F12", "Space", "Enter"] {
            XCTAssertTrue(
                HotkeyBinding(code: code).isAllowedAsCancelBinding,
                "Non-modifier \(code) must be allowed as a cancel binding."
            )
        }
    }

    func test_isAllowedAsCancelBinding_rejectsAllModifiers() {
        // Modifier-only cancels would fire on incidental modifier
        // presses during typing — too noisy. Restricted to keys that
        // dispatch through keyDown / keyUp.
        for code in ["AltRight", "AltLeft", "MetaLeft", "MetaRight", "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight", "Fn"] {
            XCTAssertFalse(
                HotkeyBinding(code: code).isAllowedAsCancelBinding,
                "Modifier \(code) must NOT be allowed as a cancel binding."
            )
        }
    }

    func test_isAllowedAsCancelBinding_rejectsReservedNonKeys() {
        XCTAssertFalse(HotkeyBinding(code: "Power").isAllowedAsCancelBinding)
        XCTAssertFalse(HotkeyBinding(code: "CapsLock").isAllowedAsCancelBinding)
        XCTAssertFalse(HotkeyBinding(code: "").isAllowedAsCancelBinding)
    }

    func test_isAllowedAsCancelBinding_rejectsUnknownCodes() {
        // Codes outside the static `virtualKeyCodes` table have no
        // way to route through keyDown — they're effectively dead
        // bindings and must be refused.
        XCTAssertFalse(HotkeyBinding(code: "MadeUpKey").isAllowedAsCancelBinding)
    }

    // MARK: - Symmetry / asymmetry between the two allowlists

    func test_escape_isAllowedAsCancelBut_notAsHotkey() {
        // The whole point of the cancel allowlist existing: Escape
        // must be a valid cancel binding but never a recording one.
        let escape = HotkeyBinding(code: "Escape")
        XCTAssertTrue(escape.isAllowedAsCancelBinding)
        XCTAssertFalse(escape.isAllowedAsHotkey)
    }
}
