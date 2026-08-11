import XCTest
@testable import NoType

/// Pins `RecordingSession.shouldWithholdPaste(sourcePID:currentPID:)` —
/// the pure gate `stop()` consults at the last synchronous instruction
/// before `TextInjector.paste`, so a transcript that arrived after the
/// user moved on is never typed into a document they did not mean to
/// edit (R23, R24, R26; KD8, KD9).
///
/// **This table is the whole contract.** `RecordingSession` owns an
/// `AudioRecorder`, a `SileroVAD`, a `GeminiClient` and a `HistoryStore`
/// and cannot be stood up in a unit test, so the surrounding wiring —
/// that the gate is called after the cancellation re-check, that only
/// the paste is skipped, and that the entry build and `history.append`
/// still run — is verified by code reading plus the manual smoke in the
/// plan's Verification Contract. Same scope note as
/// `RecordingSessionCancellationTests` and `RecordingSessionOCRGateTests`.
///
/// The two axes the table sweeps:
///
///   * **Mismatch withholds.** A positively-known difference between the
///     process the user dictated into and the process that would receive
///     the keystroke is the only thing that stops a paste.
///   * **Conservatism.** An unknown identifier on *either* side pastes.
///     A missing fact is never evidence of a mismatch — withholding on
///     one would silently swallow ordinary dictations whenever the
///     frontmost app could not be read.
final class RecordingSessionFocusGuardTests: XCTestCase {

    /// Stand-ins for real `pid_t` values. Nothing in the predicate reads
    /// a live process; these only need to be distinct and positive.
    private let dictatedInto: pid_t = 501
    private let somewhereElse: pid_t = 812

    // MARK: - The mismatch axis

    func test_sameProcess_pastes() {
        // AE13. The user left the application mid-transcription and came
        // back before the transcript was ready — or never left at all.
        // Same process, so this is the place they dictated into.
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            sourcePID: dictatedInto,
            currentPID: dictatedInto
        ))
    }

    func test_differentProcess_withholds() {
        // AE12. The wait was long enough for the user to switch away.
        // Pasting here would edit a document they did not intend to
        // touch — the one outcome KD8 rules out.
        XCTAssertTrue(RecordingSession.shouldWithholdPaste(
            sourcePID: dictatedInto,
            currentPID: somewhereElse
        ))
    }

    func test_noTypeItselfFrontmost_withholds() {
        // The user opened the popover mid-transcription. NoType is not
        // the process they dictated into, so this withholds like any
        // other mismatch — there is deliberately no self-carve-out.
        let noTypesOwnPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertNotEqual(noTypesOwnPID, dictatedInto, "fixture pid collided with the test host's real pid")
        XCTAssertTrue(RecordingSession.shouldWithholdPaste(
            sourcePID: dictatedInto,
            currentPID: noTypesOwnPID
        ))
    }

    // MARK: - R26: window identity is not considered

    func test_twoWindowsOfOneProcess_compareEqual_andPaste() {
        // R26 / KD9. Process identity decides "the same place", so
        // switching between two windows of the *same* application cannot
        // change the identifier the gate compares. The predicate has no
        // window term to test — this pins that switching windows is
        // indistinguishable from never switching, which is the point.
        let beforeWindowSwitch = dictatedInto
        let afterWindowSwitch = dictatedInto
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            sourcePID: beforeWindowSwitch,
            currentPID: afterWindowSwitch
        ))
    }

    // MARK: - The conservatism axis: a missing fact is not a mismatch

    func test_unknownSource_pastes() {
        // `start()` stores 0 when `NSWorkspace` had no frontmost
        // application. We do not know where the user dictated, so we
        // cannot know they left — paste, as the pre-guard build did.
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            sourcePID: 0,
            currentPID: somewhereElse
        ))
    }

    func test_unknownCurrent_pastes() {
        // Nothing is frontmost at paste time (or the read failed). Same
        // reasoning in the other direction.
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            sourcePID: dictatedInto,
            currentPID: 0
        ))
    }

    func test_bothUnknown_pastes() {
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            sourcePID: 0,
            currentPID: 0
        ))
    }

    func test_terminatedSourceProcess_pastes() {
        // `NSRunningApplication.processIdentifier` answers -1 once the
        // process is gone. That is the same "unknown", and it must be
        // read through the same `<= 0` rule rather than compared as a
        // number — otherwise -1 vs any live pid reads as a mismatch and
        // the conservatism above is undone for exactly the negative
        // sentinel the API produces.
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            sourcePID: -1,
            currentPID: somewhereElse
        ))
    }

    func test_terminatedCurrentProcess_pastes() {
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            sourcePID: dictatedInto,
            currentPID: -1
        ))
    }

    // MARK: - Sweep

    func test_onlyAPositivelyKnownMismatchWithholds_overThePIDSpace() {
        // Property form of the table: across a spread of source/current
        // combinations the gate withholds iff both identifiers are known
        // and they differ. Written as a sweep rather than more cases so
        // a future term added to the predicate (a bundle check, a window
        // check, a "NoType is special" carve-out) fails here loudly
        // instead of only in whichever single case it happened to break.
        let values: [pid_t] = [-2, -1, 0, 1, 42, 501, 812, 99_999]
        for source in values {
            for current in values {
                let expected = source > 0 && current > 0 && source != current
                XCTAssertEqual(
                    RecordingSession.shouldWithholdPaste(
                        sourcePID: source,
                        currentPID: current
                    ),
                    expected,
                    "source=\(source) current=\(current)"
                )
            }
        }
    }

    // MARK: - The fact the summary carries (KTD7)

    func test_summaryDefaultsToNotWithheld() {
        // U4 reads this field to decide whether to surface the notice
        // instead of pasting. Every pre-existing construction of a
        // summary — and every session that pasted normally — must read
        // as "not withheld", which is what the defaulted parameter buys.
        let summary = RecordingSession.SessionSummary(
            failedChunkCount: 0,
            dispatchedChunkCount: 1,
            tokens: .zero,
            model: .flashLite
        )
        XCTAssertFalse(summary.pasteWithheldForDestinationChange)
    }

    func test_summaryReportsAWithheldPaste() {
        let summary = RecordingSession.SessionSummary(
            failedChunkCount: 0,
            dispatchedChunkCount: 1,
            tokens: .zero,
            model: .flashLite,
            pasteWithheldForDestinationChange: true
        )
        XCTAssertTrue(summary.pasteWithheldForDestinationChange)
    }

    func test_withheldPasteIsIndependentOfGapsAndRetention() {
        // The two facts `AppState` branches on are orthogonal: a session
        // can change destination without losing a chunk, and lose chunks
        // without changing destination. Pinned because U4 folds both into
        // one notice and a reader could reasonably assume one implies the
        // other.
        let gapsOnly = RecordingSession.SessionSummary(
            failedChunkCount: 2,
            dispatchedChunkCount: 3,
            tokens: .zero,
            model: .flashLite
        )
        XCTAssertTrue(gapsOnly.hasFailures)
        XCTAssertFalse(gapsOnly.pasteWithheldForDestinationChange)

        let withheldOnly = RecordingSession.SessionSummary(
            failedChunkCount: 0,
            dispatchedChunkCount: 3,
            tokens: .zero,
            model: .flashLite,
            pasteWithheldForDestinationChange: true
        )
        XCTAssertFalse(withheldOnly.hasFailures)
        XCTAssertTrue(withheldOnly.pasteWithheldForDestinationChange)
    }
}
