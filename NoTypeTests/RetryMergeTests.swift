import XCTest
@testable import NoType

/// Pins the pure gap-slot merge a retry lands its results through (R12).
///
/// Every fixture builds its markers from `RecordingSession.failureMarker`
/// rather than spelling `[…]` out, so a change to the marker literal moves
/// the production code and these tests together instead of leaving a suite
/// that passes against a string nothing emits any more.
final class RetryMergeTests: XCTestCase {

    private let marker = RecordingSession.failureMarker

    // MARK: - Marker substitution (AE3)

    func test_merge_twoMarkers_twoRecoveries_leavesNoMarkerBehind() {
        // AE3. The row pasted with gaps; both gaps come back.
        let text = "Ship it by \(marker) and review \(marker) after."

        let merged = RetryMerge.merge(
            existingText: text,
            recovered: ["the tenth", "the draft"]
        )

        XCTAssertEqual(merged, "Ship it by the tenth and review the draft after.")
        XCTAssertFalse(merged.contains(marker), "no gap left")
    }

    func test_merge_fillsMarkersLeftToRight_notInReverse() {
        // The ordering claim, isolated: recovered[0] belongs to the FIRST
        // marker. Distinguishable fillers, so a right-to-left or
        // reversed-zip implementation produces a different string rather
        // than an equally-plausible one.
        let text = "alpha \(marker) beta \(marker) gamma"

        let merged = RetryMerge.merge(existingText: text, recovered: ["ONE", "TWO"])

        XCTAssertEqual(merged, "alpha ONE beta TWO gamma")
    }

    func test_merge_fewerRecoveredChunksThanMarkers_leavesTrailingMarkers() {
        let text = "one \(marker) two \(marker) three \(marker) four"

        let merged = RetryMerge.merge(existingText: text, recovered: ["FIRST"])

        XCTAssertEqual(merged, "one FIRST two \(marker) three \(marker) four")
    }

    func test_merge_unrecoveredSlot_keepsItsOwnMarker_andShiftsNothing() {
        // A `nil` slot must hold its position. If the implementation
        // compacted recoveries onto the leading markers instead, "SECOND"
        // would land in the first gap.
        let text = "one \(marker) two \(marker) three"

        let merged = RetryMerge.merge(existingText: text, recovered: [nil, "SECOND"])

        XCTAssertEqual(merged, "one \(marker) two SECOND three")
    }

    func test_merge_emptyRecovery_leavesItsMarkerInPlace() {
        // Gemini answered with nothing, or the hallucination gate dropped
        // the answer. Substituting `""` would delete the gap and glue the
        // words together — a silently shortened sentence is worse than a
        // visible gap.
        let text = "one \(marker) two \(marker) three"

        let merged = RetryMerge.merge(existingText: text, recovered: ["", "SECOND"])

        XCTAssertEqual(merged, "one \(marker) two SECOND three")
    }

    func test_merge_whitespaceOnlyRecovery_isNotARecovery() {
        let text = "one \(marker) two"

        XCTAssertEqual(
            RetryMerge.merge(existingText: text, recovered: ["   \n "]),
            text
        )
    }

    func test_merge_trimsTheRecoveredText_soTheMarkersSpacingSurvives() {
        // The marker already sits in the slot `stitchChunks` gave the
        // failed chunk, so the replacement must not bring its own padding.
        let text = "one \(marker) two"

        let merged = RetryMerge.merge(existingText: text, recovered: ["  MIDDLE  "])

        XCTAssertEqual(merged, "one MIDDLE two")
    }

    func test_merge_nothingRecovered_returnsTheTextUntouched() {
        // R19's merge-level half: a run that recovered nothing must not
        // rewrite the row at all.
        let text = "one \(marker) two \(marker)"

        XCTAssertEqual(RetryMerge.merge(existingText: text, recovered: [nil, nil]), text)
        XCTAssertEqual(RetryMerge.merge(existingText: text, recovered: []), text)
    }

    func test_merge_rowWithNoMarkers_isUnchanged() {
        // Defensive: a well-formed broken row always has one marker per
        // retained chunk, but a merge that appended leftovers would corrupt
        // a row that somehow had none.
        XCTAssertEqual(
            RetryMerge.merge(existingText: "already whole.", recovered: ["stray"]),
            "already whole."
        )
    }

    // MARK: - The row that never had any text

    func test_merge_emptyText_threeRecoveries_joinsWithTheStitchingRule() {
        // The all-failed session's row. `TextInjector.stitchChunks` is the
        // joiner, so the seam rules are the paste path's, not a second
        // implementation: a space between word and word, none before glue
        // punctuation.
        let merged = RetryMerge.merge(
            existingText: "",
            recovered: ["Ship it by Friday", "then review the draft", ", please."]
        )

        XCTAssertEqual(merged, "Ship it by Friday then review the draft, please.")
    }

    func test_merge_emptyText_partialRecovery_emitsMarkersForTheChunksThatDidNot() {
        // Load-bearing: without the markers the row would carry recovered
        // text and hold audio for chunks with nowhere to land, and the next
        // retry would have no slots to index. With them, the row lands in
        // exactly the shape a partially-failed session produces.
        let merged = RetryMerge.merge(
            existingText: "",
            recovered: ["Hello there", nil, nil]
        )

        XCTAssertEqual(merged, "Hello there \(marker) \(marker)")
    }

    func test_merge_emptyText_thenASecondRetryFillsTheMarkersItLeft() {
        // The two-retry round trip of AE9, at the merge level: the output
        // of the first run is a valid input to the second.
        let afterFirst = RetryMerge.merge(existingText: "", recovered: ["Hello there", nil, nil])
        let afterSecond = RetryMerge.merge(
            existingText: afterFirst,
            recovered: ["how are you", "goodbye."]
        )

        XCTAssertEqual(afterSecond, "Hello there how are you goodbye.")
    }

    func test_merge_whitespaceOnlyExistingText_takesTheEmptyBranch() {
        XCTAssertEqual(
            RetryMerge.merge(existingText: "   ", recovered: ["Hello"]),
            "Hello"
        )
    }

    // MARK: - isRecovery / recoveredCount

    func test_isRecovery_matrix() {
        XCTAssertTrue(RetryMerge.isRecovery("text"))
        XCTAssertFalse(RetryMerge.isRecovery(nil), "not attempted, or the call failed")
        XCTAssertFalse(RetryMerge.isRecovery(""), "Gemini answered with nothing")
        XCTAssertFalse(RetryMerge.isRecovery("  \t\n "), "whitespace is not text")
    }

    func test_recoveredCount_countsOnlyRealRecoveries() {
        XCTAssertEqual(RetryMerge.recoveredCount(["a", nil, "", "b", "   "]), 2)
        XCTAssertEqual(RetryMerge.recoveredCount([]), 0)
    }

    // MARK: - Priors (KTD6)

    func test_priors_dropTheMarkersAndTheEmptyRuns() {
        // Mirrors `RecordingSession.currentPriors()`: the model is never
        // shown its own failure placeholders, because a prompt containing
        // `[…]` teaches it to emit them.
        let text = "Ship it by \(marker) and review \(marker) after."

        XCTAssertEqual(
            RetryMerge.priors(from: text),
            ["Ship it by", "and review", "after."]
        )
    }

    func test_priors_ofAMarkersOnlyText_isEmpty() {
        XCTAssertEqual(RetryMerge.priors(from: "\(marker) \(marker)"), [])
        XCTAssertEqual(RetryMerge.priors(from: ""), [])
    }

    func test_priors_containNoMarker() {
        let text = "one \(marker) two"
        for prior in RetryMerge.priors(from: text) {
            XCTAssertFalse(prior.contains(marker))
        }
    }
}
