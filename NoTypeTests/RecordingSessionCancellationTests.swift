import XCTest
@testable import NoType

/// Pins the cancellation-correctness primitives on `RecordingSession`.
///
/// U2 — `shouldAbortBeforePaste(failureIsSet:taskIsCancelled:)`: the pure
/// gate `stop()` consults synchronously right before it commits
/// `TextInjector.paste`. Together with `cancel()` installing its latch as
/// its *first* statement, this closes the window where a cancel that
/// lands while `stop()` is suspended in its sender drain-loop would still
/// paste and write history.
///
/// Scope note (matches `RecordingSessionPartialRecoveryTests`): the full
/// concurrent race — cancel firing while a real `stop()` is suspended
/// mid-drain with `responses` populated, and the normal-release
/// "pastes + persists" path — needs a Gemini mock plus a real
/// `AudioRecorder` / `SileroVAD` to drive an actual `RecordingSession`.
/// The project deliberately has no such scaffolding (see that file's
/// header), so those integration scenarios are verified by the pure gate
/// below + code reading + the manual release smoke. This file pins the
/// decision logic the fix rests on.
final class RecordingSessionCancellationTests: XCTestCase {

    // MARK: - U2: paste-abort gate

    func test_abortGate_failureLatchSet_aborts() {
        // Scenario (a): `cancel()` fired while `stop()` was suspended in
        // its drain-loop; `stop()` resumes, reaches the pre-paste gate,
        // and sees the latch. → abort: no paste, no history.append.
        XCTAssertTrue(RecordingSession.shouldAbortBeforePaste(
            failureIsSet: true,
            taskIsCancelled: false
        ))
    }

    func test_abortGate_taskCancelled_aborts() {
        // Belt-and-braces: even without the `failure` latch, a cancelled
        // enclosing task aborts the paste.
        XCTAssertTrue(RecordingSession.shouldAbortBeforePaste(
            failureIsSet: false,
            taskIsCancelled: true
        ))
    }

    func test_abortGate_bothSet_aborts() {
        XCTAssertTrue(RecordingSession.shouldAbortBeforePaste(
            failureIsSet: true,
            taskIsCancelled: true
        ))
    }

    func test_abortGate_neitherSet_proceeds() {
        // Scenario (c): a normal release with no cancel — the gate lets
        // `stop()` through to paste + persist exactly as before. And
        // scenario (b): a cancel arriving *after* this decision returned
        // false is the acceptable "genuinely late" case — the paste is
        // already in flight and the late latch is a no-op.
        XCTAssertFalse(RecordingSession.shouldAbortBeforePaste(
            failureIsSet: false,
            taskIsCancelled: false
        ))
    }
}
