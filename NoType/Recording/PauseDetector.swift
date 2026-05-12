import Foundation

/// State machine that turns a stream of Silero VAD probabilities into chunk
/// boundaries. Pure logic — no audio, no AVFoundation, no concurrency.
///
/// Driven once per VAD window (256 ms at 16 kHz). Each `observe(...)` call
/// passes the probability and the sample-index range that window covered;
/// the detector returns either `nil` (no boundary yet) or a `Chunk` whose
/// `[start, end)` indexes the recorder's PCM buffer.
///
/// Behaviour mirrors `NoType/Recording/CLAUDE.md`:
///
/// - **`voicedFrameThreshold`** = 0.5. Probabilities at or above this count
///   as voiced.
/// - **`minVoicedRunForChunkStart`** = 1. Tuned for the 256 ms unified
///   model: a single voiced frame is already 256 ms of evidence, plenty for
///   onset detection. Bump if false starts on coughs become a problem.
/// - **`pauseThresholdSamples`** = 1.0 s of unvoiced audio counts as a
///   pause and ends the chunk.
/// - **`preRollSamples`** = 300 ms. Every chunk's start is rewound by this
///   much so the chunk includes the leading consonants Silero needs a few
///   frames to confirm.
/// - **`maxChunkSamples`** = 30 s. Force-cut when a chunk reaches this
///   duration without a natural pause — keeps PCM memory bounded for users
///   who speak continuously without pausing, and keeps Gemini call payloads
///   reasonable. The cut emits a chunk and immediately starts a new one at
///   the cut boundary (no pre-roll loss; we *don't* go back to idle).
struct PauseDetector {
    struct Chunk: Equatable {
        /// Inclusive sample index where this chunk's PCM begins. Already
        /// pre-roll-rewound; clamp at 0 in the slicer.
        let start: Int
        /// Exclusive sample index where this chunk ends — the moment the
        /// pause was detected to begin.
        let end: Int
    }

    enum State: Equatable {
        case idle
        case speaking
        /// Waiting to confirm a pause. `unvoicedSince` is the sample index
        /// of the first unvoiced frame in the current run.
        case pausing(unvoicedSince: Int)
    }

    var state: State = .idle

    /// Sample index where the *current* chunk's voiced run started (before
    /// pre-roll rewind). 0 when no chunk is in progress.
    var chunkStart: Int = 0

    /// Voiced frames seen consecutively while in `.idle`. Used to confirm
    /// onset before transitioning to `.speaking`.
    var voicedRun: Int = 0

    let voicedFrameThreshold: Float
    let minVoicedRunForChunkStart: Int
    let pauseThresholdSamples: Int
    let preRollSamples: Int
    let maxChunkSamples: Int

    init(
        voicedFrameThreshold: Float = 0.5,
        minVoicedRunForChunkStart: Int = 1,
        pauseThresholdSamples: Int = 16_000,    // 1.0 s @ 16 kHz
        preRollSamples: Int = 4_800,            // 300 ms @ 16 kHz
        maxChunkSamples: Int = 480_000          // 30 s @ 16 kHz
    ) {
        self.voicedFrameThreshold = voicedFrameThreshold
        self.minVoicedRunForChunkStart = minVoicedRunForChunkStart
        self.pauseThresholdSamples = pauseThresholdSamples
        self.preRollSamples = preRollSamples
        self.maxChunkSamples = maxChunkSamples
    }

    /// Drive one VAD window through the state machine. `frameStart` /
    /// `frameEnd` are sample indices (in the recorder's 16 kHz buffer) that
    /// this VAD window covered.
    mutating func observe(probability: Float, frameStart: Int, frameEnd: Int) -> Chunk? {
        let voiced = probability >= voicedFrameThreshold

        switch state {
        case .idle:
            if voiced {
                voicedRun += 1
                if voicedRun >= minVoicedRunForChunkStart {
                    state = .speaking
                    chunkStart = frameStart
                    voicedRun = 0
                }
            } else {
                voicedRun = 0
            }
            return nil

        case .speaking:
            // Hard cut on continuous speech: if we've been speaking for
            // >= maxChunkSamples without a pause, emit a chunk now and
            // immediately start a new one at `frameEnd`. Keeps PCM memory
            // bounded and Gemini call payloads reasonable.
            if frameEnd - chunkStart >= maxChunkSamples {
                let cut = Chunk(
                    start: max(0, chunkStart - preRollSamples),
                    end: frameEnd
                )
                // Continue speaking — the user hasn't paused, we just
                // chopped a long utterance. New chunk starts where this
                // one ended; no pre-roll on the seam because the previous
                // chunk already covered the audio up to `frameEnd`.
                chunkStart = frameEnd
                voicedRun = 0
                return cut
            }
            if !voiced {
                state = .pausing(unvoicedSince: frameStart)
            }
            return nil

        case .pausing(let unvoicedSince):
            if voiced {
                // False alarm — the pause didn't last. Stay in the same
                // chunk and resume speaking. Also re-check the length
                // cap, since this window pushed `frameEnd` further.
                state = .speaking
                if frameEnd - chunkStart >= maxChunkSamples {
                    let cut = Chunk(
                        start: max(0, chunkStart - preRollSamples),
                        end: frameEnd
                    )
                    chunkStart = frameEnd
                    voicedRun = 0
                    return cut
                }
                return nil
            }
            let unvoicedDuration = frameEnd - unvoicedSince
            if unvoicedDuration >= pauseThresholdSamples {
                let chunk = Chunk(
                    start: max(0, chunkStart - preRollSamples),
                    end: unvoicedSince
                )
                state = .idle
                voicedRun = 0
                chunkStart = 0
                return chunk
            }
            return nil
        }
    }

    /// Force-emit a final chunk at session end. Returns `nil` if no chunk
    /// was in flight (user released without speaking).
    mutating func finalize(currentEnd: Int) -> Chunk? {
        switch state {
        case .idle:
            return nil
        case .speaking, .pausing:
            let chunk = Chunk(
                start: max(0, chunkStart - preRollSamples),
                end: currentEnd
            )
            state = .idle
            voicedRun = 0
            chunkStart = 0
            return chunk
        }
    }
}
