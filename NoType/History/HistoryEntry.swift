import Foundation
import OSLog

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
    /// `chunkIndices` is **never empty**, and the enforcement sits in three
    /// different places on purpose:
    ///
    /// - **In-process construction** — the `precondition` below. Both
    ///   producers already satisfy it upstream (`processBatch` returns early
    ///   on `encoded.isEmpty`, and every `recordRecoverableFailure` caller
    ///   passes exactly one index), but those guards are three call-frames
    ///   away from the type that states the invariant. The house pattern for
    ///   a contract a value type asserts about itself is a `precondition` at
    ///   construction — `GeminiClient`'s lite-path `audios.count == 1` is the
    ///   same shape. Synthesized `Codable` assigns stored properties
    ///   directly rather than routing through this initializer, so the check
    ///   guards the in-process paths only and cannot turn a damaged file into
    ///   a crash.
    /// - **Decode** — `init(from:)` rejects a stored sequence violating it
    ///   and reconstructs instead, which is the path a damaged file takes.
    ///
    /// Without the guarantee `isBroken` and `failedChunkCount` could
    /// disagree, which is the split representation this whole shape exists
    /// to remove. Worse, an empty-positioned segment written to disk would
    /// make the decoder reject the *whole* sequence on the next read, so a
    /// row **this build wrote** would go through R12's marker parse — the
    /// one thing KTD10 declares structurally impossible.
    struct Segment: Codable, Sendable, Equatable {
        /// The chunk positions this segment covers, ascending. Non-empty.
        let chunkIndices: [Int]

        /// The text Gemini returned for those chunks, **raw** — exactly as
        /// the model produced it, before any dictionary replacement pair
        /// ran (R2). `nil` means the call failed recoverably and this
        /// position is a gap.
        ///
        /// Raw is the point. `HistoryText.rendered` assembles the sequence
        /// and applies the user's *current* replacement pairs at display
        /// and copy time, so editing a pair changes how already-stored
        /// rows read and a pair whose phrase spans a chunk seam still
        /// matches (KD2) — neither of which is possible once the
        /// substitution is baked in at write time.
        ///
        /// A consequence, recorded rather than implied: `history.json`
        /// holds pre-replacement text (R31). Display-time substitution is
        /// presentation-only — it removes nothing from disk, and deleting
        /// a pair restores the original in the row. The file is
        /// unencrypted and readable by anything running as the user.
        let text: String?

        /// True when this position carries no text because its Gemini call
        /// failed recoverably. The single predicate for "gap"; call sites
        /// read it rather than re-deriving `text == nil`.
        var isGap: Bool { text == nil }

        init(chunkIndices: [Int], text: String?) {
            precondition(
                !chunkIndices.isEmpty,
                "a segment must cover at least one chunk position — see the type's doc-comment"
            )
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
    /// The structural truth about the session lives in `segments`, and
    /// **no display, copy or accounting reader consults this field any
    /// more** — they all go through `HistoryText.rendered`, which
    /// assembles the sequence and applies the user's *current* pairs
    /// (R13). Exactly one reader is left — `encode(to:)` below still
    /// writes the mirror out, per the paragraph above, but nothing
    /// downstream consumes what it wrote:
    ///
    /// - `init(from:)` below, for a legacy row that carries no sequence.
    ///   There the text is the only record of where the gaps were, which
    ///   is exactly what R12's migration reads it for. Permanent.
    ///
    /// **The retry path reads nothing here at all.** It used to twice. The
    /// merge scanned this string for markers, which failed outright on a
    /// row whose `[…]` a replacement pair had rewritten, and — worse —
    /// rebuilt the row's sequence from the merged post-replacement string,
    /// destroying the raw text on disk; `RetryMerge` writes by chunk index
    /// now and `settleRetry` uses the `segments:` initializer below. And
    /// `settleRetry`'s stats gate read `isBroken && text.isEmpty` as its
    /// "lifetime stats never counted this session" signal; that is
    /// `isEntirelyLost` below now (R18, KTD11), which says the same thing
    /// without depending on the emptiness of a string that boundary
    /// normalisation and replacement pairs both run over. So this stays a
    /// pure mirror on every path that produces a row.
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

    /// True when **every** segment is a gap — the structural form of
    /// "lifetime statistics never counted this session" (R18, KTD11).
    ///
    /// `AppState.settleRetry` is the only reader. A retry that recovers
    /// text either counts the session it recovered (`StatsStore.record`)
    /// or folds only its spend (`recordTokens`), and this predicate picks
    /// between them. `record` is not idempotent, so getting it wrong in
    /// either direction is a silent accounting defect — and this is what
    /// makes a recovered session count exactly once across however many
    /// retries it takes (AE9): the first recovery writes text into a gap,
    /// after which the sequence carries a text segment and this is false
    /// forever.
    ///
    /// **An empty-text segment is text, and that is the whole trap
    /// (R27).** The looser reading — "no segment carries any *characters*"
    /// — is wrong on a row that really exists: a session where one chunk
    /// failed recoverably and another's answer `HallucinationLengthGate`
    /// dropped stores a gap beside a `text: ""` segment, stitches to
    /// `[…]`, takes the **success** arm, pastes, and is counted. Reading
    /// that row as never-counted would double-count it the moment its gap
    /// recovered. The gate's `""` means *Gemini answered and we filtered
    /// the answer*, which is a call that succeeded; only `nil` is a lost
    /// chunk.
    ///
    /// **Why this is exactly the never-counted set.** `stop()` throws
    /// when every response is a gap, so the success arm — the one path
    /// that reaches `StatsStore.record` — can never produce an all-gap
    /// sequence. The only producer of one is
    /// `RecordingSession.brokenHistoryEntry()`, which builds the row for
    /// the session that threw: nothing was pasted and nothing was
    /// counted.
    ///
    /// **It rests on `segments` never being empty**, because `allSatisfy`
    /// is vacuously true over an empty array and would report a row with
    /// no positions at all as never-counted. Both construction paths
    /// guarantee it — the initializer below normalises an empty sequence
    /// to a single text segment *for this predicate*, and `init(from:)`
    /// reconstructs rather than storing one. There is deliberately no
    /// second emptiness check here: a term no input can reach is dead
    /// code that reads like a live guard.
    ///
    /// **The migration can fabricate an all-gap sequence for a row that
    /// was counted, and that is unreachable rather than tolerated.**
    /// `migratedSegments("[…]", failedChunkCount: 1)` yields `[gap]` —
    /// the legacy shape of the gate-filtered row above. A row read off
    /// disk outlived the process whose memory held its audio, so
    /// `canRetry` is already false for it and `settleRetry` never sees
    /// it. An in-process producer reaching for the `failedChunkCount:`
    /// initializer re-opens this, which is the same exposure that
    /// initializer's own doc-comment records.
    var isEntirelyLost: Bool { segments.allSatisfy(\.isGap) }

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
    /// `failedChunkCount == 0` and `isBroken == false` correctly, but
    /// `isEntirelyLost` — "every segment is a gap", the never-counted
    /// signal — is vacuously *true* over an empty array. Reachable only if
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
    /// read off disk without a sequence knows about itself. **No in-process
    /// producer uses it any more** — `settleRetry` was the last one and
    /// moved to the `segments:` initializer when the merge started writing
    /// by index. A producer holding real per-response data must keep using
    /// that one: the positions this initializer derives are ordinals of a
    /// marker parse, and its segment text would be post-replacement,
    /// violating R2.
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
    /// just its place in the sequence.
    ///
    /// **Nothing may depend on these positions, and decode is now the only
    /// path that can produce them.** A row read off disk without a sequence
    /// outlived the process whose memory held its audio, so `canRetry` is
    /// already false for it and no index write can reach it.
    ///
    /// That was not always true, and the exception is worth keeping in
    /// view: `AppState.settleRetry` used to rebuild a retried row through
    /// the `failedChunkCount:` initializer below, in-process, re-`put`ting
    /// the audio for whatever did not land — so a **live, retryable** row
    /// carried these fabricated ordinals, and the moment the merge started
    /// writing by index a second retry would have landed text in the wrong
    /// slot. Converting that call site to the `segments:` initializer is
    /// what closed it. A future in-process producer reaching for this
    /// initializer re-opens it.
    ///
    /// **`maxMigratedGaps` bounds the tail.** `failedChunkCount` is read
    /// straight off disk, and the loop below turns it into that many
    /// allocations — ten bytes of JSON buying an unbounded array. A
    /// corrupt-but-parseable count therefore hangs or OOM-kills the app
    /// *at launch*, every launch, which is strictly worse than the
    /// renamed-file outcome the rest of this decoder works to avoid: that
    /// one self-heals, a boot loop does not. Measured: 5 000 000 allocates
    /// in 0.09 s, `Int.max` never returns. The ceiling is far above any
    /// real session — it would take that many separately-failed Gemini
    /// responses in one dictation — so no honest row is clamped, and a
    /// clamped row still reads as broken, which is the fact that matters.
    ///
    /// Note the clamp is deliberately *not* also applied to a stored
    /// sequence's gap count: there the gaps are physically in the file, so
    /// the array cannot be larger than the bytes that carried it. The
    /// amplification exists only on this count-to-segments path, and that
    /// is the only place it is bounded.
    static func migratedSegments(text: String, failedChunkCount: Int) -> [Segment] {
        let gapsWanted = min(max(0, failedChunkCount), maxMigratedGaps)
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

    /// Ceiling on the gaps a *reconstruction* may fabricate from a stored
    /// count — see `migratedSegments`. Sized to be unreachable by an honest
    /// row rather than to be tight: a session would need this many
    /// separately-failed Gemini responses, and the whole array costs a few
    /// tens of kilobytes, so there is nothing to buy by lowering it.
    static let maxMigratedGaps = 4096

    private static let log = Logger(subsystem: "app.notype", category: "history")

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
    ///
    /// **Know the scope of that sentence — the tolerance covers `segments`
    /// and `failedChunkCount`, not the row.** The five fields above it are
    /// still bare `try`, so a row missing `id` / `text` / `sourceAppName` /
    /// `sourceBundleID` / `timestamp`, or carrying a `null` text, a
    /// non-UUID id, or a timestamp the `.iso8601` strategy rejects, still
    /// throws from here. That is **unchanged** from the pre-sequence decoder
    /// — measured, not assumed: across a corpus of hostile rows, exactly
    /// those inputs throw here and threw there, and every `segments`-shaped
    /// malformation that is fatal to nothing was fatal to nothing before
    /// either.
    ///
    /// **What a throw here now costs is one row, not the file — and the
    /// difference is not in this type.** The question this doc-comment used
    /// to leave open ("should the remaining cliff become a per-row `try?`")
    /// has since been decided by the maintainer as product owner: skip only
    /// the broken row. It is implemented one level up, in
    /// `HistoryStore.allEntries()`, which decodes the top-level array
    /// element-by-element so a row that throws is dropped while the rest
    /// load. Nothing about *this* decoder changed for it, and nothing here
    /// should be loosened on the strength of it: the reason those five
    /// fields stay bare `try` is that defaulting an absent `id` or
    /// `timestamp` would invent data, which a dropped row does not.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Bound to a local before assignment: the log below is an escaping
        // autoclosure, and interpolating `self.id` from inside an
        // initializer captures a mutating `self`, which does not compile.
        let rowID = try c.decode(UUID.self, forKey: .id)
        self.id              = rowID
        self.text            = try c.decode(String.self, forKey: .text)
        self.sourceAppName   = try c.decode(String.self, forKey: .sourceAppName)
        self.sourceBundleID  = try c.decode(String.self, forKey: .sourceBundleID)
        self.timestamp       = try c.decode(Date.self,   forKey: .timestamp)
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0

        let stored = (try? c.decodeIfPresent([Segment].self, forKey: .segments)) ?? nil
        if let stored, !stored.isEmpty, stored.allSatisfy({ !$0.chunkIndices.isEmpty }) {
            self.segments = stored
        } else {
            // Absence is the *expected* legacy shape and says nothing — it
            // would fire for every row of a pre-sequence file. A key that is
            // present and still unusable is the anomaly: no writer produces
            // it, so it means either on-disk damage or a future unit
            // emitting a sequence this decoder rejects. Recovering from that
            // silently is how such a bug stays invisible for a release —
            // the row still renders, just from the legacy pair. Only the id
            // is logged; a segment holds the user's speech.
            if c.contains(.segments) {
                Self.log.error(
                    "row \(rowID, privacy: .public) carries an unusable response sequence; reconstructing from the legacy pair"
                )
            }
            let legacyCount = ((try? c.decodeIfPresent(Int.self, forKey: .failedChunkCount)) ?? nil) ?? 0
            self.segments = Self.migratedSegments(text: text, failedChunkCount: legacyCount)
        }
    }

    /// Writes the sequence **and both legacy mirrors** (KTD10).
    ///
    /// `text` and `failedChunkCount` are emitted for the benefit of a
    /// pre-sequence build, which decodes the first non-optionally and would
    /// otherwise throw on the whole array. They are write-only from this
    /// build's point of view: the stored count is ignored entirely whenever
    /// a sequence is present, and `text` is read only on the migration
    /// path — see the field's own doc-comment for the one reader that
    /// remains and why. (The `encode` below is a read of the property in
    /// the language's sense; it is the mirror write this paragraph
    /// describes, not a consumer, and the field's count excludes it.)
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
