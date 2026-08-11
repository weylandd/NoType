import Foundation

struct HistoryEntry: Codable, Identifiable, Sendable {

    /// One entry in a session's stored response sequence: the chunk
    /// positions a single Gemini answer covered, and either the text it
    /// returned for them or a gap where it returned nothing.
    ///
    /// **A segment, not a chunk (R1).** One request can cover several
    /// chunks and answer with a single joined transcript
    /// (`GeminiClient.transcribeBatch`), so per-chunk text does not exist
    /// for most sessions — the stored unit is what the sender actually
    /// received. `chunkIndices` mirrors
    /// `RecordingSession.ChunkResponse.chunkIndices` field-for-field, which
    /// is what lets a retry write into the position it re-sent instead of
    /// scanning the row's text for the Nth marker.
    ///
    /// **`nil` text is a gap; `""` text is not (R27).** That distinction is
    /// load-bearing three times over: it is what makes `isBroken` true, it
    /// is what keeps a chunk the hallucination gate filtered (`text: ""` —
    /// Gemini answered and *we* dropped the answer) from making its row
    /// broken (R19), and it is what the "lifetime stats never counted this
    /// session" signal rests on. It is the same three-state table
    /// `NoType/Recording/CLAUDE.md` documents under "Post-response
    /// hallucination gate", carried onto disk unchanged.
    ///
    /// `chunkIndices` is **never empty**: both producers guarantee it (a
    /// `ChunkResponse` always covers at least one chunk; a migrated segment
    /// is assigned exactly one ordinal), and the decoder rejects a stored
    /// sequence that violates it. Without that guarantee `isBroken` and
    /// `failedChunkCount` could disagree, which is the split representation
    /// this whole shape exists to remove.
    struct Segment: Codable, Sendable, Equatable {
        /// The chunk positions this segment covers, ascending. Non-empty.
        let chunkIndices: [Int]

        /// The text Gemini returned for those chunks, **raw** — exactly as
        /// the model produced it, before any dictionary replacement pair
        /// ran (R2). `nil` means the call failed recoverably and this
        /// position is a gap.
        ///
        /// Raw is the point: a replacement pair is applied to the assembled
        /// row at display and copy time, so editing a pair changes how
        /// already-stored rows read, and a pair whose phrase spans a chunk
        /// seam still matches (KD2). It also means `history.json` holds
        /// pre-replacement text — presentation-only substitution removes
        /// nothing from disk (R31).
        let text: String?

        /// True when this position carries no text because its Gemini call
        /// failed recoverably. The single predicate for "gap"; call sites
        /// read it rather than re-deriving `text == nil`.
        var isGap: Bool { text == nil }

        init(chunkIndices: [Int], text: String?) {
            self.chunkIndices = chunkIndices
            self.text = text
        }

        /// A segment holding what the model returned for `indices`.
        static func carrying(_ text: String, at indices: [Int]) -> Segment {
            Segment(chunkIndices: indices, text: text)
        }

        /// A segment marking `indices` as lost.
        static func gap(at indices: [Int]) -> Segment {
            Segment(chunkIndices: indices, text: nil)
        }
    }

    let id: UUID

    /// The session's transcript as one flat string: stitched, boundary-
    /// normalised for insertion, and with the session's dictionary
    /// replacement pairs already applied — i.e. exactly what was pasted.
    ///
    /// **This is a legacy mirror (KTD10), and it is written on every row
    /// this build produces on purpose.** A rollback to a pre-sequence build
    /// decodes `text` non-optionally; without it that decoder throws on the
    /// whole top-level array, `JSONFileStorage` renames the file aside, and
    /// the user loses all ten transcripts rather than one field. Its
    /// companion mirror is `failedChunkCount`.
    ///
    /// The structural truth about the session lives in `segments`. Readers
    /// that need the row as one string still read this field today; the
    /// unit that assembles it from `segments` and applies the user's
    /// *current* pairs at render time replaces those reads.
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

    /// The session's ordered response sequence — the row's source of
    /// truth (R1).
    ///
    /// Ordered by position and never empty. Every row has one, including
    /// rows already on disk when this shape shipped: absence of the key is
    /// the migration discriminator, and `migratedSegments(text:failedChunkCount:)`
    /// reconstructs a sequence that reproduces what the row looks like
    /// today (R12). `history.json` is a bare top-level array with no
    /// version envelope, so absence — the precedent `durationSeconds` and
    /// `failedChunkCount` already set — is the discriminator available
    /// without changing the file's top-level shape.
    ///
    /// **Nothing audio-shaped is here, and nothing may be added.** A
    /// segment stores the model's text and the positions it covered; the
    /// audio a gap would need to be re-sent lives in memory for the
    /// process's lifetime (`NoType/Recording/RetainedRecording.swift`,
    /// `RetainedAudioStore`) and is deliberately not part of this entry.
    /// That is why a row whose process died comes back dead — see
    /// `NoType/History/CLAUDE.md` invariant 4.
    let segments: [Segment]

    /// How many of the session's chunks came back as a recoverable Gemini
    /// failure and were pasted as `RecordingSession.failureMarker` ("[…]")
    /// instead of text.
    ///
    /// **Derived from `segments`, never read back from disk.** It is still
    /// *encoded* — a legacy mirror beside `text` (KTD10) so a pre-sequence
    /// build keeps decoding the file — but the decoder ignores the stored
    /// value for any row that carries a sequence. The stored count only
    /// gets a say during migration, where it is authoritative: it decides
    /// brokenness and the text merely supplies positions (R12).
    ///
    /// Matches `SessionSummary.failedChunkCount` by construction: both are
    /// "how many chunk positions carry no text", counted over the same
    /// per-response data (`RecordingSession.chunkCounts(in:)`).
    var failedChunkCount: Int {
        segments.reduce(0) { $0 + ($1.isGap ? $1.chunkIndices.count : 0) }
    }

    /// True when the sequence contains at least one gap (R3). The single
    /// predicate for "this row is broken" — call sites read this rather
    /// than re-deriving it. Computed, so it never reaches the JSON.
    ///
    /// Derived from the sequence rather than from a count, so a row's
    /// brokenness and its rendered gaps can no longer disagree: the split
    /// representation they used to have — markers-as-characters for a
    /// partial failure, an empty string plus a count for a total one — is
    /// gone, and there is one encoding of the fact.
    var isBroken: Bool { segments.contains(where: \.isGap) }

    /// The producing initializer: a row built from a session's own response
    /// sequence, with `text` as the string that was pasted.
    ///
    /// Use this one wherever a real sequence exists. The `failedChunkCount:`
    /// sibling below reconstructs a sequence by parsing markers out of
    /// `text`, which is a migration rule — correct for legacy data, wrong
    /// for a session that knows its own responses (its segment text would
    /// be post-replacement, violating R2).
    ///
    /// An empty `segments` is normalised to a single text segment rather
    /// than stored: a row with no positions at all would report
    /// `failedChunkCount == 0` and `isBroken == false` correctly, but "every
    /// segment is a gap" is vacuously *true* over an empty array, which is
    /// the shape the never-counted-session signal reads. Reachable only if
    /// a session ends with no responses at all.
    init(
        id: UUID,
        text: String,
        sourceAppName: String,
        sourceBundleID: String,
        timestamp: Date,
        durationSeconds: Double = 0,
        segments: [Segment]
    ) {
        self.id = id
        self.text = text
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.segments = segments.isEmpty
            ? [Segment.carrying(text, at: [0])]
            : segments
    }

    /// The reconstruction initializer: a row described the pre-sequence
    /// way — one flat string plus a failure count — whose sequence is
    /// derived by R12's migration rule.
    ///
    /// This is the *legacy* shape, kept because it is exactly what a row
    /// read off disk without a sequence knows about itself, and because a
    /// retry that rewrites a row's text and count still describes its
    /// result that way until the merge writes by index. A producer holding
    /// real per-response data must use the `segments:` initializer instead.
    init(
        id: UUID,
        text: String,
        sourceAppName: String,
        sourceBundleID: String,
        timestamp: Date,
        durationSeconds: Double = 0,
        failedChunkCount: Int = 0
    ) {
        self.init(
            id: id,
            text: text,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            timestamp: timestamp,
            durationSeconds: durationSeconds,
            segments: Self.migratedSegments(text: text, failedChunkCount: failedChunkCount)
        )
    }

    /// Reconstruct a response sequence from the pre-sequence pair — the
    /// flat transcript and the stored failure count (R12).
    ///
    /// **The count decides brokenness; the text only supplies positions.**
    /// That asymmetry is the whole rule, and both directions of getting it
    /// wrong are live defects this migration exists to avoid:
    ///
    /// - **Count zero** → one text segment holding `text` verbatim,
    ///   whatever it contains. A `[…]` the user happened to *dictate* must
    ///   not turn their row broken, so the marker is never looked for here.
    /// - **Count non-zero, markers present** → split on them into
    ///   alternating text and gap segments, at most `count` of them. A
    ///   marker beyond the count is dictated text and stays in the tail
    ///   segment.
    /// - **Count non-zero, fewer markers than the count** → a replacement
    ///   pair rewrote some or all of them (`TextReplacementEngine`'s
    ///   `(?<![\p{L}\p{N}])…(?![\p{L}\p{N}])` boundary matches the `…`
    ///   inside `[…]`). Split on whatever remains, then append gaps until
    ///   the gap count equals the stored count. **This is the row the whole
    ///   change exists for and it must stay broken** — the shipped
    ///   behaviour hid its retry action instead.
    /// - **Count non-zero, text empty** → that many gaps. Falls out of the
    ///   arm above rather than being special-cased.
    ///
    /// **Positions are ordinal, not recovered.** A migrated text segment
    /// stands for an unknown number of original chunks and its index is
    /// just its place in the sequence. Nothing may depend on these
    /// positions, and nothing has to: no migrated row can be retried,
    /// because the audio a retry needs is memory-only and did not survive
    /// the restart that produced the migration.
    static func migratedSegments(text: String, failedChunkCount: Int) -> [Segment] {
        let gapsWanted = max(0, failedChunkCount)
        guard gapsWanted > 0 else {
            return [Segment.carrying(text, at: [0])]
        }

        var segments: [Segment] = []
        var gapsPlaced = 0
        var remainder = Substring(text)
        while gapsPlaced < gapsWanted,
              let hit = remainder.range(of: RecordingSession.failureMarker) {
            let head = remainder[remainder.startIndex..<hit.lowerBound]
            if !head.isEmpty {
                segments.append(.carrying(String(head), at: [segments.count]))
            }
            segments.append(.gap(at: [segments.count]))
            gapsPlaced += 1
            remainder = remainder[hit.upperBound...]
        }
        if !remainder.isEmpty {
            segments.append(.carrying(String(remainder), at: [segments.count]))
        }
        while gapsPlaced < gapsWanted {
            segments.append(.gap(at: [segments.count]))
            gapsPlaced += 1
        }
        return segments
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, sourceAppName, sourceBundleID, timestamp
        case durationSeconds, failedChunkCount, segments
    }

    /// Tolerant decoder, in the shape `durationSeconds` and
    /// `failedChunkCount` already established: a field this build did not
    /// always write is `decodeIfPresent`-ed with a default rather than
    /// being required.
    ///
    /// **Absence of `segments` is the migration discriminator (KTD10).**
    /// A row this build wrote carries one, so `migratedSegments` — the
    /// marker parser — is structurally unreachable for it. A row from
    /// before carries none and is reconstructed from `text` plus the stored
    /// count.
    ///
    /// A stored sequence that is present but *unusable* — empty, or
    /// carrying a segment with no positions, or malformed enough that
    /// decoding it throws — falls through to the same reconstruction rather
    /// than out of the decoder. That tolerance is not politeness: a throw
    /// here fails the whole top-level array, and `JSONFileStorage` responds
    /// by renaming `history.json` aside, so one bad row would cost the user
    /// all ten transcripts. Reconstruction reproduces the row's appearance
    /// from fields that were readable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self,   forKey: .id)
        self.text            = try c.decode(String.self, forKey: .text)
        self.sourceAppName   = try c.decode(String.self, forKey: .sourceAppName)
        self.sourceBundleID  = try c.decode(String.self, forKey: .sourceBundleID)
        self.timestamp       = try c.decode(Date.self,   forKey: .timestamp)
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0

        let stored = (try? c.decodeIfPresent([Segment].self, forKey: .segments)) ?? nil
        if let stored, !stored.isEmpty, stored.allSatisfy({ !$0.chunkIndices.isEmpty }) {
            self.segments = stored
        } else {
            let legacyCount = ((try? c.decodeIfPresent(Int.self, forKey: .failedChunkCount)) ?? nil) ?? 0
            self.segments = Self.migratedSegments(text: text, failedChunkCount: legacyCount)
        }
    }

    /// Writes the sequence **and both legacy mirrors** (KTD10).
    ///
    /// `text` and `failedChunkCount` are emitted for the benefit of a
    /// pre-sequence build, which decodes the first non-optionally and would
    /// otherwise throw on the whole array. They are write-only from this
    /// build's point of view: `init(from:)` reads `text` (still the string
    /// every current reader consumes) and ignores the stored count entirely
    /// whenever a sequence is present.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,              forKey: .id)
        try c.encode(text,            forKey: .text)
        try c.encode(sourceAppName,   forKey: .sourceAppName)
        try c.encode(sourceBundleID,  forKey: .sourceBundleID)
        try c.encode(timestamp,       forKey: .timestamp)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(failedChunkCount, forKey: .failedChunkCount)
        try c.encode(segments,        forKey: .segments)
    }
}
