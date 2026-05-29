import Foundation
import OSLog

/// Per-model token tally stored inside `DayBucket.tokensByModel`, keyed
/// by `GeminiModel.rawValue`. Split out from the flat
/// `tokenInput/Output/Cached` aggregate (which stays as the cross-model
/// sum — it drives the count cells and keeps a v4 reader's totals intact
/// on downgrade) so `GeminiPricing` can price each model's tokens at its
/// own rate. Tolerant decode → all-zero default. Local-only, never sent
/// anywhere (no-telemetry carve-out).
struct ModelTokens: Codable, Sendable, Equatable {
    var input: Int
    var output: Int
    var cached: Int

    init(input: Int = 0, output: Int = 0, cached: Int = 0) {
        self.input = input
        self.output = output
        self.cached = cached
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.input  = try c.decodeIfPresent(Int.self, forKey: .input)  ?? 0
        self.output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        self.cached = try c.decodeIfPresent(Int.self, forKey: .cached) ?? 0
    }
}

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
    /// Gemini prompt tokens billed across every session that landed
    /// in this bucket (v4+). Decoded with `decodeIfPresent ?? 0`
    /// so v3 files load cleanly — `healIfPreV4` doesn't backfill
    /// (purely additive migration; tolerant decoder IS the
    /// migration for token fields). Local-only — never sent
    /// anywhere; see `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
    var tokenInput: Int
    /// Gemini output (candidate) tokens billed across every session
    /// in this bucket.
    var tokenOutput: Int
    /// Subset of `tokenInput` that hit Gemini's implicit cache and
    /// were billed at the discounted rate (`cached <= input` always).
    var tokenCached: Int
    /// Per-model token split (v5+), keyed by `GeminiModel.rawValue`.
    /// The sum across models equals the flat `tokenInput/Output/Cached`
    /// fields above — the flat fields stay as the model-agnostic
    /// aggregate (count cells + v4-reader downgrade), this map exists so
    /// `GeminiPricing` can price each model's slice at its own rate.
    /// Empty for v4 files until `healIfPreV5` attributes their flat
    /// tokens to Flash-Lite (the only model that existed pre-v5).
    var tokensByModel: [String: ModelTokens]

    init(
        words: Int,
        sessions: Int,
        durationSeconds: Double = 0,
        durationWords: Int = 0,
        tokenInput: Int = 0,
        tokenOutput: Int = 0,
        tokenCached: Int = 0,
        tokensByModel: [String: ModelTokens] = [:]
    ) {
        self.words = words
        self.sessions = sessions
        self.durationSeconds = durationSeconds
        self.durationWords = durationWords
        self.tokenInput = tokenInput
        self.tokenOutput = tokenOutput
        self.tokenCached = tokenCached
        self.tokensByModel = tokensByModel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.words           = try c.decodeIfPresent(Int.self,    forKey: .words)           ?? 0
        self.sessions        = try c.decodeIfPresent(Int.self,    forKey: .sessions)        ?? 0
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        self.durationWords   = try c.decodeIfPresent(Int.self,    forKey: .durationWords)   ?? 0
        self.tokenInput      = try c.decodeIfPresent(Int.self,    forKey: .tokenInput)      ?? 0
        self.tokenOutput     = try c.decodeIfPresent(Int.self,    forKey: .tokenOutput)     ?? 0
        self.tokenCached     = try c.decodeIfPresent(Int.self,    forKey: .tokenCached)     ?? 0
        self.tokensByModel   = try c.decodeIfPresent([String: ModelTokens].self, forKey: .tokensByModel) ?? [:]
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

    /// Latest schema version.
    ///
    ///   - v2 → v3 (`healIfPreV3`): zeroed asymmetric duration
    ///     fields that an intermediate build wrote without matching
    ///     word counts (WPM denominator integrity).
    ///   - v3 → v4 (`healIfPreV4`): **purely additive** — adds
    ///     `tokenInput / tokenOutput / tokenCached` per `DayBucket`.
    ///     Token fields default to 0 via tolerant decode (that IS
    ///     the migration); existing v3 aggregates (words, sessions,
    ///     duration, app buckets) are preserved verbatim. Plan
    ///     2026-05-18-001 §491.
    ///   - v4 → v5 (`healIfPreV5`): adds `DayBucket.tokensByModel`
    ///     (per-model token split for exact per-model pricing).
    ///     Existing flat token aggregates are **attributed to
    ///     Flash-Lite** — the only transcription model that existed
    ///     before the model toggle shipped — so historical cost still
    ///     prices correctly. Flat fields are preserved verbatim.
    static let currentVersion = 5

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
        healIfPreV4()
        healIfPreV5()
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
        guard version < 3 else { return }
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
        version = 3
    }

    /// v3 → v4: token fields joined `DayBucket`. **Purely additive.**
    /// The tolerant decoder already defaulted every new field to 0
    /// for files that don't carry them — token aggregates start
    /// accumulating from the first session under the v4 build.
    /// Existing v3 aggregates (`totalDurationSeconds`,
    /// `totalDurationWords`, day buckets, app buckets) MUST be
    /// preserved verbatim — semantics differ from `healIfPreV3`,
    /// which zeroed duration fields because pre-v3 had no duration
    /// concept. v3 already has every aggregate v4 needs, so nothing
    /// to backfill here — just bump the version stamp so subsequent
    /// writes claim v4 ownership. Plan 2026-05-18-001 §491.
    private mutating func healIfPreV4() {
        guard version < 4 else { return }
        version = 4
    }

    /// v4 → v5: per-model token split joined `DayBucket`. Files written
    /// before the model toggle recorded all tokens under one model
    /// (Flash-Lite — the only one that existed), so attribute each
    /// bucket's flat `tokenInput/Output/Cached` to the Flash-Lite key.
    /// That way `tokenTotalsByModel` / cost prices historical usage
    /// correctly instead of dropping it. Buckets that already carry a
    /// `tokensByModel` map are left alone; flat fields are untouched
    /// (they remain the cross-model aggregate). Runs on both
    /// `dayBuckets` and `dayAppBuckets`.
    private mutating func healIfPreV5() {
        guard version < 5 else { return }
        let liteKey = GeminiModel.flashLite.rawValue
        func attribute(_ bucket: DayBucket) -> DayBucket {
            guard bucket.tokensByModel.isEmpty else { return bucket }
            guard bucket.tokenInput != 0 || bucket.tokenOutput != 0 || bucket.tokenCached != 0
            else { return bucket }
            var b = bucket
            b.tokensByModel[liteKey] = ModelTokens(
                input: bucket.tokenInput,
                output: bucket.tokenOutput,
                cached: bucket.tokenCached
            )
            return b
        }
        for (key, bucket) in dayBuckets {
            dayBuckets[key] = attribute(bucket)
        }
        for (outerKey, innerMap) in dayAppBuckets {
            var fixed = innerMap
            for (innerKey, bucket) in innerMap {
                fixed[innerKey] = attribute(bucket)
            }
            dayAppBuckets[outerKey] = fixed
        }
        version = 5
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

    /// Token totals summed across the last `days` local days
    /// (inclusive of today). `days == nil` returns lifetime totals
    /// (sums every recorded day's bucket — no separate lifetime
    /// field; `dayBuckets` IS the source of truth for tokens).
    /// All three components default to 0 for empty windows or files
    /// migrated from v3 (no tokens recorded yet).
    func tokenTotals(
        overLastDays days: Int?,
        today: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> (input: Int, output: Int, cached: Int) {
        if let days, days > 0 {
            var input = 0
            var output = 0
            var cached = 0
            for offset in 0..<days {
                guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                let key = StatsSnapshot.dayKey(for: d, calendar: calendar)
                if let bucket = dayBuckets[key] {
                    input  += bucket.tokenInput
                    output += bucket.tokenOutput
                    cached += bucket.tokenCached
                }
            }
            return (input, output, cached)
        }
        // Lifetime: sum every day bucket. No `totalToken*` field on
        // the top-level snapshot — the per-day slice is the only
        // place these aggregates live, by design (`StatsSnapshot`
        // already carries every other lifetime total separately;
        // adding three more would mostly duplicate the day-bucket
        // sums and risk drift between the two).
        var input = 0
        var output = 0
        var cached = 0
        for bucket in dayBuckets.values {
            input  += bucket.tokenInput
            output += bucket.tokenOutput
            cached += bucket.tokenCached
        }
        return (input, output, cached)
    }

    /// Per-model token totals over the window, keyed by
    /// `GeminiModel.rawValue`. Same window semantics as `tokenTotals`
    /// but split by model so the cost cell can price each model's
    /// slice at its own rate (`GeminiPricing.cost(perModel:)`). v4
    /// files carry their tokens under the Flash-Lite key after
    /// `healIfPreV5`. Models not seen in the window are simply absent
    /// from the result.
    func tokenTotalsByModel(
        overLastDays days: Int?,
        today: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [String: ModelTokens] {
        var out: [String: ModelTokens] = [:]
        func fold(_ bucket: DayBucket) {
            for (model, tokens) in bucket.tokensByModel {
                var acc = out[model] ?? ModelTokens()
                acc.input  += tokens.input
                acc.output += tokens.output
                acc.cached += tokens.cached
                out[model] = acc
            }
        }
        if let days, days > 0 {
            for offset in 0..<days {
                guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                let key = StatsSnapshot.dayKey(for: d, calendar: calendar)
                if let bucket = dayBuckets[key] { fold(bucket) }
            }
        } else {
            for bucket in dayBuckets.values { fold(bucket) }
        }
        return out
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
    ///
    /// Backwards-compat shim: callers that don't track per-session
    /// `TokenUsage` (legacy paths, tests, the still-extant
    /// no-token-aware code path) route here. The `tokens:`-aware
    /// overload below is the production wiring after U5.
    @discardableResult
    func record(_ entry: HistoryEntry) -> StatsSnapshot {
        record(entry, tokens: .zero)
    }

    /// Token-aware record. Folds the session's word/duration/app
    /// aggregates AND the Gemini token usage emitted by the
    /// session's calls into the corresponding day + day×app
    /// buckets. Token aggregates are **never decremented** on
    /// history-entry deletion (matches the existing carve-out for
    /// word counts — see
    /// `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`).
    @discardableResult
    func record(_ entry: HistoryEntry, tokens: TokenUsage, model: GeminiModel = .flashLite) -> StatsSnapshot {
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
        day.tokenInput  += tokens.input
        day.tokenOutput += tokens.output
        day.tokenCached += tokens.cached
        Self.addModelTokens(&day.tokensByModel, model: model, tokens: tokens)
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
            dayAppBucket.tokenInput  += tokens.input
            dayAppBucket.tokenOutput += tokens.output
            dayAppBucket.tokenCached += tokens.cached
            Self.addModelTokens(&dayAppBucket.tokensByModel, model: model, tokens: tokens)
            perApp[entry.sourceBundleID] = dayAppBucket
            snap.dayAppBuckets[dayKey] = perApp
        }

        snap.version = StatsSnapshot.currentVersion
        cached = snap
        write(snap)
        return snap
    }

    /// Wipe every aggregate back to zero (totals, day / app / day×app
    /// buckets, token counters). Driven by Settings → "Delete all
    /// analytics". Returns the new (empty) snapshot so the caller can
    /// update its observable mirror without a round-trip read. Mirror
    /// of `HistoryStore.deleteAll()` — the two wipes are independent
    /// so the user can clear transcripts without losing stats, and
    /// vice-versa.
    @discardableResult
    func deleteAll() -> StatsSnapshot {
        let empty = StatsSnapshot.empty
        cached = empty
        write(empty)
        return empty
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

    // MARK: - Per-model token folding

    /// Fold one session's `TokenUsage` into a per-model token map,
    /// keyed by `GeminiModel.rawValue`. No-op for an all-zero usage
    /// (the `record(_:)` / `.zero` shim path) so we never seed an
    /// empty model entry — keeps `tokensByModel` honest and the JSON
    /// minimal.
    private static func addModelTokens(
        _ map: inout [String: ModelTokens],
        model: GeminiModel,
        tokens: TokenUsage
    ) {
        guard tokens.input != 0 || tokens.output != 0 || tokens.cached != 0 else { return }
        var mt = map[model.rawValue] ?? ModelTokens()
        mt.input  += tokens.input
        mt.output += tokens.output
        mt.cached += tokens.cached
        map[model.rawValue] = mt
    }
}
