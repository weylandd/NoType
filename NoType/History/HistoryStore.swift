import Foundation
import OSLog

actor HistoryStore {
    private static let log = Logger(subsystem: "app.notype", category: "history")
    private static let cap = 10

    private let url: URL
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
            self.url = dir.appendingPathComponent("history.json")
        }
    }

    func allEntries() -> [HistoryEntry] {
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else { return [] }

        if let arr = try? decoder.decode([HistoryEntry].self, from: data) { return arr }

        let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: backup)
        Self.log.error("history corrupted, backed up to \(backup.lastPathComponent, privacy: .public)")
        return []
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
        do {
            let data = try encoder.encode(entries)
            try data.write(to: url, options: [.atomic])
        } catch {
            Self.log.error("history write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
