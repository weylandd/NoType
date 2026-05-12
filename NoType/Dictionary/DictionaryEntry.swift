import Foundation

/// A single word or short phrase in the user's personal dictionary —
/// brand names, proper nouns, jargon — sent to Gemini as part of the
/// cached prefix to bias spelling on the audio it actually hears.
///
/// Entries are either user-added (sticky, never automatically trimmed)
/// or auto-harvested by `DictionaryHarvester` from past transcripts.
/// At most `DictionarySnapshot.maxTotalEntries` (100) entries live at
/// once; auto entries are trimmed FIFO when over cap. User entries are
/// preserved.
///
/// The 30-char cap (`DictionarySnapshot.maxEntryLength`) is enforced at
/// every entry point — UI, store mutation, and the harvester — so the
/// prompt section can't be silently bloated.
struct DictionaryEntry: Codable, Sendable, Equatable, Identifiable {
    enum Source: String, Codable, Sendable, Equatable {
        /// User-typed in the Dictionary tab. Sticky — never trimmed by
        /// cap logic, never overwritten by auto-extraction.
        case user
        /// Harvested from past transcripts by `DictionaryHarvester`.
        /// Subject to FIFO trim when the total grows past
        /// `maxTotalEntries`.
        case auto
    }

    let id: UUID
    let word: String
    let source: Source
    let addedAt: Date

    init(id: UUID = UUID(), word: String, source: Source, addedAt: Date = Date()) {
        self.id = id
        self.word = word
        self.source = source
        self.addedAt = addedAt
    }
}

/// A find/replace pair applied to the final transcript before paste.
/// Pure client-side; never sent to Gemini.
///
/// Matching rules (see `TextReplacementEngine`): exact case-sensitive
/// word-boundary match, plus an auto-generated capitalized variant when
/// `from` starts with a lowercase letter. So a pair `то есть → т.е.`
/// matches both `то есть` and `То есть` (the latter is replaced with
/// `Т.е.`), but never matches inside another word.
struct DictionaryReplacement: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let from: String
    let to: String
    let createdAt: Date

    init(id: UUID = UUID(), from: String, to: String, createdAt: Date = Date()) {
        self.id = id
        self.from = from
        self.to = to
        self.createdAt = createdAt
    }
}

/// In-memory mirror of the on-disk `dictionary.json` document. Returned
/// by `DictionaryStore.snapshot()` so callers can prime their
/// `@Observable` state without making per-field awaits.
///
/// `entries` is conceptually one list with two sources mixed in. UI
/// presents them in two visual groups; the prompt section concatenates
/// user → auto.
struct DictionarySnapshot: Sendable, Equatable {
    var entries: [DictionaryEntry]
    var replacements: [DictionaryReplacement]

    static let empty = DictionarySnapshot(entries: [], replacements: [])

    /// Combined cap. Trim logic removes oldest `.auto` entries until
    /// total ≤ this. User entries are sticky — the harvester skips
    /// entirely when `userCount >= maxTotalEntries` (no room).
    static let maxTotalEntries = 100

    /// Hard cap on entry length in characters. Enforced everywhere a
    /// word can enter the store — UI textfield, store mutator,
    /// harvester. Stops the prompt section from being silently bloated.
    /// Also matches `DictionaryHarvester.sanityMaxLength`.
    static let maxEntryLength = 30

    /// Count of user-added (sticky) entries. Drives the "no room for
    /// auto" gate at the harvester callsite.
    var userCount: Int {
        entries.lazy.filter { $0.source == .user }.count
    }

    /// Entries to actually ship in the `User dictionary:` prompt
    /// section, in newest-first order, user bucket first then auto.
    func promptEntries() -> [String] {
        let users = entries
            .filter { $0.source == .user }
            .sorted { $0.addedAt > $1.addedAt }
            .map { $0.word }
        let autos = entries
            .filter { $0.source == .auto }
            .sorted { $0.addedAt > $1.addedAt }
            .map { $0.word }
        let combined = users + autos
        if combined.count <= Self.maxTotalEntries {
            return combined
        }
        return Array(combined.prefix(Self.maxTotalEntries))
    }
}
