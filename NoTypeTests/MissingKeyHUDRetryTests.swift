import XCTest
@testable import NoType

/// Pins the regression that PR fix/missing-key-hud-open-settings-button
/// closed: the "Open Settings" button on the missing-API-key ErrorHUD
/// previously rendered a label but had a `nil` retry handler — clicking
/// it did nothing. The catalog in `AppState.swift` is the single source
/// of truth for "what does each user-facing error mode do"; these tests
/// pin the shape of that catalog so the dead-button class of bug can't
/// recur.
///
/// Higher-level integration (HUD button is actually clickable; window
/// is actually raised; Settings tab actually deep-links to API & Usage)
/// is verified manually before each release — covered by the smoke
/// note in `NoType/UI/CLAUDE.md`. These tests pin the lower-level
/// catalog contract that the integration depends on.
///
/// `@MainActor` is load-bearing: `NoTypeErrorKind.retryHandler` returns
/// `(@MainActor (AppState?) -> Void)?`, so invoking the closure
/// requires the calling context to be on the main actor. Without this
/// annotation the tests would fail to compile (and previously, when
/// the type was non-isolated and the body used
/// `MainActor.assumeIsolated`, an XCTest runner that scheduled the
/// test body off-main could have trapped at runtime).
@MainActor
final class MissingKeyHUDRetryTests: XCTestCase {

    // MARK: - Payload shape for .missingAPIKey

    func test_missingAPIKey_payload_advertisesOpenSettings_asAccent() {
        let payload = NoTypeErrorKind.missingAPIKey.payload
        XCTAssertEqual(payload.retryLabel, "Open Settings")
        XCTAssertEqual(payload.retryKind, .accent,
                       "Open Settings is the primary affordance, must render as accent button.")
        XCTAssertEqual(payload.severity, .warning,
                       "Missing key is a recoverable misconfiguration, not a danger state.")
        XCTAssertEqual(payload.code, "ERR_NO_KEY")
    }

    // MARK: - Retry handler is wired

    func test_missingAPIKey_retryHandler_isNonNil() {
        // Direct regression guard. Before the fix, this returned `nil`
        // and the rendered button no-op'd on click. ErrorHUD renders
        // the button iff `payload.retryLabel != nil`; HUDController
        // wraps `onRetry.map { ... }`. If the catalog ever ships
        // `retryLabel` without a matching handler again, this test
        // fires and the regression is caught at CI rather than by a
        // user.
        XCTAssertNotNil(
            NoTypeErrorKind.missingAPIKey.retryHandler,
            "missingAPIKey advertises 'Open Settings' — retryHandler must be wired."
        )
    }

    func test_missingAPIKey_retryHandler_nilAppState_isSafeNoOp() {
        // Defensive guard inside the closure: the wrapper in
        // AppState.surfaceError captures `[weak self]`, so a late-fire
        // click after AppState was already torn down passes `nil`. The
        // handler must early-return, not crash.
        let handler = try? XCTUnwrap(NoTypeErrorKind.missingAPIKey.retryHandler)
        handler?(nil)
        // Reaching here without trap is the assertion.
    }

    // MARK: - Other catalog entries have no spurious retry handler

    func test_otherKinds_haveNoRetryHandler_today() {
        // Pins the current catalog shape: only .missingAPIKey ships a
        // retry handler. If a future change wires another handler, this
        // test fires and the author has to update both the catalog and
        // this assertion — forcing them to think about whether the
        // payload's `retryLabel` is present (i.e. is the button
        // rendered at all). Catches the symmetric regression: a
        // retryHandler with no retryLabel is harmless but dead code.
        XCTAssertNil(NoTypeErrorKind.vadLoadFailed.retryHandler)
        XCTAssertNil(NoTypeErrorKind.sessionStartFailed(StubError()).retryHandler)
        // Both retention outcomes: the HUD deliberately ships no retry
        // button even when the recording *is* retryable — the history
        // row owns that affordance (plan R7 / R10), and a second retry
        // entry point on a HUD that auto-dismisses after 8 s would be
        // the dead-button regression this file exists for.
        XCTAssertNil(NoTypeErrorKind.sessionFailure(StubError(), retainedForRetry: false).retryHandler)
        XCTAssertNil(NoTypeErrorKind.sessionFailure(StubError(), retainedForRetry: true).retryHandler)
    }

    // MARK: - retryLabel-without-retryHandler smoke check

    func test_kindsWithRetryLabel_alsoHaveRetryHandler() {
        // The dead-button regression is exactly the pattern
        // "retryLabel != nil && retryHandler == nil". This loop pins
        // the rule across every variant we can construct without
        // exotic fixtures. Adds a guard for future catalog entries —
        // anyone wiring a label must also wire a handler or this
        // test fires.
        //
        // **Inventory of `NoTypeErrorKind` cases (keep in sync):**
        //   1. `.missingAPIKey`          — in `kinds` below.
        //   2. `.vadLoadFailed`          — in `kinds` below.
        //   3. `.sessionStartFailed(_)`  — in `kinds` below (stub error).
        //   4. `.sessionFailure(_, retainedForRetry:)` — in `kinds`
        //      below, **both** retention outcomes (stub error). The flag
        //      only changes the description's consequence clause, but
        //      listing both is what keeps this guard honest if a future
        //      change ever gives the retained variant its own button.
        //   5. `.partialTranscription(_)` — SKIPPED. Constructing it
        //      requires a real `RecordingSession.SessionSummary`
        //      fixture; its payload deliberately has no `retryLabel`,
        //      so the regression class this test protects against
        //      cannot apply to it.
        //
        // If you add a sixth case, add it here and update the
        // inventory comment. `NoTypeErrorKind` does not (and cannot
        // easily) conform to `CaseIterable` because three cases carry
        // associated values, so this manual list is the contract.
        let kinds: [NoTypeErrorKind] = [
            .missingAPIKey,
            .vadLoadFailed,
            .sessionStartFailed(StubError()),
            .sessionFailure(StubError(), retainedForRetry: false),
            .sessionFailure(StubError(), retainedForRetry: true),
        ]
        for kind in kinds {
            if kind.payload.retryLabel != nil {
                XCTAssertNotNil(
                    kind.retryHandler,
                    "Catalog entry advertises retryLabel '\(kind.payload.retryLabel ?? "?")' but has no retryHandler — button would be dead."
                )
            }
        }
    }
}

private struct StubError: Error {}
