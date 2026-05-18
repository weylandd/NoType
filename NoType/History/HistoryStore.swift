import Foundation
import OSLog

actor HistoryStore {
    private static let log = Logger(subsystem: "app.notype", category: "history")
    private static let cap = 10

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
