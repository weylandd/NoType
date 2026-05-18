import XCTest
@testable import NoType

/// Pins `AppState.shouldEnableSpacebarLock(...)` — the pure predicate
/// behind the only `.defaultTap` `CGEventTap` in the project
/// (`SpacebarLockMonitor`). A regression here silently breaks Space
/// typing across the OS while a recording session is active.
///
/// The predicate returns true when Hold+Space lock should be armed.
/// Inputs:
///
///   - `isRecording` — session in `.recording` state
///   - `pressActive` — recording hotkey currently held (`pressStartedAt != nil`)
///   - `lockedRecording` — already locked; no second Space-lock needed
///   - `hotkeyCode` — recording binding's `HotkeyBinding.code`
///   - `cancelCode` — cancel binding's `HotkeyBinding.code`
///
/// The `spaceOwnedElsewhere` carve-out (either binding == Space)
/// suppresses the predicate to avoid two `.headInsertEventTap`
/// observers consuming the same Space keyDown.
final class SpacebarLockPredicateTests: XCTestCase {

    // MARK: - Happy path

    func test_armed_whenRecording_pressActive_notLocked_andNeitherBindingIsSpace() {
        XCTAssertTrue(
            AppState.shouldEnableSpacebarLock(
                isRecording: true,
                pressActive: true,
                lockedRecording: false,
                hotkeyCode: "AltRight",
                cancelCode: "Escape"
            )
        )
    }

    // MARK: - Each negative input independently disarms

    func test_disarmed_whenNotRecording() {
        XCTAssertFalse(
            AppState.shouldEnableSpacebarLock(
                isRecording: false,
                pressActive: true,
                lockedRecording: false,
                hotkeyCode: "AltRight",
                cancelCode: "Escape"
            )
        )
    }

    func test_disarmed_whenPressNotActive() {
        // Session is in `.recording` but the user has already released
        // the recording hotkey (a queued state somewhere in the
        // press-release transition). `pressStartedAt` got cleared.
        XCTAssertFalse(
            AppState.shouldEnableSpacebarLock(
                isRecording: true,
                pressActive: false,
                lockedRecording: false,
                hotkeyCode: "AltRight",
                cancelCode: "Escape"
            )
        )
    }

    func test_disarmed_whenLockedRecording() {
        // Already promoted to locked state — a second Space-lock is
        // redundant (and would conflict with the tap-toggle path
        // that finalizes a locked session on next hotkey press).
        XCTAssertFalse(
            AppState.shouldEnableSpacebarLock(
                isRecording: true,
                pressActive: true,
                lockedRecording: true,
                hotkeyCode: "AltRight",
                cancelCode: "Escape"
            )
        )
    }

    // MARK: - spaceOwnedElsewhere carve-out

    func test_disarmed_whenRecordingHotkeyIsSpace() {
        // Recording hotkey == Space means the primary tap already
        // handles Space; the secondary tap consuming Space too would
        // cause a double-handle on the same `.headInsertEventTap`.
        XCTAssertFalse(
            AppState.shouldEnableSpacebarLock(
                isRecording: true,
                pressActive: true,
                lockedRecording: false,
                hotkeyCode: "Space",
                cancelCode: "Escape"
            )
        )
    }

    func test_disarmed_whenCancelBindingIsSpace() {
        // Cancel binding == Space means Space already cancels an
        // in-flight session. Layering Hold+Space on top would race
        // — the same Space keyDown would dispatch both cancel and
        // lock through two taps at the same `.headInsertEventTap`
        // site. The cancel side wins by design; the lock silently
        // disables.
        XCTAssertFalse(
            AppState.shouldEnableSpacebarLock(
                isRecording: true,
                pressActive: true,
                lockedRecording: false,
                hotkeyCode: "AltRight",
                cancelCode: "Space"
            )
        )
    }

    func test_disarmed_whenBothBindingsAreSpace() {
        // Pathological — `applyCancelHotkeyBinding` would refuse this
        // configuration (cancel == recording check), but the predicate
        // must still disarm so a corrupted UserDefaults pair can't
        // strand the secondary tap consuming Space.
        XCTAssertFalse(
            AppState.shouldEnableSpacebarLock(
                isRecording: true,
                pressActive: true,
                lockedRecording: false,
                hotkeyCode: "Space",
                cancelCode: "Space"
            )
        )
    }

    // MARK: - Defaults / idle states

    func test_disarmed_atIdle() {
        // Default state on app launch — no session, no press, no lock,
        // standard bindings. Predicate must be false or the tap would
        // start consuming Space immediately.
        XCTAssertFalse(
            AppState.shouldEnableSpacebarLock(
                isRecording: false,
                pressActive: false,
                lockedRecording: false,
                hotkeyCode: "AltRight",
                cancelCode: "Escape"
            )
        )
    }
}
