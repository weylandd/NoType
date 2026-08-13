import XCTest
@testable import NoType

/// Pins the one string a stored row becomes (R4, R5, R6, R13, R14, R31;
/// KD2) and the channel the dictionary harvester keeps its own input on
/// (R15).
///
/// `HistoryText` is the whole of U6's model change: the gap stops being
/// bracket characters inside a transcript and becomes a position that is
/// *rendered* as brackets, downstream of where a replacement pair can
/// reach. Everything else in the unit is wiring to this.
final class HistoryTextTests: XCTestCase {

    private let marker = RecordingSession.failureMarker

    // MARK: - Assembly (R4)

    func test_assemble_singleTextSegment_isThatTextVerbatim() {
        XCTAssertEqual(
            HistoryText.assemble([.carrying("Ship it by Friday.", at: [0])]),
            "Ship it by Friday."
        )
    }

    func test_assemble_rendersEachGapAsTheMarker() {
        XCTAssertEqual(
            HistoryText.assemble([
                .carrying("Ship it by", at: [0]),
                .gap(at: [1]),
                .carrying("and review after.", at: [2]),
            ]),
            "Ship it by \(marker) and review after."
        )
    }

    func test_assemble_anAllGapRow_rendersOneMarkerPerGap() {
        // AE2's first half. A session that lost everything used to store
        // `""` and have its markers synthesised from a count; it now
        // renders from the same sequence every other row does.
        XCTAssertEqual(
            HistoryText.assemble([.gap(at: [0]), .gap(at: [1]), .gap(at: [2])]),
            "\(marker) \(marker) \(marker)"
        )
        XCTAssertEqual(HistoryText.assemble([.gap(at: [0])]), marker)
    }

    func test_assemble_matchesTheOldCountDrivenSynthesis() {
        // AE2's second half, stated as an equality rather than a claim:
        // the shape the row used to synthesise from `failedChunkCount` is
        // byte-for-byte what the sequence renders. A different join here
        // (newlines, `joined()`, no spaces) makes this red — and would
        // have visibly reflowed every all-failed row on upgrade.
        for count in 1...4 {
            let segments = (0..<count).map { HistoryEntry.Segment.gap(at: [$0]) }
            XCTAssertEqual(
                HistoryText.assemble(segments),
                TextInjector.stitchChunks(Array(repeating: marker, count: count))
            )
        }
    }

    func test_assemble_aGateFilteredSegmentContributesNothingAndNoMarker() {
        // R19 / R27 at the render layer: `""` is text, so it neither
        // renders a marker nor makes the row broken.
        let segments: [HistoryEntry.Segment] = [
            .carrying("Ship it.", at: [0]),
            .carrying("", at: [1]),
            .carrying("Review after.", at: [2]),
        ]
        XCTAssertEqual(HistoryText.assemble(segments), "Ship it. Review after.")
        XCTAssertFalse(HistoryText.assemble(segments).contains(marker))
    }

    func test_assemble_trimsTheEnds_soALeadingGapDoesNotRenderLeadingSpace() {
        XCTAssertEqual(
            HistoryText.assemble([.carrying("  ", at: [0]), .gap(at: [1])]),
            marker
        )
    }

    func test_assemble_ofALegacyMigratedRow_reproducesWhatItLookedLikeBefore() {
        // AE5 at the render layer. R12 turns a stored string plus a count
        // into positions; assembling those positions has to hand the
        // string back. Only a round-trip checks that, and this is the
        // half U5 could not assert because nothing assembled yet.
        //
        // Markers survive → byte-identical, both partial and all-gap.
        for text in ["Ship it by \(marker) and review after.", "\(marker) \(marker)"] {
            let count = text.components(separatedBy: marker).count - 1
            XCTAssertEqual(
                HistoryText.assemble(Self.legacyRow(text: text, failedChunkCount: count).segments),
                text
            )
        }

        // A `[…]` the user dictated, with a count of zero: one text
        // segment, verbatim, not broken. The marker is never looked for
        // on that arm.
        let dictated = Self.legacyRow(text: "He said \(marker) and left.", failedChunkCount: 0)
        XCTAssertEqual(HistoryText.assemble(dictated.segments), "He said \(marker) and left.")
        XCTAssertFalse(dictated.isBroken)

        // Empty text plus a count: that many gaps, which renders as the
        // markers the row used to synthesise.
        XCTAssertEqual(
            HistoryText.assemble(Self.legacyRow(text: "", failedChunkCount: 3).segments),
            "\(marker) \(marker) \(marker)"
        )

        // **The row the whole plan exists for**: a replacement pair
        // erased the marker before it was stored, so migration appended a
        // gap to match the count. It renders with the gap restored and
        // stays visibly broken — where the shipped build showed an intact
        // sentence with a hidden retry button.
        let rewritten = Self.legacyRow(text: "Ship it and review after.", failedChunkCount: 1)
        XCTAssertEqual(
            HistoryText.assemble(rewritten.segments),
            "Ship it and review after. \(marker)"
        )
        XCTAssertTrue(rewritten.isBroken)
    }

    // MARK: - Replacement pairs at render time (R5, AE1, AE7)

    func test_rendered_appliesTheUsersCurrentPairs() {
        let entry = Self.row([.carrying("kubernetes is fine", at: [0])])
        XCTAssertEqual(
            HistoryText.rendered(
                entry,
                replacements: [DictionaryReplacement(from: "kubernetes", to: "Kubernetes")]
            ),
            "Kubernetes is fine"
        )
    }

    func test_rendered_aPairOnTheEllipsisRestylesTheGap_andCannotDeleteIt() {
        // **AE1.** This is the defect. `TextReplacementEngine`'s Unicode
        // boundary matches the `…` inside `[…]` — brackets are neither
        // letters nor numbers — so a pair as ordinary as `…` → `...` used
        // to erase every marker from the *stored* row, and with it the
        // retry action. Substitution now runs downstream of assembly, so
        // it can only change how the gap looks.
        let entry = Self.row([.carrying("Ship it", at: [0]), .gap(at: [1])])
        let pairs = [DictionaryReplacement(from: "…", to: "...")]

        XCTAssertEqual(HistoryText.rendered(entry, replacements: pairs), "Ship it [...]")
        XCTAssertTrue(entry.isBroken, "the position survived the substitution")
        XCTAssertEqual(entry.failedChunkCount, 1)
    }

    func test_rendered_aPairSpanningAChunkSeamStillMatches() {
        // The other half of KD2's reason for rendering late: per-chunk
        // substitution at write time would never see this phrase, because
        // it exists only in the assembled whole.
        let entry = Self.row([
            .carrying("machine", at: [0]),
            .carrying("learning is fun", at: [1]),
        ])
        XCTAssertEqual(
            HistoryText.rendered(
                entry,
                replacements: [DictionaryReplacement(from: "machine learning", to: "ML")]
            ),
            "ML is fun"
        )
    }

    func test_rendered_removingAPairChangesHowAStoredRowReads() {
        // **AE7.** The user edits their dictionary; rows already on disk
        // re-read. This is only possible because the segments are raw
        // (R2) and the pass is at render time.
        let entry = Self.row([.carrying("то есть, it works", at: [0])])
        let pairs = [DictionaryReplacement(from: "то есть", to: "т.е.")]

        XCTAssertEqual(HistoryText.rendered(entry, replacements: pairs), "т.е., it works")
        XCTAssertEqual(
            HistoryText.rendered(entry, replacements: []),
            "то есть, it works",
            "deleting the pair restores the original — nothing was removed from disk (R31)"
        )
    }

    func test_rendered_leavesTheStoredRowUntouched() {
        // R31, as a present-tense property rather than a promise:
        // display-time substitution is presentation-only. `history.json`
        // keeps the pre-replacement text, which is *why* deleting a pair
        // can restore the original.
        let entry = Self.row([.carrying("kubernetes", at: [0])])
        _ = HistoryText.rendered(
            entry,
            replacements: [DictionaryReplacement(from: "kubernetes", to: "Kubernetes")]
        )
        XCTAssertEqual(entry.segments.first?.text, "kubernetes")
    }

    func test_rendered_ignoresTheLegacyTextMirror() {
        // The mirror is written for a rollback (KTD10) and read by
        // nothing here. Two rows with the same sequence render the same
        // string whatever their `text` says.
        let segments: [HistoryEntry.Segment] = [.carrying("kept", at: [0]), .gap(at: [1])]
        XCTAssertEqual(
            HistoryText.rendered(Self.row(segments, text: "one thing"), replacements: []),
            HistoryText.rendered(Self.row(segments, text: "something else"), replacements: [])
        )
    }

    // MARK: - Word counts keep their meaning (R14, KD6, AE8)

    func test_wordCount_isTakenFromTheRenderedString_notTheRawSegments() async throws {
        // **AE8.** A pair that expands an abbreviation must move the count
        // exactly as it does today, when the stored string was already
        // post-replacement. Counting the raw segments instead would
        // silently re-base every lifetime total on the first such pair.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = StatsStore(url: dir.appendingPathComponent("stats.json"))

        let entry = Self.row([.carrying("ML rocks", at: [0])])
        let pairs = [DictionaryReplacement(from: "ML", to: "machine learning")]
        let rendered = HistoryText.rendered(entry, replacements: pairs)
        XCTAssertEqual(rendered, "machine learning rocks", "fixture check")

        let snap = await store.record(entry, text: rendered, tokens: .zero)
        XCTAssertEqual(snap.totalWords, 3)
        XCTAssertNotEqual(
            snap.totalWords,
            StatsStore.wordCount(HistoryText.assemble(entry.segments)),
            "counting the raw segments would have recorded 2 — the parameter is load-bearing"
        )
    }

    func test_wordCount_isUnmovedByInsertionNormalisation() {
        // The assembled row and the pasted string can differ by a leading
        // space or a stripped sentence-final period — `finalizeForInsertion`
        // decides those from the *cursor's* surroundings. Neither moves a
        // whitespace-split count, which is what lets AE8 hold across the
        // change in what gets counted.
        XCTAssertEqual(
            StatsStore.wordCount("Ship it by Friday."),
            StatsStore.wordCount(" Ship it by Friday")
        )
    }

    // MARK: - The harvester keeps the pasted string (R15)
    //
    // `RecordingSession.stop()` and `AppState.finalizeRecording` both need
    // a live session — an `AudioRecorder`, a `SileroVAD`, a `GeminiClient`
    // and a `HistoryStore` — so no test drives either. The channel is
    // therefore pinned in the source-scan shape
    // `RecordingSessionFocusGuardTests` and `AppStateFocusNoticeTests`
    // already use, with the same limits: it reads text, not the built
    // configuration, and a rename fails it loudly rather than silently.

    func test_theSummaryCarriesTheFinalizedTranscript_andDefaultsToEmpty() {
        // The field exists and defaults, which is what KTD7's channel
        // requires of a new fact: existing call sites keep compiling.
        XCTAssertEqual(
            RecordingSession.SessionSummary(
                failedChunkCount: 0, dispatchedChunkCount: 1, tokens: .zero, model: .flashLite
            ).finalizedTranscript,
            ""
        )
        XCTAssertEqual(
            RecordingSession.SessionSummary(
                failedChunkCount: 0,
                dispatchedChunkCount: 1,
                tokens: .zero,
                model: .flashLite,
                finalizedTranscript: "what the user said"
            ).finalizedTranscript,
            "what the user said"
        )
    }

    func test_stop_recordsTheFinalizedTranscriptOnTheSession() throws {
        let body = try XCTUnwrap(
            Self.body(ofFuncNamed: "stop", in: Self.source("NoType/Recording/RecordingSession.swift")),
            "Could not parse stop() — the guard lost its anchor."
        )
        XCTAssertTrue(
            body.contains("finalizedTranscript = final"),
            "stop() no longer records the string it pasted, so `SessionSummary.finalizedTranscript` "
            + "stays empty and the harvester silently learns nothing (R15)."
        )
        // Before the paste gate, not after: the withheld arm produced a
        // real transcript too, and a session whose paste was withheld
        // still harvests.
        let recordAt = try XCTUnwrap(body.range(of: "finalizedTranscript = final"))
        let gateAt = try XCTUnwrap(body.range(of: "shouldWithholdPaste("))
        XCTAssertLessThan(
            recordAt.lowerBound, gateAt.lowerBound,
            "the transcript is recorded after the paste gate — a withheld session would harvest nothing"
        )
        XCTAssertFalse(
            body.contains("#if"),
            "stop() grew a conditional-compilation block. The scan matches text, not the built "
            + "configuration, so an assignment inside `#if DEBUG` reads as present here and is "
            + "absent from the release binary. Re-derive this guard before adding one."
        )
    }

    func test_finalizeRecording_countsTheWordsTheRowShows_notTheRawSegments() throws {
        // R13 / R14 at the *production wiring*, which is otherwise
        // unpinned in either direction. `finalizeRecording` cannot be
        // driven in a test, and the only live-`AppState` test that reaches
        // the other stats call site runs with an empty pair list — so a
        // one-token regression to `replacements: []` here, or a slip back
        // onto the no-`text:` shim, compiles clean and leaves the whole
        // suite green while lifetime totals silently stop following the
        // user's dictionary. Same shape and same limits as the R15 scan
        // above.
        let body = try XCTUnwrap(
            Self.body(ofFuncNamed: "finalizeRecording", in: Self.source("NoType/AppState.swift")),
            "Could not parse finalizeRecording() — the guard lost its anchor."
        )
        // **Scoped to the counting statement, not the whole body — the
        // needle matches twice.** `finalizeRecording` also passes
        // `replacements: self.dictionaryReplacements` to
        // `noticeForFinishedSession` about forty lines earlier, so a
        // whole-body `contains` is satisfied by the notice's use alone and
        // stays green when the *counter* drops the live list. Measured,
        // not reasoned about: mutating the counter's argument to `[]` left
        // an earlier version of this test passing. So extract the region
        // from the assignment to the store call and assert inside it.
        let countedAt = try XCTUnwrap(
            body.range(of: "let countedText"),
            "finalizeRecording no longer computes a counted string — an absence-only scan would be green on a method that stopped counting altogether"
        )
        let recordAt = try XCTUnwrap(
            body.range(of: "statsStore.record("),
            "finalizeRecording no longer folds the session into lifetime stats at all"
        )
        XCTAssertLessThan(
            countedAt.lowerBound, recordAt.lowerBound,
            "the counted string is computed after the store call — it cannot be what was counted"
        )
        let countingStatement = String(body[countedAt.lowerBound..<recordAt.lowerBound])
        XCTAssertTrue(
            countingStatement.contains("HistoryText.rendered("),
            "the counted string is not the assembled, replacement-applied row (R13 / R14)"
        )
        XCTAssertTrue(
            countingStatement.contains("replacements: self.dictionaryReplacements"),
            "the counted string is built from something other than the live pair mirror (R13 / R14). "
            + "A frozen or empty list makes lifetime word counts stop following the user's dictionary."
        )
        // Presence is not destination: the render has to reach the store.
        XCTAssertTrue(
            body.contains("text: countedText"),
            "the rendered string is computed and not handed to StatsStore — the counter is back on "
            + "whatever `record` assembles for itself, which applies no replacement pairs"
        )
        XCTAssertFalse(
            body.contains("record(entry, tokens:"),
            "finalizeRecording calls the no-`text:` shim, which assembles with no pairs applied. "
            + "That overload exists for the test surface; the production path must pass `text:`."
        )
    }

    func test_noProductionCallerReachesTheNoReplacementsStatsOverloads() throws {
        // `StatsStore.record(_:tokens:model:)` and `record(_:)` assemble
        // the row themselves and count it with **no pairs applied**. Their
        // own doc-comment says that is "right for a test surface that has
        // none and wrong for production" — but Swift resolves overloads on
        // the argument list alone, so a future call site that writes the
        // shorter, older-looking form compiles and silently mis-counts.
        // Nothing but this guard stands between the two.
        for path in ["NoType/AppState.swift"] {
            let source = Self.strippingComments(try Self.source(path))
            XCTAssertTrue(
                source.contains("statsStore.record("),
                "\(path) no longer records stats at all — an absence-only scan is green on that"
            )
            XCTAssertFalse(
                source.contains("statsStore.record(entry, tokens:")
                    || source.contains("statsStore.record(updated, tokens:"),
                "\(path) reaches a StatsStore.record overload that applies no replacement pairs. "
                + "Lifetime word counts would stop following the user's dictionary with no test failure."
            )
        }
    }

    func test_finalizeRecording_feedsTheHarvesterThePastedString_notTheRow() throws {
        let body = try XCTUnwrap(
            Self.body(ofFuncNamed: "finalizeRecording", in: Self.source("NoType/AppState.swift")),
            "Could not parse finalizeRecording() — the guard lost its anchor."
        )
        XCTAssertTrue(
            body.contains("harvestDictionaryIfRoom("),
            "finalizeRecording no longer harvests at all — an absence-only scan below would be green on that"
        )
        XCTAssertTrue(
            body.contains("sessionSummary.finalizedTranscript"),
            "the harvester is fed something other than the finalized pasted string (R15). "
            + "The assembled row carries the user's *current* pairs and no insertion normalisation, "
            + "so harvesting from it changes which terms are learned."
        )
        XCTAssertFalse(
            body.contains("transcript: entry.text"),
            "the harvester reads the legacy mirror again — it is the pasted string only by accident now"
        )
        XCTAssertFalse(
            body.contains("#if"),
            "finalizeRecording grew a conditional-compilation block. The scan matches text, not the "
            + "built configuration, so a call inside `#if DEBUG` reads as present here and is absent "
            + "from the release binary. Re-derive this guard before adding one."
        )
    }

    func test_bodyExtractor_isScopedToTheNamedFunction() throws {
        // Without this, an extractor that silently matched the whole file
        // would pass the guards above on a function that had lost the
        // wiring entirely.
        let source = """
        private func other() {
            finalizedTranscript = final
        }

        func stop() async throws -> HistoryEntry {
            let marker = 1
        }
        """
        let body = try XCTUnwrap(Self.body(ofFuncNamed: "stop", in: source))
        XCTAssertTrue(body.contains("let marker = 1"))
        XCTAssertFalse(
            body.contains("finalizedTranscript = final"),
            "The extractor ran past its function — the presence assertion would be satisfiable by a neighbouring one."
        )
    }

    func test_commentStripping_hidesDisabledCodeAndProse() {
        // The complement to the extractor fixture above: scoping the scan
        // to one function is worth nothing if a commented-out line inside
        // that function still satisfies it.
        let stripped = Self.strippingComments("""
        // finalizedTranscript = final
        let kept = 1  /* transcript: entry.text */
        let feed = "https://weylandd.github.io/NoType/appcast.xml"
        """)
        XCTAssertFalse(
            stripped.contains("finalizedTranscript = final"),
            "A commented-out assignment still matched — the R15 presence guard would pass on a stop() where the wiring was disabled."
        )
        XCTAssertFalse(
            stripped.contains("transcript: entry.text"),
            "A block comment survived. `finalizeRecording`'s own prose names `entry.text` while explaining why the harvester must not read it, so the absence assertion would fail on the comment rather than on a regression."
        )
        XCTAssertTrue(stripped.contains("let kept = 1"))
        XCTAssertTrue(
            stripped.contains("https://weylandd.github.io/NoType/appcast.xml"),
            "A URL literal's `//` was read as a comment. Truncating a line is how an absence assertion passes for the wrong reason."
        )
    }

    // MARK: - Fixtures

    private static func row(
        _ segments: [HistoryEntry.Segment],
        text: String = "LEGACY MIRROR — NOT WHAT THIS ROW SAYS"
    ) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(),
            durationSeconds: 12,
            segments: segments
        )
    }

    /// A row described the pre-sequence way, whose sequence R12 derives.
    private static func legacyRow(text: String, failedChunkCount: Int) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(),
            durationSeconds: 12,
            failedChunkCount: failedChunkCount
        )
    }

    // MARK: - Extractor
    //
    // Duplicated rather than shared, following the precedent
    // `AppStateFocusNoticeTests` records against
    // `SplitRetryNetworkBoundTests`: each guard owns its extractor and its
    // own fidelity fixture, so tightening one cannot quietly change what
    // another proves. Naive about braces inside string literals and
    // comments, which is acceptable for the two functions it reads.

    private static func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return strippingComments(
            try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        )
    }

    /// Comments removed before any needle runs, matching what
    /// `AppStateFocusNoticeTests` and `RecordingSessionFocusGuardTests`
    /// already do to the same two files.
    ///
    /// Without it every assertion here is decided by prose. The presence
    /// needles would be satisfiable by a *commented-out* call — the exact
    /// shape of a call disabled during debugging and never restored — and
    /// the absence needles are worse: `finalizeRecording`'s own comments
    /// name `entry.text` while explaining why the harvester must not read
    /// it, so `XCTAssertFalse(body.contains("transcript: entry.text"))` was
    /// one comment edit away from failing for a reason that is not a
    /// regression. Duplicated rather than shared, per this file's
    /// documented precedent: each guard owns its extractor and its own
    /// fidelity fixture.
    private static func strippingComments(_ source: String) -> String {
        // The sentinel must not itself contain `//`, or the line pass
        // below truncates every URL literal at the scheme.
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

    private static func body(ofFuncNamed name: String, in source: String) -> String? {
        guard let decl = source.range(of: "func \(name)(") else { return nil }
        guard let open = source.range(of: "{", range: decl.upperBound..<source.endIndex) else {
            return nil
        }
        var depth = 0
        var i = open.lowerBound
        while i < source.endIndex {
            switch source[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[open.upperBound..<i])
                }
            default: break
            }
            i = source.index(after: i)
        }
        return nil
    }
}
