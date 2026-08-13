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
/// - **Adaptive pause threshold.** The "how long is a pause" bar drops as
///   the current chunk gets longer, so monologues get cut on natural
///   breath pauses instead of holding out for full 1-second silences. The
///   ladder is computed by `pauseThresholdSamples(forChunkLength:)`:
///
///   | Chunk length so far | Threshold | What it catches            |
///   |---------------------|-----------|----------------------------|
///   | < 20 s              | 1000 ms   | Logical end-of-thought     |
///   | 20 – 40 s           | 700 ms    | End-of-sentence pauses     |
///   | ≥ 40 s              | 500 ms    | Any breath (floor)         |
///
///   The early step-down keeps chunks at a size that transcribes
///   cleanly — a typical chunk after 20 s lands in the 20–40 s
///   wall-clock range. **It buys no network headroom, and used to claim
///   it did.** Since U1 of the delivery-reliability plan, latency at
///   Gemini is known to track the **number of audio parts** in a
///   request rather than the audio's duration or its byte size: a
///   4-part batch measured 26.85 s idle against 7.62 s for a
///   single-part 180 s force-cut that carried *more* audio and *more*
///   bytes. So a shorter chunk does not shorten its request;
///   `GeminiClient.requestInactivityBudget(audioPartCount:)` scales on
///   the part axis instead, and what actually costs time is how many
///   chunks the sender batches into one call. This ladder is a chunk-
///   *quality* decision and nothing else. 500 ms
///   is the floor on purpose — at ~300 ms we'd start catching stop-
///   consonant closures ("t", "p", "k" ~80–150 ms) and inter-phrase
///   micropauses, which would shred normal speech mid-sentence.
/// - **`preRollSamples`** = 300 ms. Every chunk's start is rewound by this
///   much so the chunk includes the leading consonants Silero needs a few
///   frames to confirm.
/// - **`maxChunkSamples`** = 180 s. Force-cut when a chunk reaches this
///   duration without a natural pause — keeps PCM memory bounded and is
///   the ultimate safety net if the adaptive threshold still can't find a
///   pause (physically impossible to speak 3 minutes without a ≥500 ms
///   inhale, but defensive). The cut emits a chunk and immediately starts
///   a new one at the cut boundary (no pre-roll loss; we *don't* go back
///   to idle).
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
    /// Base (max) pause threshold — applied to chunks under 20 s. The
    /// effective threshold steps down as the chunk grows; see
    /// `pauseThresholdSamples(forChunkLength:)` for the ladder.
    let pauseThresholdSamples: Int
    let preRollSamples: Int
    let maxChunkSamples: Int

    init(
        voicedFrameThreshold: Float = 0.5,
        minVoicedRunForChunkStart: Int = 1,
        pauseThresholdSamples: Int = 16_000,    // 1.0 s @ 16 kHz — base / short-chunk threshold
        preRollSamples: Int = 4_800,            // 300 ms @ 16 kHz
        maxChunkSamples: Int = 2_880_000        // 180 s @ 16 kHz — force-cut safety net
    ) {
        self.voicedFrameThreshold = voicedFrameThreshold
        self.minVoicedRunForChunkStart = minVoicedRunForChunkStart
        self.pauseThresholdSamples = pauseThresholdSamples
        self.preRollSamples = preRollSamples
        self.maxChunkSamples = maxChunkSamples
    }

    /// Effective pause threshold for the current chunk, given how many
    /// samples its voiced span has accumulated so far. Used in `.pausing`
    /// to decide whether the unvoiced run we're tracking is "long enough"
    /// to count as a chunk boundary.
    ///
    /// The ladder is intentionally coarse (three steps, not a continuous
    /// function): it makes behaviour predictable, easy to unit-test, and
    /// gives a clear story to anyone debugging "why did it cut there".
    /// Below 20 s the threshold is just `pauseThresholdSamples` (the init
    /// argument), so existing tests against short chunks behave identically
    /// to the pre-adaptive code.
    func pauseThresholdSamples(forChunkLength chunkLength: Int) -> Int {
        switch chunkLength {
        case ..<320_000:    return pauseThresholdSamples         // <20 s → base (1000 ms)
        case ..<640_000:    return 11_200                        // 20–40 s → 700 ms
        default:            return 8_000                         // ≥40 s → 500 ms (floor)
        }
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
            // Adaptive threshold — uses the current chunk's voiced span
            // (from chunkStart to the moment the pause started). Longer
            // chunks require less silence to count as a pause boundary,
            // so monologues get cut on breath inhales instead of waiting
            // for the full 1 s.
            let threshold = pauseThresholdSamples(
                forChunkLength: unvoicedSince - chunkStart
            )
            if unvoicedDuration >= threshold {
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
