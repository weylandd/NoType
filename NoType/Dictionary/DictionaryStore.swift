import Foundation
import OSLog

/// Persistence actor for the user's personal dictionary and replacement
/// pairs. Schema (`dictionary.json`) is a single versioned envelope:
///
/// ```jsonc
/// {
///   "version": 1,
///   "entries": [
///     {"id": "...", "word": "NoType",    "source": "user", "addedAt": "..."},
///     {"id": "...", "word": "Anthropic", "source": "auto", "addedAt": "..."}
///   ],
///   "replacements": [
///     {"id": "...", "from": "то есть", "to": "т.е.", "createdAt": "..."}
///   ]
/// }
/// ```
///
/// Same operational shape as `InstructionsStore`: actor isolation,
/// atomic write, corruption recovery via `.corrupt-<ts>` rename, in-memory
/// snapshot cached after the first read. Caller (AppState mirror) holds
/// the SwiftUI-facing snapshot and persists changes via these methods.
///
/// Invariants (see `NoType/Dictionary/CLAUDE.md`):
/// - User-source entries are sticky — `addAutoEntries` won't trim them.
/// - Total cap is 100; over-cap mutations drop oldest `.auto` entries.
/// - Words longer than `DictionarySnapshot.maxEntryLength` chars are
///   rejected at every entry point (loader, mutators, decoder).
/// - Dedup is case-insensitive on `word` so the same brand in different
///   casing collapses to one entry.
actor DictionaryStore {
    private static let log = Logger(subsystem: "app.notype", category: "dictionary")
    private static let currentVersion = 1

    private let url: URL
    /// In-memory mirror of the on-disk document. Populated lazily on the
    /// first `snapshot()` call; mutated by the writer methods.
    private var cached: DictionarySnapshot?

    private let encoder = JSONFileStorage.makeEncoder()
    private let decoder = JSONFileStorage.makeDecoder()

    init(url: URL? = nil) {
        self.url = url ?? JSONFileStorage.appSupportURL(filename: "dictionary.json")
    }

    // MARK: - Read

    func snapshot() -> DictionarySnapshot {
        if let cached { return cached }
        let snap = loadFromDisk()
        cached = snap
        return snap
    }

    private func loadFromDisk() -> DictionarySnapshot {
        let envelope: Envelope? = JSONFileStorage.read(
            from: url,
            as: Envelope.self,
            decoder: decoder,
            log: Self.log
        )
        return envelope?.toSnapshot() ?? .empty
    }

    // MARK: - Entry mutations

    /// Add a user-typed entry. Trims whitespace, rejects entries that
    /// are empty after trim or longer than `maxEntryLength`. Dedupes
    /// case-insensitively — if the same word already exists (as user or
    /// auto), the call is a no-op aside from refreshing `addedAt` so the
    /// entry sorts as newest.
    @discardableResult
    func addUserEntry(_ word: String, now: Date = Date()) -> DictionarySnapshot {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= DictionarySnapshot.maxEntryLength else {
            return snapshot()
        }
        var snap = snapshot()
        let lower = cleaned.lowercased()
        if let existingIdx = snap.entries.firstIndex(where: { $0.word.lowercased() == lower }) {
            // Already present. If it's an auto entry, promote to user
            // (sticky) so a future trim won't drop it. If user, just
            // bump addedAt so it surfaces as newest in the UI.
            let existing = snap.entries[existingIdx]
            snap.entries[existingIdx] = DictionaryEntry(
                id: existing.id,
                word: existing.word,
                source: .user,
                addedAt: now
            )
            write(snap)
            return snap
        }
        snap.entries.append(DictionaryEntry(word: cleaned, source: .user, addedAt: now))
        // User insertion still trims auto entries if we somehow blew the
        // cap (e.g. legacy file was over-stuffed). User entries are
        // protected by the trim helper.
        snap.entries = Self.trimmed(snap.entries)
        write(snap)
        return snap
    }

    /// Add or refresh auto-extracted entries. For each input word:
    /// - If the word (case-insensitive) is already an entry, **refresh
    ///   its `addedAt`** so it survives the FIFO trim — the harvester
    ///   re-saw it in the current session, so it's still relevant.
    /// - Otherwise append it as a new `.auto` entry.
    ///
    /// After processing, trim to the global 100 cap by dropping the
    /// oldest `.auto` entries first. User entries remain sticky.
    ///
    /// Length and trim invariants from `addUserEntry` apply identically.
    @discardableResult
    func addAutoEntries(_ words: [String], now: Date = Date()) -> DictionarySnapshot {
        var snap = snapshot()
        var changed = false
        // Anchor the batch strictly after any existing entry. Two
        // back-to-back `addAutoEntries` calls in a test (or any rapid-
        // fire scenario) can otherwise produce overlapping per-entry
        // stamps and break the "this batch is the newest" contract that
        // the trim path relies on.
        let maxExisting = snap.entries.map { $0.addedAt }.max() ?? .distantPast
        let baseStamp = max(now, maxExisting.addingTimeInterval(0.001))
        var seenLower: Set<String> = []
        var batchCount = 0
        for raw in words {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= DictionarySnapshot.maxEntryLength else { continue }
            let lower = cleaned.lowercased()
            // De-dup within the input batch (in case harvest returned
            // the same word twice through different code paths).
            if seenLower.contains(lower) { continue }
            seenLower.insert(lower)
            // Monotonic batch timestamp keeps ordering stable.
            let stamp = baseStamp.addingTimeInterval(TimeInterval(batchCount) * 0.001)
            batchCount += 1
            if let idx = snap.entries.firstIndex(where: { $0.word.lowercased() == lower }) {
                // Refresh existing entry's timestamp (don't overwrite
                // source or original casing — a user-added entry stays
                // user-source so the FIFO trim keeps protecting it).
                let existing = snap.entries[idx]
                snap.entries[idx] = DictionaryEntry(
                    id: existing.id,
                    word: existing.word,
                    source: existing.source,
                    addedAt: stamp
                )
                changed = true
            } else {
                snap.entries.append(DictionaryEntry(word: cleaned, source: .auto, addedAt: stamp))
                changed = true
            }
        }
        if !changed { return snap }
        snap.entries = Self.trimmed(snap.entries)
        write(snap)
        return snap
    }

    /// Remove an entry regardless of source. No-op if id is missing.
    @discardableResult
    func removeEntry(id: UUID) -> DictionarySnapshot {
        var snap = snapshot()
        if let idx = snap.entries.firstIndex(where: { $0.id == id }) {
            snap.entries.remove(at: idx)
            write(snap)
        }
        return snap
    }

    /// Wipe every entry of the given source in one shot. Drives the
    /// Dictionary tab's two-stage "Clear all" button (first click clears
    /// `.auto`, second click clears `.user`). Replacement pairs are
    /// untouched — they live in their own panel.
    @discardableResult
    func removeEntries(source: DictionaryEntry.Source) -> DictionarySnapshot {
        var snap = snapshot()
        let before = snap.entries.count
        snap.entries.removeAll { $0.source == source }
        if snap.entries.count != before {
            write(snap)
        }
        return snap
    }

    // MARK: - Replacement mutations

    /// Add a replacement pair. Rejects when either side is empty after
    /// trim. Duplicate `from` (case-insensitive) replaces the existing
    /// pair's `to` rather than adding a second pair — keeps the apply
    /// order deterministic and prevents accidental cascading via
    /// duplicate keys.
    @discardableResult
    func addReplacement(from: String, to: String, now: Date = Date()) -> DictionarySnapshot {
        let cleanedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedFrom.isEmpty, !cleanedTo.isEmpty else { return snapshot() }

        var snap = snapshot()
        let lower = cleanedFrom.lowercased()
        if let idx = snap.replacements.firstIndex(where: { $0.from.lowercased() == lower }) {
            let existing = snap.replacements[idx]
            snap.replacements[idx] = DictionaryReplacement(
                id: existing.id,
                from: cleanedFrom,
                to: cleanedTo,
                createdAt: existing.createdAt
            )
        } else {
            snap.replacements.append(DictionaryReplacement(from: cleanedFrom, to: cleanedTo, createdAt: now))
        }
        write(snap)
        return snap
    }

    /// Update an existing replacement by id (both sides). Rejects empty
    /// `from`/`to`. No-op if id is missing.
    @discardableResult
    func updateReplacement(id: UUID, from: String, to: String) -> DictionarySnapshot {
        let cleanedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedFrom.isEmpty, !cleanedTo.isEmpty else { return snapshot() }
        var snap = snapshot()
        guard let idx = snap.replacements.firstIndex(where: { $0.id == id }) else { return snap }
        let existing = snap.replacements[idx]
        snap.replacements[idx] = DictionaryReplacement(
            id: existing.id,
            from: cleanedFrom,
            to: cleanedTo,
            createdAt: existing.createdAt
        )
        write(snap)
        return snap
    }

    @discardableResult
    func removeReplacement(id: UUID) -> DictionarySnapshot {
        var snap = snapshot()
        if let idx = snap.replacements.firstIndex(where: { $0.id == id }) {
            snap.replacements.remove(at: idx)
            write(snap)
        }
        return snap
    }

    // MARK: - Write

    private func write(_ snap: DictionarySnapshot) {
        cached = snap
        let envelope = Envelope(from: snap, version: Self.currentVersion)
        JSONFileStorage.write(envelope, to: url, encoder: encoder, log: Self.log)
    }

    // MARK: - Trim helper

    /// Trim the combined entries list to `maxTotalEntries` by removing
    /// the oldest `.auto` entries first. User entries are preserved
    /// regardless of count (if the user has more than 100 user entries —
    /// which shouldn't be reachable through the UI — we keep them all,
    /// and the auto bucket simply has zero room).
    static func trimmed(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        if entries.count <= DictionarySnapshot.maxTotalEntries { return entries }
        let users = entries.filter { $0.source == .user }
        let autos = entries
            .filter { $0.source == .auto }
            .sorted { $0.addedAt > $1.addedAt }
        let autoSlots = max(0, DictionarySnapshot.maxTotalEntries - users.count)
        let keptAutos = Array(autos.prefix(autoSlots))
        return users + keptAutos
    }

    // MARK: - On-disk envelope

    /// On-disk Codable shape. `DictionaryEntry.Source` is a string enum
    /// that survives forward-compat as long as future schema versions
    /// keep the cases. Decoder enforces the 20-char cap so a hand-edited
    /// file can't sneak overlong entries past the prompt.
    private struct Envelope: Codable {
        let version: Int
        let entries: [DictionaryEntry]
        let replacements: [DictionaryReplacement]

        init(from snap: DictionarySnapshot, version: Int) {
            self.version = version
            self.entries = snap.entries
            self.replacements = snap.replacements
        }

        func toSnapshot() -> DictionarySnapshot {
            let filteredEntries = entries.filter { entry in
                let trimmed = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && trimmed.count <= DictionarySnapshot.maxEntryLength
            }
            let filteredReplacements = replacements.filter { r in
                !r.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !r.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return DictionarySnapshot(
                entries: DictionaryStore.trimmed(filteredEntries),
                replacements: filteredReplacements
            )
        }
    }
}
