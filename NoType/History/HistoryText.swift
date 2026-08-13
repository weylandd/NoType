import Foundation

/// One row, one string: how a stored response sequence becomes the text
/// the user reads, copies, and is counted by (R4, R5, R6, R13, R14; KD2).
///
/// **Why this is a render step and not a stored field.** A segment holds
/// the model's text raw (R2) and the user's replacement pairs are applied
/// *here*, on every read, from whatever the pair list says now. That is
/// the whole of KD2, and it buys two things the pre-sequence model could
/// not: editing or deleting a pair changes how rows already on disk read
/// (R5 / AE7), and a pair whose phrase spans a chunk seam still matches,
/// because substitution runs over the assembled whole rather than per
/// chunk.
///
/// **A pair can restyle a gap; it can no longer delete one.** That
/// inversion is the defect this unit exists to fix. The marker used to
/// *be* the storage — `TextReplacementEngine`'s
/// `(?<![\p{L}\p{N}])…(?![\p{L}\p{N}])` boundary matches the `…` inside
/// `[…]`, so a pair as ordinary as `…` → `...` erased every gap from the
/// stored row and took the retry action with it. Now the gap is a
/// position in `segments` and substitution happens *downstream* of
/// assembly: the pair rewrites how the marker looks, and the position it
/// stands for is untouched. `history.json` keeps the pre-replacement text
/// either way (R31) — this pass removes nothing from disk.
///
/// Pure and `nonisolated`, no I/O. It runs once per row per render rather
/// than once per session, which is a real change in frequency and a
/// deliberate one: the work is one fold over the segments plus **one or
/// two** regex passes per pair — `TextReplacementEngine.applySingle`
/// compiles a second `NSRegularExpression` whenever a pair's `from` starts
/// lowercase, for the auto-capitalised variant, and nothing caches either.
/// Linear in rows × pairs; nothing here is quadratic in either.
///
/// The rows are bounded at ten by the history cap. **The pair list is not
/// bounded** — `DictionaryStore`'s 100-entry cap covers `entries`, not
/// `replacements` — so "small" is a property of how the list is authored
/// (by hand, in the Dictionary tab) rather than one the code enforces. If
/// that ever stops holding, memoise the compiled patterns in
/// `TextReplacementEngine` rather than moving this pass back to write
/// time: write-time substitution is the defect this file exists to undo.
enum HistoryText {

    /// The row's sequence as one string, each gap rendered as
    /// `RecordingSession.failureMarker` (R4) — **before** any replacement
    /// pair runs.
    ///
    /// Joined with `TextInjector.stitchChunks`, the same rule
    /// `RecordingSession.stop()` uses to build what it pastes, so a row
    /// this build wrote assembles back into the transcript it was built
    /// from. It is deliberately **not** the pasted string: the paste path
    /// additionally runs `TextInjector.finalizeForInsertion`, whose
    /// leading-space insertion and trailing-punctuation strip are
    /// decisions about the *cursor's surroundings*, not about the
    /// transcript. So a row may keep a sentence-final period that the
    /// insertion normalisation trimmed on its way into the user's
    /// document. Intended, and it moves no word count — both sides are
    /// whitespace splits (KD6 / AE8).
    ///
    /// Trimmed at the ends for the same reason `stop()` trims: a session
    /// whose first response is a gap would otherwise render leading
    /// space.
    static func assemble(_ segments: [HistoryEntry.Segment]) -> String {
        TextInjector
            .stitchChunks(segments.map { $0.text ?? RecordingSession.failureMarker })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a row shows and what it copies — assembly (R4) followed by
    /// the user's *current* replacement pairs (R5).
    ///
    /// **One function for both, which is the whole of R6.** Display and
    /// copy cannot disagree about what was transcribed because there is
    /// nothing left for them to disagree through: the row's transcript
    /// `Text`, the row's copy button, and the withheld-paste notice's
    /// Copy action all call this with the same pair list.
    ///
    /// The pairs are passed in rather than read from a store, so this
    /// stays pure and the caller decides which list is current — for
    /// every production caller that is `AppState.dictionaryReplacements`,
    /// the observable mirror, which is what makes an edit re-render
    /// already-stored rows instead of only affecting the next session.
    static func rendered(
        _ entry: HistoryEntry,
        replacements: [DictionaryReplacement]
    ) -> String {
        rendered(entry.segments, replacements: replacements)
    }

    /// The same string, for a caller holding a sequence that is not yet a
    /// row — `AppState.settleRetry`, which needs the legacy `text` mirror
    /// (KTD10) for the sequence it is about to store and cannot ask an
    /// entry that does not exist yet.
    ///
    /// A delegation rather than a second body: the entry overload above is
    /// this one, so R6's "display and copy cannot disagree" extends to the
    /// mirror a retried row is written with.
    static func rendered(
        _ segments: [HistoryEntry.Segment],
        replacements: [DictionaryReplacement]
    ) -> String {
        TextReplacementEngine.apply(
            assemble(segments),
            replacements: replacements
        )
    }
}
