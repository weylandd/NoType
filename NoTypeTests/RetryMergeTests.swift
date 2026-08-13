import XCTest
@testable import NoType

/// Pins the pure gap-slot merge a retry lands its results through (R7, R10,
/// R11).
///
/// Every fixture gives each chunk a **distinct** text and a **distinct**
/// index. That is not decoration: a merge defect that mis-orders, compacts,
/// or drops a slot is invisible against a fixture whose elements are equal,
/// and the whole point of the index write is that it survives an order the
/// caller did not sort.
final class RetryMergeTests: XCTestCase {

    private typealias Segment = HistoryEntry.Segment
    private typealias Outcome = RetryMerge.ChunkOutcome

    /// Sugar so a fixture reads as the response sequence it is.
    private func text(_ s: String, _ indices: Int...) -> Segment {
        .carrying(s, at: indices)
    }

    private func gap(_ indices: Int...) -> Segment {
        .gap(at: indices)
    }

    // MARK: - Writing by index (AE3, R7)

    func test_merge_writesEachRecoveryIntoTheGapAtItsOwnIndex() {
        // The row pasted with gaps at chunks 1 and 3; both come back.
        let segments = [text("Ship it by", 0), gap(1), text("and review", 2), gap(3), text("after.", 4)]

        let merged = RetryMerge.merge(
            into: segments,
            outcomes: [
                Outcome(chunkIndex: 1, text: "the tenth"),
                Outcome(chunkIndex: 3, text: "the draft")
            ]
        )

        XCTAssertEqual(
            merged.segments,
            [
                text("Ship it by", 0),
                text("the tenth", 1),
                text("and review", 2),
                text("the draft", 3),
                text("after.", 4)
            ]
        )
        XCTAssertEqual(merged.placed, [true, true])
        XCTAssertFalse(merged.segments.contains(where: \.isGap), "no gap left")
    }

    func test_merge_onlyTheLaterGapRecovers_theEarlierOneStays() {
        // AE3, stated exactly: gaps at 1 and 4, and the *later* one is the
        // one that came back. A positional left-to-right merge writes
        // "FOURTH" into chunk 1.
        let segments = [text("alpha", 0), gap(1), text("beta", 2), text("gamma", 3), gap(4)]

        let merged = RetryMerge.merge(
            into: segments,
            outcomes: [Outcome(chunkIndex: 1, text: nil), Outcome(chunkIndex: 4, text: "FOURTH")]
        )

        XCTAssertEqual(
            merged.segments,
            [text("alpha", 0), gap(1), text("beta", 2), text("gamma", 3), text("FOURTH", 4)]
        )
        XCTAssertEqual(merged.placed, [false, true])
    }

    func test_merge_isIndependentOfTheOrderTheOutcomesArriveIn() {
        // R11. The retry loop's stop rule and its iteration order are
        // properties of the loop, not of the data. Reversing the outcomes
        // must change nothing.
        let segments = [gap(0), text("middle", 1), gap(2), gap(3)]
        // Deliberately asymmetric, so `reversed.placed` is not trivially
        // equal to `forward.placed` and the assertion has something to say.
        let outcomes = [
            Outcome(chunkIndex: 0, text: "ZERO"),
            Outcome(chunkIndex: 2, text: "TWO"),
            Outcome(chunkIndex: 3, text: nil)
        ]

        let forward = RetryMerge.merge(into: segments, outcomes: outcomes)
        let reversed = RetryMerge.merge(into: segments, outcomes: Array(outcomes.reversed()))

        XCTAssertEqual(
            forward.segments,
            [text("ZERO", 0), text("middle", 1), text("TWO", 2), gap(3)]
        )
        XCTAssertEqual(reversed.segments, forward.segments, "the row does not depend on arrival order")
        XCTAssertEqual(forward.placed, [true, true, false])
        XCTAssertEqual(
            reversed.placed,
            [false, true, true],
            "each flag still describes its own outcome, wherever it sat in the list"
        )
    }

    func test_merge_remainingGapsAreExactlyTheChunksThatDidNotRecover() {
        // R11 as a set property rather than a shape assertion: the gaps
        // left cover the unrecovered indices and nothing else, so nobody
        // has to decrement a count to find them.
        let segments = [gap(0), gap(1), text("kept", 2), gap(3), gap(4)]

        let merged = RetryMerge.merge(
            into: segments,
            outcomes: [
                Outcome(chunkIndex: 0, text: nil),
                Outcome(chunkIndex: 1, text: "ONE"),
                Outcome(chunkIndex: 3, text: nil),
                Outcome(chunkIndex: 4, text: "FOUR")
            ]
        )

        let remainingGaps = Set(merged.segments.filter(\.isGap).flatMap(\.chunkIndices))
        XCTAssertEqual(remainingGaps, [0, 3])
    }

    // MARK: - A gap covering several chunks (R7)

    func test_merge_multiIndexGap_splitsWhenOnlySomeOfItsChunksRecover() {
        // One Gemini call can answer for several chunks, so a gap is not
        // always one position. When the middle one recovers, the segment
        // has to split around it.
        let segments = [text("head", 0), gap(1, 2, 3), text("tail", 4)]

        let merged = RetryMerge.merge(
            into: segments,
            outcomes: [Outcome(chunkIndex: 2, text: "MIDDLE")]
        )

        XCTAssertEqual(
            merged.segments,
            [text("head", 0), gap(1), text("MIDDLE", 2), gap(3), text("tail", 4)]
        )
        XCTAssertEqual(merged.placed, [true])
    }

    func test_merge_multiIndexGap_keepsUnrecoveredRunsGrouped_soTheMarkerCountIsStable() {
        // `HistoryText.assemble` emits one `[…]` per gap *segment*, so
        // splitting a run that did not recover would silently multiply the
        // markers the user sees. Chunk 3 recovers; 1 and 2 stay one gap.
        let segments = [gap(1, 2, 3, 4)]

        let merged = RetryMerge.merge(
            into: segments,
            outcomes: [Outcome(chunkIndex: 3, text: "THIRD")]
        )

        XCTAssertEqual(merged.segments, [gap(1, 2), text("THIRD", 3), gap(4)])
        XCTAssertEqual(
            HistoryText.assemble(merged.segments),
            "\(RecordingSession.failureMarker) THIRD \(RecordingSession.failureMarker)",
            "two markers where the sequence has two gap segments — not four"
        )
    }

    func test_merge_multiIndexGap_everyChunkRecovers_becomesOneSegmentPerChunk() {
        let segments = [gap(0, 1)]

        let merged = RetryMerge.merge(
            into: segments,
            outcomes: [
                Outcome(chunkIndex: 0, text: "ZERO"),
                Outcome(chunkIndex: 1, text: "ONE")
            ]
        )

        XCTAssertEqual(merged.segments, [text("ZERO", 0), text("ONE", 1)])
        XCTAssertEqual(merged.placedCount, 2)
    }

    // MARK: - What counts as a recovery

    func test_merge_emptyAnswer_leavesItsGapInPlace() {
        // Gemini answered with nothing, or the hallucination gate dropped
        // the answer. Writing `""` would turn a visible hole into a
        // silently shortened sentence and release the audio for it.
        let segments = [gap(0), text("kept", 1), gap(2)]

        let merged = RetryMerge.merge(
            into: segments,
            outcomes: [Outcome(chunkIndex: 0, text: ""), Outcome(chunkIndex: 2, text: "TWO")]
        )

        XCTAssertEqual(merged.segments, [gap(0), text("kept", 1), text("TWO", 2)])
        XCTAssertEqual(merged.placed, [false, true])
    }

    func test_merge_whitespaceOnlyAnswer_isNotARecovery() {
        let segments = [gap(0)]

        let merged = RetryMerge.merge(
            into: segments,
            outcomes: [Outcome(chunkIndex: 0, text: "   \n ")]
        )

        XCTAssertEqual(merged.segments, segments)
        XCTAssertEqual(merged.placed, [false])
    }

    func test_merge_trimsTheRecoveredText_soTheStitchedSeamSurvives() {
        // `HistoryText.assemble` re-derives the seam spacing from
        // `TextInjector.stitchChunks`; a recovery bringing its own padding
        // would render a double space at the join.
        let merged = RetryMerge.merge(
            into: [text("one", 0), gap(1), text("two", 2)],
            outcomes: [Outcome(chunkIndex: 1, text: "  MIDDLE  ")]
        )

        XCTAssertEqual(merged.segments[1], text("MIDDLE", 1))
        XCTAssertEqual(HistoryText.assemble(merged.segments), "one MIDDLE two")
    }

    func test_merge_nothingRecovered_returnsTheSequenceUntouched() {
        let segments = [text("one", 0), gap(1), gap(2)]

        XCTAssertEqual(
            RetryMerge.merge(
                into: segments,
                outcomes: [Outcome(chunkIndex: 1, text: nil), Outcome(chunkIndex: 2, text: nil)]
            ).segments,
            segments
        )
        XCTAssertEqual(RetryMerge.merge(into: segments, outcomes: []).segments, segments)
    }

    func test_isRecovery_matrix() {
        XCTAssertTrue(RetryMerge.isRecovery("text"))
        XCTAssertFalse(RetryMerge.isRecovery(nil), "not attempted, or the call failed")
        XCTAssertFalse(RetryMerge.isRecovery(""), "Gemini answered with nothing")
        XCTAssertFalse(RetryMerge.isRecovery("  \t\n "), "whitespace is not text")
    }

    // MARK: - Raw storage (R9)

    func test_merge_storesTheRecoveredTextRaw_notSubstituted() {
        // R9 / AE4 at this layer: the merge must not apply the user's
        // pairs. It has no pair list and must never grow one — substitution
        // happens downstream, in `HistoryText.rendered`, which is what
        // makes editing a pair change how an already-stored row reads.
        let merged = RetryMerge.merge(
            into: [gap(0)],
            outcomes: [Outcome(chunkIndex: 0, text: "we deploy kubernetes weekly")]
        )

        XCTAssertEqual(merged.segments, [text("we deploy kubernetes weekly", 0)])
        XCTAssertEqual(
            HistoryText.rendered(
                merged.segments,
                replacements: [DictionaryReplacement(from: "kubernetes", to: "Kubernetes")]
            ),
            "we deploy Kubernetes weekly",
            "the pair reaches it at render, because storage kept the raw form"
        )
    }

    // MARK: - Placement (what the caller may release audio for)

    func test_placed_recoveryWhoseIndexHasNoGap_isNotPlaced() {
        // The data-loss shape, in the form that survives the index write: a
        // payload out of step with its row — a chunk whose position the row
        // already carries text for. There is nowhere to write it, so it
        // must be reported unplaced or the settle path frees the only copy
        // of the audio AND discards the recovered text.
        let segments = [text("already recovered", 0), gap(1)]

        let merged = RetryMerge.merge(
            into: segments,
            outcomes: [Outcome(chunkIndex: 0, text: "the tenth")]
        )

        XCTAssertEqual(merged.segments, segments, "nothing to write into")
        XCTAssertEqual(merged.placed, [false], "so the chunk did NOT land")
        XCTAssertEqual(merged.placedCount, 0)
    }

    func test_placed_recoveryForAnIndexTheRowDoesNotCoverAtAll_isNotPlaced() {
        let merged = RetryMerge.merge(
            into: [gap(0)],
            outcomes: [
                Outcome(chunkIndex: 0, text: "ZERO"),
                Outcome(chunkIndex: 9, text: "STRAY")
            ]
        )

        XCTAssertEqual(merged.segments, [text("ZERO", 0)])
        XCTAssertEqual(merged.placed, [true, false], "the stray chunk's audio must stay held")
    }

    func test_placed_isSizedToTheOutcomes_evenOnANoOp() {
        let merged = RetryMerge.merge(
            into: [gap(0), gap(1)],
            outcomes: [Outcome(chunkIndex: 0, text: nil), Outcome(chunkIndex: 1, text: nil)]
        )

        XCTAssertEqual(merged.placed, [false, false], "one flag per retained chunk")
        XCTAssertEqual(merged.placedCount, 0)
    }

    func test_placed_duplicatedIndex_landsOnceAndReportsTheSecondUnplaced() {
        // No caller produces one — `RetainedRecording.chunks` is one chunk
        // per index — but "first wins" must not become "both released".
        let merged = RetryMerge.merge(
            into: [gap(0)],
            outcomes: [
                Outcome(chunkIndex: 0, text: "FIRST"),
                Outcome(chunkIndex: 0, text: "SECOND")
            ]
        )

        XCTAssertEqual(merged.segments, [text("FIRST", 0)])
        XCTAssertEqual(merged.placed, [true, false])
    }

    func test_merge_emptySequence_isANoOp() {
        let merged = RetryMerge.merge(into: [], outcomes: [Outcome(chunkIndex: 0, text: "X")])

        XCTAssertEqual(merged.segments, [])
        XCTAssertEqual(merged.placed, [false])
    }

    // MARK: - Priors (R10)

    func test_priors_areTheTextCarryingChunks_andAGapContributesNothing() {
        // Mirrors `RecordingSession.currentPriors()`: one prior per
        // text-carrying response, in order. The model is never shown its
        // own failure placeholders, because a prompt containing `[…]`
        // teaches it to emit them.
        let segments = [text("Ship it by", 0), gap(1), text("and review", 2), gap(3), text("after.", 4)]

        XCTAssertEqual(
            RetryMerge.priors(from: segments),
            ["Ship it by", "and review", "after."]
        )
    }

    func test_priors_containNoMarker() {
        let segments = [text("one", 0), gap(1), text("two", 2)]

        for prior in RetryMerge.priors(from: segments) {
            XCTAssertFalse(prior.contains(RecordingSession.failureMarker))
        }
    }

    func test_priors_ofAnAllGapRow_isEmpty() {
        XCTAssertEqual(RetryMerge.priors(from: [gap(0), gap(1)]), [])
        XCTAssertEqual(RetryMerge.priors(from: []), [])
    }

    func test_priors_dropAGateFilteredEmptySegment_butKeepItATextSegment() {
        // R27's third state: `""` is a text segment, not a gap. It has
        // nothing to say to Gemini, so it is not a prior — but it also does
        // not make its row broken, which is `isBroken`'s business, not this
        // function's.
        let segments = [text("kept", 0), text("", 1), text("   ", 2)]

        XCTAssertEqual(RetryMerge.priors(from: segments), ["kept"])
        XCTAssertFalse(segments.contains(where: \.isGap))
    }

    func test_priors_areRaw_soAReplacementPairHasNotTouchedThem() {
        // R10 says raw, and it matters: the retry must send Gemini the same
        // context the original attempt did. A pair applied before this
        // point would send the model a phrase it never transcribed.
        let segments = [text("we deploy kubernetes weekly", 0), gap(1)]

        XCTAssertEqual(RetryMerge.priors(from: segments), ["we deploy kubernetes weekly"])
    }

    // MARK: - Round trip

    func test_merge_outputIsAValidInputToASecondRun() {
        // The two-retry round trip: a partially-recovered row is merged
        // into again, and the second run's write lands in the gap the first
        // one left — at the index it always had, not at an ordinal.
        let afterFirst = RetryMerge.merge(
            into: [gap(0), gap(1), gap(2)],
            outcomes: [
                Outcome(chunkIndex: 0, text: "Hello there"),
                Outcome(chunkIndex: 1, text: nil),
                Outcome(chunkIndex: 2, text: nil)
            ]
        )
        XCTAssertEqual(afterFirst.segments, [text("Hello there", 0), gap(1), gap(2)])

        let afterSecond = RetryMerge.merge(
            into: afterFirst.segments,
            outcomes: [
                Outcome(chunkIndex: 1, text: "how are you"),
                Outcome(chunkIndex: 2, text: "goodbye.")
            ]
        )

        XCTAssertEqual(
            afterSecond.segments,
            [text("Hello there", 0), text("how are you", 1), text("goodbye.", 2)]
        )
        XCTAssertEqual(
            HistoryText.assemble(afterSecond.segments),
            "Hello there how are you goodbye."
        )
    }

    // MARK: - The join this merge rests on

    func test_theJoin_gapPositionsAndRetainedChunkIndices_bothComeFromOneResponseSet() throws {
        // `RetryMerge`'s type-level claim is that
        // `HistoryEntry.Segment.chunkIndices` and
        // `RetainedRecording.Chunk.idx` "are the same number by
        // construction — the session records both from one
        // `ChunkResponse`". Every other test in this file, and every one
        // in `AppStateRetryTests`, *constructs* that agreement in its
        // fixture: it hands `merge` a row and a set of outcomes it wrote
        // to match. So none of them can see the join break.
        //
        // This one derives both sides from a single `[ChunkResponse]`,
        // through the two production functions a session actually uses,
        // and only then drives the pair through the merge.
        // The **first response covers two chunks** — a batched Gemini call,
        // which production produces on every successful batch. That is what
        // makes a response's ordinal differ from its chunks' indices from
        // here on, and it is the whole reason this fixture is shaped this
        // way: with one response per chunk the two are numerically equal
        // and an ordinal-for-index substitution is invisible.
        let responses: [RecordingSession.ChunkResponse] = [
            .init(chunkIndices: [0, 1], text: "Ship it by the tenth"),
            .init(chunkIndices: [2], text: nil),
            // R27's third state, included on purpose: the hallucination
            // gate's `""` is a text segment, so it must contribute no gap
            // and hold back no audio.
            .init(chunkIndices: [3], text: ""),
            .init(chunkIndices: [4], text: nil),
            .init(chunkIndices: [5], text: "after.")
        ]
        let encoded = (0...5).map { idx in
            RetainedRecording.Chunk(
                idx: idx,
                isFinal: idx == 5,
                audio: Data([UInt8(0xA0 + idx)]),
                samples: 16_000
            )
        }

        let segments = RecordingSession.historySegments(from: responses)
        let payload = RecordingSession.retainedPayload(
            inBatch: encoded,
            failedChunkIndices: Set(
                responses.filter { $0.text == nil }.flatMap(\.chunkIndices)
            ),
            context: ContextSnapshot.minimal(
                activeApp: AppInfo(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
            ),
            model: .flashLite
        )
        let held = try XCTUnwrap(payload, "the session lost chunks, so it retains a payload").chunks

        XCTAssertEqual(
            Set(held.map(\.idx)),
            Set(segments.filter(\.isGap).flatMap(\.chunkIndices)),
            "the audio held is keyed by exactly the positions the row stores as gaps"
        )
        XCTAssertEqual(
            Set(held.map(\.idx)),
            [2, 4],
            "and those are the chunk indices, not the ordinals (1 and 3) of the responses that failed"
        )

        // And therefore every held chunk has somewhere to land: no
        // recovery is reported unplaced, so no audio is stranded and no
        // gap survives a run in which every chunk answered.
        let merged = RetryMerge.merge(
            into: segments,
            outcomes: held.map { Outcome(chunkIndex: $0.idx, text: "R\($0.idx)") }
        )

        XCTAssertEqual(merged.placedCount, held.count)
        XCTAssertFalse(merged.segments.contains(where: \.isGap))
        XCTAssertEqual(
            HistoryText.assemble(merged.segments),
            "Ship it by the tenth R2 R4 after.",
            "the batched response's two chunks stay one segment; each recovery lands at its own index"
        )
    }
}
