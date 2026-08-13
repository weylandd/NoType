import XCTest
@testable import NoType

/// Pins `RecordingSession.shouldWithholdPaste(destinationPID:currentPID:)`
/// — the pure gate `stop()` consults at the last synchronous instruction
/// before `TextInjector.paste`, so a transcript that arrived after the
/// user moved on is never typed into a document they did not mean to
/// edit (R23, R24, R26; KD8, KD9).
///
/// **The destination is frozen at the stop, not at session start.**
/// Product ruling of 2026-08-11: the transcript belongs wherever the
/// cursor was when the user pressed stop. Freezing at session start
/// broke hands-free dictation outright — with the recording locked, a
/// user who starts talking in one application, walks to another and taps
/// to stop there is deliberately aiming at the second one, and the paste
/// was withheld every single time. So the freeze lives in
/// `AppState.finalizeRecording`, and the guard for it below reads
/// `AppState.swift` rather than `start()`. What KD8 protects against is
/// untouched: moving away *during transcription* still withholds.
///
/// **Two halves, proved two different ways.** The truth table below is
/// the predicate's whole contract. But `RecordingSession` owns an
/// `AudioRecorder`, a `SileroVAD`, a `GeminiClient` and a `HistoryStore`
/// and cannot be stood up in a unit test, so the surrounding wiring —
/// that the destination is frozen before the stop path suspends, that
/// the gate is called after the cancellation re-check, that only the
/// paste is skipped, and that the entry build and `history.append` still
/// run — is pinned by the source guards under "The wiring the table
/// above does not prove" rather than left to the manual smoke. Read that
/// section's doc-comment for what those guards do and do not establish.
///
/// The two axes the table sweeps:
///
///   * **Mismatch withholds.** A positively-known difference between the
///     process the user stopped in and the process that would receive
///     the keystroke is the only thing that stops a paste.
///   * **Conservatism.** An unknown identifier on *either* side pastes.
///     A missing fact is never evidence of a mismatch — withholding on
///     one would silently swallow ordinary dictations whenever the
///     frontmost app could not be read.
///
/// **A second gate reads the same frozen destination, and answers a
/// different question.** `shouldDiscardInsertionContext(sourcePID:
/// destinationPID:)` compares the destination against the process the
/// session *started* in, to decide whether the cursor context captured at
/// start still describes the document the transcript is landing in. Its
/// table is under "The cursor-context gate" below, together with the
/// independence cases — a hands-free dictation is cross-application *and*
/// pastes, which is the pair a reader is most likely to conflate.
final class RecordingSessionFocusGuardTests: XCTestCase {

    /// Stand-ins for real `pid_t` values. Nothing in the predicate reads
    /// a live process; these only need to be distinct and positive.
    private let stoppedIn: pid_t = 501
    private let somewhereElse: pid_t = 812

    // MARK: - The mismatch axis

    func test_sameProcess_pastes() {
        // AE13. The user left the application mid-transcription and came
        // back before the transcript was ready — or never left at all.
        // Same process, so this is the place they stopped in.
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            destinationPID: stoppedIn,
            currentPID: stoppedIn
        ))
    }

    func test_differentProcess_withholds() {
        // AE12. The wait was long enough for the user to switch away
        // after stopping. Pasting here would edit a document they did not
        // intend to touch — the one outcome KD8 rules out.
        XCTAssertTrue(RecordingSession.shouldWithholdPaste(
            destinationPID: stoppedIn,
            currentPID: somewhereElse
        ))
    }

    func test_handsFreeWalkDuringRecording_isNotAMismatch() {
        // The case the 2026-08-11 ruling exists for. With the recording
        // locked, the user starts talking in one application and walks to
        // another before tapping stop. The destination is where they
        // stopped, so the identity the gate compares is *that*
        // application — and the paste goes through.
        let startedIn: pid_t = 333
        XCTAssertNotEqual(startedIn, stoppedIn)

        // What the old start-frozen identity fed the gate, and why the
        // whole hands-free dictation delivered nothing:
        XCTAssertTrue(
            RecordingSession.shouldWithholdPaste(
                destinationPID: startedIn,
                currentPID: stoppedIn
            ),
            "Sanity: the predicate is unchanged — it is the identity handed to it that moved."
        )

        // What it is fed now: the user stopped where the cursor is, so
        // there is no mismatch to withhold on.
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            destinationPID: stoppedIn,
            currentPID: stoppedIn
        ))
    }

    func test_noTypeItselfFrontmost_withholds() {
        // The user opened the popover after stopping. NoType is not the
        // process they stopped in, so this withholds like any other
        // mismatch — there is deliberately no self-carve-out.
        let noTypesOwnPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertNotEqual(noTypesOwnPID, stoppedIn, "fixture pid collided with the test host's real pid")
        XCTAssertTrue(RecordingSession.shouldWithholdPaste(
            destinationPID: stoppedIn,
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
        let beforeWindowSwitch = stoppedIn
        let afterWindowSwitch = stoppedIn
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            destinationPID: beforeWindowSwitch,
            currentPID: afterWindowSwitch
        ))
    }

    // MARK: - The conservatism axis: a missing fact is not a mismatch

    func test_unknownDestination_pastes() {
        // `freezePasteDestination` stores 0 when `NSWorkspace` had no
        // frontmost application at the stop — and 0 is also what a
        // session that never reached the freeze carries. We do not know
        // where the transcript was headed, so we cannot know the user
        // left — paste, as the pre-guard build did.
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            destinationPID: 0,
            currentPID: somewhereElse
        ))
    }

    func test_unknownCurrent_pastes() {
        // Nothing is frontmost at paste time (or the read failed). Same
        // reasoning in the other direction.
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            destinationPID: stoppedIn,
            currentPID: 0
        ))
    }

    func test_bothUnknown_pastes() {
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            destinationPID: 0,
            currentPID: 0
        ))
    }

    func test_terminatedDestinationProcess_pastes() {
        // `NSRunningApplication.processIdentifier` answers -1 once the
        // process is gone. That is the same "unknown", and it must be
        // read through the same `<= 0` rule rather than compared as a
        // number — otherwise -1 vs any live pid reads as a mismatch and
        // the conservatism above is undone for exactly the negative
        // sentinel the API produces.
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            destinationPID: -1,
            currentPID: somewhereElse
        ))
    }

    func test_terminatedCurrentProcess_pastes() {
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            destinationPID: stoppedIn,
            currentPID: -1
        ))
    }

    // MARK: - Sweep

    func test_onlyAPositivelyKnownMismatchWithholds_overThePIDSpace() {
        // Property form of the table: across a spread of
        // destination/current combinations the gate withholds iff both
        // identifiers are known and they differ. Written as a sweep
        // rather than more cases so a future term added to the predicate
        // (a bundle check, a window check, a "NoType is special"
        // carve-out) fails here loudly instead of only in whichever
        // single case it happened to break.
        let values: [pid_t] = [-2, -1, 0, 1, 42, 501, 812, 99_999]
        for destination in values {
            for current in values {
                let expected = destination > 0 && current > 0 && destination != current
                XCTAssertEqual(
                    RecordingSession.shouldWithholdPaste(
                        destinationPID: destination,
                        currentPID: current
                    ),
                    expected,
                    "destination=\(destination) current=\(current)"
                )
            }
        }
    }

    // MARK: - The facts the summary carries (KTD7)

    func test_summaryDefaultsToNotWithheld_andNamesNoDestination() {
        // U4 reads these fields to decide whether to surface the notice
        // instead of pasting, and what to call the place the transcript
        // went. Every pre-existing construction of a summary — and every
        // session that pasted normally — must read as "not withheld",
        // which is what the defaulted parameters buy.
        let summary = RecordingSession.SessionSummary(
            failedChunkCount: 0,
            dispatchedChunkCount: 1,
            tokens: .zero,
            model: .flashLite
        )
        XCTAssertFalse(summary.pasteWithheldForDestinationChange)
        XCTAssertNil(summary.pasteDestinationAppName)
    }

    func test_summaryReportsAWithheldPaste_andWhereItWasHeaded() {
        let summary = RecordingSession.SessionSummary(
            failedChunkCount: 0,
            dispatchedChunkCount: 1,
            tokens: .zero,
            model: .flashLite,
            pasteWithheldForDestinationChange: true,
            pasteDestinationAppName: "Mail"
        )
        XCTAssertTrue(summary.pasteWithheldForDestinationChange)
        // R25's notice names the application the transcript was destined
        // for. Since the 2026-08-11 ruling that is the stop-moment
        // application, carried here rather than re-read at notice time —
        // by then the user has moved again.
        XCTAssertEqual(summary.pasteDestinationAppName, "Mail")
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

    // MARK: - The cursor-context gate

    /// `InsertionTarget` is read once, in the context phase of `start()`,
    /// from the focused field of the application frontmost *then*. Since
    /// the 2026-08-11 ruling moved the destination to the stop, that is no
    /// longer necessarily where the transcript lands — so
    /// `finalizeForInsertion` can be handed one application's cursor text
    /// while pasting into another's document. Its trailing-punctuation
    /// strip is destructive: a period the user dictated is deleted on the
    /// strength of a character read out of a different window.
    ///
    /// The gate's table is the same shape as `shouldWithholdPaste`'s —
    /// both identifiers known and different — over a different pair of
    /// identifiers.

    func test_startedAndStoppedInTheSameProcess_keepsTheContext() {
        // The ordinary hold-to-talk dictation, and the overwhelming
        // majority of sessions. The cursor context was read in the same
        // document the paste lands in, so both of `finalizeForInsertion`'s
        // corrections are about the right text.
        XCTAssertFalse(RecordingSession.shouldDiscardInsertionContext(
            sourcePID: stoppedIn,
            destinationPID: stoppedIn
        ))
    }

    func test_startedAndStoppedInDifferentProcesses_discardsTheContext() {
        // The maintainer's ruling: "if I started recording in one window
        // and pressed stop in a different window, then everything has
        // already changed, and those formatting corrections should not be
        // applied."
        let startedIn: pid_t = 333
        XCTAssertTrue(RecordingSession.shouldDiscardInsertionContext(
            sourcePID: startedIn,
            destinationPID: stoppedIn
        ))
    }

    func test_unknownSource_keepsTheContext() {
        // Nothing was frontmost at session start (or the read failed).
        // Conservative in the same direction as the paste gate: a missing
        // fact never triggers the defensive path. Chosen deliberately —
        // an unknown identifier is a failed read on what is almost always
        // an ordinary same-application dictation, not evidence of a move.
        XCTAssertFalse(RecordingSession.shouldDiscardInsertionContext(
            sourcePID: 0,
            destinationPID: stoppedIn
        ))
    }

    func test_unknownDestination_keepsTheContext() {
        // The freeze found nothing frontmost at the stop, or never ran.
        XCTAssertFalse(RecordingSession.shouldDiscardInsertionContext(
            sourcePID: stoppedIn,
            destinationPID: 0
        ))
    }

    func test_bothUnknown_keepTheContext() {
        XCTAssertFalse(RecordingSession.shouldDiscardInsertionContext(
            sourcePID: 0,
            destinationPID: 0
        ))
    }

    func test_terminatedSourceProcess_keepsTheContext() {
        // `NSRunningApplication.processIdentifier` answers -1 once the
        // process is gone, and `sourcePID` is frozen precisely so that
        // sentinel is never what gets compared. Read through the same
        // `> 0` rule anyway: a plain `!=` would call -1 a mismatch.
        XCTAssertFalse(RecordingSession.shouldDiscardInsertionContext(
            sourcePID: -1,
            destinationPID: stoppedIn
        ))
    }

    func test_terminatedDestination_keepsTheContext() {
        XCTAssertFalse(RecordingSession.shouldDiscardInsertionContext(
            sourcePID: stoppedIn,
            destinationPID: -1
        ))
    }

    func test_onlyAPositivelyKnownMoveDiscardsTheContext_overThePIDSpace() {
        // Property form, written as a sweep for the same reason the paste
        // gate's is: a future term added to the predicate fails here
        // loudly rather than only in whichever single case it broke.
        let values: [pid_t] = [-2, -1, 0, 1, 42, 333, 501, 812, 99_999]
        for source in values {
            for destination in values {
                let expected = source > 0 && destination > 0 && source != destination
                XCTAssertEqual(
                    RecordingSession.shouldDiscardInsertionContext(
                        sourcePID: source,
                        destinationPID: destination
                    ),
                    expected,
                    "source=\(source) destination=\(destination)"
                )
            }
        }
    }

    // MARK: - The two gates are independent

    func test_handsFreeWalk_discardsTheContext_andStillPastes() {
        // Start in A, walk to B, stop there, still in B when the
        // transcript is ready. The cursor context describes A's document
        // and must go; the paste is aimed at B and must happen. A change
        // that folded these two questions into one would break exactly
        // this flow — the whole reason the destination moved to the stop.
        let startedIn: pid_t = 333
        let stoppedAndStillIn = stoppedIn

        XCTAssertTrue(RecordingSession.shouldDiscardInsertionContext(
            sourcePID: startedIn,
            destinationPID: stoppedAndStillIn
        ))
        XCTAssertFalse(RecordingSession.shouldWithholdPaste(
            destinationPID: stoppedAndStillIn,
            currentPID: stoppedAndStillIn
        ))
    }

    func test_movedAwayDuringTranscription_withholds_andKeepsTheContext() {
        // The mirror case. Start and stop in A, then switch to B while
        // waiting. The context is still about A — the place the paste was
        // aimed at — so there is nothing stale to discard; what fires is
        // the paste gate.
        XCTAssertFalse(RecordingSession.shouldDiscardInsertionContext(
            sourcePID: stoppedIn,
            destinationPID: stoppedIn
        ))
        XCTAssertTrue(RecordingSession.shouldWithholdPaste(
            destinationPID: stoppedIn,
            currentPID: somewhereElse
        ))
    }

    func test_bothFire_whenTheUserWalkedAndThenMovedAgain() {
        // Start in A, stop in B, then move to C during transcription.
        // Nothing pastes, and the row's text is still finalized — against
        // `.unknown` rather than A's cursor — so both gates matter on the
        // same session and neither subsumes the other.
        let startedIn: pid_t = 333
        XCTAssertTrue(RecordingSession.shouldDiscardInsertionContext(
            sourcePID: startedIn,
            destinationPID: stoppedIn
        ))
        XCTAssertTrue(RecordingSession.shouldWithholdPaste(
            destinationPID: stoppedIn,
            currentPID: somewhereElse
        ))
    }

    // MARK: - The wiring the table above does not prove

    /// Everything above pins the *predicate*. That leaves the claims the
    /// feature actually rests on unproven, and the gap is not
    /// theoretical — this repo already ran the experiment one function
    /// over. Deleting `retainable.formUnion(acct.retainable)` from
    /// `splitRetry`'s abandon arm, the exact permanent-loss bug that arm
    /// exists to prevent, left every seam test green (see
    /// `NoType/Recording/CLAUDE.md`, "Know what that proof covers"), and
    /// the adopted answer was a source guard, not manual smoke.
    ///
    /// The same six mutations are green against the table above:
    /// delete the `freezePasteDestination` call in
    /// `AppState.finalizeRecording` (pinned separately below); delete the
    /// gate call; invert the two arms; move `history.append` into the
    /// paste arm; make the withheld arm `throw` (which routes to
    /// `finalizeRecording`'s catch arm and writes no row — the exact
    /// mistake KTD6 names); or compare `sourceApp?.processIdentifier`
    /// instead of the frozen `destinationPID`.
    ///
    /// So this is a source guard in the shape `RaiseSiteScanner`
    /// (`HUDPanelGeometryTests.swift`) established, and it inherits that
    /// shape's documented limits: it matches literal spellings in one
    /// file and proves the statements are *present*, not that they are
    /// reached; a comment containing one of the needles would satisfy an
    /// absence assertion, which is why every scanned file is stripped of
    /// comments first; and a rename fails it loudly, which is a review
    /// trigger rather than a false negative.
    func test_stopWiring_withholdsOnlyThePaste_andStillWritesTheHistoryRow() throws {
        let stopBody = try XCTUnwrap(
            Self.body(ofFuncNamed: "stop", in: Self.recordingSessionSource()),
            "Could not parse stop() — the guard lost its anchor."
        )

        // Presence complement: without these the absence assertions below
        // are vacuously true on a file that deleted the feature outright.
        let abort = try XCTUnwrap(
            stopBody.range(of: "shouldAbortBeforePaste("),
            "stop() no longer consults the cancellation gate."
        )
        let gate = try XCTUnwrap(
            stopBody.range(of: "Self.shouldWithholdPaste("),
            "stop() no longer consults the destination gate — every transcript pastes into whatever is frontmost (R23)."
        )
        XCTAssertTrue(
            stopBody.contains("destinationPID: destinationPID"),
            "The gate must compare the pid frozen at the stop. Re-deriving it from an NSRunningApplication reads -1 once that process exits, which the predicate treats as unknown — so the guard would silently stop firing for the quit-and-relaunch case it exists to catch."
        )

        // KTD5: the destination gate runs after the cancellation re-check.
        XCTAssertLessThan(abort.lowerBound, gate.lowerBound)

        // The withheld arm: skips the paste, and nothing else.
        let ifBrace = try XCTUnwrap(
            stopBody.range(of: "if pasteWithheldForDestinationChange {"),
            "The gate no longer branches on its own result."
        )
        let withheld = try XCTUnwrap(
            Self.block(from: stopBody.index(before: ifBrace.upperBound), in: stopBody)
        )
        XCTAssertFalse(
            withheld.body.contains("TextInjector.paste("),
            "The withheld arm must not paste — not pasting into a document the user never meant to edit is the whole point (KD8)."
        )
        XCTAssertFalse(
            withheld.body.contains("throw"),
            "The withheld arm must not throw. Throwing routes stop() into finalizeRecording's catch arm, which writes no history row — the transcript would be destroyed rather than kept, which is exactly the mistake KTD6 forbids."
        )
        XCTAssertFalse(
            withheld.body.contains("return"),
            "The withheld arm must fall through to the entry build and history.append (R24), not return the row's only copy away."
        )

        // The paste arm still pastes.
        let elseBrace = try XCTUnwrap(
            stopBody[withheld.close...].range(of: "else {"),
            "The gate lost its else arm — an ordinary dictation no longer pastes at all."
        )
        let pasteArm = try XCTUnwrap(
            Self.block(from: stopBody.index(before: elseBrace.upperBound), in: stopBody)
        )
        XCTAssertTrue(
            pasteArm.body.contains("TextInjector.paste("),
            "The non-withheld arm must still paste — the common case is an ordinary dictation."
        )

        // R24: both the entry build and the append sit *after* the whole
        // if/else closes, so they run on either arm. This is the assertion
        // that stops either one being moved inside a branch.
        let entryBuild = try XCTUnwrap(
            stopBody.range(of: "makeHistoryEntry("),
            "stop() no longer builds a history entry."
        )
        let append = try XCTUnwrap(
            stopBody.range(of: "history.append("),
            "stop() no longer appends the row."
        )
        XCTAssertLessThan(
            pasteArm.close, entryBuild.lowerBound,
            "makeHistoryEntry moved inside a branch of the paste gate — a withheld session would keep no row (R24)."
        )
        XCTAssertLessThan(
            pasteArm.close, append.lowerBound,
            "history.append moved inside a branch of the paste gate — a withheld session's transcript would exist nowhere (R24)."
        )
    }

    /// The cursor-context gate's wiring, which its table proves nothing
    /// about: deleting the call, or keeping it and feeding
    /// `finalizeForInsertion` the cached context anyway, leaves every case
    /// in "The cursor-context gate" above green while the destructive
    /// correction it exists to prevent runs on every hands-free
    /// dictation. Same source-scan shape and same limits as the guard
    /// above — literal spellings, comments stripped first, presence rather
    /// than reachability.
    func test_stopWiring_discardsTheStaleCursorContext_beforeFinalizing() throws {
        let stopBody = try XCTUnwrap(
            Self.body(ofFuncNamed: "stop", in: Self.recordingSessionSource()),
            "Could not parse stop() — the guard lost its anchor."
        )

        let gate = try XCTUnwrap(
            stopBody.range(of: "Self.shouldDiscardInsertionContext("),
            "stop() no longer consults the cursor-context gate, so a hands-free dictation is finalized against the document it started in — and a sentence-final period the user dictated is stripped on the strength of a character read out of another window."
        )
        XCTAssertEqual(
            stopBody.components(separatedBy: "Self.shouldDiscardInsertionContext(").count - 1, 1,
            "The gate is consulted more than once in stop(). Every assertion below anchors on the first occurrence, so a second call deciding a different `target` passes them all."
        )
        XCTAssertTrue(
            stopBody.contains("sourcePID: sourcePID"),
            "The gate must compare the pid frozen at session start. Re-deriving it from `sourceApp` reads -1 once that process exits, which the predicate treats as unknown — the context would then be kept for exactly the cross-application session it must be dropped for."
        )
        XCTAssertTrue(
            stopBody.contains("destinationPID: destinationPID"),
            "The gate must compare against the destination frozen at the stop, not against a fresh read. A paste-time read would make this the paste gate's question instead of its own."
        )

        // It has to run before the correction it governs.
        let finalize = try XCTUnwrap(
            stopBody.range(of: "TextInjector.finalizeForInsertion("),
            "stop() no longer finalizes the transcript for insertion — re-derive this guard against whatever replaced it."
        )
        XCTAssertLessThan(
            gate.lowerBound, finalize.lowerBound,
            "The cursor-context gate runs after the text has already been finalized, so its verdict changes nothing."
        )

        let open = try XCTUnwrap(
            stopBody.range(of: "{", range: gate.upperBound..<stopBody.endIndex),
            "The gate's result no longer opens a branch."
        )
        let discardArm = try XCTUnwrap(Self.block(from: open.lowerBound, in: stopBody))
        XCTAssertTrue(
            discardArm.body.contains("target = .unknown"),
            "The discard arm no longer substitutes `.unknown`. `.empty` is not a synonym for it: `.empty` claims the field is empty, which suppresses the defensive leading space AND re-enables the trailing-punctuation strip — the destructive correction this gate exists to avoid."
        )
        XCTAssertFalse(
            discardArm.body.contains("cachedContext"),
            "The discard arm still reads the session's captured context. That stale value is the one thing it must not pass on."
        )

        let elseBrace = try XCTUnwrap(
            stopBody[discardArm.close...].range(of: "else {"),
            "The gate lost its else arm — an ordinary same-application dictation would finalize against `.unknown` and pick up a stray leading space on every paste."
        )
        let keepArm = try XCTUnwrap(
            Self.block(from: stopBody.index(before: elseBrace.upperBound), in: stopBody)
        )
        XCTAssertTrue(
            keepArm.body.contains("cachedContext?.insertionTarget"),
            "The non-discard arm no longer feeds the captured cursor context, so the common case lost its boundary normalisation entirely."
        )
    }

    /// The other end of that comparison. Deleting the freeze leaves
    /// `sourcePID` at its `0` default, which the predicate reads as
    /// "unknown" and keeps the context for — the feature is silently off
    /// and every case in its table still passes. The single-read
    /// assertions are the second half: `sourceApp`, the OCR gate's pid and
    /// `sourcePID` all have to come from one `NSWorkspace` read, or the
    /// application this session believes it began in can differ between
    /// the three consumers.
    func test_startFreezesTheSourceProcess_fromTheReadItAlreadyPerforms() throws {
        let startBody = try XCTUnwrap(
            Self.body(ofFuncNamed: "start", in: Self.recordingSessionSource()),
            "Could not parse start() — the guard lost its anchor."
        )

        XCTAssertTrue(
            startBody.contains("sourcePID = pid"),
            "start() no longer freezes the process the session began in, so the cursor-context gate compares against 0 and never fires."
        )
        XCTAssertEqual(
            startBody.components(separatedBy: "sourcePID =").count - 1, 1,
            "The source process is frozen more than once in start(). The later write wins, and one placed after a suspension would name an application the session did not begin in."
        )
        XCTAssertEqual(
            startBody.components(separatedBy: "NSWorkspace.shared.frontmostApplication").count - 1, 1,
            "start() reads the frontmost application more than once. One read feeds `sourceApp`, the OCR gate and `sourcePID`; a second read is a second answer, and the session would then hold two disagreeing accounts of where it began."
        )
        XCTAssertFalse(
            startBody.contains("#if"),
            "start() grew a conditional-compilation block. The scan matches text, not the built configuration, so a freeze inside `#if DEBUG` reads as present here and ships absent."
        )
    }

    /// The freeze itself, and *where* it sits. Deleting the call leaves
    /// `destinationPID` at its `0` default, which the predicate reads as
    /// "unknown" and pastes through — the feature is silently off and
    /// every case in the table above still passes.
    ///
    /// The ordering assertions are the other half, and they are the
    /// product ruling's mechanical form. The freeze must run before the
    /// stop path suspends: every `await` between the user's stop action
    /// and the read is a window in which the frontmost application can
    /// change, and a destination captured after one of them names
    /// somewhere the user was not when they stopped. Moving the read
    /// inside the `Task` — or into `stop()`, which that `Task` calls —
    /// reopens exactly that window while leaving every other assertion in
    /// this file green.
    ///
    /// **The occurrence count is load-bearing, not defensive style.** Every
    /// ordering assertion below anchors on the *first* match, so a second
    /// freeze added after the suspension is invisible to all of them while
    /// being the exact bug they exist to prevent: the later call is the one
    /// that wins, and it reads the frontmost application at a moment the
    /// user was never promised. One call, or this guard proves nothing.
    func test_finalizeRecording_freezesTheDestination_beforeThePathSuspends() throws {
        let body = try XCTUnwrap(
            Self.body(ofFuncNamed: "finalizeRecording", in: Self.appStateSource()),
            "Could not parse finalizeRecording() — the guard lost its anchor."
        )

        let freeze = try XCTUnwrap(
            body.range(of: "session.freezePasteDestination("),
            "finalizeRecording no longer freezes the paste destination, so the gate compares against 0 and never fires — the feature is off."
        )
        XCTAssertTrue(
            body.contains("freezePasteDestination(NSWorkspace.shared.frontmostApplication)"),
            "The destination must be the application frontmost at the stop. Passing anything derived from the session's own start-time state restores the behaviour the 2026-08-11 ruling reversed: a hands-free locked dictation that walks to another application delivers nothing."
        )
        XCTAssertEqual(
            body.components(separatedBy: "session.freezePasteDestination(").count - 1, 1,
            "The destination is frozen more than once in finalizeRecording. Every ordering assertion here anchors on the first occurrence, so a second freeze sitting after the suspension passes them all and still overwrites the destination with a later reading — the precise failure this guard exists to catch."
        )

        // A `#if` around the freeze would satisfy every literal assertion
        // above while compiling the call out of the shipping configuration.
        XCTAssertFalse(
            body.contains("#if"),
            "finalizeRecording grew a conditional-compilation block. The scan matches text, not the built configuration, so a freeze inside `#if DEBUG` reads as present here and is absent from the release binary. Re-derive this guard before adding one."
        )

        // Currently subsumed by the `Task {` assertion below — `finalizeRecording`
        // is synchronous, so an `await` ahead of the freeze does not compile at
        // all. Kept because that is a property of today's signature, not of the
        // contract: the day this method becomes `async`, this is the assertion
        // that still holds the line.
        let firstAwait = try XCTUnwrap(
            body.range(of: "await "),
            "finalizeRecording no longer awaits anything — this guard's ordering assertion has lost its meaning and needs rewriting, not deleting."
        )
        XCTAssertLessThan(
            freeze.lowerBound, firstAwait.lowerBound,
            "The destination is frozen after the path suspends. Between the user's stop and that suspension the frontmost application can change, so the transcript would be aimed somewhere the user never was."
        )

        let firstTask = try XCTUnwrap(
            body.range(of: "Task {"),
            "finalizeRecording no longer spawns the stop task — re-derive this guard against whatever replaced it."
        )
        XCTAssertLessThan(
            freeze.lowerBound, firstTask.lowerBound,
            "The freeze moved inside the stop task. That task is scheduled, not immediate: the main actor can service an app-switch before its body runs."
        )

        // The production comment claims the freeze is the first statement
        // after the session guard, and `recordingState = .sending` is the
        // statement it claims to precede. Pinning it keeps the claim and the
        // code from drifting apart without anything failing.
        let stateChange = try XCTUnwrap(
            body.range(of: "recordingState = .sending"),
            "finalizeRecording no longer marks the session as sending — re-derive this guard against whatever replaced it."
        )
        XCTAssertLessThan(
            freeze.lowerBound, stateChange.lowerBound,
            "Statements moved ahead of the freeze. Each one is a chance for a future edit to slip a suspension in front of the destination read; the freeze stays first so that cannot happen quietly."
        )
    }

    /// The transcribing HUD is on screen for the whole transcription wait
    /// and names where the transcript is going, so it has to be fed the
    /// frozen destination. It was fed `session.sourceAppName` — the
    /// *session-start* application — which named the wrong window for
    /// every hands-free dictation that walked somewhere else, the same
    /// class of false statement as a "Pasted with gaps" notice on a
    /// session that pasted nothing.
    ///
    /// Reverting it is invisible to every other assertion in this file, so
    /// it gets its own: the label must come from the freeze's return value,
    /// which is the same read the gate compares.
    func test_transcribingHUD_isLabelledFromTheFrozenDestination() throws {
        let body = try XCTUnwrap(
            Self.body(ofFuncNamed: "finalizeRecording", in: Self.appStateSource()),
            "Could not parse finalizeRecording() — the guard lost its anchor."
        )

        XCTAssertTrue(
            body.contains("let destinationName = session.freezePasteDestination("),
            "The HUD label no longer comes from the freeze's return value. One read of NSWorkspace has to feed both the label and the comparison, or the HUD can name one application while the transcript is aimed at another."
        )
        XCTAssertTrue(
            body.contains("let target = destinationName ??"),
            "The transcribing HUD's target label is derived from something other than the frozen destination."
        )
        XCTAssertFalse(
            body.contains("sourceAppName"),
            "The HUD label reads the session-start application again. That is the application the user began in, not the one the transcript is headed for — under the 2026-08-11 ruling those differ for every hands-free dictation that walks somewhere else."
        )
    }

    /// The complement: the freeze must *not* come back at session start.
    /// That is the exact behaviour the product owner reversed, and it is
    /// a plausible "restoration" for someone reading the guard's
    /// conservatism and concluding the identity should be the one the
    /// session dictated into.
    func test_startDoesNotFreezeTheDestination() throws {
        let startBody = try XCTUnwrap(
            Self.body(ofFuncNamed: "start", in: Self.recordingSessionSource()),
            "Could not parse start() — the guard lost its anchor."
        )
        XCTAssertFalse(
            startBody.contains("destinationPID"),
            "start() froze the paste destination again. The destination is where the user pressed stop, not where they began: a hands-free locked dictation that starts in one application and ends in another must land in the one it ended in."
        )
        XCTAssertFalse(
            startBody.contains("freezePasteDestination"),
            "start() froze the paste destination again — see above."
        )
    }

    /// The gate's normal case rests on a fact owned by another module:
    /// NoType's own windows never take frontmost by themselves. The
    /// transcribing HUD is on screen for *every* session, so if
    /// `HUDPanel` ever became activating, `shouldWithholdPaste` would
    /// see NoType as the frontmost process and withhold **every**
    /// dictation — a total failure reached by editing a file this
    /// feature's own tests otherwise never look at.
    ///
    /// This guard lives here rather than beside `HUDPanel`'s geometry
    /// tests because the paste gate is what depends on the property; the
    /// failure it should provoke is "dictation stopped pasting", not
    /// "a panel changed style". Same source-scan limits as above.
    func test_hudPanelStaysNonActivating_orEveryPasteIsWithheld() {
        let source = Self.strippingComments(Self.source(of: "NoType/UI/HUDPanel.swift"))
        XCTAssertTrue(
            source.contains(".nonactivatingPanel"),
            "HUDPanel dropped .nonactivatingPanel. It shows during every session, so it would now take frontmost and shouldWithholdPaste would withhold every dictation."
        )
        XCTAssertTrue(
            source.contains("var canBecomeKey: Bool  { false }")
                || source.contains("var canBecomeKey: Bool { false }"),
            "HUDPanel can now become key. See above — this withholds every dictation, not a rare one."
        )
        XCTAssertTrue(
            source.contains("var canBecomeMain: Bool { false }"),
            "HUDPanel can now become main. See above — this withholds every dictation, not a rare one."
        )
    }

    // MARK: - Fixtures for the extractors themselves

    /// Without this, a guard whose extractor silently matched the whole
    /// file would pass on a `stop()` that had lost the gate entirely.
    func test_bodyExtractor_isScopedToTheNamedFunction() throws {
        let source = """
        private func other() {
            Self.shouldWithholdPaste(destinationPID: destinationPID, currentPID: 1)
        }

        func stop() async throws -> HistoryEntry {
            let marker = 1
        }
        """
        let body = try XCTUnwrap(Self.body(ofFuncNamed: "stop", in: source))
        XCTAssertTrue(body.contains("let marker = 1"))
        XCTAssertFalse(
            body.contains("shouldWithholdPaste"),
            "The extractor ran past its function — the assertions above would be satisfiable by a neighbouring function."
        )
    }

    /// `stop()` is reached by name, not by prefix: `stopCapture()` is
    /// declared just above it and must not be what the guard reads.
    func test_bodyExtractor_doesNotMatchStopCapture() throws {
        let source = """
        func stopCapture() {
            let wrongOne = 1
        }

        func stop() async throws -> HistoryEntry {
            let rightOne = 2
        }
        """
        let body = try XCTUnwrap(Self.body(ofFuncNamed: "stop", in: source))
        XCTAssertFalse(body.contains("wrongOne"))
        XCTAssertTrue(body.contains("rightOne"))
    }

    /// The mutation that produced `strippingComments`: a disabled line
    /// must not satisfy a presence assertion, and prose must not satisfy
    /// an absence one.
    func test_commentStripping_hidesDisabledCodeAndProse() {
        let stripped = Self.strippingComments("""
        // session.freezePasteDestination(NSWorkspace.shared.frontmostApplication)
        let kept = 1  // TextInjector.paste(final)
        """)
        XCTAssertFalse(
            stripped.contains("session.freezePasteDestination("),
            "A commented-out call still matched — the guard would pass on a file where the feature was disabled."
        )
        XCTAssertFalse(stripped.contains("TextInjector.paste("))
        XCTAssertTrue(stripped.contains("let kept = 1"))
    }

    /// The line-comment sibling of the mutation above. A `/* … */` around
    /// the freeze turns the feature off while leaving every literal this
    /// guard searches for in the file, so a stripper that handled only
    /// `//` would stay green on it. Neither scanned file carries a block
    /// comment today — which is why this has to be a fixture rather than
    /// something the real scan would have surfaced.
    func test_commentStripping_hidesBlockCommentedCode_andSparesURLLiterals() {
        let stripped = Self.strippingComments("""
        /* an older copy: session.freezePasteDestination(NSWorkspace.shared.frontmostApplication) */
        let feed = "https://weylandd.github.io/NoType/appcast.xml"
        let live = session.freezePasteDestination(NSWorkspace.shared.frontmostApplication)
        """)
        XCTAssertEqual(
            stripped.components(separatedBy: "session.freezePasteDestination(").count - 1, 1,
            "Only the live call may survive. A block-commented copy satisfying the presence needle is the mutation this stripper exists to catch."
        )
        XCTAssertTrue(
            stripped.contains("https://weylandd.github.io/NoType/appcast.xml"),
            "A URL literal's `//` was read as a comment. Truncating a line is how an absence assertion passes for the wrong reason."
        )
    }

    func test_blockExtractor_stopsAtTheMatchingBrace() throws {
        let source = "if a { inner { nested } done } after"
        let open = try XCTUnwrap(source.range(of: "{")).lowerBound
        let block = try XCTUnwrap(Self.block(from: open, in: source))
        XCTAssertTrue(block.body.contains("nested"))
        XCTAssertTrue(block.body.contains("done"))
        XCTAssertFalse(
            block.body.contains("after"),
            "The extractor ran past the matching brace."
        )
    }

    // MARK: - Extractors

    /// Brace-balanced slice of a named function's body. Same shape and
    /// same caveats as the extractor in `SplitRetryNetworkBoundTests`
    /// (naive about braces inside string literals; adequate for the two
    /// Swift files it reads).
    private static func body(ofFuncNamed name: String, in source: String) -> String? {
        guard let decl = source.range(of: "func \(name)(") else { return nil }
        guard let open = source.range(of: "{", range: decl.upperBound..<source.endIndex) else { return nil }
        return block(from: open.lowerBound, in: source)?.body
    }

    /// Brace-balanced slice starting at `open`, which must index a `{`.
    /// Returns the text between the braces and the index of the matching
    /// closing brace, so callers can assert on what follows it.
    private static func block(
        from open: String.Index,
        in source: String
    ) -> (body: String, close: String.Index)? {
        var depth = 0
        var idx = open
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(source[source.index(after: open)..<idx]), idx)
                }
            }
            idx = source.index(after: idx)
        }
        return nil
    }

    /// Comments are stripped before any assertion runs, and that is
    /// load-bearing rather than tidiness. Calibrating this guard by
    /// mutation caught it: commenting out the freeze left the line
    /// `// session.freezePasteDestination(…)` in the file, and a raw
    /// `contains` check happily matched the disabled code and stayed
    /// green. The same trap runs the other way — this file's own prose
    /// names `TextInjector.paste(`, `throw` and `destinationPID` while
    /// explaining where each must and must not appear, so an absence
    /// assertion over un-stripped text would fail on the comments alone.
    ///
    /// **Block comments are stripped too, and that is not symmetry for its
    /// own sake.** A `/* … */` around the freeze disables the feature while
    /// leaving every literal this guard searches for intact, so a line-only
    /// stripper is green on exactly the mutation it was written to catch —
    /// the same hole `GeminiClientOfflineShortCircuitTests`' stripper
    /// already closed, ported here rather than rediscovered. Neither
    /// scanned file contains a block comment today; that makes the gap
    /// latent, not absent, and latent is what a guard is for.
    ///
    /// The `://` sentinel is the companion trap: without it the line pass
    /// truncates every URL literal at its scheme. **Do not restate the old
    /// claim that mangling a string literal "can only cause a loud failure,
    /// never a silent pass"** — that was true when this file only asserted
    /// presence, and stopped being true when it grew absence assertions
    /// (`start()` must not contain `destinationPID`; the withheld arm must
    /// not contain `TextInjector.paste(`). Deleting text is exactly how an
    /// absence assertion passes for the wrong reason.
    private static func strippingComments(_ source: String) -> String {
        // The sentinel must not itself contain `//`, or the line pass below
        // truncates every URL literal at the scheme.
        let urlSchemeSentinel = "\u{1}"
        var s = source.replacingOccurrences(of: "://", with: urlSchemeSentinel)

        while let open = s.range(of: "/*"),
              let close = s.range(of: "*/", range: open.upperBound..<s.endIndex) {
            s.replaceSubrange(open.lowerBound..<close.upperBound, with: "")
        }

        return s
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: urlSchemeSentinel, with: "://")
    }

    private static func source(of repoRelativePath: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NoTypeTests/
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent(repoRelativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func recordingSessionSource() -> String {
        strippingComments(source(of: "NoType/Recording/RecordingSession.swift"))
    }

    /// The freeze moved out of `RecordingSession` and into its caller, so
    /// the guard follows it across the file boundary.
    private static func appStateSource() -> String {
        strippingComments(source(of: "NoType/AppState.swift"))
    }
}
