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
        // The gap notice stays button-less on purpose: the text is
        // already in the user's document and the history row owns the
        // retry. Its withheld sibling is the one that ships an action —
        // see `AppStateFocusNoticeTests`.
        XCTAssertNil(
            NoTypeErrorKind.partialTranscription(
                summary: Self.summary(failed: 1, dispatched: 3)
            ).retryHandler
        )
        // `.pasteWithheld` is the one *conditional* entry in the catalog:
        // its Copy button exists iff the history row it points at offers
        // one (the 2026-08-11 ruling). On the arm where it doesn't, the
        // kind belongs in this list beside the permanently button-less
        // ones — and the pairing with its vanished label is what the sweep
        // below owns.
        XCTAssertNil(
            NoTypeErrorKind.pasteWithheld(
                entry: Self.entry(text: RecordingSession.failureMarker, failedChunkCount: 1),
                summary: Self.summary(failed: 1, dispatched: 2, withheld: true)
            , replacements: []).retryHandler,
            "A transcript of nothing but gap markers still ships a Copy handler — the row itself offers no copy button for it."
        )
    }

    // MARK: - Fixtures

    private static func summary(
        failed: Int,
        dispatched: Int,
        withheld: Bool = false
    ) -> RecordingSession.SessionSummary {
        RecordingSession.SessionSummary(
            failedChunkCount: failed,
            dispatchedChunkCount: dispatched,
            tokens: .zero,
            model: .flashLite,
            pasteWithheldForDestinationChange: withheld,
            pasteDestinationAppName: withheld ? "Mail" : nil
        )
    }

    /// The notice's `entry` supplies the Copy string, which this file never
    /// reads — but since the 2026-08-11 ruling it also decides *whether*
    /// the Copy button exists at all, so the shape is parameterised: a row
    /// whose every position is a gap is one the history row won't copy,
    /// and the notice matches it. What the copy actually places, and the
    /// agreement with the row, are pinned in `AppStateFocusNoticeTests`.
    ///
    /// **`failedChunkCount` is what makes it a gaps-only row, not the
    /// text.** Since the sequence became the row's source of truth, a row
    /// storing the literal `[…]` with a count of zero is a row where the
    /// user *dictated* those characters (R12's fourth case) — one text
    /// segment, and genuinely worth copying.
    private static func entry(
        text: String = "the transcript",
        failedChunkCount: Int = 0
    ) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(),
            failedChunkCount: failedChunkCount
        )
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
        //   5. `.partialTranscription(_)` — in `kinds` below. It needs a
        //      `RecordingSession.SessionSummary` fixture, which is why it
        //      was originally skipped; the summary's initializer is
        //      hand-written with defaulted trailing parameters, so one
        //      costs four arguments and the skip no longer pays for
        //      itself. Its payload deliberately has no `retryLabel`.
        //   6. `.pasteWithheld(entry:summary:replacements:)` — in `kinds` below, and
        //      the first entry since `.missingAPIKey` that *does* ship a
        //      `retryLabel`. **This is why the guard exists, not an
        //      exception to it**: the regression it catches is a label
        //      with no handler, and this case's Copy button is exactly
        //      the shape that could regress into one. It is not the
        //      "second retry entry point" objection recorded above
        //      either — that argues against duplicating an affordance the
        //      history row already owns, whereas Copy is the only
        //      affordance a withheld paste offers, its handler needs no
        //      `AppState` and no window, and the row's own copy button
        //      stays the durable path once the 8 s panel is gone.
        //      **It is also the catalog's only *conditional* entry, and
        //      that is new to this sweep** (the 2026-08-11 ruling): its
        //      label and its handler both exist iff the history row the
        //      notice points at offers a copy button, which a transcript
        //      of nothing but gap markers does not. One case therefore
        //      needs two rows below — a copyable entry and a gaps-only one
        //      — because a sweep that only ever saw the copyable arm would
        //      be green on a gate that fired for the label and not for the
        //      handler. The `else` limb of the loop is what makes the
        //      second row assert anything at all.
        //
        // If you add a seventh case, add it here and update the
        // inventory comment. `NoTypeErrorKind` does not (and cannot
        // easily) conform to `CaseIterable` because four cases carry
        // associated values, so this manual list is the contract.
        //
        // **But it is no longer the only thing standing between a seventh
        // case and a dead button, and it must not be read as if it were.**
        // A hand-maintained population cannot fail for a case that was
        // never added to it: the omission is invisible to the sweep, which
        // is the discovery-set failure in
        // `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`.
        // `NoTypeErrorKind.retryHandler` is therefore an exhaustive switch
        // rather than one ending in `default: return nil` — a seventh case
        // fails to compile there, at the moment its author is deciding
        // whether it has a handler. What this sweep still owns is the
        // *pairing* for each case it lists: that a kind advertising a
        // label also ships a handler, which no switch can express.
        // Deleting a case from `kinds` therefore weakens this file without
        // any compiler complaint — keep the list complete.
        let kinds: [NoTypeErrorKind] = [
            .missingAPIKey,
            .vadLoadFailed,
            .sessionStartFailed(StubError()),
            .sessionFailure(StubError(), retainedForRetry: false),
            .sessionFailure(StubError(), retainedForRetry: true),
            .partialTranscription(summary: Self.summary(failed: 1, dispatched: 3)),
            // Both gap outcomes: the flag changes the description only,
            // but a future change that gave the gapless variant a
            // different action would otherwise sweep past unnoticed.
            .pasteWithheld(entry: Self.entry(), summary: Self.summary(failed: 0, dispatched: 3, withheld: true), replacements: []),
            .pasteWithheld(entry: Self.entry(), summary: Self.summary(failed: 2, dispatched: 4, withheld: true), replacements: []),
            // ...and both sides of the conditional gate. Every position in
            // this entry's sequence is a gap, so the row offers no copy
            // button and neither does the notice — the `else` limb below
            // is what holds it to that.
            .pasteWithheld(
                entry: Self.entry(text: RecordingSession.failureMarker, failedChunkCount: 1),
                summary: Self.summary(failed: 1, dispatched: 2, withheld: true)
            , replacements: []),
        ]
        for kind in kinds {
            if kind.payload.retryLabel != nil {
                XCTAssertNotNil(
                    kind.retryHandler,
                    "Catalog entry advertises retryLabel '\(kind.payload.retryLabel ?? "?")' but has no retryHandler — button would be dead."
                )
            } else {
                // The symmetric half, and it stopped being hypothetical
                // once a case started deciding its label at runtime: a gate
                // applied to the label but not to the handler leaves a
                // closure nothing can invoke, and the loop above is silent
                // about it. Harmless in isolation, but it is the same
                // drift that produces the dead button when the two are
                // wired the other way round.
                XCTAssertNil(
                    kind.retryHandler,
                    "Catalog entry ships a retryHandler with no retryLabel — nothing renders the button, so the handler is unreachable."
                )
            }
        }
    }
}

private struct StubError: Error {}
