import XCTest
@testable import NoType

/// Lifetime aggregate of every recorded session. Per-test temp file —
/// no shared state across cases.
final class StatsStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatsStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("stats.json")
    }

    override func tearDown() {
        if let parent = tempURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }
        super.tearDown()
    }

    private func makeStore() -> StatsStore {
        StatsStore(url: tempURL)
    }

    private func entry(
        text: String,
        bundleID: String = "com.tinyspeck.slackmacgap",
        name: String = "Slack",
        date: Date = Date(),
        durationSeconds: Double = 0
    ) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: name,
            sourceBundleID: bundleID,
            timestamp: date,
            durationSeconds: durationSeconds
        )
    }

    // MARK: - Empty state

    func test_summary_onMissingFile_returnsEmpty() async {
        let store = makeStore()
        let snap = await store.summary()
        XCTAssertEqual(snap, .empty)
    }

    // MARK: - Single record

    func test_record_singleEntry_updatesTotalsAndBuckets() async {
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        let e = entry(text: "hello world from the dictation", date: day)
        let snap = await store.record(e)

        XCTAssertEqual(snap.totalWords, 5)
        XCTAssertEqual(snap.totalSessions, 1)
        let dayKey = StatsSnapshot.dayKey(for: day)
        XCTAssertEqual(snap.dayBuckets[dayKey], DayBucket(words: 5, sessions: 1))
        XCTAssertEqual(
            snap.appBuckets["com.tinyspeck.slackmacgap"],
            AppBucket(name: "Slack", words: 5, sessions: 1)
        )
    }

    // MARK: - Accumulation

    func test_record_accumulatesAcrossSessions() async {
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        _ = await store.record(entry(text: "one two three", date: day))
        _ = await store.record(entry(text: "four five", date: day))
        let snap = await store.record(entry(text: "six", date: day))

        XCTAssertEqual(snap.totalWords, 6)
        XCTAssertEqual(snap.totalSessions, 3)
        XCTAssertEqual(snap.dayBuckets[StatsSnapshot.dayKey(for: day)],
                       DayBucket(words: 6, sessions: 3))
        XCTAssertEqual(snap.appBuckets["com.tinyspeck.slackmacgap"]?.sessions, 3)
    }

    func test_record_splitsAcrossDifferentDays() async {
        let store = makeStore()
        let d1 = makeDate(y: 2026, m: 5, d: 10, h: 09)
        let d2 = makeDate(y: 2026, m: 5, d: 11, h: 14)
        _ = await store.record(entry(text: "monday", date: d1))
        let snap = await store.record(entry(text: "tuesday morning hello", date: d2))

        XCTAssertEqual(snap.totalWords, 4)
        XCTAssertEqual(snap.totalSessions, 2)
        XCTAssertEqual(snap.dayBuckets[StatsSnapshot.dayKey(for: d1)],
                       DayBucket(words: 1, sessions: 1))
        XCTAssertEqual(snap.dayBuckets[StatsSnapshot.dayKey(for: d2)],
                       DayBucket(words: 3, sessions: 1))
    }

    func test_record_splitsAcrossDifferentApps() async {
        let store = makeStore()
        _ = await store.record(entry(
            text: "hi from slack",
            bundleID: "com.tinyspeck.slackmacgap",
            name: "Slack"
        ))
        let snap = await store.record(entry(
            text: "todo bug fix",
            bundleID: "co.linear.linear",
            name: "Linear"
        ))

        XCTAssertEqual(snap.appBuckets.count, 2)
        XCTAssertEqual(snap.appBuckets["com.tinyspeck.slackmacgap"]?.words, 3)
        XCTAssertEqual(snap.appBuckets["co.linear.linear"]?.words, 3)
    }

    func test_record_lastSeenDisplayNameWins() async {
        let store = makeStore()
        _ = await store.record(entry(
            text: "old",
            bundleID: "com.example.app",
            name: "Old Name"
        ))
        let snap = await store.record(entry(
            text: "new",
            bundleID: "com.example.app",
            name: "Fancy New Name"
        ))
        XCTAssertEqual(snap.appBuckets["com.example.app"]?.name, "Fancy New Name")
        XCTAssertEqual(snap.appBuckets["com.example.app"]?.sessions, 2)
    }

    func test_record_emptyBundleID_skipsAppBucketButCountsTotals() async {
        let store = makeStore()
        let snap = await store.record(entry(
            text: "no bundle here",
            bundleID: "",
            name: "Mystery"
        ))
        XCTAssertEqual(snap.totalWords, 3)
        XCTAssertEqual(snap.totalSessions, 1)
        XCTAssertTrue(snap.appBuckets.isEmpty,
                      "empty bundle IDs would collide in a single bucket — skip")
    }

    // MARK: - Persistence

    func test_record_persistsToDiskAndReloads() async {
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        _ = await store.record(entry(text: "persist me please thanks", date: day))

        // Fresh actor — same URL — must see the same totals.
        let store2 = StatsStore(url: tempURL)
        let snap = await store2.summary()
        XCTAssertEqual(snap.totalWords, 4)
        XCTAssertEqual(snap.totalSessions, 1)
        XCTAssertEqual(snap.dayBuckets[StatsSnapshot.dayKey(for: day)]?.sessions, 1)
    }

    // MARK: - Corruption recovery

    func test_summary_corruptFile_renamesAndReturnsEmpty() async throws {
        try "this is not json".data(using: .utf8)!.write(to: tempURL)
        let store = makeStore()
        let snap = await store.summary()
        XCTAssertEqual(snap, .empty)

        // The corrupt file should have been renamed; the writable URL is
        // clear for new writes.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "corrupt file should be renamed out of the way")
    }

    // MARK: - Day key

    func test_dayKey_isStableYYYYMMDD() {
        let date = makeDate(y: 2026, m: 5, d: 11, h: 14)
        XCTAssertEqual(StatsSnapshot.dayKey(for: date), "2026-05-11")
    }

    // MARK: - v1 backward compat

    func test_summary_loadsV1FileWithoutDayAppBuckets() async throws {
        // Pre-v2 stats.json — no `dayAppBuckets` field. The tolerant
        // decoder must accept it and default the new map to empty.
        let v1JSON = """
        {
          "version": 1,
          "totalWords": 42,
          "totalSessions": 3,
          "dayBuckets": { "2026-05-10": { "words": 42, "sessions": 3 } },
          "appBuckets": {
            "com.tinyspeck.slackmacgap": { "name": "Slack", "words": 42, "sessions": 3 }
          }
        }
        """
        try v1JSON.data(using: .utf8)!.write(to: tempURL)

        let store = makeStore()
        let snap = await store.summary()
        XCTAssertEqual(snap.totalWords, 42)
        XCTAssertEqual(snap.totalSessions, 3)
        XCTAssertEqual(snap.dayBuckets["2026-05-10"], DayBucket(words: 42, sessions: 3))
        XCTAssertEqual(snap.appBuckets["com.tinyspeck.slackmacgap"]?.words, 42)
        XCTAssertTrue(snap.dayAppBuckets.isEmpty,
                      "v1 files have no day×app slice — must default to empty")
    }

    func test_record_populatesDayAppBuckets() async {
        let store = makeStore()
        let d = makeDate(y: 2026, m: 5, d: 11, h: 14)
        _ = await store.record(entry(
            text: "hi slack",
            bundleID: "com.tinyspeck.slackmacgap",
            name: "Slack",
            date: d
        ))
        let snap = await store.record(entry(
            text: "linear ticket bug",
            bundleID: "co.linear.linear",
            name: "Linear",
            date: d
        ))

        let key = StatsSnapshot.dayKey(for: d)
        XCTAssertEqual(snap.dayAppBuckets[key]?["com.tinyspeck.slackmacgap"],
                       DayBucket(words: 2, sessions: 1))
        XCTAssertEqual(snap.dayAppBuckets[key]?["co.linear.linear"],
                       DayBucket(words: 3, sessions: 1))
    }

    // MARK: - Range queries

    func test_totals_overLastDays_sumsRecentBuckets() async {
        let store = makeStore()
        let today = makeDate(y: 2026, m: 5, d: 11, h: 12)
        let cal = Calendar.autoupdatingCurrent

        // Today: 3 words. Yesterday: 5. 8 days ago: 100.
        _ = await store.record(entry(text: "one two three", date: today))
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        _ = await store.record(entry(text: "uno dos tres cuatro cinco", date: yesterday))
        let weekPlus = cal.date(byAdding: .day, value: -8, to: today) ?? today
        let longText = Array(repeating: "x", count: 100).joined(separator: " ")
        let snap = await store.record(entry(text: longText, date: weekPlus))

        // 7-day window from today: today + yesterday only = 8 words.
        let last7 = snap.totals(overLastDays: 7, today: today, calendar: cal)
        XCTAssertEqual(last7.words, 8)
        XCTAssertEqual(last7.sessions, 2)

        // 30-day window: includes the old 100-word session = 108.
        let last30 = snap.totals(overLastDays: 30, today: today, calendar: cal)
        XCTAssertEqual(last30.words, 108)
        XCTAssertEqual(last30.sessions, 3)

        // nil (All): same as lifetime.
        let allTime = snap.totals(overLastDays: nil, today: today, calendar: cal)
        XCTAssertEqual(allTime.words, 108)
        XCTAssertEqual(allTime.sessions, 3)
    }

    // MARK: - Duration / WPM

    func test_record_accumulatesDurationSeconds() async {
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        _ = await store.record(entry(
            text: "hello world from dictation today",  // 5 words
            date: day,
            durationSeconds: 2.0
        ))
        let snap = await store.record(entry(
            text: "another quick session",  // 3 words
            date: day,
            durationSeconds: 1.5
        ))

        XCTAssertEqual(snap.totalWords, 8)
        XCTAssertEqual(snap.totalSessions, 2)
        XCTAssertEqual(snap.totalDurationSeconds, 3.5)

        let dayKey = StatsSnapshot.dayKey(for: day)
        XCTAssertEqual(snap.dayBuckets[dayKey]?.durationSeconds, 3.5)
        XCTAssertEqual(snap.dayAppBuckets[dayKey]?["com.tinyspeck.slackmacgap"]?.durationSeconds, 3.5)
    }

    func test_totals_overLastDays_includesDuration() async {
        let store = makeStore()
        let today = makeDate(y: 2026, m: 5, d: 11, h: 12)
        let cal = Calendar.autoupdatingCurrent
        _ = await store.record(entry(text: "a b c", date: today, durationSeconds: 4.0))
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let snap = await store.record(entry(text: "d e", date: yesterday, durationSeconds: 2.0))

        let last7 = snap.totals(overLastDays: 7, today: today, calendar: cal)
        XCTAssertEqual(last7.durationSeconds, 6.0)
        let allTime = snap.totals(overLastDays: nil, today: today, calendar: cal)
        XCTAssertEqual(allTime.durationSeconds, 6.0)
    }

    func test_record_legacyZeroDurationEntry_doesNotInflateWPMDenominator() async {
        // Reproduces the "3 words → 10 000 WPM" bug: legacy entries
        // (duration = 0) used to contribute words to the WPM
        // numerator without contributing seconds to the denominator.
        // With the matched-pair tracking, legacy words must NOT
        // appear in `totalDurationWords` either.
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        _ = await store.record(entry(
            text: "one two three four five six seven eight nine ten",  // 10 words
            date: day,
            durationSeconds: 0   // legacy / aborted-style
        ))
        let snap = await store.record(entry(
            text: "three little words",  // 3 words
            date: day,
            durationSeconds: 5
        ))

        XCTAssertEqual(snap.totalWords, 13, "every word still counts in the lifetime total")
        XCTAssertEqual(snap.totalDurationSeconds, 5.0)
        XCTAssertEqual(snap.totalDurationWords, 3,
                       "only words from sessions with measured duration feed the WPM rate")

        let dayKey = StatsSnapshot.dayKey(for: day)
        XCTAssertEqual(snap.dayBuckets[dayKey]?.durationWords, 3)
        XCTAssertEqual(snap.dayAppBuckets[dayKey]?["com.tinyspeck.slackmacgap"]?.durationWords, 3)
    }

    func test_summary_healsAsymmetricV2DurationOnFirstRead() async throws {
        // Reproduces the "4 words / 2 s but WPM=4" report: a file
        // written by the intermediate v2 build carries
        // `totalDurationSeconds` from sessions that never tracked
        // matching word counts. After the heal chain runs, the file
        // should be self-healed: duration fields zeroed at every
        // level by `healIfPreV3`, then version bumped to current
        // (v4) by `healIfPreV4`, text totals preserved throughout.
        let v2JSON = """
        {
          "version": 2,
          "totalWords": 100,
          "totalSessions": 5,
          "totalDurationSeconds": 58.0,
          "dayBuckets": {
            "2026-05-10": { "words": 100, "sessions": 5, "durationSeconds": 58.0 }
          },
          "appBuckets": {
            "com.tinyspeck.slackmacgap": { "name": "Slack", "words": 100, "sessions": 5 }
          },
          "dayAppBuckets": {
            "2026-05-10": {
              "com.tinyspeck.slackmacgap": { "words": 100, "sessions": 5, "durationSeconds": 58.0 }
            }
          }
        }
        """
        try v2JSON.data(using: .utf8)!.write(to: tempURL)

        let store = makeStore()
        let snap = await store.summary()

        XCTAssertEqual(snap.version, StatsSnapshot.currentVersion, "post-heal file should claim the current schema version")
        // Text totals survive — the user keeps their session count
        // and Top apps history.
        XCTAssertEqual(snap.totalWords, 100)
        XCTAssertEqual(snap.totalSessions, 5)
        XCTAssertEqual(snap.dayBuckets["2026-05-10"]?.words, 100)
        XCTAssertEqual(snap.dayBuckets["2026-05-10"]?.sessions, 5)
        XCTAssertEqual(snap.appBuckets["com.tinyspeck.slackmacgap"]?.words, 100)
        XCTAssertEqual(snap.dayAppBuckets["2026-05-10"]?["com.tinyspeck.slackmacgap"]?.words, 100)
        // Duration fields zeroed — would otherwise wreck WPM.
        XCTAssertEqual(snap.totalDurationSeconds, 0)
        XCTAssertEqual(snap.totalDurationWords, 0)
        XCTAssertEqual(snap.dayBuckets["2026-05-10"]?.durationSeconds, 0)
        XCTAssertEqual(snap.dayBuckets["2026-05-10"]?.durationWords, 0)
        XCTAssertEqual(snap.dayAppBuckets["2026-05-10"]?["com.tinyspeck.slackmacgap"]?.durationSeconds, 0)
        XCTAssertEqual(snap.dayAppBuckets["2026-05-10"]?["com.tinyspeck.slackmacgap"]?.durationWords, 0)
    }

    func test_healIfPreV4_preservesV3Duration() async throws {
        // v3 file (full duration tracking; no token fields). After
        // `healIfPreV4` runs, every v3 field MUST survive verbatim
        // and token fields MUST default to 0. Pins the
        // "purely-additive migration" contract — `healIfPreV4` is
        // explicitly forbidden from zeroing v3 fields (the v4 schema
        // already has every aggregate v3 ships; the existence of
        // token fields with default-0 via tolerant decode IS the
        // migration). See plan 2026-05-18-001 §491.
        let v3JSON = """
        {
          "version": 3,
          "totalWords": 50,
          "totalSessions": 7,
          "totalDurationSeconds": 1234.5,
          "totalDurationWords": 40,
          "dayBuckets": {
            "2026-05-15": {
              "words": 50,
              "sessions": 7,
              "durationSeconds": 1234.5,
              "durationWords": 40
            }
          },
          "appBuckets": {
            "com.tinyspeck.slackmacgap": { "name": "Slack", "words": 50, "sessions": 7 }
          },
          "dayAppBuckets": {
            "2026-05-15": {
              "com.tinyspeck.slackmacgap": {
                "words": 50,
                "sessions": 7,
                "durationSeconds": 1234.5,
                "durationWords": 40
              }
            }
          }
        }
        """
        try v3JSON.data(using: .utf8)!.write(to: tempURL)

        let store = makeStore()
        let snap = await store.summary()

        XCTAssertEqual(snap.version, StatsSnapshot.currentVersion, "post-heal file should claim the current schema version")

        // EVERY v3 aggregate preserved verbatim.
        XCTAssertEqual(snap.totalWords, 50)
        XCTAssertEqual(snap.totalSessions, 7)
        XCTAssertEqual(snap.totalDurationSeconds, 1234.5,
                       "v3 duration must NOT be zeroed by healIfPreV4")
        XCTAssertEqual(snap.totalDurationWords, 40)
        XCTAssertEqual(snap.dayBuckets["2026-05-15"]?.words, 50)
        XCTAssertEqual(snap.dayBuckets["2026-05-15"]?.sessions, 7)
        XCTAssertEqual(snap.dayBuckets["2026-05-15"]?.durationSeconds, 1234.5)
        XCTAssertEqual(snap.dayBuckets["2026-05-15"]?.durationWords, 40)
        XCTAssertEqual(snap.appBuckets["com.tinyspeck.slackmacgap"]?.words, 50)
        XCTAssertEqual(snap.dayAppBuckets["2026-05-15"]?["com.tinyspeck.slackmacgap"]?.durationSeconds, 1234.5)

        // Token fields default to 0 — the schema knows about them
        // (decode succeeded), the migration just doesn't backfill
        // anything since v3 files never carried them.
        XCTAssertEqual(snap.dayBuckets["2026-05-15"]?.tokenInput, 0)
        XCTAssertEqual(snap.dayBuckets["2026-05-15"]?.tokenOutput, 0)
        XCTAssertEqual(snap.dayBuckets["2026-05-15"]?.tokenCached, 0)
        XCTAssertEqual(snap.dayAppBuckets["2026-05-15"]?["com.tinyspeck.slackmacgap"]?.tokenInput, 0)
    }

    func test_historyEntry_decodesLegacyJSONWithoutDuration() throws {
        // Pre-duration history.json — durationSeconds field absent.
        let legacyJSON = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "text": "hello",
          "sourceAppName": "Slack",
          "sourceBundleID": "com.tinyspeck.slackmacgap",
          "timestamp": "2026-05-11T10:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(HistoryEntry.self, from: legacyJSON.data(using: .utf8)!)
        XCTAssertEqual(entry.text, "hello")
        XCTAssertEqual(entry.durationSeconds, 0,
                       "legacy rows decode with durationSeconds defaulted to 0")
    }

    func test_topApps_overLastDays_respectsWindow() async {
        let store = makeStore()
        let today = makeDate(y: 2026, m: 5, d: 11, h: 12)
        let cal = Calendar.autoupdatingCurrent

        // Slack: 5 words today.
        _ = await store.record(entry(
            text: "five words go in here",
            bundleID: "com.tinyspeck.slackmacgap", name: "Slack", date: today
        ))
        // Linear: 8 words 20 days ago.
        let weeksAgo = cal.date(byAdding: .day, value: -20, to: today) ?? today
        let snap = await store.record(entry(
            text: "linear has eight whole words placed inside this text",
            bundleID: "co.linear.linear", name: "Linear", date: weeksAgo
        ))

        // 7-day window: only Slack.
        let top7 = snap.topApps(overLastDays: 7, today: today, calendar: cal)
        XCTAssertEqual(top7.count, 1)
        XCTAssertEqual(top7.first?.bundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(top7.first?.words, 5)

        // 30-day window: both.
        let top30 = snap.topApps(overLastDays: 30, today: today, calendar: cal)
        XCTAssertEqual(top30.count, 2)
        XCTAssertEqual(top30.first?.bundleID, "co.linear.linear",
                       "Linear wins by word count in the 30-day window")

        // All: also both, but uses lifetime appBuckets path.
        let topAll = snap.topApps(overLastDays: nil, today: today, calendar: cal)
        XCTAssertEqual(topAll.count, 2)
        XCTAssertEqual(topAll.first?.bundleID, "co.linear.linear")
    }

    // MARK: - Token aggregation (v4)

    func test_record_singleSessionWithTokens_updatesDayBucket() async {
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        let e = entry(text: "hello world", date: day)
        let tokens = TokenUsage(input: 1_000, output: 500, cached: 300)
        let snap = await store.record(e, tokens: tokens)

        let key = StatsSnapshot.dayKey(for: day)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenInput,  1_000)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenOutput,   500)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenCached,   300)

        // day×app slice mirrors the same totals.
        XCTAssertEqual(snap.dayAppBuckets[key]?["com.tinyspeck.slackmacgap"]?.tokenInput,  1_000)
        XCTAssertEqual(snap.dayAppBuckets[key]?["com.tinyspeck.slackmacgap"]?.tokenOutput,   500)
        XCTAssertEqual(snap.dayAppBuckets[key]?["com.tinyspeck.slackmacgap"]?.tokenCached,   300)
    }

    func test_record_accumulatesTokensAcrossMultipleSessions_sameDay() async {
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        _ = await store.record(
            entry(text: "first", date: day),
            tokens: TokenUsage(input: 100, output: 50, cached: 30)
        )
        let snap = await store.record(
            entry(text: "second", date: day),
            tokens: TokenUsage(input: 200, output: 25, cached: 15)
        )

        let key = StatsSnapshot.dayKey(for: day)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenInput,  300)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenOutput,  75)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenCached,  45)
    }

    func test_record_zeroTokens_doesNotAffectBuckets() async {
        // Backwards-compat path: existing tests + the `record(_:)`
        // shim use `.zero`. Token fields must stay 0 throughout.
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        let snap = await store.record(entry(text: "no tokens", date: day))

        let key = StatsSnapshot.dayKey(for: day)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenInput,  0)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenOutput, 0)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenCached, 0)
    }

    func test_record_emptyBundleID_stillCountsTokensInDayBucket() async {
        // Mirrors the existing `test_record_emptyBundleID_skipsAppBucketButCountsTotals`
        // for tokens — day-level tokens accumulate, day×app skip.
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        let snap = await store.record(
            entry(text: "mystery", bundleID: "", name: "Mystery", date: day),
            tokens: TokenUsage(input: 50, output: 25, cached: 10)
        )

        let key = StatsSnapshot.dayKey(for: day)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenInput,  50)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenOutput, 25)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenCached, 10)
        XCTAssertTrue(snap.dayAppBuckets[key]?.isEmpty ?? true,
                      "empty bundle skips day×app — by design")
    }

    func test_record_tokensPersistAcrossReload() async {
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        _ = await store.record(
            entry(text: "persist", date: day),
            tokens: TokenUsage(input: 1_500, output: 600, cached: 900)
        )

        // Fresh actor — same URL — must see tokens preserved through
        // atomic write + tolerant decode.
        let store2 = StatsStore(url: tempURL)
        let snap = await store2.summary()
        let key = StatsSnapshot.dayKey(for: day)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenInput,  1_500)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenOutput,   600)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenCached,   900)
    }

    // MARK: - Per-model token tracking (v5)

    func test_record_withModel_splitsTokensByModel() async {
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        _ = await store.record(
            entry(text: "lite one", date: day),
            tokens: TokenUsage(input: 100, output: 50, cached: 30),
            model: .flashLite
        )
        let snap = await store.record(
            entry(text: "flash two", date: day),
            tokens: TokenUsage(input: 200, output: 80, cached: 0),
            model: .flash
        )

        let key = StatsSnapshot.dayKey(for: day)
        let byModel = snap.dayBuckets[key]?.tokensByModel
        XCTAssertEqual(byModel?[GeminiModel.flashLite.rawValue],
                       ModelTokens(input: 100, output: 50, cached: 30))
        XCTAssertEqual(byModel?[GeminiModel.flash.rawValue],
                       ModelTokens(input: 200, output: 80, cached: 0))
        // Flat aggregate stays the cross-model sum.
        XCTAssertEqual(snap.dayBuckets[key]?.tokenInput,  300)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenOutput, 130)
        XCTAssertEqual(snap.dayBuckets[key]?.tokenCached,  30)
    }

    func test_record_modelDefaultsToFlashLite() async {
        // The token-aware record without an explicit model attributes
        // to Flash-Lite, keeping pre-toggle callers correct.
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        let snap = await store.record(
            entry(text: "default model", date: day),
            tokens: TokenUsage(input: 10, output: 5, cached: 0)
        )
        let key = StatsSnapshot.dayKey(for: day)
        XCTAssertEqual(snap.dayBuckets[key]?.tokensByModel[GeminiModel.flashLite.rawValue],
                       ModelTokens(input: 10, output: 5, cached: 0))
    }

    func test_record_zeroTokens_seedsNoModelEntry() async {
        // `.zero` (the `record(_:)` shim) must not create an empty
        // per-model row.
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        let snap = await store.record(entry(text: "nothing", date: day))
        let key = StatsSnapshot.dayKey(for: day)
        XCTAssertTrue(snap.dayBuckets[key]?.tokensByModel.isEmpty ?? true)
    }

    func test_tokenTotalsByModel_sumsPerModelAcrossWindow() async {
        let store = makeStore()
        let today = makeDate(y: 2026, m: 5, d: 11, h: 12)
        let cal = Calendar.autoupdatingCurrent
        _ = await store.record(entry(text: "a", date: today),
                               tokens: TokenUsage(input: 100, output: 50, cached: 0), model: .flash)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let snap = await store.record(entry(text: "b", date: yesterday),
                                      tokens: TokenUsage(input: 200, output: 60, cached: 0), model: .flash)

        let byModel = snap.tokenTotalsByModel(overLastDays: 7, today: today, calendar: cal)
        XCTAssertEqual(byModel[GeminiModel.flash.rawValue],
                       ModelTokens(input: 300, output: 110, cached: 0))
        XCTAssertNil(byModel[GeminiModel.flashLite.rawValue])
    }

    func test_migration_v4FlatTokens_attributedToFlashLite() throws {
        // A v4 stats.json: flat day-bucket tokens, no `tokensByModel`.
        let json = """
        {
          "version": 4,
          "totalWords": 3, "totalSessions": 1,
          "totalDurationSeconds": 0, "totalDurationWords": 0,
          "appBuckets": {}, "dayAppBuckets": {},
          "dayBuckets": {
            "2026-05-11": {
              "words": 3, "sessions": 1,
              "durationSeconds": 0, "durationWords": 0,
              "tokenInput": 1000, "tokenOutput": 400, "tokenCached": 200
            }
          }
        }
        """
        let snap = try JSONDecoder().decode(StatsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.version, 5, "v4 file heals to v5")
        let b = snap.dayBuckets["2026-05-11"]
        // Flat fields preserved verbatim.
        XCTAssertEqual(b?.tokenInput, 1000)
        XCTAssertEqual(b?.tokenOutput, 400)
        XCTAssertEqual(b?.tokenCached, 200)
        // Historical tokens attributed to Flash-Lite.
        XCTAssertEqual(b?.tokensByModel[GeminiModel.flashLite.rawValue],
                       ModelTokens(input: 1000, output: 400, cached: 200))
        // And they price at Flash-Lite rates via the per-model cost path.
        let cost = GeminiPricing.cost(perModel: snap.tokenTotalsByModel(overLastDays: nil))
        // Broken into named sub-expressions on purpose: the inline 3-term
        // chain of untyped Double literals tripped Swift's type-checker
        // timeout ("unable to type-check in reasonable time") on CI runners.
        let billableInputCost = 800.0 * 0.25 / 1_000_000.0   // billable input (1000-200)
        let cachedCost = 200.0 * 0.025 / 1_000_000.0
        let outputCost = 400.0 * 1.50 / 1_000_000.0
        let expected = billableInputCost + cachedCost + outputCost
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
    }

    func test_migration_v4FlatTokens_attributedToFlashLite_inDayAppBuckets() throws {
        // v4 file with a NON-empty dayAppBuckets entry — exercises the
        // nested attribution loop in healIfPreV5 (the top-level dayBuckets
        // migration test alone leaves it uncovered).
        let json = """
        {
          "version": 4,
          "totalWords": 3, "totalSessions": 1,
          "totalDurationSeconds": 0, "totalDurationWords": 0,
          "appBuckets": {}, "dayBuckets": {},
          "dayAppBuckets": {
            "2026-05-11": {
              "com.tinyspeck.slackmacgap": {
                "words": 3, "sessions": 1,
                "durationSeconds": 0, "durationWords": 0,
                "tokenInput": 500, "tokenOutput": 200, "tokenCached": 100
              }
            }
          }
        }
        """
        let snap = try JSONDecoder().decode(StatsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.version, 5)
        let inner = snap.dayAppBuckets["2026-05-11"]?["com.tinyspeck.slackmacgap"]
        XCTAssertEqual(inner?.tokenInput, 500, "flat fields preserved")
        XCTAssertEqual(inner?.tokensByModel[GeminiModel.flashLite.rawValue],
                       ModelTokens(input: 500, output: 200, cached: 100))
    }

    func test_migration_v5File_isIdempotent() throws {
        // A v5 file with tokensByModel already populated must NOT be
        // re-attributed — `guard version < 5` + the `tokensByModel.isEmpty`
        // short-circuit protect it. The flat fields must not leak a third
        // Flash-Lite entry on top of the existing per-model split.
        let json = """
        {
          "version": 5,
          "totalWords": 3, "totalSessions": 1,
          "totalDurationSeconds": 0, "totalDurationWords": 0,
          "appBuckets": {}, "dayAppBuckets": {},
          "dayBuckets": {
            "2026-05-11": {
              "words": 3, "sessions": 1,
              "durationSeconds": 0, "durationWords": 0,
              "tokenInput": 300, "tokenOutput": 90, "tokenCached": 0,
              "tokensByModel": {
                "gemini-3.1-flash-lite": { "input": 100, "output": 30, "cached": 0 },
                "gemini-3.5-flash":      { "input": 200, "output": 60, "cached": 0 }
              }
            }
          }
        }
        """
        let snap = try JSONDecoder().decode(StatsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.version, 5)
        let b = snap.dayBuckets["2026-05-11"]
        XCTAssertEqual(b?.tokensByModel.count, 2, "no extra Flash-Lite re-attribution")
        XCTAssertEqual(b?.tokensByModel[GeminiModel.flashLite.rawValue],
                       ModelTokens(input: 100, output: 30, cached: 0))
        XCTAssertEqual(b?.tokensByModel[GeminiModel.flash.rawValue],
                       ModelTokens(input: 200, output: 60, cached: 0))
    }

    func test_record_dualWrite_flatEqualsSumOfPerModel() async {
        // Pin the dual-write invariant the cost cell (per-model) and the
        // count cells (flat aggregate) both rely on: after a mixed-model
        // day, sum(tokensByModel) must equal the flat fields.
        let store = makeStore()
        let day = makeDate(y: 2026, m: 5, d: 11, h: 14)
        _ = await store.record(entry(text: "lite", date: day),
                               tokens: TokenUsage(input: 100, output: 50, cached: 30), model: .flashLite)
        let snap = await store.record(entry(text: "flash", date: day),
                                      tokens: TokenUsage(input: 200, output: 80, cached: 10), model: .flash)
        guard let b = snap.dayBuckets[StatsSnapshot.dayKey(for: day)] else {
            return XCTFail("missing day bucket")
        }
        XCTAssertEqual(b.tokensByModel.values.reduce(0) { $0 + $1.input },  b.tokenInput)
        XCTAssertEqual(b.tokensByModel.values.reduce(0) { $0 + $1.output }, b.tokenOutput)
        XCTAssertEqual(b.tokensByModel.values.reduce(0) { $0 + $1.cached }, b.tokenCached)
    }

    // MARK: - tokenTotals(overLastDays:) windowing

    func test_tokenTotals_overLastDays_sumsRecentBuckets() async {
        let store = makeStore()
        let today = makeDate(y: 2026, m: 5, d: 11, h: 12)
        let cal = Calendar.autoupdatingCurrent

        _ = await store.record(
            entry(text: "today", date: today),
            tokens: TokenUsage(input: 100, output: 50, cached: 30)
        )
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        _ = await store.record(
            entry(text: "yesterday", date: yesterday),
            tokens: TokenUsage(input: 200, output: 100, cached: 80)
        )
        let weekPlus = cal.date(byAdding: .day, value: -8, to: today) ?? today
        let snap = await store.record(
            entry(text: "old", date: weekPlus),
            tokens: TokenUsage(input: 1_000, output: 500, cached: 700)
        )

        // 7-day window from today: today + yesterday only.
        let last7 = snap.tokenTotals(overLastDays: 7, today: today, calendar: cal)
        XCTAssertEqual(last7.input,  300)
        XCTAssertEqual(last7.output, 150)
        XCTAssertEqual(last7.cached, 110)

        // 30-day window: includes the old bucket.
        let last30 = snap.tokenTotals(overLastDays: 30, today: today, calendar: cal)
        XCTAssertEqual(last30.input,  1_300)
        XCTAssertEqual(last30.output,   650)
        XCTAssertEqual(last30.cached,   810)

        // nil (All): same as 30 here — no sessions outside the
        // 30-day window in this fixture.
        let allTime = snap.tokenTotals(overLastDays: nil, today: today, calendar: cal)
        XCTAssertEqual(allTime.input,  1_300)
        XCTAssertEqual(allTime.output,   650)
        XCTAssertEqual(allTime.cached,   810)
    }

    func test_tokenTotals_emptyWindow_returnsZero() async {
        // No sessions at all → every window returns (0, 0, 0), not
        // nil and not an error. UI consumers (e.g. `TokenStatsPanel`
        // in U6) format zeros for the "Today" column on a fresh
        // install without crashing.
        let store = makeStore()
        let today = makeDate(y: 2026, m: 5, d: 11, h: 12)
        let snap = await store.summary()
        let totals = snap.tokenTotals(overLastDays: 7, today: today)
        XCTAssertEqual(totals.input,  0)
        XCTAssertEqual(totals.output, 0)
        XCTAssertEqual(totals.cached, 0)
    }

    func test_tokenTotals_allLifetime_sumsEveryDayBucket() async {
        // Even when the day predates the windowed range, the "All"
        // case (`days: nil`) still picks it up. Source of truth for
        // tokens is the `dayBuckets` map directly — no separate
        // lifetime field.
        let store = makeStore()
        let cal = Calendar.autoupdatingCurrent
        let today = makeDate(y: 2026, m: 5, d: 11, h: 12)
        let yearAgo = cal.date(byAdding: .day, value: -400, to: today) ?? today
        _ = await store.record(
            entry(text: "ancient", date: yearAgo),
            tokens: TokenUsage(input: 1, output: 2, cached: 3)
        )
        let snap = await store.record(
            entry(text: "recent", date: today),
            tokens: TokenUsage(input: 10, output: 20, cached: 30)
        )
        let total = snap.tokenTotals(overLastDays: nil, today: today, calendar: cal)
        XCTAssertEqual(total.input,  11)
        XCTAssertEqual(total.output, 22)
        XCTAssertEqual(total.cached, 33)
    }

    // MARK: - Helpers

    private func makeDate(y: Int, m: Int, d: Int, h: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h
        return Calendar.autoupdatingCurrent.date(from: comps) ?? Date()
    }
}
