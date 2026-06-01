import XCTest
@testable import NoType

/// Pins the pure decision behind the Screen-capture toggle's tap
/// (`AppState.screenCaptureToggleAction`). The stored flag is the user's
/// *intent*; the displayed switch position is the *effective* state
/// (`granted && intent`). The load-bearing rule pinned here: when Screen
/// Recording permission is **not** granted, a tap NEVER silently flips the
/// stored flag — it always routes to System Settings. See the screen-capture
/// toggle plan, KTD-6.
final class ScreenCaptureToggleActionTests: XCTestCase {

    // MARK: - Permission granted → normal toggle

    func test_granted_requestOn_setsIntentTrue() {
        XCTAssertEqual(
            AppState.screenCaptureToggleAction(permissionGranted: true, requestedOn: true),
            .setIntent(true)
        )
    }

    func test_granted_requestOff_setsIntentFalse() {
        // Normal turn-off: permission present, user toggles to off.
        XCTAssertEqual(
            AppState.screenCaptureToggleAction(permissionGranted: true, requestedOn: false),
            .setIntent(false)
        )
    }

    // MARK: - Permission missing → redirect, never flip

    func test_ungranted_requestOn_opensSettings() {
        XCTAssertEqual(
            AppState.screenCaptureToggleAction(permissionGranted: false, requestedOn: true),
            .openSettings
        )
    }

    func test_ungranted_requestOff_opensSettings_neverSilentlyFlips() {
        // Defensive: the ungranted switch already shows off, so a real
        // "turn off" tap shouldn't occur — but the function must never
        // return a `.setIntent` when permission is missing.
        XCTAssertEqual(
            AppState.screenCaptureToggleAction(permissionGranted: false, requestedOn: false),
            .openSettings
        )
    }
}
