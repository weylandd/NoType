import Foundation

/// The encoded audio of one session's failed chunks, plus everything
/// needed to re-issue their Gemini calls unchanged.
///
/// **Memory-only, for the lifetime of the app process.** This type is
/// deliberately not `Codable` and must never be serialized, cached, or
/// written to disk in any form — including a crash-survivable cache.
/// That is the whole of R1 in the failed-recording-retry plan and the
/// premise the amended no-audio-retention statements rest on
/// (`README.md`, `AGENTS.md`, `NoType/History/CLAUDE.md` invariant 4).
/// Adding a `Codable` conformance here, or serializing an instance
/// alongside its `HistoryEntry`, is a scope violation rather than a
/// refactor. `NoType/Recording/ChunkBuilder.swift` remains the only
/// file in the app that touches an audio file, and it deletes it in
/// the same function.
///
/// **Never log an instance of this type, or any of its fields.** The
/// chunks are the user's speech and `context` carries masked but real
/// on-screen text from other applications. This repo logs at `.fault`
/// in places, which would put that content in the system log.
///
/// A payload is produced by `RecordingSession` for exactly the chunks
/// whose call failed in the class `RecordingSession.shouldRetain(_:)`
/// admits, handed to `AppState` through the session summary, and held
/// against a history entry id until a retry recovers it, the row is
/// deleted or evicted by the ten-entry cap, or the process exits.
struct RetainedRecording: Sendable {

    /// One failed chunk, carrying enough to reproduce its original
    /// request byte-for-byte.
    ///
    /// Mirrors `RecordingSession.EncodedChunk`'s field set (that type
    /// is private to the session; this is its escaping counterpart).
    /// `isFinal` is part of the set because it selects between the
    /// final- and mid-chunk instruction lines in `GeminiClient`, so
    /// dropping it would make a retry send a different prompt than the
    /// attempt that failed. `samples` is the raw PCM sample count, not
    /// the encoded byte size — `HallucinationLengthGate` divides it by
    /// `AudioRecorder.outputSampleRate` to get audio duration.
    struct Chunk: Sendable {
        /// Chunk index within the session. Also the position of this
        /// chunk's `[…]` marker in the stitched transcript, which is
        /// what lets a recovered text land back in the right slot.
        let idx: Int
        /// Whether this was the session's final chunk (user release).
        let isFinal: Bool
        /// AAC-in-M4A blob out of `ChunkBuilder.encodeAAC`.
        let audio: Data
        /// Raw PCM sample count at `AudioRecorder.outputSampleRate`.
        let samples: Int
    }

    /// The failed chunks, in ascending chunk order.
    let chunks: [Chunk]

    /// The `ContextSnapshot` frozen at session start (R3). Retained
    /// with the audio because on-screen context is what makes names,
    /// terms, and code transcribe correctly — a retry without it would
    /// return systematically worse text than the original attempt.
    /// Already masked at capture: its AX content is a
    /// `RedactedAXSnapshot`, which exposes no accessor for raw text,
    /// so retaining it adds no unmasked surface.
    let context: ContextSnapshot

    /// The transcription model frozen at session start. A retry bills
    /// and prices against the same model the session ran on, not
    /// whatever the user has selected at retry time.
    let model: GeminiModel
}
