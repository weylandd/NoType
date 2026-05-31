import XCTest
@testable import NoType

/// Pins `AppState.keyUIState` — the pure mapping from a
/// `SecretStore.KeyResolution` to the UI's `(key, needsReentry)` pair that
/// drives the "re-enter your key" surface. The load-bearing property is that
/// `.needsReentry` is NOT collapsed into the `.absent` (first-run) state:
/// a stranded user must see the calm re-entry note, not a blank first-run UI.
final class AppStateKeyStateTests: XCTestCase {
    func test_keyUIState_present_returnsKey_noReentry() {
        let state = AppState.keyUIState(for: .present("AIzaSy-key"))
        XCTAssertEqual(state.key, "AIzaSy-key")
        XCTAssertFalse(state.needsReentry)
    }

    func test_keyUIState_needsReentry_nilKey_flagSet() {
        let state = AppState.keyUIState(for: .needsReentry)
        XCTAssertNil(state.key)
        XCTAssertTrue(state.needsReentry)
    }

    func test_keyUIState_absent_nilKey_noReentry() {
        let state = AppState.keyUIState(for: .absent)
        XCTAssertNil(state.key)
        XCTAssertFalse(state.needsReentry)
    }
}
