import Foundation

/// The gap-slot merge: how a retry's per-chunk results land back in the
/// history row they were re-sent from (R7, R10, R11).
///
/// Pure, `nonisolated`, no I/O — which is the point. The orchestration in
/// `AppState.retryEntry(id:)` is a network loop nothing can prove without
/// a live Gemini; this is the only part of a retry with real branching,
/// and it is provable offline. Pinned by `NoTypeTests/RetryMergeTests.swift`.
///
/// ## The merge writes by index; it does not scan
///
/// A recovered chunk's text is written into the gap segment covering
/// **that chunk's own index** (R7). Nothing here reads the row's rendered
/// string, counts markers, or depends on the order the retry loop happened
/// to answer in. `HistoryEntry.Segment.chunkIndices` and
/// `RetainedRecording.Chunk.idx` are the same number by construction — the
/// session records both from one `ChunkResponse` — and this merge joins
/// the two on it.
///
/// **That is a correction, not a refinement.** The merge used to substitute
/// the *i*-th `[…]` in `HistoryEntry.text` for the *i*-th retained chunk,
/// resting on a one-to-one, order-aligned correspondence between
/// markers-as-characters and retained chunks. Two things broke it, and both
/// were shipped defects rather than future risks:
///
/// 1. **`text` is post-replacement.** `TextReplacementEngine`'s
///    `(?<![\p{L}\p{N}])…(?![\p{L}\p{N}])` boundary matches the `…` inside
///    `[…]`, so a user pair as ordinary as `…` → `...` left a row that was
///    still broken and still held audio but carried no marker to substitute
///    into. Every retry on it was billed and recovered nothing — on
///    precisely the row this whole change exists for.
/// 2. **Rebuilding the row from the merged string baked that substitution
///    into storage.** The raw text was then gone from disk, so the user's
///    *current* pairs were re-applied on top of an old one: a pair whose
///    `to` contains its `from` double-applied, and deleting the pair no
///    longer changed how the row read (R2, R5, R31).
///
/// Both disappear once the gap is a position. Replacement pairs are applied
/// **downstream** of this merge, by `HistoryText.rendered`, so a pair can
/// restyle a gap and can no longer move or erase one — and the text this
/// merge writes stays raw (R9), which is what lets it pick up the pairs at
/// render like every other segment.
///
/// ## Placement is still reported, never re-derived
///
/// `Merged.placed` survives the rewrite unchanged in purpose. "This chunk
/// recovered" and "this chunk's text landed in the row" are two facts, and
/// `RetainedAudioStore.take` hands out the only copy of the user's audio —
/// so a caller releasing on `isRecovery` alone would free the audio *and*
/// throw the recovered text away, silently. Writing by index makes a
/// mismatch rare, not impossible: a recovery whose index no gap covers (a
/// payload out of step with its row — a second run against a row a first
/// already recovered) is reported unplaced and its audio stays held. See
/// `docs/solutions/conventions/gate-irreversible-actions-on-the-outcome-2026-08-09.md`.
enum RetryMerge {

    /// Whether a per-chunk retry outcome counts as a recovery.
    ///
    /// `nil` is a chunk that failed or was never attempted (the run stops
    /// at the first failure, so the tail of a partial run is all `nil`). An
    /// empty or whitespace-only string is Gemini answering with nothing —
    /// or `HallucinationLengthGate` filtering the answer away — and is
    /// deliberately **not** a recovery: writing it into the gap would turn
    /// a visible hole into a silently shortened sentence, and would release
    /// the chunk's audio for an answer that said nothing.
    ///
    /// The single source of truth for that rule: `merge(into:outcomes:)`
    /// reads it to build both the new sequence and the `placed` flags
    /// `AppState`'s settle path releases audio from, so the row and the
    /// retained set can never disagree about what recovered.
    static func isRecovery(_ text: String?) -> Bool {
        guard let text else { return false }
        return !isEmptyText(text)
    }

    /// Whether a piece of stored or recovered text counts as "carrying
    /// nothing" — trimmed, because a row rendering a lone space is empty to
    /// the user in every sense that matters.
    ///
    /// The **single** definition of that question. `isRecovery` above reads
    /// it, `priors(from:)` below reads it, and
    /// `HistoryRowView.hasCopyableText` asks the same thing of a row's
    /// segments. Those readings were briefly three separate `.isEmpty`
    /// spellings that disagreed on whitespace-only text.
    static func isEmptyText(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One retained chunk's outcome: the chunk position it was re-sent for,
    /// and what came back for it.
    ///
    /// The index is the whole point — it is what makes placement
    /// independent of the order the caller iterated in, of how many chunks
    /// it got through before stopping, and of anything at all about the
    /// row's rendered text. `AppState` builds these by zipping
    /// `RetainedRecording.chunks` against the run's answers, so the index
    /// is the one the session recorded the audio under.
    struct ChunkOutcome: Equatable, Sendable {
        /// The chunk position this outcome is for — `RetainedRecording.Chunk.idx`.
        let chunkIndex: Int
        /// What Gemini returned for it, **raw**; `nil` where the call
        /// failed or the chunk was never attempted.
        let text: String?

        init(chunkIndex: Int, text: String?) {
            self.chunkIndex = chunkIndex
            self.text = text
        }
    }

    /// What one merge did: the row's new response sequence, and which
    /// outcomes' text actually reached it.
    ///
    /// `placed` exists because the caller releases audio on the second fact
    /// and not the first. See the type-level note above.
    struct Merged {
        /// The row's sequence after the merge — raw text throughout (R9),
        /// so `HistoryText.rendered` applies the user's current pairs to it
        /// exactly as it does to a segment the session wrote.
        let segments: [HistoryEntry.Segment]

        /// One flag per entry of the `outcomes` array passed in: true iff
        /// that outcome's text was written into a gap.
        let placed: [Bool]

        /// How many outcomes actually landed. This — not a count of
        /// `isRecovery` verdicts — is what a caller may release audio for.
        var placedCount: Int { placed.reduce(0) { $0 + ($1 ? 1 : 0) } }
    }

    /// Write each recovery into the gap covering its own chunk index (R7).
    ///
    /// - Parameter segments: the row's sequence as it stands now.
    /// - Parameter outcomes: one entry per retained chunk this run
    ///   describes, carrying the index it was re-sent for. Order is
    ///   irrelevant to the result (R11) — a caller may hand these over in
    ///   whatever order its loop produced them.
    ///
    /// A text segment is copied through untouched: a recovery aimed at an
    /// index it covers has nowhere to go and is reported unplaced rather
    /// than overwriting text the row already has.
    ///
    /// **A gap segment spanning several indices splits when only some of
    /// them recover** (R7) — one Gemini call can answer for several chunks,
    /// so a gap is not always one position. The unrecovered positions on
    /// either side of a recovery stay grouped exactly as they were, which
    /// is what keeps the row's rendering stable: `HistoryText.assemble`
    /// emits one `[…]` per gap *segment*, so splitting a run that did not
    /// recover would silently multiply the markers the user sees.
    ///
    /// A duplicated index in `outcomes` is resolved first-wins, and both
    /// entries report placement honestly — the second is unplaced, so its
    /// audio stays held. No caller produces one; `RetainedRecording.chunks`
    /// is one chunk per index.
    static func merge(
        into segments: [HistoryEntry.Segment],
        outcomes: [ChunkOutcome]
    ) -> Merged {
        let nonePlaced = [Bool](repeating: false, count: outcomes.count)

        var recoveryByIndex: [Int: String] = [:]
        for outcome in outcomes where isRecovery(outcome.text) {
            guard let text = outcome.text else { continue }
            if recoveryByIndex[outcome.chunkIndex] == nil {
                recoveryByIndex[outcome.chunkIndex] = text
            }
        }

        // Nothing recovered → the row is untouched, and the caller's
        // nothing-landed exit re-puts every chunk.
        guard !recoveryByIndex.isEmpty else {
            return Merged(segments: segments, placed: nonePlaced)
        }

        var written: Set<Int> = []
        var out: [HistoryEntry.Segment] = []
        for segment in segments {
            guard segment.isGap else {
                out.append(segment)
                continue
            }
            var pendingGap: [Int] = []
            for index in segment.chunkIndices {
                guard let recoveredText = recoveryByIndex[index] else {
                    pendingGap.append(index)
                    continue
                }
                if !pendingGap.isEmpty {
                    out.append(.gap(at: pendingGap))
                    pendingGap = []
                }
                // Trimmed, not because the text is untrusted, but because
                // `assemble` re-derives the seam spacing from
                // `TextInjector.stitchChunks`: a recovery arriving with its
                // own padding would render a double space at the join.
                out.append(
                    .carrying(
                        recoveredText.trimmingCharacters(in: .whitespacesAndNewlines),
                        at: [index]
                    )
                )
                written.insert(index)
            }
            if !pendingGap.isEmpty {
                out.append(.gap(at: pendingGap))
            }
        }

        // Placement is read back off what the walk actually wrote, so a
        // recovery aimed at an index no gap covers reports false and keeps
        // its audio. First-wins on a duplicate is expressed here too: only
        // the outcome whose text is the one in the map counts as placed.
        var claimed: Set<Int> = []
        let placed = outcomes.map { outcome -> Bool in
            guard isRecovery(outcome.text),
                  written.contains(outcome.chunkIndex),
                  !claimed.contains(outcome.chunkIndex)
            else { return false }
            claimed.insert(outcome.chunkIndex)
            return true
        }
        return Merged(segments: out, placed: placed)
    }

    /// The row's text-carrying chunks, as Gemini-facing priors (R10).
    ///
    /// **A gap contributes nothing**, so no marker is ever sent back to the
    /// model — a prompt containing `[…]` teaches it to emit them. That used
    /// to be enforced by splitting the row's rendered string on the marker,
    /// which is the same defect the merge above had: a replacement pair on
    /// the ellipsis moved the seam. Reading the sequence makes it
    /// structural.
    ///
    /// The text is **raw** (R10), and the result is now a field-for-field
    /// mirror of `RecordingSession.currentPriors()` — one prior per
    /// text-carrying response, in order, exactly what the original attempt
    /// would have sent. The one addition is the whitespace-only filter:
    /// `currentPriors` drops `""` and this drops anything that trims to it,
    /// per `isEmptyText`.
    static func priors(from segments: [HistoryEntry.Segment]) -> [String] {
        segments.compactMap { segment in
            guard let text = segment.text, !isEmptyText(text) else { return nil }
            return text
        }
    }
}
