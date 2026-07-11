import XCTest
@testable import NoType

/// Pins `AppState.shouldDeferForScreenRecordingPrompt(fallbackEnabled:screenRecordingNotDetermined:)`
/// — the pure gate that decides whether a first hotkey press (with Screen
/// Recording still `.notDetermined`) defers the session to surface the TCC
/// prompt, or falls straight through into recording.
///
/// Product decision OQ2 (R22): keep the prompt when the OCR fallback is ON;
/// suppress it when the user has turned OCR OFF, so a user who doesn't use
/// screen-capture context is never interrupted for a permission the OCR limb
/// will never touch.
///
/// The full integration (a real first press driving `handleHotkeyPress` →
/// `permissions.requestScreenRecording()`) is not unit-tested: `AppState` is a
/// heavy `@MainActor @Observable` aggregate the suite never instantiates (see
/// `AppStateAxRevokeTests` / `AppStateKeyStateTests` for the same stance).
/// That path is covered by the manual first-press smoke.
final class AppStateScreenRecordingGateTests: XCTestCase {

    // MARK: - OCR on → keep the prompt (unchanged behaviour)

    func test_ocrOn_notDetermined_defers() {
        // The canonical first-press case: OCR enabled, TCC has never seen us
        // → defer and surface the prompt.
        XCTAssertTrue(AppState.shouldDeferForScreenRecordingPrompt(
            fallbackEnabled: true,
            screenRecordingNotDetermined: true
        ))
    }

    // MARK: - OCR off → skip the prompt, record immediately (R22 fix)

    func test_ocrOff_notDetermined_doesNotDefer() {
        // The bug the unit fixes: OCR disabled means the ScreenCaptureKit
        // path never runs, so a first press must NOT be interrupted by the
        // permission prompt — fall through and record.
        XCTAssertFalse(AppState.shouldDeferForScreenRecordingPrompt(
            fallbackEnabled: false,
            screenRecordingNotDetermined: true
        ))
    }

    // MARK: - Already decided → never defer regardless of toggle

    func test_ocrOn_alreadyDecided_doesNotDefer() {
        // Permission granted or denied — the prompt has already been
        // surfaced once, so the gate lets the session start.
        XCTAssertFalse(AppState.shouldDeferForScreenRecordingPrompt(
            fallbackEnabled: true,
            screenRecordingNotDetermined: false
        ))
    }

    func test_ocrOff_alreadyDecided_doesNotDefer() {
        XCTAssertFalse(AppState.shouldDeferForScreenRecordingPrompt(
            fallbackEnabled: false,
            screenRecordingNotDetermined: false
        ))
    }
}
