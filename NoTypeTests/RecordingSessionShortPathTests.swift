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
///
/// See `merry-percolating-hare.md` plan + `NoType/Recording/CLAUDE.md`
/// "Short final-only path (lite context)" subsection.
final class RecordingSessionShortPathTests: XCTestCase {

    // MARK: - Happy path

    func test_finalOnly_underTwoSeconds_emptyTranscripts_isLite() {
        XCTAssertTrue(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 16_000        // 1.0 s
        ))
    }

    func test_finalOnly_oneSampleUnderThreshold_isLite() {
        XCTAssertTrue(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 31_999        // just under 2.0 s
        ))
    }

    // MARK: - Threshold boundary (strict less-than)

    func test_atThreshold_exact_isNotLite() {
        // Strict `<` — 32 000 samples exactly is NOT lite.
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 32_000
        ))
    }

    func test_overThreshold_isNotLite() {
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 0,
            totalBatchSamples: 48_000        // 3 s
        ))
    }

    // MARK: - Non-final batches

    func test_nonFinal_shortAudio_isNotLite() {
        // VAD-pause-triggered chunk that happens to be short. Still must
        // wait for full context — lite is reserved for user-release.
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: false,
            priorTranscriptCount: 0,
            totalBatchSamples: 16_000
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
            totalBatchSamples: 16_000
        ))
    }

    func test_finalShort_withSinglePriorTranscript_isNotLite() {
        XCTAssertFalse(RecordingSession.shouldUseLitePath(
            isFinalBatch: true,
            priorTranscriptCount: 1,
            totalBatchSamples: 8_000
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
            totalBatchSamples: 0
        ))
    }

    func test_thresholdConstant_isTwoSeconds() {
        // Sanity-pin so a careless edit to the constant trips this test.
        // 32 000 samples @ 16 kHz = 2.0 s.
        XCTAssertEqual(RecordingSession.shortSessionMaxSamples, 32_000)
    }
}
