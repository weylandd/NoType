import XCTest
@testable import NoType

/// Pins the pure-function gate that decides whether the screenshot + OCR
/// context fallback runs for a session. The gate lives on
/// `RecordingSession` as a `nonisolated static` so we can test it without
/// standing up a real session (which owns AudioRecorder / GeminiClient /
/// HistoryStore — not unit-test-friendly).
///
/// OCR runs iff ALL hold:
///   1. `fallbackEnabled` — the user's in-app "Use screen capture for
///      context" toggle (frozen at session start). Default on.
///   2. `permissionGranted` — Screen Recording TCC permission is granted.
///   3. `pid > 0` — there is a frontmost app to screenshot.
///
/// See the screen-capture toggle plan + `NoType/Context/CLAUDE.md`
/// (OCR fallback) + `NoType/Recording/CLAUDE.md` "Lifecycle".
final class RecordingSessionOCRGateTests: XCTestCase {

    // MARK: - Happy path

    func test_allConditionsTrue_runsOCR() {
        XCTAssertTrue(RecordingSession.shouldRunOCR(
            fallbackEnabled: true,
            permissionGranted: true,
            pid: 1234
        ))
    }

    // MARK: - Off-switch wins

    func test_fallbackDisabled_suppressesOCR_evenWithPermission() {
        // The whole point of the toggle: permission granted, but the user
        // turned OCR off in Settings.
        XCTAssertFalse(RecordingSession.shouldRunOCR(
            fallbackEnabled: false,
            permissionGranted: true,
            pid: 1234
        ))
    }

    // MARK: - Permission gate

    func test_permissionMissing_suppressesOCR_evenIfEnabled() {
        XCTAssertFalse(RecordingSession.shouldRunOCR(
            fallbackEnabled: true,
            permissionGranted: false,
            pid: 1234
        ))
    }

    // MARK: - No frontmost app

    func test_zeroPid_suppressesOCR() {
        // No frontmost application to screenshot.
        XCTAssertFalse(RecordingSession.shouldRunOCR(
            fallbackEnabled: true,
            permissionGranted: true,
            pid: 0
        ))
    }
}
