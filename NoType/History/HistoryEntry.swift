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

    init(
        id: UUID,
        text: String,
        sourceAppName: String,
        sourceBundleID: String,
        timestamp: Date,
        durationSeconds: Double = 0
    ) {
        self.id = id
        self.text = text
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self,   forKey: .id)
        self.text            = try c.decode(String.self, forKey: .text)
        self.sourceAppName   = try c.decode(String.self, forKey: .sourceAppName)
        self.sourceBundleID  = try c.decode(String.self, forKey: .sourceBundleID)
        self.timestamp       = try c.decode(Date.self,   forKey: .timestamp)
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
    }
}
