import Foundation
import OSLog

/// Per-day usage bucket. One row per local-calendar day; keyed by
/// "yyyy-MM-dd" string in `StatsSnapshot.dayBuckets`. The same shape
/// is reused inside `dayAppBuckets[dayKey][bundleID]` for the
/// day×app slice. `durationSeconds` is the **sum** of hotkey-press
/// durations across all sessions in this bucket — drives windowed
/// WPM and Time saved on the Home tab.
struct DayBucket: Codable, Sendable, Equatable {
    var words: Int
    var sessions: Int
    var durationSeconds: Double
    /// **Subset** of `words` from sessions where `durationSeconds`
    /// was actually measured (i.e. the entry had `durationSeconds >
    /// 0`). Pairs with `durationSeconds` for fair WPM / Time-saved
    /// calculations — using `words` would mix in legacy sessions
    /// that contributed text but no timing, blowing up the rate.
    var durationWords: Int

    init(words: Int, sessions: Int, durationSeconds: Double = 0, durationWords: Int = 0) {
        self.words = words
        self.sessions = sessions
        self.durationSeconds = durationSeconds
        self.durationWords = durationWords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.words           = try c.decodeIfPresent(Int.self,    forKey: .words)           ?? 0
        self.sessions        = try c.decodeIfPresent(Int.self,    forKey: .sessions)        ?? 0
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        self.durationWords   = try c.decodeIfPresent(Int.self,    forKey: .durationWords)   ?? 0
    }
}

/// Per-app usage bucket, keyed by bundle ID in `StatsSnapshot.appBuckets`.
/// `name` carries the most recently seen display name so existing rows
/// keep the latest label even if the user renames the app.
struct AppBucket: Codable, Sendable, Equatable {
    var name: String
    var words: Int
    var sessions: Int
}

/// Aggregate of every transcription session ever recorded. Stored as a
/// single JSON blob in App Support — small even after years of use.
///
/// **Schema v2.** Adds `dayAppBuckets` (day × bundle ID) so the Home
/// tab's range filter (7D / 30D / 90D / All) can show *windowed* top
/// apps, not just lifetime aggregates. v1 files (no `dayAppBuckets`)
/// load as `[:]` via a tolerant decoder; existing app totals stay
/// correct for the "All" tab, the windowed tabs start populating from
/// the first session recorded on the v2 build.
struct StatsSnapshot: Codable, Sendable, Equatable {
    var version: Int
    var totalWords: Int
    var totalSessions: Int
    /// Sum of `HistoryEntry.durationSeconds` across every session
    /// **that had a measured duration**. Zero for v1 / pre-duration
    /// files. Drives lifetime WPM and Time-saved cards on the Home tab.
    var totalDurationSeconds: Double
    /// Words counted **only** from sessions where `durationSeconds >
    /// 0`. The matched numerator for WPM / Time-saved formulas —
    /// keeps the rate honest when the store has legacy entries
    /// without timing data.
    var totalDurationWords: Int
    /// Day-level totals across every app. Keyed by `dayKey(for:)`.
    var dayBuckets: [String: DayBucket]
    /// Lifetime per-app totals. Carries the most recently seen display
    /// name. Used for the "All" range and as the name source for the
    /// windowed views.
    var appBuckets: [String: AppBucket]
    /// Per-day per-bundle totals. Outer key = day key, inner key =
    /// bundle ID. Empty for sessions recorded before v2 shipped.
    var dayAppBuckets: [String: [String: DayBucket]]

    /// Latest schema version. Bumped from 2 → 3 when
    /// `totalDurationWords` joined the schema: pre-v3 files may carry
    /// `totalDurationSeconds` from an intermediate build where
    /// seconds were tracked but matched word counts weren't. Decoding
    /// such a file triggers `healIfPreV3()` which zeroes the duration
    /// fields so WPM doesn't divide by a stale denominator.
    static let currentVersion = 3

    static let empty = StatsSnapshot(
        version: currentVersion,
        totalWords: 0,
        totalSessions: 0,
        totalDurationSeconds: 0,
        totalDurationWords: 0,
        dayBuckets: [:],
        appBuckets: [:],
        dayAppBuckets: [:]
    )

    /// Local-calendar day key for a given timestamp. Local time zone is
    /// load-bearing: a session at 23:45 local on May 11 must land in the
    /// May 11 bucket, not May 12 UTC.
    static func dayKey(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1
        )
    }

    /// Tolerant decoder — every field is `decodeIfPresent` with a
    /// default so adding new fields in the future doesn't break old
    /// files. v1 files (no `dayAppBuckets`, no duration) load cleanly
    /// with the new fields defaulted to empty / zero.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version              = try c.decodeIfPresent(Int.self,    forKey: .version) ?? 1
        self.totalWords           = try c.decodeIfPresent(Int.self,    forKey: .totalWords) ?? 0
        self.totalSessions        = try c.decodeIfPresent(Int.self,    forKey: .totalSessions) ?? 0
        self.totalDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .totalDurationSeconds) ?? 0
        self.totalDurationWords   = try c.decodeIfPresent(Int.self,    forKey: .totalDurationWords) ?? 0
        self.dayBuckets           = try c.decodeIfPresent([String: DayBucket].self, forKey: .dayBuckets) ?? [:]
        self.appBuckets           = try c.decodeIfPresent([String: AppBucket].self, forKey: .appBuckets) ?? [:]
        self.dayAppBuckets        = try c.decodeIfPresent([String: [String: DayBucket]].self, forKey: .dayAppBuckets) ?? [:]
        healIfPreV3()
    }

    /// Pre-v3 files may have `totalDurationSeconds` accumulated from a
    /// build where `durationWords` wasn't yet tracked. Those seconds
    /// have no matching word total, so feeding them into WPM produces
    /// nonsense (e.g. 4 words ÷ 60 s of mixed-source duration = 4
    /// WPM instead of the real 120). Reset every duration field
    /// (top-level + day buckets + day×app buckets) so future sessions
    /// rebuild the rate cleanly. Text totals — `totalWords`,
    /// `totalSessions`, `appBuckets`, and the `words` / `sessions`
    /// columns of the daily buckets — are untouched.
    private mutating func healIfPreV3() {
        guard version < Self.currentVersion else { return }
        totalDurationSeconds = 0
        totalDurationWords = 0
        for (key, var bucket) in dayBuckets {
            bucket.durationSeconds = 0
            bucket.durationWords = 0
            dayBuckets[key] = bucket
        }
        for (outerKey, innerMap) in dayAppBuckets {
            var fixed = innerMap
            for (innerKey, var bucket) in innerMap {
                bucket.durationSeconds = 0
                bucket.durationWords = 0
                fixed[innerKey] = bucket
            }
            dayAppBuckets[outerKey] = fixed
        }
        version = Self.currentVersion
    }

    // Memberwise init is normally synthesized but custom `init(from:)`
    // suppresses it — restore it explicitly so callers (and `.empty`)
    // keep working.
    init(
        version: Int,
        totalWords: Int,
        totalSessions: Int,
        totalDurationSeconds: Double,
        totalDurationWords: Int,
        dayBuckets: [String: DayBucket],
        appBuckets: [String: AppBucket],
        dayAppBuckets: [String: [String: DayBucket]]
    ) {
        self.version = version
        self.totalWords = totalWords
        self.totalSessions = totalSessions
        self.totalDurationSeconds = totalDurationSeconds
        self.totalDurationWords = totalDurationWords
        self.dayBuckets = dayBuckets
        self.appBuckets = appBuckets
        self.dayAppBuckets = dayAppBuckets
    }
}

// MARK: - Range queries

extension StatsSnapshot {
    /// Returns aggregates summed across the last `days` local days
    /// (inclusive of today). `days == nil` is the "All" case and
    /// returns lifetime totals directly.
    ///
    /// `durationWords` is the **matched** word count for the same
    /// sessions that contributed to `durationSeconds` — divide one
    /// by the other for WPM. `words` is the unconditional total
    /// (including legacy sessions without timing data) and is what
    /// the "Words transcribed" card shows.
    func totals(
        overLastDays days: Int?,
        today: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> (words: Int, sessions: Int, durationSeconds: Double, durationWords: Int) {
        guard let days, days > 0 else {
            return (totalWords, totalSessions, totalDurationSeconds, totalDurationWords)
        }
        var words = 0
        var sessions = 0
        var duration: Double = 0
        var durationWords = 0
        for offset in 0..<days {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = StatsSnapshot.dayKey(for: d, calendar: calendar)
            if let bucket = dayBuckets[key] {
                words += bucket.words
                sessions += bucket.sessions
                duration += bucket.durationSeconds
                durationWords += bucket.durationWords
            }
        }
        return (words, sessions, duration, durationWords)
    }

    /// Per-app totals over the last `days` local days. `days == nil` →
    /// lifetime via `appBuckets`. Display names are pulled from
    /// `appBuckets` (last-seen wins); bundles seen only in the window
    /// fall back to the bundle ID.
    func topApps(overLastDays days: Int?, limit: Int = 5, today: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [TopAppRow] {
        guard let days, days > 0 else {
            return appBuckets
                .filter { $0.value.words > 0 }
                .map { TopAppRow(bundleID: $0.key, name: $0.value.name, words: $0.value.words, sessions: $0.value.sessions) }
                .sorted { $0.words > $1.words }
                .prefix(limit)
                .map { $0 }
        }
        var byBundle: [String: (words: Int, sessions: Int)] = [:]
        for offset in 0..<days {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = StatsSnapshot.dayKey(for: d, calendar: calendar)
            for (bundleID, bucket) in dayAppBuckets[key] ?? [:] {
                var prev = byBundle[bundleID] ?? (0, 0)
                prev.words += bucket.words
                prev.sessions += bucket.sessions
                byBundle[bundleID] = prev
            }
        }
        return byBundle
            .filter { $0.value.words > 0 }
            .map { (bundleID, agg) in
                TopAppRow(
                    bundleID: bundleID,
                    name: appBuckets[bundleID]?.name ?? bundleID,
                    words: agg.words,
                    sessions: agg.sessions
                )
            }
            .sorted { $0.words > $1.words }
            .prefix(limit)
            .map { $0 }
    }
}

struct TopAppRow: Sendable, Equatable {
    let bundleID: String
    let name: String
    let words: Int
    let sessions: Int
}

/// Persistent, append-only aggregate of every recorded transcription.
/// Stored at `~/Library/Application Support/NoType/stats.json` and kept
/// independent of `HistoryStore` (which caps at 10 entries) so the Home
/// tab's totals, top-apps panel, and activity heatmap can show data
/// across the whole lifetime of the install without retaining transcripts.
actor StatsStore {
    private static let log = Logger(subsystem: "app.notype", category: "stats")

    private let url: URL
    private var cached: StatsSnapshot?

    private let encoder = JSONFileStorage.makeEncoder()
    private let decoder = JSONFileStorage.makeDecoder()

    init(url: URL? = nil) {
        self.url = url ?? JSONFileStorage.appSupportURL(filename: "stats.json")
    }

    /// Returns the current snapshot, loading from disk on first call and
    /// serving from the in-memory cache thereafter.
    func summary() -> StatsSnapshot {
        if let cached { return cached }
        let loaded = readFromDisk()
        cached = loaded
        return loaded
    }

    /// Fold one transcription session into the totals + day bucket +
    /// app bucket and persist atomically. Returns the new snapshot so
    /// the caller can update its observable mirror without an extra
    /// round-trip.
    @discardableResult
    func record(_ entry: HistoryEntry) -> StatsSnapshot {
        var snap = summary()
        let words = Self.wordCount(entry.text)
        let duration = max(0, entry.durationSeconds)
        // Sessions without measured duration (legacy entries) contribute
        // to text totals but NOT to WPM / Time-saved calculations.
        // Tracking words and seconds as a matched pair keeps the rate
        // honest — otherwise legacy words would inflate the numerator
        // while only new sessions contribute to the denominator,
        // producing absurd (10 000+) WPM readings.
        let contributesToRate = duration > 0
        let timedWords = contributesToRate ? words : 0

        snap.totalWords += words
        snap.totalSessions += 1
        snap.totalDurationSeconds += duration
        snap.totalDurationWords += timedWords

        let dayKey = StatsSnapshot.dayKey(for: entry.timestamp)
        var day = snap.dayBuckets[dayKey] ?? DayBucket(words: 0, sessions: 0)
        day.words += words
        day.sessions += 1
        day.durationSeconds += duration
        day.durationWords += timedWords
        snap.dayBuckets[dayKey] = day

        // Empty bundle IDs would all collapse into one bucket and the
        // labels would race — skip the per-app bucket entirely in that
        // case, but still count the words in totals + day.
        if !entry.sourceBundleID.isEmpty {
            var app = snap.appBuckets[entry.sourceBundleID]
                ?? AppBucket(name: entry.sourceAppName, words: 0, sessions: 0)
            app.name = entry.sourceAppName    // last-seen display name wins
            app.words += words
            app.sessions += 1
            snap.appBuckets[entry.sourceBundleID] = app

            // day × bundle slice — drives the windowed Top apps panel.
            var perApp = snap.dayAppBuckets[dayKey] ?? [:]
            var dayAppBucket = perApp[entry.sourceBundleID]
                ?? DayBucket(words: 0, sessions: 0)
            dayAppBucket.words += words
            dayAppBucket.sessions += 1
            dayAppBucket.durationSeconds += duration
            dayAppBucket.durationWords += timedWords
            perApp[entry.sourceBundleID] = dayAppBucket
            snap.dayAppBuckets[dayKey] = perApp
        }

        snap.version = StatsSnapshot.currentVersion
        cached = snap
        write(snap)
        return snap
    }

    // MARK: - Disk I/O

    private func readFromDisk() -> StatsSnapshot {
        JSONFileStorage.read(
            from: url,
            as: StatsSnapshot.self,
            decoder: decoder,
            log: Self.log
        ) ?? .empty
    }

    private func write(_ snap: StatsSnapshot) {
        JSONFileStorage.write(snap, to: url, encoder: encoder, log: Self.log)
    }

    // MARK: - Word count

    /// Same split rule as `HomeStats.wordCount` — keep them in lockstep
    /// so totals don't drift between the live history view and stored
    /// stats.
    static func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.count
    }
}
