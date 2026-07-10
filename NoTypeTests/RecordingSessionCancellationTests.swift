import XCTest
@testable import NoType

/// Pins the cancellation-correctness primitives on `RecordingSession`
/// (R2, R3):
///
///   * U2 — `shouldAbortBeforePaste(failureIsSet:taskIsCancelled:)`: the
///     pure gate `stop()` consults synchronously right before it commits
///     `TextInjector.paste`. Together with `cancel()` installing its
///     latch as its *first* statement, this closes the window where a
///     cancel that lands while `stop()` is suspended in its sender
///     drain-loop would still paste and write history.
///
///   * U3 — the VAD drain loop's top-of-body `Task.isCancelled` break:
///     a cancelled session must stop feeding the app-shared `SileroVAD`
///     actor so the next session's `vad.reset()` can't interleave.
///
/// Scope note (matches `RecordingSessionPartialRecoveryTests`): the
/// full concurrent race — cancel firing while a real `stop()` is
/// suspended mid-drain with `responses` populated, and the
/// normal-release "pastes + persists" path — needs a Gemini mock plus a
/// real `AudioRecorder` / `SileroVAD` to drive an actual
/// `RecordingSession`. The project deliberately has no such scaffolding
/// (see that file's header), so those integration scenarios are verified
/// by the pure gate below + code reading + the manual release smoke.
/// This file pins the decision logic the fix rests on.
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

    // MARK: - U3: VAD drain loop breaks on cancellation

    /// Characterizes the exact idiom `spawnVADConsumer` uses: a detached
    /// consumer of an `AsyncStream<[Float]>` that checks `Task.isCancelled`
    /// at the top of each iteration and breaks. Proves that once the task
    /// is cancelled, no further frames are submitted (in production, no
    /// further `vad.probability(...)` calls reach the shared Silero actor).
    ///
    /// We can't drive the private `spawnVADConsumer` directly — it needs a
    /// real `AudioRecorder` + `SileroVAD` (the codebase's no-full-session
    /// unit-test stance) — so this pins the concurrency contract the fix
    /// relies on.
    func test_vadDrainLoop_stopsSubmittingAfterCancellation() async {
        let submissions = SubmissionSpy()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let processedFirst = expectation(description: "first frame processed")

        let task = Task.detached {
            var firstSignalled = false
            for await frame in stream {
                // Mirror of the production guard added in U3.
                if Task.isCancelled { break }
                await submissions.record(frame)
                if !firstSignalled {
                    firstSignalled = true
                    processedFirst.fulfill()
                }
            }
        }

        // Deliver one frame and wait until it's processed, so the cancel
        // below is guaranteed to land while the consumer is parked in
        // `for await` waiting for the *next* frame.
        continuation.yield([1])
        await fulfillment(of: [processedFirst], timeout: 2)
        let countBeforeCancel = await submissions.count
        XCTAssertEqual(countBeforeCancel, 1)

        // Cancel, then flood post-cancel frames. The top-of-body check
        // must break before any of them are recorded.
        task.cancel()
        for _ in 0..<50 { continuation.yield([9]) }
        continuation.finish()
        await task.value

        let finalCount = await submissions.count
        XCTAssertEqual(
            finalCount, 1,
            "no frames should be submitted to the shared VAD actor after cancellation"
        )
    }

    /// Records how many frames a consumer "submitted" — stands in for the
    /// app-shared `SileroVAD` actor's `probability(_:)` call count.
    private actor SubmissionSpy {
        private(set) var count = 0
        func record(_ frame: [Float]) { count += 1 }
    }
}
