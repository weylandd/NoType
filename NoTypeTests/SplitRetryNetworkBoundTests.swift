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
    func test_shouldAbandon_requiresAllThreeTerms() {
        func decide(_ batch: Bool, _ offset: Int, _ chunk: Bool) -> Bool {
            RecordingSession.shouldAbandonSplitRetry(
                batchFailureWasNetwork: batch,
                chunkOffset: offset,
                chunkFailureWasNetwork: chunk
            )
        }
        XCTAssertTrue(decide(true, 0, true), "Batch and first chunk both network — the only abandoning case.")
        XCTAssertFalse(decide(false, 0, true), "Batch failed for another reason; the network evidence is one sample.")
        XCTAssertFalse(decide(true, 0, false), "First chunk failed for another reason.")
        XCTAssertFalse(decide(true, 1, true), "Only the first split chunk's verdict abandons the run.")
        XCTAssertFalse(decide(true, 2, true))
        XCTAssertFalse(decide(false, 1, false))
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
