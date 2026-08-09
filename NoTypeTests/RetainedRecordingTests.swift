import XCTest
@testable import NoType

/// Pins the retention classifier (`RecordingSession.shouldRetain(_:)`)
/// and the value type that carries a retained chunk set
/// (`RetainedRecording`).
///
/// `shouldRetain` decides whether a failed chunk's encoded audio is
/// held in memory so the user can re-send it from the history row.
/// Its contract is R4 of the failed-recording-retry plan: retention
/// fires for exactly the failure class that today produces a `[…]`
/// gap marker (network, 5xx, 429, empty, decoding, truncated) and for
/// nothing else. Terminal failures — rejected key, content block,
/// cancellation, encode failure — retain nothing.
///
/// The classifier is a `nonisolated static` beside
/// `RecordingSession.isTerminal(_:)`, so both can be exercised without
/// standing up a session (which owns AudioRecorder / SileroVAD /
/// GeminiClient / HistoryStore — not unit-test-friendly). Mirrors the
/// seam shape of `RecordingSessionShortPathTests`.
///
/// See `NoType/Recording/CLAUDE.md` "Partial recovery" for the
/// case-for-case table this matrix must match.
final class RetainedRecordingTests: XCTestCase {

    /// One classification fixture. `expectedRetain` is the R4 verdict;
    /// `expectedTerminal` is today's `isTerminal(_:)` verdict, recorded
    /// here so the no-drift test can assert the two classifiers against
    /// one shared list rather than two hand-maintained ones.
    private struct Fixture {
        let label: String
        let error: Error
        let expectedRetain: Bool
        let expectedTerminal: Bool
    }

    /// Stand-in for the non-Gemini terminal class — an AAC encode
    /// failure out of `ChunkBuilder`, or anything AVFAudio raises.
    private struct EncodeFailure: Error {}

    /// Stand-in for the `Error` payload `GeminiError.decoding` wraps.
    private struct DecodeFailure: Error {}

    private var fixtures: [Fixture] {
        [
            // --- Terminal: retains nothing (R4) ---
            Fixture(label: "cancellation",
                    error: CancellationError(),
                    expectedRetain: false, expectedTerminal: true),
            Fixture(label: "missingKey",
                    error: GeminiClient.GeminiError.missingKey,
                    expectedRetain: false, expectedTerminal: true),
            Fixture(label: "http 401 (rejected key)",
                    error: GeminiClient.GeminiError.http(status: 401, body: ""),
                    expectedRetain: false, expectedTerminal: true),
            Fixture(label: "http 403 (key not authorised)",
                    error: GeminiClient.GeminiError.http(status: 403, body: ""),
                    expectedRetain: false, expectedTerminal: true),
            Fixture(label: "content block",
                    error: GeminiClient.GeminiError.blocked("SAFETY"),
                    expectedRetain: false, expectedTerminal: true),
            Fixture(label: "encode failure",
                    error: EncodeFailure(),
                    expectedRetain: false, expectedTerminal: true),

            // --- Recoverable: retains (R4) ---
            Fixture(label: "http 0 (network failure)",
                    error: GeminiClient.GeminiError.http(status: 0, body: ""),
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "http 429 (rate limit)",
                    error: GeminiClient.GeminiError.http(status: 429, body: ""),
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "http 500",
                    error: GeminiClient.GeminiError.http(status: 500, body: ""),
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "http 503",
                    error: GeminiClient.GeminiError.http(status: 503, body: ""),
                    expectedRetain: true, expectedTerminal: false),
            // R4's governing clause is "the class that today produces a
            // gap marker", not only the six kinds it then names. A
            // generic 4xx is in that class today, so it retains — the
            // plan's Scope Boundaries forbid changing which errors abort
            // a session versus continue with a marker.
            Fixture(label: "http 400 (generic 4xx)",
                    error: GeminiClient.GeminiError.http(status: 400, body: ""),
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "empty response",
                    error: GeminiClient.GeminiError.empty,
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "decoding failure",
                    error: GeminiClient.GeminiError.decoding(DecodeFailure()),
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "truncated response",
                    error: GeminiClient.GeminiError.truncated,
                    expectedRetain: true, expectedTerminal: false),
        ]
    }

    // MARK: - Classification matrix

    func test_shouldRetain_matchesTheGapMarkerClass() {
        for f in fixtures {
            XCTAssertEqual(
                RecordingSession.shouldRetain(f.error),
                f.expectedRetain,
                "shouldRetain(\(f.label)) should be \(f.expectedRetain)"
            )
        }
    }

    // MARK: - Terminal cases retain nothing (AE1, AE2)

    func test_rejectedKey_doesNotRetain() {
        // AE1 — an expired / rejected key aborts the session and keeps
        // no audio. Both statuses `isTerminal` singles out.
        XCTAssertFalse(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.http(status: 401, body: "")))
        XCTAssertFalse(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.http(status: 403, body: "")))
    }

    func test_cancellation_doesNotRetain() {
        // AE2 — the user pressed the cancel binding; nothing is kept.
        XCTAssertFalse(RecordingSession.shouldRetain(CancellationError()))
    }

    func test_contentBlock_doesNotRetain() {
        XCTAssertFalse(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.blocked("PROHIBITED_CONTENT")))
    }

    func test_missingKey_doesNotRetain() {
        XCTAssertFalse(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.missingKey))
    }

    func test_unrecognisedError_doesNotRetain() {
        // Encode failure / AVFAudio / anything else: terminal by
        // default, exactly as `isTerminal` treats it.
        XCTAssertFalse(RecordingSession.shouldRetain(EncodeFailure()))
    }

    // MARK: - Recoverable cases retain

    func test_networkAndServerFailures_retain() {
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.http(status: 0, body: "")))
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.http(status: 500, body: "")))
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.http(status: 429, body: "")))
    }

    func test_emptyDecodingTruncated_retain() {
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.empty))
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.decoding(DecodeFailure())))
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.truncated))
    }

    // MARK: - No drift between the two classifiers

    func test_everyTerminalCase_declinesRetention() {
        // The load-bearing assertion (KTD8): the two classifiers sit
        // next to each other so a new error case is added to both. If
        // someone adds a case to `isTerminal` and forgets `shouldRetain`,
        // this fails — provided the new case is added to `fixtures` too.
        //
        // That proviso is why this test is NOT the whole guard. It closes
        // the enum axis only, and weakly: a seventh `GeminiError` case is
        // already caught by the compiler (both switches are exhaustive
        // with no `default`), while a *classification* disagreement on it
        // is caught here only if someone also appends a fixture. The
        // genuinely uncovered axis — the `Int` inside `.http`, where both
        // functions encode their only real policy — is closed
        // mechanically by `test_noHTTPStatusIsBothTerminalAndRetained`
        // below, which needs no fixture maintenance at all.
        for f in fixtures {
            XCTAssertEqual(
                RecordingSession.isTerminal(f.error),
                f.expectedTerminal,
                "isTerminal(\(f.label)) should be \(f.expectedTerminal)"
            )
            if RecordingSession.isTerminal(f.error) {
                XCTAssertFalse(
                    RecordingSession.shouldRetain(f.error),
                    "\(f.label) is terminal, so it must retain nothing"
                )
            }
        }
    }

    func test_noHTTPStatusIsBothTerminalAndRetained() {
        // Closes the axis the fixture list cannot: `.http` carries an
        // `Int`, so no hand-maintained list and no `CaseIterable`
        // conformance can enumerate it. Both classifiers branch on that
        // Int (`status == 401 || status == 403` vs `status != 401 &&
        // status != 403`), so a future edit that widens the terminal band
        // in one and not the other — say adding `|| status == 402` to
        // `isTerminal` — would retain audio for a session that aborted,
        // writing a broken history row with a live retry button for a
        // failure the retry can never fix (violating AE1's shape).
        //
        // Sweeping the whole status space makes that impossible to miss
        // without touching this file. Proved red per
        // `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`
        // ("prove the guard red"): with `|| status == 402` temporarily
        // added to `isTerminal`, this fails on HTTP 402 while every other
        // test in the file stays green.
        for status in 0...599 {
            let error = GeminiClient.GeminiError.http(status: status, body: "")
            if RecordingSession.isTerminal(error) {
                XCTAssertFalse(
                    RecordingSession.shouldRetain(error),
                    "HTTP \(status) is terminal, so it must retain nothing"
                )
            }
        }
    }

    // MARK: - RetainedRecording payload

    func test_retainedRecording_carriesChunksContextAndModel() {
        let app = AppInfo(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let context = ContextSnapshot.minimal(activeApp: app)
        let payload = RetainedRecording(
            chunks: [
                RetainedRecording.Chunk(idx: 1, isFinal: false,
                                        audio: Data([0x01, 0x02]), samples: 16_000),
                RetainedRecording.Chunk(idx: 2, isFinal: true,
                                        audio: Data([0x03]), samples: 8_000),
            ],
            context: context,
            model: .flash
        )

        XCTAssertEqual(payload.chunks.map(\.idx), [1, 2])
        XCTAssertEqual(payload.chunks.map(\.isFinal), [false, true])
        XCTAssertEqual(payload.chunks.map(\.samples), [16_000, 8_000])
        XCTAssertEqual(payload.chunks.first?.audio, Data([0x01, 0x02]))
        XCTAssertEqual(payload.context.activeApp.bundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(payload.model, .flash)
    }

    // MARK: - Memory-only contract (R1)

    /// Runtime conformance probe. Written generically so the check is
    /// made at runtime on an opaque `T.Type` — a direct
    /// `RetainedRecording.self is any Encodable.Type` would let the
    /// compiler resolve it statically and warn that the cast always
    /// fails, which the Definition of Done's warning-free bar forbids.
    private func conformsToCoding<T>(_ type: T.Type) -> Bool {
        type is any Encodable.Type || type is any Decodable.Type
    }

    func test_retainedRecording_isNotSerializable() {
        // R1: retained audio is memory-only and never written to disk.
        // Today that holds by accident at the container level —
        // `ContextSnapshot` is not `Codable`, so `RetainedRecording:
        // Codable` would fail to compile — but `Chunk` has no such
        // barrier: its members are `Int` / `Bool` / `Data` / `Int`, so
        // adding the conformance synthesizes silently, and `Chunk` is
        // the limb that actually holds the user's speech.
        //
        // The plan's Risks section nominates a human reviewer as the
        // guard against serializing this type; this is the mechanical
        // half. `test_retainedRecording_carriesChunksContextAndModel`
        // above is its presence complement — an absence-only assertion
        // would stay green if the type were deleted outright.
        XCTAssertFalse(conformsToCoding(RetainedRecording.self),
                       "RetainedRecording must never be serializable (R1)")
        XCTAssertFalse(conformsToCoding(RetainedRecording.Chunk.self),
                       "RetainedRecording.Chunk must never be serializable (R1)")
    }

    // MARK: - Retain-set derivation (U2)
    //
    // `RecordingSession.retainedPayload(inBatch:failedChunkIndices:context:model:)`
    // is the pure seam the session's two failure arms funnel through:
    // `processBatch`'s single-chunk arm and `splitRetry`'s per-chunk arm
    // each collect the indices that passed `shouldRetain(_:)`, and the
    // batch's encoded chunks plus that set produce the payload. The
    // session itself owns an AudioRecorder / SileroVAD / GeminiClient /
    // HistoryStore and is not drivable end to end, so this is where the
    // R2 / R3 behaviour is proved; the wiring is covered by the plan's
    // manual smoke protocol.

    /// A batch chunk with a distinguishable audio blob and sample count,
    /// so a mis-mapped index is visible rather than plausible.
    private func chunk(
        _ idx: Int,
        isFinal: Bool = false
    ) -> RetainedRecording.Chunk {
        RetainedRecording.Chunk(
            idx: idx,
            isFinal: isFinal,
            audio: Data([UInt8(0xA0 + idx)]),
            samples: 16_000 * (idx + 1)
        )
    }

    private var slackContext: ContextSnapshot {
        ContextSnapshot.minimal(
            activeApp: AppInfo(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        )
    }

    private func payload(
        batch: [RetainedRecording.Chunk],
        failed: Set<Int>,
        context: ContextSnapshot? = nil,
        model: GeminiModel = .flashLite
    ) -> RetainedRecording? {
        RecordingSession.retainedPayload(
            inBatch: batch,
            failedChunkIndices: failed,
            context: context ?? slackContext,
            model: model
        )
    }

    func test_retainSet_oneOfThreeFailed_keepsOnlyThatChunk() {
        // R2: audio for chunks that returned text is released on the
        // existing schedule — only the failed one survives, and it
        // survives at its original chunk index, which is what lets its
        // recovered text land back in the right `[…]` slot later.
        let batch = [chunk(0), chunk(1), chunk(2, isFinal: true)]

        let result = payload(batch: batch, failed: [1])

        XCTAssertEqual(result?.chunks.map(\.idx), [1])
        XCTAssertEqual(result?.chunks.first?.audio, Data([0xA1]))
        XCTAssertEqual(result?.chunks.first?.samples, 32_000)
        XCTAssertEqual(result?.chunks.first?.isFinal, false)
    }

    func test_retainSet_everyChunkFailed_keepsAllInChunkOrder() {
        let batch = [chunk(3), chunk(4), chunk(5, isFinal: true)]

        let result = payload(batch: batch, failed: [3, 4, 5])

        XCTAssertEqual(result?.chunks.map(\.idx), [3, 4, 5])
        XCTAssertEqual(result?.chunks.map(\.isFinal), [false, false, true])
    }

    func test_retainSet_isSortedByChunkIndex_notByBatchOrder() {
        // `failedChunkIndices` is a `Set`, so nothing about iteration
        // order can be relied on, and a future change to the sender's
        // drain order must not reshuffle the payload. Feed the batch
        // deliberately out of order and require ascending output.
        let batch = [chunk(7), chunk(2), chunk(5)]

        let result = payload(batch: batch, failed: [7, 2, 5])

        XCTAssertEqual(result?.chunks.map(\.idx), [2, 5, 7])
    }

    func test_retainSet_noChunkFailed_retainsNothing() {
        // The ordinary successful session: no payload at all, so the
        // normal path gains no memory cost.
        let batch = [chunk(0), chunk(1), chunk(2, isFinal: true)]

        XCTAssertNil(payload(batch: batch, failed: []))
    }

    func test_retainSet_hallucinationGateDrop_retainsNothing() {
        // The gate's third state (`text: ""`, not `nil`): Gemini answered
        // and we filtered the answer. That is not a failure, so the
        // chunk never enters the failed set and nothing is retained —
        // retaining it would hold audio for a call that succeeded.
        // See `NoType/Recording/CLAUDE.md` "Post-response hallucination
        // gate".
        let batch = [chunk(0), chunk(1), chunk(2, isFinal: true)]

        // Chunk 1 was gate-dropped; 0 and 2 transcribed normally.
        XCTAssertNil(payload(batch: batch, failed: []))
    }

    func test_retainSet_gateDropAlongsideARealFailure_keepsOnlyTheFailure() {
        // Same batch, but chunk 2's call genuinely failed. The
        // gate-dropped chunk 1 still contributes nothing.
        let batch = [chunk(0), chunk(1), chunk(2, isFinal: true)]

        let result = payload(batch: batch, failed: [2])

        XCTAssertEqual(result?.chunks.map(\.idx), [2])
    }

    func test_retainSet_carriesTheFrozenContextAndModel() {
        // R3 / KTD3: the payload ships the snapshot the failed requests
        // actually used and the model the session was frozen on — not
        // whatever is current when the payload is read. Both are
        // parameters precisely so nothing inside this function can read
        // live state.
        let frozen = ContextSnapshot.minimal(
            activeApp: AppInfo(name: "Xcode", bundleID: "com.apple.dt.Xcode")
        )

        let result = payload(
            batch: [chunk(0, isFinal: true)],
            failed: [0],
            context: frozen,
            model: .flash
        )

        XCTAssertEqual(result?.context, frozen)
        XCTAssertEqual(result?.context.activeApp.bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(result?.model, .flash)
    }

    func test_retainSet_indexWithNoMatchingChunk_fabricatesNothing() {
        // The filter runs over the batch, not over the index set, so a
        // set carrying an index the batch never held (a sub-150 ms chunk
        // dropped before encode, say) yields no chunk rather than a
        // synthesised one with empty audio.
        let batch = [chunk(0), chunk(1)]

        XCTAssertNil(payload(batch: batch, failed: [9]))
        XCTAssertEqual(payload(batch: batch, failed: [1, 9])?.chunks.map(\.idx), [1])
    }

    func test_retainSet_emptyBatch_retainsNothing() {
        XCTAssertNil(payload(batch: [], failed: [0, 1]))
    }

    // MARK: - SessionSummary carries the payload

    func test_sessionSummary_defaultsToNoRetainedPayload() {
        // The successful session's shape: `AppState` branches on
        // presence, so absence has to be the default rather than an
        // empty payload.
        let summary = RecordingSession.SessionSummary(
            failedChunkCount: 0,
            dispatchedChunkCount: 3,
            tokens: .zero,
            model: .flashLite
        )
        XCTAssertNil(summary.retained)
    }

    func test_sessionSummary_carriesRetainedPayloadVerbatim() {
        let retained = payload(batch: [chunk(0), chunk(1, isFinal: true)],
                               failed: [0, 1])
        let summary = RecordingSession.SessionSummary(
            failedChunkCount: 2,
            dispatchedChunkCount: 2,
            tokens: .zero,
            model: .flashLite,
            retained: retained
        )

        XCTAssertTrue(summary.hasFailures)
        XCTAssertEqual(summary.retained?.chunks.map(\.idx), [0, 1])
        XCTAssertEqual(summary.retained?.chunks.map(\.audio),
                       [Data([0xA0]), Data([0xA1])])
    }
}
