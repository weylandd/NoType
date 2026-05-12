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
        // matching word counts. After the v3 decoder runs, the file
        // should be self-healed: duration fields zeroed at every
        // level, version bumped to 3, text totals preserved.
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

        XCTAssertEqual(snap.version, 3, "post-heal file should claim v3")
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

    // MARK: - Helpers

    private func makeDate(y: Int, m: Int, d: Int, h: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h
        return Calendar.autoupdatingCurrent.date(from: comps) ?? Date()
    }
}
