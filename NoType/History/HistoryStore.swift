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

    private func write(_ entries: [HistoryEntry]) {
        JSONFileStorage.write(entries, to: url, encoder: encoder, log: Self.log)
    }
}
