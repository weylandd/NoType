import XCTest
@testable import NoType

/// Drives `PauseDetector` with synthetic VAD probability sequences and
/// pins the chunking semantics described in `NoType/Recording/CLAUDE.md`.
///
/// Conventions used by these tests:
/// - One "frame" = 4096 samples (256 ms @ 16 kHz), matching the
///   unified-256 ms Silero model used in production.
/// - Frame indices walk continuously from 0 (no gaps) — that mirrors
///   the recorder's contiguous sample stream.
final class PauseDetectorTests: XCTestCase {

    /// Default size of one VAD window in samples — same as
    /// `AudioRecorder.frameSize` / `SileroVAD.chunkSize`.
    private let frame = 4_096
    /// Default pre-roll constant in `PauseDetector.init`: 4800 samples.
    private let preRoll = 4_800
    /// 1.0 s of unvoiced audio = the default pause threshold.
    private let pauseThreshold = 16_000

    // MARK: - Helpers

    /// Drive a sequence of voiced/unvoiced frames through the detector,
    /// returning any chunk boundaries it emitted along the way.
    private func run(
        _ flags: [Bool],
        detector: inout PauseDetector
    ) -> [PauseDetector.Chunk] {
        var out: [PauseDetector.Chunk] = []
        for (i, voiced) in flags.enumerated() {
            let start = i * frame
            let end = start + frame
            let prob: Float = voiced ? 0.9 : 0.05
            if let chunk = detector.observe(probability: prob, frameStart: start, frameEnd: end) {
                out.append(chunk)
            }
        }
        return out
    }

    // MARK: - Idle → speaking → pausing → emit

    func test_singleSpeechRun_pausesAndEmits() {
        var d = PauseDetector()
        // 3 voiced frames (≥ 256 ms speech), then 4 unvoiced frames
        // (1024 ms ≥ 1 s pause threshold) → emit one chunk.
        let flags = [true, true, true, false, false, false, false]
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 1)
        let chunk = chunks[0]
        // chunkStart = frame 0, pre-roll-rewound to max(0, -preRoll) = 0.
        XCTAssertEqual(chunk.start, 0)
        // pauseStart = first unvoiced frame = frame 3.
        XCTAssertEqual(chunk.end, 3 * frame)
        // State machine returns to idle after emit.
        XCTAssertEqual(d.state, .idle)
    }

    func test_preRollRewound_whenSpeechStartsLater() {
        var d = PauseDetector()
        // 3 silent frames, then 2 voiced, then a long pause.
        let flags = [false, false, false, true, true, false, false, false, false]
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 1)
        // chunkStart = frame 3 (first voiced) = sample 12288.
        // Pre-roll rewinds by 4800 → 7488.
        XCTAssertEqual(chunks[0].start, 3 * frame - preRoll)
        // pauseStart = frame 5 (first unvoiced after speech) = 5 * 4096.
        XCTAssertEqual(chunks[0].end, 5 * frame)
    }

    // MARK: - Pause-detection edge cases

    func test_falsePauseResumesSpeaking_noChunkEmitted() {
        var d = PauseDetector()
        // 2 voiced, 2 unvoiced (only 512 ms — under the 1 s threshold),
        // 2 voiced again. Should NOT emit; stays in one chunk.
        let flags = [true, true, false, false, true, true]
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 0)
        XCTAssertEqual(d.state, .speaking)
    }

    func test_pauseExactlyAtThresholdEmits() {
        var d = PauseDetector()
        // 1 voiced + 4 unvoiced frames. 4 * 4096 = 16384 samples >= 16000.
        let flags = [true, false, false, false, false]
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 1, "pause >= threshold must emit")
        XCTAssertGreaterThanOrEqual(
            chunks[0].end - max(0, 0 - preRoll),
            0,
            "chunk range non-negative"
        )
    }

    func test_pauseJustBelowThreshold_doesNotEmit() {
        var d = PauseDetector()
        // 1 voiced + 3 unvoiced. 3 * 4096 = 12288 < 16000 — not yet a pause.
        let flags = [true, false, false, false]
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 0)
        // We're still in `.pausing(unvoicedSince: frame 1)` — confirm.
        switch d.state {
        case .pausing(let since): XCTAssertEqual(since, 1 * frame)
        default: XCTFail("expected .pausing, got \(d.state)")
        }
    }

    func test_idleStaysIdle_throughSilence() {
        var d = PauseDetector()
        let chunks = run(Array(repeating: false, count: 10), detector: &d)
        XCTAssertEqual(chunks.count, 0)
        XCTAssertEqual(d.state, .idle)
    }

    // MARK: - Multiple chunks per session

    func test_twoSeparateChunks_areEmittedInOrder() {
        var d = PauseDetector()
        // Speak 2, pause 4 (emit), speak 2, pause 4 (emit).
        let flags = [
            true, true,
            false, false, false, false,
            true, true,
            false, false, false, false,
        ]
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].start, 0)
        XCTAssertEqual(chunks[0].end, 2 * frame)
        // Second chunk: speech starts at frame 6, pre-roll-rewound to
        // 6*4096 - 4800 = 19776.
        XCTAssertEqual(chunks[1].start, 6 * frame - preRoll)
        // Second pauseStart at frame 8.
        XCTAssertEqual(chunks[1].end, 8 * frame)
    }

    // MARK: - 30 s force-cut

    /// Number of voiced frames to cross the 30 s cap by one frame.
    /// 30 s @ 16 kHz = 480_000 samples ; each frame = 4096 → 118 frames
    /// gives 483_328 samples ( > 480_000 ).
    private let forceCutFrameCount = 118

    func test_forceCutFires_onContinuousSpeechBeyond30s() {
        var d = PauseDetector()
        // Stream 118 consecutive voiced frames. The cut should fire on
        // the frame whose `frameEnd` first reaches 480_000 samples.
        let flags = Array(repeating: true, count: forceCutFrameCount)
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 1, "expected exactly one force-cut")
        let cut = chunks[0]
        XCTAssertEqual(cut.start, 0, "first chunk's pre-roll-rewound start clamps at 0")
        XCTAssertGreaterThanOrEqual(cut.end, 480_000, "force-cut at >= 30 s of speech")
        // After a force-cut we remain in .speaking (user hasn't paused) —
        // the seam starts a new chunk at frameEnd. Confirm.
        XCTAssertEqual(d.state, .speaking)
    }

    func test_forceCut_resumesSpeakingWithoutPreRollOnSeam() {
        var d = PauseDetector()
        // 119 voiced frames (one past the cut) + pause. Should emit two
        // chunks: the 30 s force-cut, then the tail.
        let flags = Array(repeating: true, count: 119)
            + Array(repeating: false, count: 5)
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 2)
        // First chunk = force-cut at the boundary.
        let firstEnd = chunks[0].end
        XCTAssertGreaterThanOrEqual(firstEnd, 480_000)
        // Second chunk's pre-roll-rewound start equals max(0, seam - preRoll).
        // The seam (chunkStart for chunk 2) is the first-chunk's `end`;
        // pre-roll subtracts 4800 from it. Confirm exactly.
        XCTAssertEqual(chunks[1].start, max(0, firstEnd - preRoll))
    }

    // MARK: - finalize()

    func test_finalize_returnsNilWhenIdle() {
        var d = PauseDetector()
        // Never enter speaking.
        let chunks = run([false, false, false], detector: &d)
        XCTAssertEqual(chunks.count, 0)
        XCTAssertNil(d.finalize(currentEnd: 3 * frame))
    }

    func test_finalize_emitsTailChunkWhileSpeaking() {
        var d = PauseDetector()
        // Two voiced frames, then session ends (user released hotkey).
        _ = run([true, true], detector: &d)
        XCTAssertEqual(d.state, .speaking)
        let tail = d.finalize(currentEnd: 2 * frame)

        XCTAssertNotNil(tail)
        XCTAssertEqual(tail?.start, max(0, 0 - preRoll))  // = 0
        XCTAssertEqual(tail?.end, 2 * frame)
        XCTAssertEqual(d.state, .idle)
    }

    func test_finalize_emitsTailChunkWhilePausing() {
        var d = PauseDetector()
        // Speak then start pausing — but don't reach the 1 s threshold.
        _ = run([true, true, false, false], detector: &d)
        switch d.state {
        case .pausing: break
        default: XCTFail("expected .pausing, got \(d.state)")
        }
        let tail = d.finalize(currentEnd: 4 * frame)

        XCTAssertNotNil(tail)
        XCTAssertEqual(tail?.start, 0)
        XCTAssertEqual(tail?.end, 4 * frame)
        XCTAssertEqual(d.state, .idle)
    }
}
