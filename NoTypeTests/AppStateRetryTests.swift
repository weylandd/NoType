import XCTest
@testable import NoType

/// Pins the retry orchestration: what a run does to the row, to the
/// retained-audio holder, and to lifetime stats (R11–R13, R15, R16, R19).
///
/// Every test drives `AppState.retryChunkSender`, the injected stand-in for
/// the per-chunk Gemini call. That seam is the whole reason these
/// properties are testable: each of them — KTD7's stats split, R16's
/// stop-at-first-failure, R19's leave-everything-alone — is only observable
/// across a *sequence* of per-chunk outcomes, and there is no way to author
/// that sequence against a live network.
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
        let row = fx.appendBrokenRow(text: "", failedChunkCount: 1, chunkCount: 1)

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
        let first = fx.appendBrokenRow(text: "", failedChunkCount: 1, chunkCount: 1)
        let second = fx.appendBrokenRow(text: "", failedChunkCount: 1, chunkCount: 1)

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
        let row = fx.appendBrokenRow(text: "", failedChunkCount: 1, chunkCount: 1)
        fx.state.recordingState = .sending

        var requests = 0
        fx.state.retryChunkSender = { _, _, _, _ in
            requests += 1
            return ("recovered", .zero)
        }

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(requests, 0)
        XCTAssertEqual(fx.row(row.id)?.text, "")
        XCTAssertNotNil(fx.store.peek(row.id), "a refused retry does not consume the payload")
    }

    // MARK: - Full recovery

    func test_retry_fullRecovery_fillsTheRow_clearsTheCount_andReleasesTheAudio() async {
        let fx = Fixture(self)
        let row = fx.appendBrokenRow(
            text: "Ship it by \(marker) and review \(marker) after.",
            failedChunkCount: 2,
            chunkCount: 2
        )
        fx.state.retryChunkSender = fx.sender(["the tenth", "the draft"])

        await fx.state.retryEntry(id: row.id)

        let settled = fx.row(row.id)
        XCTAssertEqual(settled?.text, "Ship it by the tenth and review the draft after.")
        XCTAssertEqual(settled?.failedChunkCount, 0)
        XCTAssertEqual(settled?.isBroken, false, "a fully recovered row is no longer broken")
        XCTAssertNil(fx.store.peek(row.id), "R5: a retry that succeeded releases the audio")
    }

    func test_retry_passesTheRetainedContextAndModel_notTodaysSettings() async {
        // R11 / KD3: the retry reproduces the request the session made —
        // the context frozen at session start and the model it ran on.
        let fx = Fixture(self)
        let row = fx.appendBrokenRow(text: "", failedChunkCount: 1, chunkCount: 1, model: .flash)

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

    func test_retry_sendsSurvivingTextAsPriors_withMarkersFilteredOut() async {
        // KTD6. A prompt containing `[…]` teaches the model to emit them.
        let fx = Fixture(self)
        let row = fx.appendBrokenRow(
            text: "before \(marker) middle \(marker) end",
            failedChunkCount: 2,
            chunkCount: 2
        )

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
            ["before FIRST middle", "end"],
            "the chunk that just recovered becomes context for the next one"
        )
        for call in priorsPerCall {
            for prior in call {
                XCTAssertFalse(prior.contains(marker), "no marker is ever sent to Gemini")
            }
        }
    }

    // MARK: - Partial run (R16)

    func test_retry_stopsAtTheFirstFailure_andIssuesNoRequestForLaterChunks() async {
        // R16. One request timeout is the bound on an uncancellable wait,
        // not the sum of every retained chunk's.
        let fx = Fixture(self)
        let row = fx.appendBrokenRow(
            text: "a \(marker) b \(marker) c \(marker) d",
            failedChunkCount: 3,
            chunkCount: 3
        )

        var attempted: [Int] = []
        fx.state.retryChunkSender = { chunk, _, _, _ in
            attempted.append(chunk.idx)
            if chunk.idx == 1 { throw GeminiClient.GeminiError.http(status: 0, body: "offline") }
            return ("ONE", .zero)
        }

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(attempted, [0, 1], "chunk 2 is never attempted")
    }

    func test_retry_partialRun_writesWhatRecovered_reputsOnlyTheRest_andDropsTheCount() async {
        // R16's three consequences in one assertion block: the recovered
        // text lands, the recovered chunks are released, and the count
        // drops to what remains — so a second retry re-pays for the
        // unrecovered chunk only.
        let fx = Fixture(self)
        let row = fx.appendBrokenRow(
            text: "a \(marker) b \(marker) c \(marker) d",
            failedChunkCount: 3,
            chunkCount: 3
        )
        fx.state.retryChunkSender = { chunk, _, _, _ in
            if chunk.idx == 2 { throw GeminiClient.GeminiError.http(status: 503, body: "") }
            return ("R\(chunk.idx)", .zero)
        }

        await fx.state.retryEntry(id: row.id)

        let settled = fx.row(row.id)
        XCTAssertEqual(settled?.text, "a R0 b R1 c \(marker) d")
        XCTAssertEqual(settled?.failedChunkCount, 1, "one gap remains, so the count is one")
        XCTAssertEqual(settled?.isBroken, true, "the row stays broken")

        let held = fx.store.peek(row.id)
        XCTAssertEqual(
            held?.chunks.map(\.idx),
            [2],
            "only the chunk that did not recover is re-put — the other two are released"
        )
        XCTAssertTrue(fx.state.canRetry(entryID: row.id), "and the row can be retried again")
    }

    func test_retry_secondRunFillsTheRemainingGap() async {
        // The round trip the previous test sets up.
        let fx = Fixture(self)
        let row = fx.appendBrokenRow(
            text: "a \(marker) b \(marker) c",
            failedChunkCount: 2,
            chunkCount: 2
        )
        fx.state.retryChunkSender = { chunk, _, _, _ in
            if chunk.idx == 1 { throw GeminiClient.GeminiError.http(status: 0, body: "offline") }
            return ("ONE", .zero)
        }
        await fx.state.retryEntry(id: row.id)

        fx.state.retryChunkSender = fx.sender(["TWO"])
        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(fx.row(row.id)?.text, "a ONE b TWO c")
        XCTAssertEqual(fx.row(row.id)?.failedChunkCount, 0)
        XCTAssertNil(fx.store.peek(row.id))
    }

    func test_retry_anEmptyAnswerIsNotARecovery_soItsChunkStaysHeld() async {
        // Gemini answered with nothing. Substituting `""` would delete the
        // gap; keeping the marker AND the audio keeps the count honest and
        // leaves the user something to retry.
        let fx = Fixture(self)
        let row = fx.appendBrokenRow(
            text: "a \(marker) b \(marker) c",
            failedChunkCount: 2,
            chunkCount: 2
        )
        fx.state.retryChunkSender = fx.sender(["", "TWO"])

        await fx.state.retryEntry(id: row.id)

        XCTAssertEqual(fx.row(row.id)?.text, "a \(marker) b TWO c")
        XCTAssertEqual(fx.row(row.id)?.failedChunkCount, 1)
        XCTAssertEqual(fx.store.peek(row.id)?.chunks.map(\.idx), [0])
    }

    func test_retry_recoveryWithNoMarkerToLandIn_keepsTheAudioAndSurfacesTheFailure() async {
        // The data-loss regression. A broken row can carry fewer markers
        // than retained chunks — `TextReplacementEngine` runs over the
        // stitched transcript before it is stored and its Unicode boundary
        // matches the `…` inside `[…]`, so a user replacement pair on the
        // ellipsis rewrites every marker in the row. Gemini then answers,
        // the merge has nowhere to put the text, and the run must be
        // treated as a failure: releasing the chunk on the strength of
        // "it recovered" would destroy the only copy of the audio and
        // throw the recovered text away in the same breath.
        let fx = Fixture(self)
        let row = fx.appendBrokenRow(
            text: "Ship it by [...] and review after.",
            failedChunkCount: 1,
            chunkCount: 1
        )
        fx.state.retryChunkSender = fx.sender(
            ["the tenth"],
            tokens: TokenUsage(input: 70, output: 5, cached: 0)
        )

        await fx.state.retryEntry(id: row.id)

        let settled = fx.row(row.id)
        XCTAssertEqual(settled?.text, "Ship it by [...] and review after.", "the row is not rewritten")
        XCTAssertEqual(settled?.failedChunkCount, 1, "and it stays broken")
        XCTAssertEqual(
            fx.store.peek(row.id)?.chunks.map(\.idx),
            [0],
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
        let row = fx.appendBrokenRow(
            text: "a \(marker) b \(marker) c \(marker) d",
            failedChunkCount: 3,
            chunkCount: 3
        )
        fx.state.retryChunkSender = { chunk, _, _, _ in
            (
                "R\(chunk.idx)",
                TokenUsage(
                    input: 100 * (chunk.idx + 1),
                    output: 10 * (chunk.idx + 1),
                    cached: chunk.idx
                )
            )
        }

        await fx.state.retryEntry(id: row.id)

        let day = await fx.stats.summary().dayBuckets[fx.dayKey(row)]
        XCTAssertEqual(day?.tokenInput, 600, "100 + 200 + 300")
        XCTAssertEqual(day?.tokenOutput, 60, "10 + 20 + 30")
        XCTAssertEqual(day?.tokenCached, 3, "0 + 1 + 2")
    }

    // MARK: - Nothing recovered (R19)

    func test_retry_nothingRecovered_leavesTheRowAndPayloadUntouched_andSurfacesTheFailure() async {
        let fx = Fixture(self)
        let before = fx.appendBrokenRow(text: "", failedChunkCount: 2, chunkCount: 2)
        fx.state.retryChunkSender = { _, _, _, _ in
            throw GeminiClient.GeminiError.http(status: 0, body: "offline")
        }

        await fx.state.retryEntry(id: before.id)

        let settled = fx.row(before.id)
        XCTAssertEqual(settled?.text, "", "the row is not rewritten")
        XCTAssertEqual(settled?.failedChunkCount, 2, "and its count is untouched")
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
        let row = fx.appendBrokenRow(text: "", failedChunkCount: 2, chunkCount: 2)
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
        let row = fx.appendBrokenRow(
            text: "Ship it by \(marker) and review after.",
            failedChunkCount: 1,
            chunkCount: 1
        )
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
        let row = fx.appendBrokenRow(text: "", failedChunkCount: 2, chunkCount: 2)

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
        XCTAssertEqual(fx.row(row.id)?.text, "hello world goodbye")
    }

    func test_retry_recordsTokensEvenWhenNothingRecovered() async {
        // R15 says every time. A chunk that answered with nothing still
        // cost the user a request.
        let fx = Fixture(self)
        let row = fx.appendBrokenRow(text: "", failedChunkCount: 1, chunkCount: 1)
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
        let row = fx.appendBrokenRow(text: "", failedChunkCount: 2, chunkCount: 2)

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
        let row = fx.appendBrokenRow(text: "", failedChunkCount: 1, chunkCount: 1)
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
        let row = fx.appendBrokenRow(text: "", failedChunkCount: 4, chunkCount: 4)

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
            failedChunkCount: 0
        )
        await fx.history.append(older)

        let row = fx.appendBrokenRow(
            text: "Ship it by \(marker) and review after.",
            failedChunkCount: 1,
            chunkCount: 1
        )
        await fx.history.append(row)

        fx.state.retryChunkSender = fx.sender(["the tenth"])
        await fx.state.retryEntry(id: row.id)

        let onDisk = await fx.history.allEntries()
        XCTAssertEqual(
            onDisk.map(\.id),
            [older.id, row.id],
            "the row is replaced where it stood — a re-append would reorder the last-10 list"
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

        /// A broken row plus its retained payload, appended through the same
        /// path production uses.
        @discardableResult
        func appendBrokenRow(
            text: String,
            failedChunkCount: Int,
            chunkCount: Int,
            model: GeminiModel = .flashLite
        ) -> HistoryEntry {
            let entry = HistoryEntry(
                id: UUID(),
                text: text,
                sourceAppName: "Slack",
                sourceBundleID: Self.bundleID,
                timestamp: Date(),
                durationSeconds: Self.durationSeconds,
                failedChunkCount: failedChunkCount
            )
            state.recordHistoryEntry(entry, retaining: payload(chunkCount: chunkCount, model: model))
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

        private func payload(chunkCount: Int, model: GeminiModel) -> RetainedRecording {
            RetainedRecording(
                chunks: (0..<chunkCount).map {
                    RetainedRecording.Chunk(
                        idx: $0,
                        isFinal: $0 == chunkCount - 1,
                        audio: Data([UInt8(0xA0 + $0)]),
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
