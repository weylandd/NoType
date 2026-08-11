import Foundation
import OSLog

actor HistoryStore {
    private static let log = Logger(subsystem: "app.notype", category: "history")
    /// The rolling window (invariant 1). **Internal, not private, because
    /// it is the single source of truth for a second trim:**
    /// `AppState.historyMirrorCap` is derived from it, so the optimistic
    /// main-actor mirror and this actor's FIFO cannot drift apart. A
    /// private copy here would leave the mirror hand-synced to a literal,
    /// which is the drift `AppState.liveHistoryIDs` cannot survive — see
    /// `AppState.historyMirrorCap`.
    static let cap = 10

    private let url: URL
    private let encoder = JSONFileStorage.makeEncoder()
    private let decoder = JSONFileStorage.makeDecoder()

    init(url: URL? = nil) {
        self.url = url ?? JSONFileStorage.appSupportURL(filename: "history.json")
    }

    func allEntries() -> [HistoryEntry] {
        JSONFileStorage.read(
            from: url,
            as: [HistoryEntry].self,
            decoder: decoder,
            log: Self.log
        ) ?? []
    }

    @discardableResult
    func append(_ entry: HistoryEntry) -> [HistoryEntry] {
        var entries = allEntries()
        entries.append(entry)
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
        }
        write(entries)
        return entries
    }

    /// Replace the stored entry that shares `entry.id`, in place. No-op if
    /// the id isn't present, mirroring `remove(id:)`'s contract.
    ///
    /// **In place, not remove-then-append.** A retry rewrites a broken row's
    /// text and failure count (R12, R16) without changing what the row *is*:
    /// re-appending would move it to the newest slot, reorder the last-10
    /// list under the user, and put the trim in a position to evict a
    /// different row than the one the cap would have taken.
    ///
    /// The no-op case is reachable and benign: `AppState`'s mirror is
    /// optimistic and its disk writes are fire-and-forget, so a retry can
    /// settle against a row whose original `append` has not landed yet. The
    /// row's own append then persists it — carrying the pre-retry text until
    /// the next mutation, which is the same eventual-consistency the mirror
    /// has always had. The mirror is what the UI renders.
    @discardableResult
    func update(_ entry: HistoryEntry) -> [HistoryEntry] {
        var entries = allEntries()
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else {
            return entries
        }
        entries[idx] = entry
        write(entries)
        return entries
    }

    /// Remove the entry with the given id. No-op if not found.
    @discardableResult
    func remove(id: UUID) -> [HistoryEntry] {
        var entries = allEntries()
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before {
            write(entries)
        }
        return entries
    }

    /// Wipe every transcript. Used by Settings → System → "Delete all
    /// transcripts" (plan §584-646, AE7). Privacy-only: does NOT touch
    /// `stats.json` — usage aggregates (word count, session count,
    /// duration, token totals) are preserved per the carve-out
    /// documented in
    /// `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
    /// Always writes — an empty file is the desired post-state — so
    /// the on-disk snapshot reflects the wipe even when history was
    /// already empty in-memory.
    func deleteAll() {
        write([])
    }

    private func write(_ entries: [HistoryEntry]) {
        JSONFileStorage.write(entries, to: url, encoder: encoder, log: Self.log)
    }
}
