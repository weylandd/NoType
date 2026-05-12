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
    /// first `snapshot()` call; mutated by the writer methods. The
    /// `cached` flag is what lets a stale envelope read return its result
    /// without re-decoding the file every call.
    private var cached: DictionarySnapshot?
    private var loaded = false

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let appSupport = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            let dir = appSupport.appendingPathComponent("NoType", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.url = dir.appendingPathComponent("dictionary.json")
        }
    }

    // MARK: - Read

    func snapshot() -> DictionarySnapshot {
        if let cached { return cached }
        let snap = loadFromDisk()
        cached = snap
        loaded = true
        return snap
    }

    private func loadFromDisk() -> DictionarySnapshot {
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else { return .empty }

        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            return envelope.toSnapshot()
        } catch {
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            Self.log.error("dictionary corrupted, backed up to \(backup.lastPathComponent, privacy: .public) (\(error.localizedDescription, privacy: .public))")
            return .empty
        }
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

    /// Append auto-extracted words. Deduped case-insensitively against
    /// existing entries (both user and auto), filtered for length, then
    /// trimmed to the global 100 cap by removing oldest `.auto`. User
    /// entries are sticky. Returns the updated snapshot.
    @discardableResult
    func addAutoEntries(_ words: [String], now: Date = Date()) -> DictionarySnapshot {
        var snap = snapshot()
        var existingLower = Set(snap.entries.map { $0.word.lowercased() })
        var added = 0
        // Anchor the batch strictly after any existing entry. Two
        // back-to-back `addAutoEntries` calls in a test (or any rapid-
        // fire scenario) can otherwise produce overlapping per-entry
        // stamps and break the "this batch is the newest" contract that
        // the trim path relies on.
        let maxExisting = snap.entries.map { $0.addedAt }.max() ?? .distantPast
        let baseStamp = max(now, maxExisting.addingTimeInterval(0.001))
        for raw in words {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= DictionarySnapshot.maxEntryLength else { continue }
            let lower = cleaned.lowercased()
            if existingLower.contains(lower) { continue }
            existingLower.insert(lower)
            // Slight monotonic addedAt so successive entries in the same
            // batch keep their relative order in newest-first sorting.
            // 1 ms increments are cheaper than tracking an explicit
            // sequence; the resolution is enough for any realistic
            // session count.
            let stamp = baseStamp.addingTimeInterval(TimeInterval(added) * 0.001)
            snap.entries.append(DictionaryEntry(word: cleaned, source: .auto, addedAt: stamp))
            added += 1
        }
        if added == 0 { return snap }
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
        do {
            let data = try encoder.encode(envelope)
            try data.write(to: url, options: [.atomic])
        } catch {
            Self.log.error("dictionary write failed: \(error.localizedDescription, privacy: .public)")
        }
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
