import XCTest
@testable import NoType

/// Pins the partial-recovery primitives on `RecordingSession`:
///
///   1. `failureMarker` — the visible placeholder inserted into the
///      pasted text when a chunk's Gemini call fails recoverably.
///      Constant on purpose so a casual edit trips this test rather
///      than silently changing what users see in the field.
///   2. `isTerminal(_:)` — classifier that decides whether a Gemini /
///      system error aborts the session or just opens a gap. Terminal
///      errors throw out of `stop()` and surface via Error HUD;
///      recoverable errors become `[…]` markers in the pasted text.
///
/// Higher-level scenarios (split-on-batch-failure, marker-stitch
/// order, "all chunks failed → throw last error") are not unit-tested
/// here — they require a Gemini mock and a full `AudioRecorder` /
/// `SileroVAD` to drive a real `RecordingSession`. Those land
/// alongside the planned `SileroVADTests` work if the value warrants
/// the test scaffolding. See `NoType/Recording/CLAUDE.md` "Partial
/// recovery".
final class RecordingSessionPartialRecoveryTests: XCTestCase {

    // MARK: - Failure marker

    func test_failureMarker_isStableUserVisibleString() {
        // Sanity-pin so a careless edit to the constant trips this
        // test. The marker is part of the user-facing contract — it
        // appears in their pasted text and in the "Pasted with gaps"
        // HUD body string.
        XCTAssertEqual(RecordingSession.failureMarker, "[…]")
    }

    // MARK: - isTerminal — terminal cases

    func test_isTerminal_cancellation_isTerminal() {
        XCTAssertTrue(RecordingSession.isTerminal(CancellationError()))
    }

    func test_isTerminal_missingKey_isTerminal() {
        // No point continuing the session — every subsequent chunk
        // would hit the same authentication wall.
        XCTAssertTrue(RecordingSession.isTerminal(GeminiClient.GeminiError.missingKey))
    }

    func test_isTerminal_blocked_isTerminal() {
        // Content-policy block. Splitting / retrying won't change the
        // policy decision; surface the error and stop.
        XCTAssertTrue(RecordingSession.isTerminal(GeminiClient.GeminiError.blocked("safety")))
    }

    func test_isTerminal_arbitraryNSError_isTerminal() {
        // Unknown error class (e.g. encoder failure, AVFAudio issue)
        // — conservatively terminal. We'd rather fail loudly than
        // accumulate invisible markers from a deeper bug.
        let nsErr = NSError(domain: "FakeDomain", code: 42, userInfo: nil)
        XCTAssertTrue(RecordingSession.isTerminal(nsErr))
    }

    func test_isTerminal_http401_isTerminal() {
        // Bad key — no point burning N×retries on every chunk of a
        // session whose authentication is already broken. The user
        // has to fix the key in Settings before anything works.
        XCTAssertTrue(RecordingSession.isTerminal(
            GeminiClient.GeminiError.http(status: 401, body: "unauthorized")
        ))
    }

    func test_isTerminal_http403_isTerminal() {
        // Key not authorised for this model. Same reasoning as 401 —
        // every chunk will hit the same wall, so fast-fail instead of
        // letting splitRetry burn the user's quota.
        XCTAssertTrue(RecordingSession.isTerminal(
            GeminiClient.GeminiError.http(status: 403, body: "forbidden")
        ))
    }

    // MARK: - isTerminal — recoverable cases (Gemini transient errors)

    func test_isTerminal_http500_isRecoverable() {
        XCTAssertFalse(RecordingSession.isTerminal(
            GeminiClient.GeminiError.http(status: 500, body: "server")
        ))
    }

    func test_isTerminal_http503_isRecoverable() {
        XCTAssertFalse(RecordingSession.isTerminal(
            GeminiClient.GeminiError.http(status: 503, body: "unavailable")
        ))
    }

    func test_isTerminal_http429_isRecoverable() {
        // Rate-limit. GeminiClient already retries with backoff
        // internally — if it gives up, treat as a gap rather than
        // poisoning the rest of a 3-minute monologue.
        XCTAssertFalse(RecordingSession.isTerminal(
            GeminiClient.GeminiError.http(status: 429, body: "rate")
        ))
    }

    func test_isTerminal_httpZero_networkError_isRecoverable() {
        // URLError wrapped by performOnce as status=0 — Wi-Fi blip,
        // DNS hiccup, etc. Independent chunks are likely to succeed
        // when the underlying network recovers.
        XCTAssertFalse(RecordingSession.isTerminal(
            GeminiClient.GeminiError.http(status: 0, body: "URLError code=-1009")
        ))
    }

    func test_isTerminal_empty_isRecoverable() {
        // Mid-session empty response — the chunk genuinely had no
        // intelligible content; gap is benign.
        XCTAssertFalse(RecordingSession.isTerminal(
            GeminiClient.GeminiError.empty
        ))
    }

    func test_isTerminal_decoding_isRecoverable() {
        // Garbled response body — one bad chunk shouldn't sink the
        // whole session.
        let underlying = NSError(domain: "JSON", code: 0, userInfo: nil)
        XCTAssertFalse(RecordingSession.isTerminal(
            GeminiClient.GeminiError.decoding(underlying)
        ))
    }

    // MARK: - SessionSummary basics

    func test_sessionSummary_hasFailures_false_whenNothingFailed() {
        let s = RecordingSession.SessionSummary(
            failedChunkCount: 0,
            dispatchedChunkCount: 3,
            tokens: .zero,
            model: .flashLite
        )
        XCTAssertFalse(s.hasFailures)
    }

    func test_sessionSummary_hasFailures_true_whenAnyFailed() {
        let s = RecordingSession.SessionSummary(
            failedChunkCount: 1,
            dispatchedChunkCount: 5,
            tokens: .zero,
            model: .flashLite
        )
        XCTAssertTrue(s.hasFailures)
    }

    // MARK: - SessionSummary token field (v4)

    func test_sessionSummary_carriesTokens_verbatim() {
        // Pin the tokens field round-trip — `AppState.finalizeRecording`
        // forwards `summary.tokens` straight into `StatsStore.record`
        // so anything that mutates this value silently would skew
        // per-day token totals.
        let t = TokenUsage(input: 1234, output: 567, cached: 890)
        let s = RecordingSession.SessionSummary(
            failedChunkCount: 0,
            dispatchedChunkCount: 1,
            tokens: t,
            model: .flashLite
        )
        XCTAssertEqual(s.tokens, t)
    }

    func test_sessionSummary_carriesFlashModel() {
        // The model field must carry a non-default value verbatim —
        // AppState.finalizeRecording forwards summary.model into
        // StatsStore.record so token costs price at the right per-model
        // rate. Only .flashLite is exercised elsewhere in this file.
        let s = RecordingSession.SessionSummary(
            failedChunkCount: 0,
            dispatchedChunkCount: 1,
            tokens: .zero,
            model: .flash
        )
        XCTAssertEqual(s.model, .flash)
    }

    // MARK: - historySegments (the three-state table, carried onto disk)

    /// R1. The map is one-to-one because `ChunkResponse` already *is* the
    /// stored segment: the positions one Gemini call covered plus the text
    /// it answered with. A batched call answering for several chunks with
    /// one joined transcript stays one segment — per-chunk text does not
    /// exist for it and must not be invented.
    func test_historySegments_mapsResponsesOneToOne_preservingOrderAndPositions() {
        let segments = RecordingSession.historySegments(from: [
            .init(chunkIndices: [0], text: "alpha"),
            .init(chunkIndices: [1, 2], text: "bravo charlie"),
            .init(chunkIndices: [3], text: nil),
        ])
        XCTAssertEqual(segments, [
            .carrying("alpha", at: [0]),
            .carrying("bravo charlie", at: [1, 2]),
            .gap(at: [3]),
        ])
    }

    /// R19 / R27, and the reason the gate stores `""` rather than `nil`:
    /// Gemini answered and *we* dropped the answer, so the position is
    /// text — an empty one — not a lost chunk. Carried onto disk unchanged,
    /// its row is not broken and renders no marker.
    func test_historySegments_gateFilteredChunk_isATextSegment_notAGap() {
        let segments = RecordingSession.historySegments(from: [
            .init(chunkIndices: [0], text: "first"),
            .init(chunkIndices: [1], text: ""),      // hallucination gate fired
            .init(chunkIndices: [2], text: "third"),
        ])
        XCTAssertEqual(segments[1], .carrying("", at: [1]))
        XCTAssertFalse(segments[1].isGap)
        XCTAssertFalse(segments.contains(where: \.isGap),
            "a gate-filtered chunk must not make its row broken")
    }

    /// The two readings of "how many chunks carry no text" must never
    /// drift: `SessionSummary.failedChunkCount` counts them over
    /// `responses`, `HistoryEntry.failedChunkCount` counts them over the
    /// segments those responses became. Swept over the three states,
    /// including a gap spanning two positions.
    func test_historySegments_gapCount_agreesWithChunkCounts() {
        let responses: [RecordingSession.ChunkResponse] = [
            .init(chunkIndices: [0], text: "kept"),
            .init(chunkIndices: [1], text: ""),
            .init(chunkIndices: [2, 3], text: nil),
            .init(chunkIndices: [4], text: nil),
        ]
        let counts = RecordingSession.chunkCounts(in: responses)
        let entry = HistoryEntry(
            id: UUID(),
            text: "kept […] […]",
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(),
            durationSeconds: 1,
            segments: RecordingSession.historySegments(from: responses)
        )
        XCTAssertEqual(counts.failed, 3)
        XCTAssertEqual(entry.failedChunkCount, counts.failed,
            "the row and the summary count the same thing over the same data")
        XCTAssertTrue(entry.isBroken)
    }
}
