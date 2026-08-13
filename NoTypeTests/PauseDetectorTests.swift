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

    // MARK: - 180 s force-cut

    /// Number of voiced frames to cross the 180 s cap by one frame.
    /// 180 s @ 16 kHz = 2 880 000 samples ; each frame = 4096 → 704 frames
    /// gives 2 883 584 samples ( > 2 880 000 ).
    private let forceCutFrameCount = 704

    func test_forceCutFires_onContinuousSpeechBeyond180s() {
        var d = PauseDetector()
        // Stream 704 consecutive voiced frames. The cut should fire on
        // the frame whose `frameEnd` first reaches 2_880_000 samples.
        // No unvoiced frames → adaptive threshold never engages; only
        // the force-cut path can produce a chunk here.
        let flags = Array(repeating: true, count: forceCutFrameCount)
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 1, "expected exactly one force-cut")
        let cut = chunks[0]
        XCTAssertEqual(cut.start, 0, "first chunk's pre-roll-rewound start clamps at 0")
        XCTAssertGreaterThanOrEqual(cut.end, 2_880_000, "force-cut at >= 180 s of speech")
        // After a force-cut we remain in .speaking (user hasn't paused) —
        // the seam starts a new chunk at frameEnd. Confirm.
        XCTAssertEqual(d.state, .speaking)
    }

    func test_forceCut_doesNotFire_oneFrameBeforeBoundary() {
        var d = PauseDetector()
        // 703 voiced frames = 2 879 488 samples (< 2 880 000) — exactly
        // one frame short of the 180 s cap. Pins the `>=` comparison.
        let flags = Array(repeating: true, count: forceCutFrameCount - 1)
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 0, "must not force-cut before reaching the cap")
        XCTAssertEqual(d.state, .speaking, "still in mid-speech")
    }

    func test_forceCut_resumesSpeakingWithoutPreRollOnSeam() {
        var d = PauseDetector()
        // 705 voiced frames (one past the cut) + pause. Should emit two
        // chunks: the 180 s force-cut, then the tail.
        let flags = Array(repeating: true, count: forceCutFrameCount + 1)
            + Array(repeating: false, count: 5)
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 2)
        // First chunk = force-cut at the boundary.
        let firstEnd = chunks[0].end
        XCTAssertGreaterThanOrEqual(firstEnd, 2_880_000)
        // Second chunk's pre-roll-rewound start equals max(0, seam - preRoll).
        // The seam (chunkStart for chunk 2) is the first-chunk's `end`;
        // pre-roll subtracts 4800 from it. Confirm exactly.
        XCTAssertEqual(chunks[1].start, max(0, firstEnd - preRoll))
    }

    // MARK: - Adaptive pause threshold

    func test_adaptiveThresholdLadder_pureMapping() {
        // Construct with an explicit base threshold so the assertions stay
        // honest if `PauseDetector.init`'s default ever moves — the ladder
        // contract is "first rung returns the constructor argument", and
        // this test pins that contract independent of the default.
        let d = PauseDetector(pauseThresholdSamples: 16_000)
        // <20 s → base threshold passed at init (here 16_000 = 1000 ms).
        XCTAssertEqual(d.pauseThresholdSamples(forChunkLength: 0), 16_000)
        XCTAssertEqual(d.pauseThresholdSamples(forChunkLength: 319_999), 16_000)
        // 20–40 s → 700 ms = 11_200 samples.
        XCTAssertEqual(d.pauseThresholdSamples(forChunkLength: 320_000), 11_200)
        XCTAssertEqual(d.pauseThresholdSamples(forChunkLength: 639_999), 11_200)
        // ≥40 s → 500 ms = 8_000 samples (floor).
        XCTAssertEqual(d.pauseThresholdSamples(forChunkLength: 640_000), 8_000)
        XCTAssertEqual(d.pauseThresholdSamples(forChunkLength: 10_000_000), 8_000)
    }

    func test_adaptiveThreshold_catchesShortPauseAfterLongMonologue() {
        var d = PauseDetector()
        // Speak for ~42 s — past the 40 s adaptive-floor boundary
        // (threshold drops to 500 ms = 8 000 samples). 42 s ÷ 256 ms/frame
        // ≈ 164 voiced frames is enough to land in the ≥40 s bucket
        // (164 × 4096 = 671 744 ≥ 640 000).
        let voicedFrames = 164
        // Then pause for 2 unvoiced frames = 512 ms — below the legacy
        // 1 s threshold (would have stayed in .pausing) but above the
        // adaptive 500 ms floor (must emit).
        let flags = Array(repeating: true, count: voicedFrames)
            + Array(repeating: false, count: 2)
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 1, "long-monologue pause must cut at the 500 ms floor")
        // Chunk.end = sample index of the first unvoiced frame.
        XCTAssertEqual(chunks[0].end, voicedFrames * frame)
        // We're back in .idle after the cut.
        XCTAssertEqual(d.state, .idle)
    }

    func test_adaptiveThreshold_middleRungCatchesShortPause() {
        var d = PauseDetector()
        // Speak for ~26 s — past the 20 s adaptive-mid boundary
        // (threshold drops to 700 ms = 11 200 samples). 26 s ÷ 256 ms/frame
        // ≈ 102 voiced frames lands in the 20–40 s bucket
        // (102 × 4096 = 417 792 ≥ 320 000, < 640 000).
        let voicedFrames = 102
        // Pause for 3 unvoiced frames = 768 ms — above the 700 ms rung,
        // below the legacy 1 s threshold.
        let flags = Array(repeating: true, count: voicedFrames)
            + Array(repeating: false, count: 3)
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 1, "20–40 s pause must cut at the 700 ms rung")
        XCTAssertEqual(chunks[0].end, voicedFrames * frame)
        XCTAssertEqual(d.state, .idle)
    }

    func test_adaptiveThreshold_middleRungIgnoresPauseBelowRung() {
        var d = PauseDetector()
        // Same ~26 s voiced span landing in the 20–40 s bucket (700 ms rung)…
        let voicedFrames = 102
        // …followed by 2 unvoiced frames = 512 ms — below the 700 ms
        // threshold. We must NOT emit, even though we would at ≥40 s
        // (where 500 ms applies). Pins the rung boundary.
        let flags = Array(repeating: true, count: voicedFrames)
            + Array(repeating: false, count: 2)
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 0, "20–40 s chunk with <700 ms pause must not cut")
        switch d.state {
        case .pausing: break
        default: XCTFail("expected .pausing, got \(d.state)")
        }
    }

    func test_adaptiveThreshold_doesNotCutShortChunkOnShortPause() {
        var d = PauseDetector()
        // Speak for 2 frames (≈ 512 ms — well under 20 s), then 2 unvoiced
        // frames (512 ms). Threshold for a <20 s chunk is still 1 s = no
        // emit. This is the regression guard — adaptive must not affect
        // short chunks.
        let flags = [true, true, false, false]
        let chunks = run(flags, detector: &d)

        XCTAssertEqual(chunks.count, 0)
        // Still in .pausing with 2 frames of unvoiced behind us.
        switch d.state {
        case .pausing: break
        default: XCTFail("expected .pausing, got \(d.state)")
        }
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
