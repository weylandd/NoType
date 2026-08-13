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
///
/// Degrading safely in the *text* is only half of it, though, and the
/// other half is why `mergeDetailed` reports `placed` separately: the
/// caller releases a chunk's audio, and a recovery the merge could not
/// land must not license that release. The one-to-one above is not in
/// fact guaranteed today — `TextReplacementEngine` runs over the stitched
/// transcript before it is stored, and its Unicode boundaries match the
/// `…` inside `[…]`, so a user replacement pair on the ellipsis leaves a
/// row that is still broken and still holds audio but carries no marker
/// to substitute into. Placement is what keeps that case lossless.
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
    /// The single source of truth for that rule: `mergeDetailed` reads it
    /// to build both the text and the `placed` flags `AppState`'s settle
    /// path releases audio from, so the text and the retained set can
    /// never disagree about what recovered.
    static func isRecovery(_ text: String?) -> Bool {
        guard let text else { return false }
        return !isEmptyText(text)
    }

    /// Whether a row's stored text counts as "carrying nothing".
    ///
    /// The **single** definition of that question, deliberately: this file
    /// decides which merge branch a retry takes, and `HistoryRowView`
    /// decides whether to synthesise markers for display, whether to offer
    /// copy, and whether a recovery has anywhere to land. Those are four
    /// readings of one fact, and they were briefly three separate
    /// `.isEmpty` spellings — two trimmed here, one untrimmed in the view —
    /// which disagreed on whitespace-only text. That state is not
    /// hypothetical: `RetryMergeTests.test_merge_whitespaceOnlyExistingText_takesTheEmptyBranch`
    /// already pins it, and `TextReplacementEngine` runs over the stitched
    /// transcript before it is stored (see the note on `Merged.placed`), so
    /// a user replacement pair can leave a row holding only whitespace.
    ///
    /// Trimmed, because a row rendering a lone space is empty to the user
    /// in every sense that matters.
    static func isEmptyText(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // `canAcceptRecovery(_:)` used to live here — "is there still a
    // marker in this row's text for a recovery to land in" — and
    // `HistoryRowView.actions` read it as the retry gate. It was a
    // mitigation for a storage defect rather than a rule: a replacement
    // pair on the ellipsis erased every `[…]` from the stored string, and
    // hiding the retry button was how the shipped build coped. A gap is a
    // position in `HistoryEntry.segments` now and a pair applied at render
    // time cannot reach it, so the question has no answer worth asking and
    // the predicate is gone (R8 / AE1). The gate is `isBroken && canRetry`.

    /// What one merge did: the row's new text, and which slots' recovered
    /// text actually reached it.
    ///
    /// `placed` exists because "this chunk recovered" and "this chunk's
    /// text landed in the row" are **not** the same fact, and the caller
    /// releases audio on the second one. A recovery with no marker to
    /// substitute into is dropped by the merge; deciding what to release
    /// from `isRecovery` alone would then free the chunk's audio *and*
    /// throw its text away, which destroys the only copy of the user's
    /// recording silently. Markers can go missing for reasons outside this
    /// file — `TextReplacementEngine` runs over the stitched transcript
    /// before it is stored (`NoType/History/CLAUDE.md`), and its
    /// `(?<![\p{L}\p{N}])…(?![\p{L}\p{N}])` boundary matches the `…`
    /// inside `[…]`, so a user pair on the ellipsis rewrites every marker
    /// in the row.
    struct Merged {
        /// The row's text after the merge.
        let text: String
        /// One flag per entry of the `recovered` array passed in: true iff
        /// that slot's text is present in `text`.
        let placed: [Bool]

        /// How many slots actually landed. This — not a count of
        /// `isRecovery` outcomes — is what a caller may release audio for.
        var placedCount: Int { placed.reduce(0) { $0 + ($1 ? 1 : 0) } }
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
        mergeDetailed(existingText: existingText, recovered: recovered).text
    }

    /// `merge`, plus which slots actually landed — the shape the settle
    /// path must use, because releasing a chunk's audio is only safe once
    /// its text is in the row. See `Merged.placed`.
    static func mergeDetailed(existingText: String, recovered: [String?]) -> Merged {
        let slots: [String?] = recovered.map {
            isRecovery($0) ? $0?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        let nonePlaced = [Bool](repeating: false, count: recovered.count)

        // Nothing recovered → the row is untouched (R19). Also what keeps
        // the empty-text branch from turning a blank row into a row of
        // bare markers.
        guard slots.contains(where: { $0 != nil }) else {
            return Merged(text: existingText, placed: nonePlaced)
        }

        let marker = RecordingSession.failureMarker

        if isEmptyText(existingText) {
            // The empty-text branch emits every slot — a recovery as its
            // text, an unrecovered one as a marker — so every recovery
            // lands by construction.
            let text = TextInjector
                .stitchChunks(slots.map { $0 ?? marker })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Merged(text: text, placed: slots.map { $0 != nil })
        }

        // Left-to-right marker substitution. Spacing needs no repair: the
        // marker already occupies the slot `stitchChunks` gave the failed
        // chunk at paste time, so dropping the trimmed recovery into it
        // inherits the surrounding whitespace.
        var out = ""
        var placed = nonePlaced
        var rest = Substring(existingText)
        var slot = 0
        while let hit = rest.range(of: marker) {
            out += rest[rest.startIndex..<hit.lowerBound]
            if slot < slots.count, let recoveredText = slots[slot] {
                out += recoveredText
                placed[slot] = true
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
        // Slots past the last marker were never visited, so their `placed`
        // flags stay false and the caller keeps holding their audio. That
        // is the whole point of reporting placement separately: a row with
        // fewer markers than retained chunks (a rewritten marker, a
        // narrowed retention class) loses no audio and no text — the run
        // simply reads as a partial one and can be retried.
        return Merged(text: out, placed: placed)
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
