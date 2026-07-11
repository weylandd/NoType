import XCTest
@testable import NoType

/// Pins the pure-function discriminator that decides whether a final
/// batch goes through the short-session lite path. The discriminator
/// lives on `RecordingSession` as a nonisolated static so we can test
/// it without standing up a real session (which owns AVAudioEngine /
/// GeminiClient / HistoryStore — not unit-test-friendly).
///
/// Lite path fires iff ALL hold:
///   1. `isFinalBatch` — batch contains the final chunk (user release).
///   2. `priorTranscriptCount == 0` — no chunks have been transcribed
///      yet in this session.
///   3. `totalBatchSamples < shortSessionMaxSamples` — audio fits under
///      2 s at 16 kHz.
///   4. `batchChunkCount == 1` — the batch encodes to exactly one audio
///      chunk. The lite dispatch ships `encoded[0]` only, so a ≥2-chunk
///      batch would silently drop every chunk after the first (R1).
///
/// See `merry-percolating-hare.md` plan + `NoType/Recording/CLAUDE.md`
/// "Short final-only path (lite context)" subsection.
final class RecordingSessionShortPathTests: XCTestCase {

    // MARK: - Happy path

    func test_finalOnly_underTwoSeconds_emptyTranscripts_isLite() {
        XCTAssertTrue(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 16_000,       // 1.0 s
            batchChunkCount: 1
        ))
    }

    func test_finalOnly_oneSampleUnderThreshold_isLite() {
        XCTAssertTrue(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 31_999,       // just under 2.0 s
            batchChunkCount: 1
        ))
    }

    // MARK: - Threshold boundary (strict less-than)

    func test_atThreshold_exact_isNotLite() {
        // Strict `<` — 32 000 samples exactly is NOT lite.
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 32_000,
            batchChunkCount: 1
        ))
    }

    func test_overThreshold_isNotLite() {
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 48_000,       // 3 s
            batchChunkCount: 1
        ))
    }

    // MARK: - Non-final batches

    func test_nonFinal_shortAudio_isNotLite() {
        // VAD-pause-triggered chunk that happens to be short. Still must
        // wait for full context — lite is reserved for user-release.
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: false,
            priorTranscriptCount: 0,
            totalBatchSamples: 16_000,
            batchChunkCount: 1
        ))
    }

    // MARK: - Prior transcripts

    func test_finalShort_withPriorTranscripts_isNotLite() {
        // VAD already split off chunks during this session. The system
        // prompt + full path is needed because Prior chunks must be
        // shipped — lite shape doesn't fit.
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 2,
            totalBatchSamples: 16_000,
            batchChunkCount: 1
        ))
    }

    func test_finalShort_withSinglePriorTranscript_isNotLite() {
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 1,
            totalBatchSamples: 8_000,
            batchChunkCount: 1
        ))
    }

    // MARK: - Batch cardinality (R1 — the drop-later-chunks fix)

    func test_finalShort_twoEncodedChunks_isNotLite() {
        // A queued multi-chunk final batch (e.g. a mid-session VAD split
        // whose sender was busy, then the final chunk piles on behind it)
        // that still totals under 2 s. The lite dispatch would ship only
        // `encoded[0]` yet record every chunk as covered → the user's
        // later words vanish. Cardinality > 1 must force the batched path.
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 16_000,       // 1.0 s total, but two chunks
            batchChunkCount: 2
        ))
    }

    func test_finalShort_oneEncodedChunk_isLite() {
        // The complement of the case above: a single encoded chunk under
        // 2 s with no priors on release is exactly the lite path's home.
        XCTAssertTrue(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 16_000,
            batchChunkCount: 1
        ))
    }

    func test_finalShort_threeEncodedChunks_isNotLite() {
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 24_000,
            batchChunkCount: 3
        ))
    }

    func test_finalShort_zeroEncodedChunks_isNotLite() {
        // Degenerate — an all-dropped batch never reaches the dispatch
        // (the caller returns on `encoded.isEmpty` first), but the pure
        // contract still must not report lite for a non-1 count.
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 0,
            batchChunkCount: 0
        ))
    }

    // MARK: - Edge cases

    func test_finalOnly_zeroSamples_isLite() {
        // Degenerate but well-defined — `< shortSessionMaxSamples` holds.
        // (In practice processBatch drops sub-150 ms chunks elsewhere,
        // so a zero-sample batch never reaches this discriminator. The
        // contract still has to be defined.)
        XCTAssertTrue(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 0,
            batchChunkCount: 1
        ))
    }

    func test_thresholdConstant_isTwoSeconds() {
        // Sanity-pin so a careless edit to the constant trips this test.
        // 32 000 samples @ 16 kHz = 2.0 s.
        XCTAssertEqual(RecordingSession.shortSessionMaxSamples, 32_000)
    }
}
