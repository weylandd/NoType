import Foundation

/// The gap-slot merge: how a retry's per-chunk results land back in the
/// history row they were re-sent from (R12).
///
/// Pure, `nonisolated`, no I/O — which is the point. The orchestration in
/// `AppState.retryEntry(id:)` is a network loop nothing can prove without
/// a live Gemini; this is the only part of a retry with real branching,
/// and it is provable offline. Pinned by `NoTypeTests/RetryMergeTests.swift`.
///
/// ## Why replacing markers positionally is sound
///
/// A broken row's text carries one `RecordingSession.failureMarker`
/// (`[…]`) per chunk whose call failed, and the retained payload carries
/// one `RetainedRecording.Chunk` for each of the same chunks, in ascending
/// chunk order. The correspondence is one-to-one and order-aligned, so the
/// i-th marker in the text belongs to the i-th retained chunk and no index
/// needs to be carried on the entry.
///
/// That holds for three reasons, all of which are load-bearing:
///
/// 1. A recoverable failure appends exactly one `ChunkResponse` with
///    `text: nil`, and `stop()` maps each of those to exactly one marker.
/// 2. A *batched* call covering several chunks never records a marker of
///    its own — `RecordingSession.processBatch` routes a recoverable batch
///    failure into `splitRetry`, which re-issues one call per chunk and
///    records per-chunk markers. So no marker ever stands for two chunks.
/// 3. `RecordingSession.shouldRetain(_:)` admits exactly the class
///    `isTerminal(_:)` declines, so every marker-producing failure also
///    produces a retained chunk. A future narrowing of `shouldRetain`
///    (its doc-comment explicitly reserves the right) would break the
///    one-to-one and this merge would need index-carrying state on the
///    entry instead — as would a world where a user-authored or
///    model-emitted `[…]` could appear in transcript text.
///
/// The merge is written to degrade safely if that ever slips: a slot with
/// no recovery keeps its marker, a marker with no slot keeps itself, and
/// a run that recovered nothing returns the text untouched.
enum RetryMerge {

    /// Whether a per-chunk retry outcome counts as a recovery.
    ///
    /// `nil` is a chunk that failed or was never attempted (R16 stops the
    /// run at the first failure, so the tail of a partial run is all
    /// `nil`). An empty or whitespace-only string is Gemini answering with
    /// nothing — or `HallucinationLengthGate` filtering the answer away —
    /// and is deliberately **not** a recovery: substituting it would
    /// delete the marker and glue the surrounding words together, leaving
    /// the user a silently shortened sentence instead of a visible gap.
    /// Treating it as unrecovered keeps the marker, keeps the chunk's
    /// audio held, and keeps `failedChunkCount` equal to the number of
    /// markers left in the text.
    ///
    /// The single source of truth for that rule: `merge(existingText:recovered:)`
    /// and `AppState`'s settle path both read it, so the text and the
    /// retained set can never disagree about what recovered.
    static func isRecovery(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How many of `recovered` count as recoveries.
    static func recoveredCount(_ recovered: [String?]) -> Int {
        recovered.reduce(0) { $0 + (isRecovery($1) ? 1 : 0) }
    }

    /// Merge one retry run's per-chunk outcomes into the row's stored text.
    ///
    /// - Parameter existingText: the row's text as it stands now. Either a
    ///   partial transcript carrying `[…]` markers, or empty for a session
    ///   that recovered nothing when it failed.
    /// - Parameter recovered: one entry per retained chunk, in ascending
    ///   chunk order — the recovered text, or `nil` where the chunk failed
    ///   or was never attempted. The caller pads this to the full chunk
    ///   count before settling, so a stopped-early run still describes
    ///   every chunk.
    ///
    /// Two branches, and the empty-text one is not merely "join the
    /// pieces": it emits a marker for every chunk that did **not** recover,
    /// so a partially-recovered row that started with no text ends up in
    /// exactly the shape a partially-failed session produces. Without that,
    /// the row would hold recovered text with no markers while still
    /// holding audio for the rest, and the next retry would have nowhere
    /// to put its results.
    static func merge(existingText: String, recovered: [String?]) -> String {
        let slots: [String?] = recovered.map {
            isRecovery($0) ? $0?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        // Nothing recovered → the row is untouched (R19). Also what keeps
        // the empty-text branch from turning a blank row into a row of
        // bare markers.
        guard slots.contains(where: { $0 != nil }) else { return existingText }

        let marker = RecordingSession.failureMarker

        if existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return TextInjector
                .stitchChunks(slots.map { $0 ?? marker })
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Left-to-right marker substitution. Spacing needs no repair: the
        // marker already occupies the slot `stitchChunks` gave the failed
        // chunk at paste time, so dropping the trimmed recovery into it
        // inherits the surrounding whitespace.
        var out = ""
        var rest = Substring(existingText)
        var slot = 0
        while let hit = rest.range(of: marker) {
            out += rest[rest.startIndex..<hit.lowerBound]
            if slot < slots.count, let recoveredText = slots[slot] {
                out += recoveredText
            } else {
                // No slot for this marker (fewer chunks than markers), or
                // the chunk did not recover. Either way the gap stays
                // visible and its audio stays held.
                out += marker
            }
            slot += 1
            rest = rest[hit.upperBound...]
        }
        out += rest
        return out
    }

    /// The surviving transcripts of a row, as Gemini-facing priors (KTD6).
    ///
    /// Mirrors `RecordingSession.currentPriors()`: the model is never shown
    /// its own failure placeholders, because a prompt containing `[…]`
    /// teaches it to emit them. Splitting on the marker and dropping the
    /// empties is the row-level equivalent of that filter — a row's text is
    /// one stitched string rather than a response list, so the marker is
    /// the only seam available.
    static func priors(from text: String) -> [String] {
        text
            .components(separatedBy: RecordingSession.failureMarker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
