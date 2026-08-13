import XCTest
@testable import NoType

/// Pins the network-class bound on `RecordingSession.splitRetry`: once the
/// batched call **and** the first split chunk have both failed in the
/// status-0 class, the remaining chunks are accounted for without being
/// dispatched into the same wall.
///
/// **The dangerous half is retention, not latency.** Retention today is
/// driven by classifying a real error through `shouldRetain(_:)`. A chunk
/// that is never dispatched produces no error, so the naive shape of this
/// change would let its audio fall out of the accumulation path — turning a
/// bounded wait into permanent data loss, which is the exact inverse of
/// what the retry feature exists to do. Every test below that touches
/// `abandonedAccounting` is really asking one question: *is an undispatched
/// chunk indistinguishable from a dispatched-and-failed one?*
///
/// The session owns an AudioRecorder / SileroVAD / GeminiClient /
/// HistoryStore and is not drivable end to end, so the proof lives at the
/// pure seams the abandon arm is assembled from — the same shape
/// `RetainedRecordingTests` uses for the retention path it extends.
final class SplitRetryNetworkBoundTests: XCTestCase {

    private typealias GErr = GeminiClient.GeminiError

    private struct EncodeFailure: Error {}

    private let offline = GErr.http(status: 0, body: "URLError code=-1009: offline")

    // MARK: - The network class

    func test_isNetworkClass_isStatusZeroOnly() {
        XCTAssertTrue(RecordingSession.isNetworkClass(offline))
        XCTAssertTrue(RecordingSession.isNetworkClass(GErr.offlineShortCircuit))
    }

    /// Swept over the status space rather than the handful of statuses the
    /// bound was designed against, so a future `case 0...99` style edit
    /// cannot widen the class unnoticed. A 5xx or a 429 is per-request —
    /// the next chunk genuinely might succeed — so those must keep today's
    /// dispatch-everything behaviour.
    func test_isNetworkClass_isFalseForEveryOtherStatus() {
        for status in 1...599 {
            XCTAssertFalse(
                RecordingSession.isNetworkClass(GErr.http(status: status, body: "")),
                "HTTP \(status) must not count as the network class — only status 0 does."
            )
        }
    }

    func test_isNetworkClass_isFalseForNonHTTPErrors() {
        let others: [Error] = [
            GErr.missingKey,
            GErr.empty,
            GErr.truncated,
            GErr.blocked("SAFETY"),
            GErr.decoding(EncodeFailure()),
            CancellationError(),
            EncodeFailure(),
        ]
        for error in others {
            XCTAssertFalse(RecordingSession.isNetworkClass(error), "\(error)")
        }
    }

    // MARK: - The trigger

    /// Truth table. All three terms are required, and each one is a
    /// separate reason the bound would be wrong on its own: without the
    /// batch term a lone network blip on one chunk would abandon the rest;
    /// without the offset term a mid-run failure would abandon chunks the
    /// run had already proved were reachable; without the chunk term a
    /// network-failed batch whose first chunk then failed on a 5xx would
    /// abandon on the wrong evidence.
    func test_shouldAbandon_requiresAllFourTerms() {
        let slow = RecordingSession.abandonMinChunkFailureLatency
        // Default stands for "a real timeout": the budget of the request
        // `splitRetry` actually issues, which is always single-part. Taken
        // from the budget function rather than a literal so a future cut
        // cannot leave this fixture describing a wait that no longer exists.
        func decide(
            _ batch: Bool,
            _ offset: Int,
            _ chunk: Bool,
            _ latency: Duration = .seconds(GeminiClient.requestInactivityBudget(audioPartCount: 1))
        ) -> Bool {
            RecordingSession.shouldAbandonSplitRetry(
                batchFailureWasNetwork: batch,
                chunkOffset: offset,
                chunkFailureWasNetwork: chunk,
                chunkFailureLatency: latency
            )
        }
        XCTAssertTrue(decide(true, 0, true), "Batch and first chunk both network, and the chunk cost a real timeout — the only abandoning case.")
        XCTAssertFalse(decide(false, 0, true), "Batch failed for another reason; the network evidence is one sample.")
        XCTAssertFalse(decide(true, 0, false), "First chunk failed for another reason.")
        XCTAssertFalse(decide(true, 1, true), "Only the first split chunk's verdict abandons the run.")
        XCTAssertFalse(decide(true, 2, true))
        XCTAssertFalse(decide(false, 1, false))

        // The latency term. A reachability short-circuit answers in ~0 ms,
        // so two of them is one cached path status read twice — not two
        // observations. Abandoning on that turns a two-second Wi-Fi blip
        // into permanent `[…]` in the pasted text, and saves nothing,
        // because the remaining chunks would short-circuit in ~0 ms too.
        XCTAssertFalse(
            decide(true, 0, true, .zero),
            "Two instant pre-check short-circuits are one observation, not two — abandoning there is both pointless and destructive."
        )
        XCTAssertFalse(decide(true, 0, true, .milliseconds(1)))
        XCTAssertTrue(decide(true, 0, true, slow), "The threshold itself must abandon — the comparison is >=, not >.")
    }

    /// The threshold has to separate the two shapes it exists to tell
    /// apart, or the term is decoration: a pre-check short-circuit is
    /// sub-millisecond, a real `URLSession` timeout is one whole request
    /// budget.
    ///
    /// **The upper bound is the property, not a literal** (plan KTD4).
    /// It used to be `.seconds(30)`, which stopped being the timeout the
    /// moment U1 made the budget a function of the request's audio-part
    /// count — and a literal here would have stayed green while drifting
    /// arbitrarily close to (or past) the real ceiling. The comparison is
    /// against the **single-part** budget because that is the shape
    /// `splitRetry` issues: it only ever re-sends one chunk per call, so
    /// the request being timed always carries exactly one audio part.
    func test_abandonLatencyThreshold_sitsBetweenAShortCircuitAndATimeout() {
        let singlePartBudget = Duration.seconds(
            GeminiClient.requestInactivityBudget(audioPartCount: 1)
        )
        XCTAssertGreaterThan(
            RecordingSession.abandonMinChunkFailureLatency, .milliseconds(100),
            "Below this the threshold stops separating a real failure from a ~0 ms reachability short-circuit, which is the only reason the term exists."
        )
        XCTAssertLessThan(
            RecordingSession.abandonMinChunkFailureLatency, singlePartBudget,
            "A genuine timeout must always clear the threshold. At or above the budget, the case the bound was built for — a `.satisfied` path whose requests still time out — could never fire it."
        )
    }

    /// The derivation itself, pinned separately from the range above.
    ///
    /// The range test alone is satisfiable by any literal between 100 ms
    /// and 12 s, so it would stay green if someone replaced the derived
    /// expression with a hard-coded `.seconds(2)` — losing exactly the
    /// property KTD4 asked for, which is that the threshold *shrinks in
    /// step* with the budget rather than drifting toward it. This pins the
    /// ratio, so a change to either side has to be deliberate.
    func test_abandonLatencyThreshold_isDerivedFromTheSinglePartBudget() {
        XCTAssertEqual(
            RecordingSession.abandonMinChunkFailureLatency,
            .seconds(GeminiClient.requestInactivityBudget(audioPartCount: 1) / 6),
            "The threshold is a fixed fraction of the budget of the request it times, not a number of its own."
        )
        // And the value that fraction currently produces is the one that
        // shipped before the derivation replaced it — the derivation was
        // meant to change how the number is *reached*, not the number.
        XCTAssertEqual(
            RecordingSession.abandonMinChunkFailureLatency, .seconds(2),
            "U1's handoff computed 12 s / 6 = 2 s specifically so U2 carried zero behavioural risk. If this fails, the budget moved and the behaviour moved with it — which is intended, but should be a deliberate read."
        )
    }

    /// The one mutation neither assertion above can see, and the only
    /// reason a source guard earns its place here.
    ///
    /// Both are value comparisons, and the derived expression and the
    /// literal `.seconds(2)` evaluate to the *same value today* — so
    /// replacing the derivation with the literal (i.e. reverting to what
    /// shipped before KTD4) leaves this file entirely green while
    /// silently giving up the property KTD4 asked for: that the threshold
    /// shrinks in step with the budget rather than drifting toward it.
    ///
    /// **Verified by running it**, not by reasoning: replacing the
    /// declaration with `nonisolated static let
    /// abandonMinChunkFailureLatency: Duration = .seconds(2)` and running
    /// this class leaves 16 of 17 tests green — including both value
    /// assertions above — and fails only this one. That asymmetry is the
    /// entire justification for a source guard here.
    ///
    /// Scoped to the **single declaration statement**, not the file: a
    /// file-wide search for the budget call would also match this test's
    /// own prose or any future unrelated use.
    ///
    /// Limits, per `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`:
    /// this matches literal spellings in one file. Renaming either symbol
    /// fails it loudly, which is a review trigger rather than a false
    /// negative. It proves the budget call is *in the initializer
    /// expression*, not that the arithmetic around it is still `/ 6` —
    /// that is what the ratio assertion above is for. The two are
    /// complementary and neither alone is sufficient.
    func test_abandonLatencyThreshold_isDerivedInSource_notRestatedAsALiteral() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()    // NoTypeTests/
                .deletingLastPathComponent()    // repo root
                .appendingPathComponent("NoType/Recording/RecordingSession.swift"),
            encoding: .utf8
        )
        let declaration = "nonisolated static let abandonMinChunkFailureLatency: Duration ="
        XCTAssertEqual(
            source.components(separatedBy: declaration).count - 1, 1,
            "Expected exactly one declaration of abandonMinChunkFailureLatency. Zero means it was renamed or removed and this guard lost its anchor; more than one means the needle no longer identifies a single statement."
        )
        let initializer = try XCTUnwrap(source.range(of: declaration))
        // The statement runs to the end of the following line — the
        // declaration wraps, so one line past the `=` is the expression.
        let afterEquals = source[initializer.upperBound...]
        let statement = afterEquals.prefix { $0 != ")" }
        XCTAssertTrue(
            statement.contains("GeminiClient.requestInactivityBudget(audioPartCount: 1"),
            "The threshold must be derived from the budget of the request it times, not restated as a literal — that is the whole of KTD4. Got: \(statement)"
        )
    }

    // MARK: - Accounting for chunks that are never dispatched

    func test_abandonedAccounting_marksEveryUndispatchedChunkExactlyOnce() {
        let acct = RecordingSession.abandonedAccounting(
            undispatched: [chunk(1), chunk(2), chunk(3)],
            error: offline
        )
        XCTAssertEqual(
            acct.markerChunkIndices, [1, 2, 3],
            "Every undispatched chunk owes exactly one marker, at its original index — that is what makes it count toward failedChunkCount."
        )
    }

    /// The retention half of the critical constraint, at the seam.
    func test_abandonedAccounting_retainsEveryUndispatchedChunk() {
        let acct = RecordingSession.abandonedAccounting(
            undispatched: [chunk(1), chunk(2)],
            error: offline
        )
        XCTAssertEqual(
            acct.retainable, [1, 2],
            "An undispatched chunk's audio must be retained, or the bound trades a wait for permanent data loss."
        )
    }

    /// The retention decision is delegated to `shouldRetain(_:)` rather
    /// than hard-coded to "always". Production cannot reach this arm with a
    /// non-retainable error (the trigger requires the network class, which
    /// is retainable), but hard-coding would silently break the day the
    /// trigger widens.
    func test_abandonedAccounting_consultsTheRetentionClassifier() {
        let acct = RecordingSession.abandonedAccounting(
            undispatched: [chunk(1), chunk(2)],
            error: GErr.blocked("SAFETY")
        )
        XCTAssertEqual(
            acct.markerChunkIndices, [1, 2],
            "A chunk that is not dispatched is still a gap in the transcript, whatever the error class."
        )
        XCTAssertTrue(
            acct.retainable.isEmpty,
            "Retention must go through shouldRetain(_:), not be assumed."
        )
    }

    func test_abandonedAccounting_withNothingLeftIsEmpty() {
        let acct = RecordingSession.abandonedAccounting(undispatched: [], error: offline)
        XCTAssertTrue(acct.markerChunkIndices.isEmpty)
        XCTAssertTrue(acct.retainable.isEmpty)
    }

    // MARK: - THE critical test: audio reaches SessionSummary.retained

    /// Composes the abandon arm exactly as `splitRetry` does — chunk 0
    /// dispatched and failed, chunks 1 and 2 abandoned — and asserts the
    /// resulting payload is **identical** to the one a run that dispatched
    /// all three and failed all three would have produced.
    ///
    /// Equality is asserted field by field on purpose: an index-only check
    /// would pass on a payload carrying the right slots and the wrong
    /// bytes, which is the failure mode that would reach the user as a
    /// retry that recovers someone else's audio.
    func test_abandonedChunksReachTheRetainedPayload_withAudioAndOriginalIndex() throws {
        let batch = [chunk(0), chunk(1), chunk(2)]

        // What splitRetry accumulates: chunk 0 failed on dispatch...
        var retainable: Set<Int> = []
        retainable.insert(batch[0].idx)
        // ...and chunks 1-2 are abandoned rather than dispatched.
        let acct = RecordingSession.abandonedAccounting(
            undispatched: Array(batch.dropFirst(1)),
            error: offline
        )
        retainable.formUnion(acct.retainable)

        let abandoned = try XCTUnwrap(
            RecordingSession.retainedPayload(
                inBatch: batch,
                failedChunkIndices: retainable,
                context: slackContext,
                model: .flashLite
            ),
            "The abandoned run produced no retained payload at all — its audio is gone."
        )

        // The counterfactual: every chunk dispatched, every chunk failed.
        let allDispatched = try XCTUnwrap(
            RecordingSession.retainedPayload(
                inBatch: batch,
                failedChunkIndices: [0, 1, 2],
                context: slackContext,
                model: .flashLite
            )
        )

        XCTAssertEqual(abandoned.chunks.map(\.idx), [0, 1, 2])
        XCTAssertEqual(
            abandoned.chunks.map(\.idx), allDispatched.chunks.map(\.idx),
            "An undispatched chunk must occupy the same slot as a dispatched-and-failed one."
        )
        XCTAssertEqual(
            abandoned.chunks.map(\.audio), allDispatched.chunks.map(\.audio),
            "Undispatched chunks must carry their own encoded audio — this is the whole point of the bound."
        )
        XCTAssertEqual(abandoned.chunks.map(\.samples), allDispatched.chunks.map(\.samples))
        XCTAssertEqual(abandoned.chunks.map(\.isFinal), allDispatched.chunks.map(\.isFinal))
        XCTAssertEqual(abandoned.model, allDispatched.model)
    }

    /// The final chunk is the one a user notices losing, and it is always
    /// the last in dispatch order — i.e. always among the abandoned set
    /// when the bound fires on chunk 0. Its `isFinal` flag must survive,
    /// because `GeminiClient` picks the final- versus mid-chunk
    /// instruction line from it.
    func test_abandonedFinalChunk_keepsItsFinalFlag() throws {
        let batch = [chunk(0), chunk(1), chunk(2, isFinal: true)]
        let acct = RecordingSession.abandonedAccounting(
            undispatched: Array(batch.dropFirst(1)),
            error: offline
        )
        let payload = try XCTUnwrap(
            RecordingSession.retainedPayload(
                inBatch: batch,
                failedChunkIndices: acct.retainable.union([0]),
                context: slackContext,
                model: .flashLite
            )
        )
        XCTAssertEqual(payload.chunks.last?.idx, 2)
        XCTAssertTrue(
            try XCTUnwrap(payload.chunks.last).isFinal,
            "A retry of the abandoned final chunk must send the final-chunk instruction, as the dispatch that never happened would have."
        )
    }

    // MARK: - ...and counts toward failedChunkCount

    /// `SessionSummary.failedChunkCount` is the sum of `chunkIndices.count`
    /// over responses whose `text` is nil — the arithmetic `summary` runs.
    /// The abandon arm appends one such response per marker index, so an
    /// abandoned chunk is counted exactly like a dispatched-and-failed one
    /// and renders a `[…]` in the same slot.
    func test_abandonedChunksCountTowardFailedChunkCount() {
        let acct = RecordingSession.abandonedAccounting(
            undispatched: [chunk(1), chunk(2)],
            error: offline
        )
        // Chunk 0: dispatched, failed. Chunks 1-2: abandoned.
        let responses =
            [RecordingSession.ChunkResponse(chunkIndices: [0], text: nil)]
            + acct.markerChunkIndices.map {
                RecordingSession.ChunkResponse(chunkIndices: [$0], text: nil)
            }

        let counts = RecordingSession.chunkCounts(in: responses)
        XCTAssertEqual(
            counts.failed, 3,
            "All three chunks are gaps in the transcript; only one of them was ever sent."
        )
        XCTAssertEqual(counts.dispatched, 3)
    }

    /// The complement, so the counter above is not trivially always-3: a
    /// run where the abandoned chunks recovered contributes nothing.
    func test_chunkCounts_doesNotCountRecoveredChunks() {
        let responses = [
            RecordingSession.ChunkResponse(chunkIndices: [0], text: nil),
            RecordingSession.ChunkResponse(chunkIndices: [1], text: "recovered"),
            // The hallucination gate's third state: answered, then filtered.
            RecordingSession.ChunkResponse(chunkIndices: [2], text: ""),
        ]
        let counts = RecordingSession.chunkCounts(in: responses)
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(counts.dispatched, 3)
    }

    // MARK: - The call site (what the seams above do NOT prove)

    /// Everything above pins the pure seams and then **hand-composes** them
    /// the way `splitRetry` is supposed to. That leaves the composition
    /// itself — the three lines inside `splitRetry` that actually call
    /// them — unproven, and the gap is not theoretical: deleting
    /// `retainable.formUnion(acct.retainable)` from the abandon arm, which
    /// is precisely the permanent-audio-loss bug this whole file exists to
    /// prevent, left every other test in this class green. So did gutting
    /// the arm entirely.
    ///
    /// `RecordingSession` owns an `AudioRecorder`, a `SileroVAD`, a
    /// `GeminiClient` and a `HistoryStore` and cannot be driven end to end,
    /// so this is a source guard in the shape `RaiseSiteScanner`
    /// (`HUDPanelGeometryTests.swift`) established, and it inherits that
    /// shape's documented limits: it matches literal spellings in one file
    /// and proves the statements are *present*, not that they are reached.
    /// A rename makes it fail loudly, which is a review trigger rather than
    /// a false negative. It is strictly better than the nothing that was
    /// there before, and the mutations above are what calibrated it.
    func test_splitRetryAbandonArm_stillMarksAndRetainsEveryUndispatchedChunk() throws {
        let body = try XCTUnwrap(
            Self.body(ofFuncNamed: "splitRetry", in: Self.recordingSessionSource()),
            "Could not parse splitRetry — the guard lost its anchor."
        )

        // Presence complement: the arm exists at all. Without this the two
        // assertions below are vacuously true on a file that deleted it.
        XCTAssertTrue(
            body.contains("shouldAbandonSplitRetry("),
            "splitRetry no longer consults the abandon predicate — the bound is gone."
        )
        let acct = try XCTUnwrap(
            body.range(of: "abandonedAccounting("),
            "splitRetry no longer derives the abandoned accounting, so nothing can mark or retain the undispatched chunks."
        )

        // The retention half. Dropping this line is silent permanent loss
        // of the user's audio — verified green across every other test in
        // this class before this guard existed.
        XCTAssertTrue(
            body.contains("retainable.formUnion(acct.retainable)"),
            "splitRetry must fold the abandoned chunks' retention set into the set it returns, or their audio never reaches SessionSummary.retained and the user's recording is gone."
        )

        // The marker half. Without it the undispatched chunks produce no
        // `[…]`, do not count toward failedChunkCount, and the user is
        // never told anything was dropped.
        XCTAssertTrue(
            body.contains("recordRecoverableFailure(error: error, indices: [idx])"),
            "splitRetry must record one recoverable failure per abandoned chunk index, or the gaps are silent."
        )

        // Ordering: both effects must follow the accounting that produced
        // them, so a refactor cannot leave them reading a stale value.
        let fold = try XCTUnwrap(body.range(of: "retainable.formUnion(acct.retainable)"))
        XCTAssertLessThan(acct.lowerBound, fold.lowerBound)
    }

    /// Fixture proving the extractor above starts and stops at the right
    /// braces — without it, a guard that silently matched the whole file
    /// would pass on a `splitRetry` that had lost the arm entirely.
    func test_bodyExtractor_isScopedToTheNamedFunction() throws {
        let source = """
        private func other() {
            retainable.formUnion(acct.retainable)
        }

        private func splitRetry(
            encoded: [EncodedChunk]
        ) async -> Set<Int> {
            let marker = 1
        }
        """
        let body = try XCTUnwrap(Self.body(ofFuncNamed: "splitRetry", in: source))
        XCTAssertTrue(body.contains("let marker = 1"))
        XCTAssertFalse(
            body.contains("formUnion"),
            "The extractor ran past its function — the assertions above would be satisfiable by a neighbouring function."
        )
    }

    /// Brace-balanced slice of a named function's body. Same shape and same
    /// caveats as the extractor in `GeminiClientOfflineShortCircuitTests`
    /// (naive about braces inside string literals; adequate for the one
    /// Swift file it reads).
    private static func body(ofFuncNamed name: String, in source: String) -> String? {
        guard let decl = source.range(of: "func \(name)(") else { return nil }
        guard let open = source.range(of: "{", range: decl.upperBound..<source.endIndex) else { return nil }
        var depth = 0
        var idx = open.lowerBound
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: open.lowerBound)...idx])
                }
            }
            idx = source.index(after: idx)
        }
        return nil
    }

    private static func recordingSessionSource() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NoTypeTests/
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("NoType/Recording/RecordingSession.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Fixtures

    /// A chunk with a distinguishable audio blob and sample count, so a
    /// mis-mapped index is visible rather than plausible.
    private func chunk(_ idx: Int, isFinal: Bool = false) -> RetainedRecording.Chunk {
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
}
