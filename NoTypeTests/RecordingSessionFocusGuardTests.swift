import XCTest
@testable import NoType

/// Pins `RecordingSession.shouldWithholdPaste(sourcePID:currentPID:)` —
/// the pure gate `stop()` consults at the last synchronous instruction
/// before `TextInjector.paste`, so a transcript that arrived after the
/// user moved on is never typed into a document they did not mean to
/// edit (R23, R24, R26; KD8, KD9).
///
/// **Two halves, proved two different ways.** The truth table below is
/// the predicate's whole contract. But `RecordingSession` owns an
/// `AudioRecorder`, a `SileroVAD`, a `GeminiClient` and a `HistoryStore`
/// and cannot be stood up in a unit test, so the surrounding wiring —
/// that the gate is called after the cancellation re-check, that only
/// the paste is skipped, and that the entry build and `history.append`
/// still run — is pinned by the source guards under "The wiring the
/// table above does not prove" rather than left to the manual smoke.
/// Read that section's doc-comment for what those guards do and do not
/// establish.
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

    // MARK: - The wiring the table above does not prove

    /// Everything above pins the *predicate*. That leaves the four claims
    /// the feature actually rests on unproven, and the gap is not
    /// theoretical — this repo already ran the experiment one function
    /// over. Deleting `retainable.formUnion(acct.retainable)` from
    /// `splitRetry`'s abandon arm, the exact permanent-loss bug that arm
    /// exists to prevent, left every seam test green (see
    /// `NoType/Recording/CLAUDE.md`, "Know what that proof covers"), and
    /// the adopted answer was a source guard, not manual smoke.
    ///
    /// The same six mutations are green against the table above:
    /// delete the `sourcePID = pid` freeze in `start()`; delete the gate
    /// call; invert the two arms; move `history.append` into the paste
    /// arm; make the withheld arm `throw` (which routes to
    /// `finalizeRecording`'s catch arm and writes no row — the exact
    /// mistake KTD6 names); or compare `sourceApp?.processIdentifier`
    /// instead of the frozen `sourcePID`.
    ///
    /// So this is a source guard in the shape `RaiseSiteScanner`
    /// (`HUDPanelGeometryTests.swift`) established, and it inherits that
    /// shape's documented limits: it matches literal spellings in one
    /// file and proves the statements are *present*, not that they are
    /// reached; a comment containing one of the needles would satisfy an
    /// absence assertion; and a rename fails it loudly, which is a review
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
            stopBody.contains("sourcePID: sourcePID"),
            "The gate must compare the pid frozen at session start. Re-deriving it from sourceApp reads -1 once that process exits, which the predicate treats as unknown — so the guard would silently stop firing for the quit-and-relaunch case it exists to catch."
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

    /// The freeze itself. Deleting this one assignment leaves `sourcePID`
    /// at its `0` default, which the predicate reads as "unknown" and
    /// pastes through — the feature is silently off and every case in the
    /// table above still passes.
    func test_startFreezesTheSourcePID() throws {
        let startBody = try XCTUnwrap(
            Self.body(ofFuncNamed: "start", in: Self.recordingSessionSource()),
            "Could not parse start() — the guard lost its anchor."
        )
        XCTAssertTrue(
            startBody.contains("sourcePID = pid"),
            "start() must freeze the frontmost pid, or the gate compares against 0 and never fires."
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
            Self.shouldWithholdPaste(sourcePID: sourcePID, currentPID: 1)
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
        // sourcePID = pid
        let kept = 1  // TextInjector.paste(final)
        """)
        XCTAssertFalse(
            stripped.contains("sourcePID = pid"),
            "A commented-out assignment still matched — the guard would pass on a file where the feature was disabled."
        )
        XCTAssertFalse(stripped.contains("TextInjector.paste("))
        XCTAssertTrue(stripped.contains("let kept = 1"))
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
    /// (naive about braces inside string literals; adequate for the one
    /// Swift file it reads).
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
    /// mutation caught it: commenting out `sourcePID = pid` left the line
    /// `// sourcePID = pid` in the file, and a raw `contains` check
    /// happily matched the disabled code and stayed green. The same trap
    /// runs the other way — this file's own prose names
    /// `TextInjector.paste(` and `throw` while explaining why the
    /// withheld arm must not contain them, so an absence assertion over
    /// un-stripped text would fail on the comments alone.
    ///
    /// Naive about `//` inside string literals, which can only delete
    /// text and so can only cause a loud failure, never a silent pass.
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
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
}
