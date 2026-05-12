import Foundation

/// Frozen, Sendable snapshot of the dictionary state that
/// `RecordingSession` needs from `AppState` at session start. Captured
/// once, never re-read during the session — that's what keeps the
/// `User dictionary:` cache-prefix section byte-stable across chunks.
///
/// `activeEntries` and `replacements` are decided on the main actor
/// when the session starts. Edits the user makes in the Dictionary tab
/// between press and release have no effect on the in-flight session.
struct DictionaryContext: Sendable {
    /// Entries to ship in the `User dictionary:` prompt section, in
    /// the order they should appear. Always concatenated with `, `; the
    /// section body is `(empty)` when this is empty. Newest-first within
    /// each source bucket (user → auto), see
    /// `DictionarySnapshot.promptEntries()`.
    let activeEntries: [String]

    /// Replacement pairs to apply after the Gemini round-trip. Source
    /// of truth at paste time — used by `TextReplacementEngine.apply`
    /// in `RecordingSession.stop()` between `finalizeForInsertion` and
    /// `paste`.
    let replacements: [DictionaryReplacement]

    /// Empty fallback for `ContextSnapshot.minimal(activeApp:)` and the
    /// quick-release final-batch path when the contextTask hasn't
    /// settled yet.
    static let empty = DictionaryContext(activeEntries: [], replacements: [])
}
