import XCTest
@testable import NoType

/// Pins `AppState.shouldCancelActiveSessionOnAxRevoke(recordingState:)` —
/// the pure gate that decides, when Accessibility is revoked mid-run,
/// whether an active session must be cancelled (mic + HUD + sleep
/// assertion unwound) rather than merely having its hotkey tap torn down.
///
/// The load-bearing property is that a *live* session (`.recording` or
/// `.sending`) unwinds, while `.idle` is left alone. Without this,
/// revoking Accessibility mid-hold removes the tap — so the release /
/// Esc events can never arrive — and the mic stays hot (R4).
///
/// The full integration (a real granted→denied transition driving
/// `applyAccessibilityState` → `cancelRecording`) is not unit-tested:
/// `AppState` is a heavy `@MainActor @Observable` aggregate the suite
/// never instantiates (see `AppStateKeyStateTests` for the same stance).
/// That path is covered by the manual AX-revoke smoke (revoke
/// Accessibility mid-hold → mic light goes off, state returns to idle).
final class AppStateAxRevokeTests: XCTestCase {

    func test_recording_cancels() {
        XCTAssertTrue(AppState.shouldCancelActiveSessionOnAxRevoke(
            recordingState: .recording(startedAt: Date())
        ))
    }

    func test_sending_cancels() {
        XCTAssertTrue(AppState.shouldCancelActiveSessionOnAxRevoke(
            recordingState: .sending
        ))
    }

    func test_idle_doesNotCancel() {
        XCTAssertFalse(AppState.shouldCancelActiveSessionOnAxRevoke(
            recordingState: .idle
        ))
    }
}
