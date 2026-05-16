import Foundation
import OSLog

/// Shared helpers for the JSON-file-backed actor stores
/// (`HistoryStore`, `StatsStore`, `InstructionsStore`, `DictionaryStore`).
///
/// Each store still owns its own `actor` + business API; this enum
/// centralises only the file-handling boilerplate they all share:
/// resolving the App-Support URL, configuring the iso8601 encoder /
/// decoder, atomic writes, and corruption recovery via `.corrupt-<ts>`
/// rename.
enum JSONFileStorage {

    /// Build a URL like `~/Library/Application Support/NoType/<filename>`.
    /// Creates the `NoType/` directory if needed; on `FileManager`
    /// failure falls back to `NSTemporaryDirectory()` so tests and
    /// unsandboxed edge cases still get a writable path.
    static func appSupportURL(filename: String) -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("NoType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    /// Pre-configured `JSONEncoder` — iso8601 dates, sorted keys +
    /// pretty-printed output (deterministic, diff-friendly).
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Pre-configured `JSONDecoder` — iso8601 dates.
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Tolerant read. Returns `nil` when the file doesn't exist or is
    /// unreadable. On a decode failure renames the file to
    /// `<name>.corrupt-<unix-ts>` and returns `nil` — caller substitutes
    /// its own "empty" snapshot.
    ///
    /// Log lines are emitted on the caller-supplied `Logger`; that
    /// logger's `category:` already identifies the store in Console.app,
    /// so the messages here don't repeat it.
    ///
    /// - Parameters:
    ///   - url: file to read.
    ///   - type: decoded type.
    ///   - decoder: caller's pre-configured decoder (so iso8601 /
    ///     custom strategies survive).
    ///   - log: caller's logger.
    static func read<T: Decodable>(
        from url: URL,
        as type: T.Type,
        decoder: JSONDecoder,
        log: Logger
    ) -> T? {
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else { return nil }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            log.error("corrupted, backed up to \(backup.lastPathComponent, privacy: .public) (\(error.localizedDescription, privacy: .public))")
            return nil
        }
    }

    /// Atomic write + error log on the caller's logger. Throws are
    /// swallowed (matches the pattern in all four stores) — disk-full /
    /// permission errors leave the in-memory state authoritative until
    /// next launch.
    static func write<T: Encodable>(
        _ value: T,
        to url: URL,
        encoder: JSONEncoder,
        log: Logger
    ) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            log.error("write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
