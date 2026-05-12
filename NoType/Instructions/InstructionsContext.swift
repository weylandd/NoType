import Foundation

/// Frozen, Sendable snapshot of everything `RecordingSession` needs from
/// `AppState` to build the per-session prompt sections. Captured once at
/// the start of each session — categories, prompts, and the user
/// instruction must not change mid-session, or the implicit-cache prefix
/// shape would shift between chunks of the same session and break the
/// cache discount.
///
/// The closures are read-only views over the dictionaries that the
/// AppState mirror held at session-start time. They never reach back
/// into `@MainActor` state.
struct InstructionsContext: Sendable {
    /// Trimmed user instruction (empty when not set). Drives the
    /// optional `User instruction:` section in the Gemini cache prefix.
    let userInstruction: String

    /// Resolves a category to its effective prompt — user override if
    /// present, default prompt otherwise. `nil` means the
    /// `Category instruction:` section is omitted (typical for
    /// `.uncategorized`).
    let promptForCategory: @Sendable (AppCategory) -> String?

    /// Cached cache-entry lookup. Returns the stored category for a
    /// bundle id (auto or manual), or `nil` if we haven't seen this app
    /// yet — caller falls back to `.uncategorized` plus a background
    /// classify fire.
    let cachedCategoryForBundle: @Sendable (String) -> AppCategory?

    /// Empty fallback. Used by `ContextSnapshot.minimal(activeApp:)` so
    /// that a context-not-ready snapshot still has a stable shape.
    static let empty = InstructionsContext(
        userInstruction: "",
        promptForCategory: { _ in nil },
        cachedCategoryForBundle: { _ in nil }
    )
}
