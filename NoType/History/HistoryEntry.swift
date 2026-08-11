import Foundation

struct HistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let sourceAppName: String
    let sourceBundleID: String
    let timestamp: Date
    /// Wall-clock time from hotkey press to release, in seconds.
    /// 0 for sessions recorded before this field shipped (legacy
    /// `history.json` rows decode with `decodeIfPresent` defaulting
    /// to 0) — those entries simply don't contribute to WPM / Time
    /// saved aggregates in `StatsSnapshot`.
    let durationSeconds: Double
    /// How many of the session's chunks came back as a recoverable
    /// Gemini failure and were pasted as `RecordingSession.failureMarker`
    /// ("[…]") instead of text. Mirrors `SessionSummary.failedChunkCount`,
    /// which is where the value comes from.
    ///
    /// 0 for sessions recorded before this field shipped (legacy
    /// `history.json` rows decode with `decodeIfPresent` defaulting to
    /// 0) — a pre-feature row can never claim to be broken, which is
    /// the honest reading: the app of that era discarded a fully failed
    /// session rather than writing a row for it.
    ///
    /// **Only the count is persisted.** The audio those chunks would
    /// need to be re-sent lives in memory for the process's lifetime
    /// and is deliberately not part of this entry — see
    /// `NoType/Recording/RetainedRecording.swift`. Serializing it here
    /// would break the no-audio-on-disk posture.
    let failedChunkCount: Int

    /// True when at least one chunk failed. The single predicate for
    /// "this row is broken" — call sites read this rather than
    /// re-deriving `failedChunkCount > 0`. Computed, so it never
    /// reaches the JSON.
    var isBroken: Bool { failedChunkCount > 0 }

    init(
        id: UUID,
        text: String,
        sourceAppName: String,
        sourceBundleID: String,
        timestamp: Date,
        durationSeconds: Double = 0,
        failedChunkCount: Int = 0
    ) {
        self.id = id
        self.text = text
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.failedChunkCount = failedChunkCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self,   forKey: .id)
        self.text            = try c.decode(String.self, forKey: .text)
        self.sourceAppName   = try c.decode(String.self, forKey: .sourceAppName)
        self.sourceBundleID  = try c.decode(String.self, forKey: .sourceBundleID)
        self.timestamp       = try c.decode(Date.self,   forKey: .timestamp)
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        self.failedChunkCount = try c.decodeIfPresent(Int.self, forKey: .failedChunkCount) ?? 0
    }
}
