import XCTest
@testable import NoType

/// Pins the RAII lifecycle of `SleepAssertion`:
/// 1. `init()` acquires a non-zero IOPMAssertion handle.
/// 2. `release()` clears the handle and is idempotent (safe to call twice).
/// 3. `deinit` calls `release()` as a safety net — verified by allocating
///    in a scope and letting ARC drop the instance.
///
/// These tests rely on `SleepAssertion` exposing a couple of test-only
/// hooks (`assertionID`, `isReleased`) so we can introspect the underlying
/// IOKit handle without poking through Mirror.
///
/// Marked `@MainActor` because `SleepAssertion` itself is `@MainActor`
/// (production callers all run on the main actor). Test methods stay
/// synchronous — main-actor isolation propagates from the class.
@MainActor
final class SleepAssertionTests: XCTestCase {

    func test_init_acquiresNonZeroHandle() throws {
        let assertion = try SleepAssertion(reason: "NoType test recording")
        defer { assertion.release() }

        XCTAssertNotEqual(
            assertion.assertionID,
            UInt32(kIOPMNullAssertionID),
            "init should allocate a real IOPMAssertion handle (non-null)"
        )
        XCTAssertFalse(assertion.isReleased, "freshly created assertion is not released")
    }

    func test_release_marksAssertionReleased() throws {
        let assertion = try SleepAssertion(reason: "NoType test recording")

        assertion.release()

        XCTAssertTrue(
            assertion.isReleased,
            "release() flips the isReleased flag so deinit won't double-release"
        )
    }

    func test_release_isIdempotent() throws {
        let assertion = try SleepAssertion(reason: "NoType test recording")

        assertion.release()
        assertion.release()  // must not crash or assert
        assertion.release()

        XCTAssertTrue(assertion.isReleased)
    }

    func test_deinit_releasesAssertion_whenCallerForgets() throws {
        // We can't introspect the deallocated instance directly, so we
        // smoke-test the safety net by allocating-and-dropping inside an
        // autoreleasepool. If `deinit` crashed (double-release on the
        // IOKit handle, message to a freed object) the test would
        // terminate the process. The signal here is "the autoreleasepool
        // returns and the next assertion still succeeds".
        try autoreleasepool {
            let a = try SleepAssertion(reason: "NoType deinit test")
            XCTAssertNotEqual(a.assertionID, UInt32(kIOPMNullAssertionID))
            // intentionally do NOT call release() — let ARC drop it
        }

        // If the previous instance's deinit was healthy, allocating a new
        // one (and releasing it cleanly) should still work.
        let follow = try SleepAssertion(reason: "NoType deinit followup")
        follow.release()
        XCTAssertTrue(follow.isReleased)
    }
}
