import XCTest
@testable import NoType

/// Pins the retry orchestration: what a run does to the row, to the
/// retained-audio holder, and to lifetime stats (R7–R11, R15, R16, R19).
///
/// Every test drives `AppState.retryChunkSender`, the injected stand-in for
/// the per-chunk Gemini call. That seam is the whole reason these
/// properties are testable: each of them — KTD7's stats split, R16's
/// stop-at-first-failure, R19's leave-everything-alone — is only observable
/// across a *sequence* of per-chunk outcomes, and there is no way to author
/// that sequence against a live network.
///
/// **Rows are described as response sequences, never as a string plus a
/// count.** `Fixture.appendRow(_:)` takes one answer per chunk (`nil` for a
/// gap) and hands the payload exactly the indices those gaps carry, because
/// the join between `HistoryEntry.Segment.chunkIndices` and
/// `RetainedRecording.Chunk.idx` is what a retry writes by (R7). A fixture
/// that let the two drift — as a marker-parsed row does, whose positions
/// are ordinals of the parse — would be testing a row no session produces.
/// Every chunk gets a distinct answer for the same reason.
///
/// The `RetryMerge` half (which text lands where) is pinned separately by
/// `RetryMergeTests`; what is pinned here is everything around it.
@MainActor
final class AppStateRetryTests: XCTestCase {

    private let marker = RecordingSession.failureMarker

    // MARK: - In-flight state (AE7, R13)

    func test_retry_publishesInFlightState_beforeTheFirstRequestIsIssued() async {
        // AE7. Both surfaces read `retryingEntryID`, so it has to be set
        // before the first `await` — not after the run returns.
        let fx = Fixture(self)
        let row = fx.appendRow([nil], text: "")

        var seenAtFirstRequest: UUID??
        fx.state.retryChunkSender = { [state = fx.state] _, _, _, _ in
            seenAtFirstRequest = state.retryingEntryID
            return ("recovered", .zero)
        }

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(
            seenAtFirstRequest ?? nil,
            row.id,
            "the row is already marked in flight when the first request goes out"
        )
        XCTAssertNil(fx.state.retryingEntryID, "and cleared once the run settles")
    }

    func test_retry_whileInFlight_refusesASecondRunOnAnyRow() async {
        // The double-tap guard. `StatsStore.record` is non-idempotent, so a
        // second run reaching the never-counted branch would count the
        // session twice and re-spend the user's Gemini budget.
        let fx = Fixture(self)
        let first = fx.appendRow([nil], text: "")
        let second = fx.appendRow([nil], text: "")

        var reentrantCalls = 0
        fx.state.retryChunkSender = { [state = fx.state] _, _, _, _ in
            // Mid-run: neither row may start another one.
            XCTAssertFalse(state.canRetry(entryID: first.id))
            XCTAssertFalse(state.canRetry(entryID: second.id))
            await state.retryEntry(id: second.id)
            reentrantCalls += 1
            return ("recovered", .zero)
        }

        await fx.state.retryEntry(id: first.id)

        XCTAssertEqual(reentrantCalls, 1, "the re-entrant call issued no request of its own")
        XCTAssertEqual(fx.row(second.id)?.failedChunkCount, 1, "the second row is untouched")
        XCTAssertNotNil(fx.store.peek(second.id), "and still holds its audio")
    }

    func test_retry_isRefusedWhileASessionIsActive() async {
        // R14 / AE6, at the entry point rather than the predicate.
        let fx = Fixture(self)
        let row = fx.appendRow([nil], text: "")
        fx.state.recordingState = .sending

        var requests = 0
        fx.state.retryChunkSender = { _, _, _, _ in
            requests += 1
            return ("recovered", .zero)
        }

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(requests, 0)
        XCTAssertEqual(fx.row(row.id)?.segments, row.segments, "the row's sequence is untouched")
        XCTAssertNotNil(fx.store.peek(row.id), "a refused retry does not consume the payload")
    }

    // MARK: - Full recovery

    func test_retry_fullRecovery_fillsTheRow_clearsTheCount_andReleasesTheAudio() async {
        let fx = Fixture(self)
        let row = fx.appendRow(["Ship it by", nil, "and review", nil, "after."])
        fx.state.retryChunkSender = fx.sender(["the tenth", "the draft"])

        await fx.state.retryEntry(id: row.id)

        let settled = fx.row(row.id)
        XCTAssertEqual(
            settled.map { HistoryText.assemble($0.segments) },
            "Ship it by the tenth and review the draft after."
        )
        XCTAssertEqual(settled?.failedChunkCount, 0)
        XCTAssertEqual(settled?.isBroken, false, "a fully recovered row is no longer broken")
        XCTAssertNil(fx.store.peek(row.id), "R5: a retry that succeeded releases the audio")
    }

    func test_retry_passesTheRetainedContextAndModel_notTodaysSettings() async {
        // R11 / KD3: the retry reproduces the request the session made —
        // the context frozen at session start and the model it ran on.
        let fx = Fixture(self)
        let row = fx.appendRow([nil], text: "", model: .flash)

        var seenBundle: String?
        var seenModel: GeminiModel?
        fx.state.retryChunkSender = { _, context, _, model in
            seenBundle = context.activeApp.bundleID
            seenModel = model
            return ("recovered", .zero)
        }

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(seenBundle, Fixture.bundleID)
        XCTAssertEqual(seenModel, .flash)
    }

    func test_retry_sendsTheRowsTextCarryingChunksAsPriors_rawAndGapFree() async {
        // R10. One prior per text-carrying segment, in order — the same
        // shape `RecordingSession.currentPriors()` produces, because both
        // now read a response sequence rather than splitting a string on
        // the marker. A gap contributes nothing, so no `[…]` reaches
        // Gemini: a prompt containing one teaches the model to emit them.
        //
        // The pair below is the raw half of R10. It rewrites how the row
        // *reads*, and a priors path that assembled-and-substituted would
        // send Gemini a phrase the user never dictated.
        let fx = Fixture(self)
        fx.state.dictionaryReplacements = [DictionaryReplacement(from: "before", to: "BEFOREHAND")]
        let row = fx.appendRow(["before", nil, "middle", nil, "end"])

        var priorsPerCall: [[String]] = []
        var answers = ["FIRST", "SECOND"]
        fx.state.retryChunkSender = { _, _, priors, _ in
            priorsPerCall.append(priors)
            return (answers.removeFirst(), .zero)
        }

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(priorsPerCall.first, ["before", "middle", "end"])
        XCTAssertEqual(
            priorsPerCall.last,
            ["before", "FIRST", "middle", "end"],
            "the chunk that just recovered becomes context for the next one, in its own position"
        )
        for call in priorsPerCall {
            for prior in call {
                XCTAssertFalse(prior.contains(marker), "no marker is ever sent to Gemini")
                XCTAssertNotEqual(prior, "BEFOREHAND", "and no replacement pair is applied first")
            }
        }
    }

    // MARK: - Landing by index (R7, AE3)

    func test_retry_onARowWhoseMarkersAReplacementPairRewrote_stillOffersAndStillLands() async {
        // **AE1 / R8, and the regression that made this unit urgent.**
        //
        // The row's `text` mirror is the pasted string, so it is
        // post-replacement — and `TextReplacementEngine`'s
        // `(?<![\p{L}\p{N}])…(?![\p{L}\p{N}])` boundary matches the `…`
        // inside `[…]`, so a pair as ordinary as `…` → `...` leaves a
        // broken row carrying no marker at all. The merge used to scan that
        // string, so on this exact row the retry button was offered, the
        // request was billed, and the run fell through the nothing-recovered
        // exit every single time. Writing by index is what closes it; a
        // text-shaped gate on the button would only re-hide the recovery.
        let fx = Fixture(self)
        fx.state.dictionaryReplacements = [DictionaryReplacement(from: "…", to: "...")]
        let row = fx.appendRow(["Ship it by", nil, "after."])

        XCTAssertTrue(row.isBroken, "fixture check — the row is broken")
        XCTAssertFalse(
            row.text.contains(marker),
            "fixture check — and its stored mirror carries no marker, or this test proves nothing"
        )

        fx.state.retryChunkSender = fx.sender(
            ["the tenth"],
            tokens: TokenUsage(input: 70, output: 5, cached: 0)
        )

        await fx.state.retryEntry(id: row.id)

        let settled = fx.row(row.id)
        XCTAssertEqual(
            settled.map { HistoryText.assemble($0.segments) },
            "Ship it by the tenth after.",
            "the recovery landed in the gap at chunk 1, whatever the pair did to the marker"
        )
        XCTAssertEqual(settled?.isBroken, false)
        XCTAssertNil(fx.store.peek(row.id), "and the audio is released, not held for a run that failed")
        XCTAssertFalse(fx.hud.errorHUDVisible, "no nothing-recovered notice — this run recovered")
    }

    func test_retry_storesRecoveredTextRaw_soTheUsersPairsApplyOnceAndStayEditable() async {
        // **R2 / R9 / R5 / AE7 / R31, and the second regression this unit
        // closes.** Rebuilding the row from the merged *post-replacement*
        // string stored an already-substituted transcript into `segments`
        // and persisted it. From that point the raw text was gone from
        // disk, so `HistoryText.rendered` re-applied the current pairs on
        // top of an old substitution.
        //
        // A pair whose `to` contains its `from` is what makes that visible:
        // it double-applies. Every assertion below is red on a build that
        // stores the merged string.
        let fx = Fixture(self)
        fx.state.dictionaryReplacements = [DictionaryReplacement(from: "ML", to: "ML models")]
        let row = fx.appendRow(["we ship ML", nil])

        XCTAssertEqual(
            row.text,
            "we ship ML models \(marker)",
            "fixture check — the stored mirror is post-replacement, as a pasted string is"
        )

        fx.state.retryChunkSender = fx.sender(["and ML too"])

        await fx.state.retryEntry(id: row.id)

        let settled = fx.row(row.id)
        XCTAssertEqual(
            settled?.segments.compactMap(\.text),
            ["we ship ML", "and ML too"],
            "R2 / R9: each response is stored raw, per position — not one merged, substituted string"
        )
        XCTAssertEqual(
            settled.map { HistoryText.rendered($0, replacements: fx.state.dictionaryReplacements) },
            "we ship ML models and ML models too",
            "R5: the pair is applied once, at render — a stored substitution would read '…models models…'"
        )
        XCTAssertEqual(
            settled.map { HistoryText.rendered($0, replacements: []) },
            "we ship ML and ML too",
            "AE7 / R31: deleting the pair restores the original, because disk kept the pre-replacement text"
        )
    }

    // MARK: - Partial run (R16)

    func test_retry_stopsAtTheFirstFailure_andIssuesNoRequestForLaterChunks() async {
        // R16. One request timeout is the bound on an uncancellable wait,
        // not the sum of every retained chunk's.
        let fx = Fixture(self)
        let row = fx.appendRow(["a", nil, "b", nil, "c", nil, "d"])

        var attempted: [Int] = []
        fx.state.retryChunkSender = { chunk, _, _, _ in
            attempted.append(chunk.idx)
            if chunk.idx == 3 { throw GeminiClient.GeminiError.http(status: 0, body: "offline") }
            return ("ONE", .zero)
        }

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(attempted, [1, 3], "chunk 5 is never attempted")
    }

    func test_retry_partialRun_writesWhatRecovered_reputsOnlyTheRest_andDropsTheCount() async {
        // R16's three consequences in one assertion block: the recovered
        // text lands, the recovered chunks are released, and the remaining
        // gaps are exactly the chunks that did not come back (R11) — so a
        // second retry re-pays for those only.
        let fx = Fixture(self)
        let row = fx.appendRow(["a", nil, "b", nil, "c", nil, "d"])
        fx.state.retryChunkSender = { chunk, _, _, _ in
            if chunk.idx == 5 { throw GeminiClient.GeminiError.http(status: 503, body: "") }
            return ("R\(chunk.idx)", .zero)
        }

        await fx.state.retryEntry(id: row.id)

        let settled = fx.row(row.id)
        XCTAssertEqual(settled.map { HistoryText.assemble($0.segments) }, "a R1 b R3 c \(marker) d")
        XCTAssertEqual(
            settled.map { Set($0.segments.filter(\.isGap).flatMap(\.chunkIndices)) },
            Set([5]),
            "R11: the gaps left are read from the per-chunk results, not from a decremented count"
        )
        XCTAssertEqual(settled?.failedChunkCount, 1)
        XCTAssertEqual(settled?.isBroken, true, "the row stays broken")

        let held = fx.store.peek(row.id)
        XCTAssertEqual(
            held?.chunks.map(\.idx),
            [5],
            "only the chunk that did not recover is re-put — the other two are released"
        )
        XCTAssertTrue(fx.state.canRetry(entryID: row.id), "and the row can be retried again")
    }

    func test_retry_secondRunFillsTheRemainingGap() async {
        // The round trip the previous test sets up — and the case that
        // fabricated ordinals would break: the second run indexes against
        // the positions the first run's row actually carries.
        let fx = Fixture(self)
        let row = fx.appendRow(["a", nil, "b", nil, "c"])
        fx.state.retryChunkSender = { chunk, _, _, _ in
            if chunk.idx == 3 { throw GeminiClient.GeminiError.http(status: 0, body: "offline") }
            return ("ONE", .zero)
        }
        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(
            fx.row(row.id)?.segments.filter(\.isGap).flatMap(\.chunkIndices),
            [3],
            "the surviving gap keeps chunk 3's own index, not an ordinal of a re-parse"
        )

        fx.state.retryChunkSender = fx.sender(["TWO"])
        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(fx.row(row.id).map { HistoryText.assemble($0.segments) }, "a ONE b TWO c")
        XCTAssertEqual(fx.row(row.id)?.failedChunkCount, 0)
        XCTAssertNil(fx.store.peek(row.id))
    }

    func test_retry_anEmptyAnswerIsNotARecovery_soItsChunkStaysHeld() async {
        // Gemini answered with nothing. Writing `""` into the gap would
        // delete it; keeping the gap AND the audio leaves the user
        // something to retry. It is also the AE3 shape at this layer: the
        // *later* gap is the one that recovers, and it must not slide into
        // the earlier one's place.
        let fx = Fixture(self)
        let row = fx.appendRow(["a", nil, "b", nil, "c"])
        fx.state.retryChunkSender = fx.sender(["", "TWO"])

        await fx.state.retryEntry(id: row.id)

        let settled = fx.row(row.id)
        XCTAssertEqual(
            settled?.segments,
            [
                .carrying("a", at: [0]),
                .gap(at: [1]),
                .carrying("b", at: [2]),
                .carrying("TWO", at: [3]),
                .carrying("c", at: [4])
            ],
            "chunk 3 holds its text; chunk 1 stays a gap in its own position"
        )
        XCTAssertEqual(settled?.failedChunkCount, 1)
        XCTAssertEqual(fx.store.peek(row.id)?.chunks.map(\.idx), [1])
    }

    func test_retry_recoveryWhoseIndexHasNoGap_keepsTheAudioAndSurfacesTheFailure() async {
        // The data-loss shape, in the form that survives the index write: a
        // payload out of step with its row, carrying a chunk whose position
        // the row already holds text for. The merge has nowhere to put the
        // answer, so the run must be treated as the failure it is —
        // releasing the chunk on the strength of "it recovered" would
        // destroy the only copy of the audio and throw the recovered text
        // away in the same breath.
        let fx = Fixture(self)
        let row = fx.appendRow(["Ship it by", "already recovered", nil], retaining: [1])
        fx.state.retryChunkSender = fx.sender(
            ["the tenth"],
            tokens: TokenUsage(input: 70, output: 5, cached: 0)
        )

        await fx.state.retryEntry(id: row.id)

        let settled = fx.row(row.id)
        XCTAssertEqual(settled?.segments, row.segments, "the row is not rewritten")
        XCTAssertEqual(settled?.failedChunkCount, 1, "and it stays broken")
        XCTAssertEqual(
            fx.store.peek(row.id)?.chunks.map(\.idx),
            [1],
            "the audio the merge could not use goes back — it is the only copy"
        )
        XCTAssertTrue(fx.hud.errorHUDVisible, "R19: the user is told the run achieved nothing")
        let snap = await fx.stats.summary()
        XCTAssertEqual(snap.totalSessions, 0, "and no session is counted for it")
        XCTAssertEqual(
            snap.dayBuckets[fx.dayKey(row)]?.tokenInput,
            70,
            "but the request was still billed, so its tokens are recorded"
        )
    }

    func test_retry_sumsTokensAcrossEveryChunkItSent() async {
        // Distinct per-chunk usage, so an accumulator that overwrites
        // instead of summing (`tokens = result.tokens`) is caught. With a
        // single shared TokenUsage across calls, that mutation survives.
        let fx = Fixture(self)
        let row = fx.appendRow(["a", nil, "b", nil, "c", nil, "d"])
        fx.state.retryChunkSender = { chunk, _, _, _ in
            (
                "R\(chunk.idx)",
                TokenUsage(input: 100 * chunk.idx, output: 10 * chunk.idx, cached: chunk.idx)
            )
        }

        await fx.state.retryEntry(id: row.id)

        let day = await fx.stats.summary().dayBuckets[fx.dayKey(row)]
        XCTAssertEqual(day?.tokenInput, 900, "100 + 300 + 500")
        XCTAssertEqual(day?.tokenOutput, 90, "10 + 30 + 50")
        XCTAssertEqual(day?.tokenCached, 9, "1 + 3 + 5")
    }

    // MARK: - Nothing recovered (R19)

    func test_retry_nothingRecovered_leavesTheRowAndPayloadUntouched_andSurfacesTheFailure() async {
        let fx = Fixture(self)
        let before = fx.appendRow([nil, nil], text: "")
        fx.state.retryChunkSender = { _, _, _, _ in
            throw GeminiClient.GeminiError.http(status: 0, body: "offline")
        }

        await fx.state.retryEntry(id: before.id)

        let settled = fx.row(before.id)
        XCTAssertEqual(settled?.segments, before.segments, "the row is not rewritten")
        XCTAssertEqual(settled?.text, "", "and its legacy mirror is untouched")
        XCTAssertEqual(settled?.failedChunkCount, 2)
        XCTAssertEqual(
            fx.store.peek(before.id)?.chunks.map(\.idx),
            [0, 1],
            "every chunk goes back — `take` removed the only copy"
        )
        XCTAssertNil(fx.state.retryingEntryID)
        XCTAssertTrue(
            fx.hud.errorHUDVisible,
            "R19: a retry that recovered nothing must not silently restore the pre-tap appearance"
        )
        let snap = await fx.stats.summary()
        XCTAssertEqual(snap.totalSessions, 0, "and counts no session")
    }

    func test_retry_everyChunkAnsweredEmpty_isStillANothingRecoveredRun() async {
        // No thrown error at all, and still nothing to show for it.
        let fx = Fixture(self)
        let row = fx.appendRow([nil, nil], text: "")
        fx.state.retryChunkSender = fx.sender(["", ""])

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(fx.row(row.id)?.failedChunkCount, 2)
        XCTAssertEqual(fx.store.peek(row.id)?.chunks.count, 2)
        XCTAssertTrue(fx.hud.errorHUDVisible)
    }

    // MARK: - Stats accounting (R15 / KTD7)

    func test_retry_onARowWhoseSessionWasAlreadyCounted_addsTokensOnly() async {
        // AE8. The session pasted with gaps, so lifetime stats already
        // counted it. Counting again would invent a session and duplicate
        // the transcript's words.
        let fx = Fixture(self)
        let row = fx.appendRow(["Ship it by", nil, "and review after."])
        fx.state.retryChunkSender = fx.sender(
            ["the tenth"],
            tokens: TokenUsage(input: 900, output: 40, cached: 700)
        )

        await fx.state.retryEntry(id: row.id)

        let snap = await fx.stats.summary()
        XCTAssertEqual(snap.totalSessions, 0, "no session is counted by a retry of a counted row")
        XCTAssertEqual(snap.totalWords, 0)
        let day = snap.dayBuckets[StatsSnapshot.dayKey(for: row.timestamp)]
        XCTAssertEqual(day?.tokenInput, 900, "the tokens the retry spent are recorded")
        XCTAssertEqual(day?.tokenOutput, 40)
        XCTAssertEqual(day?.tokenCached, 700)
        XCTAssertEqual(day?.sessions, 0, "without a session landing in the bucket")
        XCTAssertEqual(
            day?.tokensByModel[GeminiModel.flashLite.rawValue]?.input,
            900,
            "priced against the model the session ran on"
        )
    }

    func test_retry_neverCountedRow_countsTheSessionOnce_acrossTwoRetries() async {
        // AE9. A fully-failed session lifetime stats never saw, recovered
        // across two runs: the session count rises at the first retry that
        // recovers text and never again, and both runs add their tokens.
        let fx = Fixture(self)
        let row = fx.appendRow([nil, nil], text: "")

        fx.state.retryChunkSender = { chunk, _, _, _ in
            if chunk.idx == 1 { throw GeminiClient.GeminiError.http(status: 0, body: "offline") }
            return ("hello world", TokenUsage(input: 100, output: 10, cached: 0))
        }
        await fx.state.retryEntry(id: row.id)

        let afterFirst = await fx.stats.summary()
        XCTAssertEqual(afterFirst.totalSessions, 1, "the first recovery counts the session")
        XCTAssertEqual(afterFirst.totalWords, 3, "\"hello world \(marker)\"")
        XCTAssertEqual(
            afterFirst.totalDurationSeconds,
            Fixture.durationSeconds,
            "and its duration"
        )
        XCTAssertEqual(afterFirst.dayBuckets[fx.dayKey(row)]?.tokenInput, 100)

        fx.state.retryChunkSender = fx.sender(
            ["goodbye"],
            tokens: TokenUsage(input: 55, output: 5, cached: 0)
        )
        await fx.state.retryEntry(id: row.id)

        let afterSecond = await fx.stats.summary()
        XCTAssertEqual(afterSecond.totalSessions, 1, "the second retry counts no second session")
        XCTAssertEqual(afterSecond.totalWords, 3, "and adds no second copy of the words")
        XCTAssertEqual(afterSecond.totalDurationSeconds, Fixture.durationSeconds)
        XCTAssertEqual(afterSecond.dayBuckets[fx.dayKey(row)]?.tokenInput, 155, "both runs' tokens")
        XCTAssertEqual(
            fx.row(row.id).map { HistoryText.assemble($0.segments) },
            "hello world goodbye"
        )
    }

    func test_retry_countsTheWordsTheRowShows_withTheUsersCurrentPairsApplied() async {
        // R13 / R14 on the retry side, and the reason it needs its own
        // case: every other test here runs with `dictionaryReplacements`
        // empty, where `HistoryText.rendered(updated, replacements: [])`,
        // `HistoryText.assemble(updated.segments)` and `updated.text` all
        // produce the same word count. That fixture cannot express the
        // failure — it is green for a `settleRetry` that dropped the live
        // pair list, which is exactly the regression R14 exists to stop
        // (the convention this repo wrote down in
        // `solutions/conventions/testing-spm-and-git-2026-05-15.md`).
        //
        // A pair that *expands* is what makes the readings diverge: the raw
        // segment says two words, the rendered row says three.
        let fx = Fixture(self)
        let row = fx.appendRow([nil], text: "")
        fx.state.dictionaryReplacements = [
            DictionaryReplacement(from: "ML", to: "machine learning")
        ]
        fx.state.retryChunkSender = fx.sender(["ML rocks"])

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(
            fx.row(row.id).map {
                HistoryText.rendered($0, replacements: fx.state.dictionaryReplacements)
            },
            "machine learning rocks",
            "fixture check — the pair must reach the rendered row, or the count below proves nothing"
        )
        let snap = await fx.stats.summary()
        XCTAssertEqual(snap.totalSessions, 1)
        XCTAssertEqual(
            snap.totalWords, 3,
            "lifetime words must be counted from the string the row shows, current pairs applied "
            + "(R13 / R14 / KD6). Counting the raw segments or the legacy `text` mirror records 2."
        )
    }

    func test_retry_recordsTokensEvenWhenNothingRecovered() async {
        // R15 says every time. A chunk that answered with nothing still
        // cost the user a request.
        let fx = Fixture(self)
        let row = fx.appendRow([nil], text: "")
        fx.state.retryChunkSender = fx.sender([""], tokens: TokenUsage(input: 800, output: 0, cached: 0))

        await fx.state.retryEntry(id: row.id)

        let snap = await fx.stats.summary()
        XCTAssertEqual(snap.totalSessions, 0)
        XCTAssertEqual(snap.dayBuckets[fx.dayKey(row)]?.tokenInput, 800)
    }

    // MARK: - Delete during a run (R13)

    func test_retry_rowDeletedMidRun_doesNotResurrectThePayload() async {
        // R13 keeps delete available while a retry is in flight, so this is
        // reachable by design. Re-putting would leave a payload keyed by a
        // row that no longer exists — memory nothing can reach and no
        // `retain(only:)` will visit until the next history mutation.
        let fx = Fixture(self)
        let row = fx.appendRow([nil, nil], text: "")

        fx.state.retryChunkSender = { [state = fx.state] chunk, _, _, _ in
            if chunk.idx == 0 { state.deleteHistoryEntry(id: row.id) }
            return ("recovered \(chunk.idx)", .zero)
        }

        await fx.state.retryEntry(id: row.id)

        XCTAssertFalse(fx.state.history.contains { $0.id == row.id }, "the delete stands")
        XCTAssertNil(fx.store.peek(row.id), "and no payload comes back for it")
        XCTAssertNil(fx.state.retryingEntryID)
        let snap = await fx.stats.summary()
        XCTAssertEqual(snap.totalSessions, 0, "a deleted row counts no session")
    }

    func test_retry_deletedMidRun_stillRecordsTheTokensItSpent() async {
        let fx = Fixture(self)
        let row = fx.appendRow([nil], text: "")
        fx.state.retryChunkSender = { [state = fx.state] _, _, _, _ in
            state.deleteHistoryEntry(id: row.id)
            return ("recovered", TokenUsage(input: 42, output: 7, cached: 0))
        }

        await fx.state.retryEntry(id: row.id)

        let snap = await fx.stats.summary()
        XCTAssertEqual(snap.dayBuckets[fx.dayKey(row)]?.tokenInput, 42)
    }

    func test_retry_deletedMidRun_stopsSpendingOnTheRemainingChunks() async {
        // The user said they do not want this row. Every chunk still in the
        // queue is money spent on something already discarded, so the run
        // must abandon at the next boundary rather than discovering the
        // deletion once at settle time.
        let fx = Fixture(self)
        let row = fx.appendRow([nil, nil, nil, nil], text: "")

        var attempted: [Int] = []
        fx.state.retryChunkSender = { [state = fx.state] chunk, _, _, _ in
            attempted.append(chunk.idx)
            if chunk.idx == 0 { state.deleteHistoryEntry(id: row.id) }
            return ("recovered \(chunk.idx)", TokenUsage(input: 10, output: 1, cached: 0))
        }

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(attempted, [0], "chunks 1-3 are never billed for a deleted row")
        XCTAssertNil(fx.store.peek(row.id), "and the payload is released, not resurrected")
        let snap = await fx.stats.summary()
        XCTAssertEqual(
            snap.dayBuckets[fx.dayKey(row)]?.tokenInput,
            10,
            "only the one request that had already gone out is recorded"
        )
    }

    // MARK: - The disk write

    func test_retry_persistsTheRecoveredRowInPlace_withoutReorderingHistory() async {
        // `settleRetry`'s `historyStore.update` is the feature's only disk
        // write, and every other test in this file seeds rows through the
        // mirror-only `recordHistoryEntry`, which leaves the store empty —
        // so `update` takes its no-op branch and its replace path is never
        // exercised. Seed the actor too, and assert against disk.
        let fx = Fixture(self)
        let older = HistoryEntry(
            id: UUID(),
            text: "an earlier, healthy transcript",
            sourceAppName: "Slack",
            sourceBundleID: Fixture.bundleID,
            timestamp: Date(timeIntervalSinceNow: -600),
            durationSeconds: 4,
            segments: [.carrying("an earlier, healthy transcript", at: [0])]
        )
        await fx.history.append(older)

        let row = fx.appendRow(["Ship it by", nil, "and review after."])
        await fx.history.append(row)

        fx.state.retryChunkSender = fx.sender(["the tenth"])
        await fx.state.retryEntry(id: row.id)

        let onDisk = await fx.history.allEntries()
        XCTAssertEqual(
            onDisk.map(\.id),
            [older.id, row.id],
            "the row is replaced where it stood — a re-append would reorder the last-10 list"
        )
        XCTAssertEqual(
            onDisk.last?.segments,
            [
                .carrying("Ship it by", at: [0]),
                .carrying("the tenth", at: [1]),
                .carrying("and review after.", at: [2])
            ],
            "the recovered sequence round-trips through the store, positions and all"
        )
        XCTAssertEqual(onDisk.last?.text, "Ship it by the tenth and review after.")
        XCTAssertEqual(onDisk.last?.failedChunkCount, 0, "the recovered row persists as un-broken")
        XCTAssertEqual(onDisk.first?.text, older.text, "and the untouched row is untouched")
    }

    // MARK: - Fixture

    /// One `AppState` wired to throwaway stores, plus the handles the
    /// assertions need. Mirrors `AppStateRetentionTests`' fixture; kept
    /// local rather than shared so neither suite can break the other by
    /// changing what it seeds.
    @MainActor
    private final class Fixture {
        static let bundleID = "com.tinyspeck.slackmacgap"
        static let durationSeconds: Double = 12

        let store = RetainedAudioStore()
        let stats: StatsStore
        let history: HistoryStore
        let hud: HUDController
        let state: AppState

        /// `test` only supplies the teardown hook — the production store
        /// defaults resolve to the developer's own Application Support
        /// folder, and these tests write history and stats.
        init(_ test: XCTestCase) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

            let perms = PermissionsViewModel()
            let gemini = GeminiClient()
            let instructions = InstructionsStore()
            self.stats = StatsStore(url: dir.appendingPathComponent("stats.json"))
            self.history = HistoryStore(url: dir.appendingPathComponent("history.json"))
            self.hud = HUDController(permissions: perms)
            self.state = AppState(
                permissions: perms,
                hud: hud,
                gemini: gemini,
                historyStore: history,
                statsStore: stats,
                instructionsStore: instructions,
                appCategorizer: AppCategorizer(client: gemini, store: instructions),
                dictionaryStore: DictionaryStore(url: dir.appendingPathComponent("dictionary.json")),
                onboarding: OnboardingState(),
                retainedAudio: store
            )
        }

        /// A row described the way a session produces one: one answer per
        /// chunk, in chunk order, `nil` for a gap.
        ///
        /// - Parameter text: the legacy `text` mirror. Defaults to what the
        ///   paste would have been — assembled, with the state's *current*
        ///   pairs applied — which is what `RecordingSession.makeHistoryEntry`
        ///   stores. Pass `""` for the all-failed row, which is exactly what
        ///   `brokenHistoryEntry()` writes and what the never-counted-session
        ///   signal reads.
        /// - Parameter retaining: the chunk indices whose audio is held.
        ///   Defaults to the gaps' own indices — the join a retry writes by
        ///   (R7). Override it only to build a payload deliberately out of
        ///   step with its row.
        @discardableResult
        func appendRow(
            _ answers: [String?],
            text: String? = nil,
            retaining: [Int]? = nil,
            model: GeminiModel = .flashLite
        ) -> HistoryEntry {
            appendRow(
                segments: answers.enumerated().map {
                    HistoryEntry.Segment(chunkIndices: [$0.offset], text: $0.element)
                },
                text: text,
                retaining: retaining,
                model: model
            )
        }

        @discardableResult
        func appendRow(
            segments: [HistoryEntry.Segment],
            text: String? = nil,
            retaining: [Int]? = nil,
            model: GeminiModel = .flashLite
        ) -> HistoryEntry {
            let entry = HistoryEntry(
                id: UUID(),
                text: text ?? HistoryText.rendered(
                    segments,
                    replacements: state.dictionaryReplacements
                ),
                sourceAppName: "Slack",
                sourceBundleID: Self.bundleID,
                timestamp: Date(),
                durationSeconds: Self.durationSeconds,
                segments: segments
            )
            let indices = retaining ?? segments.filter(\.isGap).flatMap(\.chunkIndices)
            state.recordHistoryEntry(entry, retaining: payload(chunkIndices: indices, model: model))
            return entry
        }

        func row(_ id: UUID) -> HistoryEntry? { state.history.first { $0.id == id } }

        func dayKey(_ row: HistoryEntry) -> String { StatsSnapshot.dayKey(for: row.timestamp) }

        /// A sender that answers each chunk in order from `answers`, with
        /// the same usage on every call.
        func sender(_ answers: [String], tokens: TokenUsage = .zero) -> AppState.RetryChunkSender {
            var remaining = answers
            return { _, _, _, _ in
                guard !remaining.isEmpty else {
                    XCTFail("sender called more times than it has answers")
                    return ("", .zero)
                }
                return (remaining.removeFirst(), tokens)
            }
        }

        private func payload(chunkIndices: [Int], model: GeminiModel) -> RetainedRecording {
            RetainedRecording(
                chunks: chunkIndices.map { idx in
                    RetainedRecording.Chunk(
                        idx: idx,
                        isFinal: idx == chunkIndices.last,
                        // Distinct per chunk, per the unit's execution note:
                        // an ordering defect is invisible against equal
                        // elements.
                        audio: Data([0xA0 &+ UInt8(truncatingIfNeeded: idx)]),
                        // 4 s of audio: comfortably above
                        // `HallucinationLengthGate`'s floor, so a short
                        // fixture answer is never filtered as a
                        // hallucination.
                        samples: 64_000
                    )
                },
                context: ContextSnapshot.minimal(
                    activeApp: AppInfo(name: "Slack", bundleID: Self.bundleID)
                ),
                model: model
            )
        }
    }
}
