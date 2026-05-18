import XCTest
@testable import NoType

/// Pins the two pure helpers backing `TokenStatsPanel`:
///
///   1. `TokenStatsRange.days` — the Today/7d/30d/All →
///      `StatsSnapshot.tokenTotals(overLastDays:)` mapping.
///   2. `TokenStatsPanel.formatCacheHitRate(input:cached:)` —
///      the divide-by-zero invariant («—» when no usage recorded)
///      and the round-to-integer percentage format.
final class TokenStatsPanelTests: XCTestCase {

    // MARK: - Range → days mapping

    func test_range_today_mapsTo1Day() {
        XCTAssertEqual(TokenStatsRange.today.days, 1)
    }

    func test_range_last7_mapsTo7Days() {
        XCTAssertEqual(TokenStatsRange.last7.days, 7)
    }

    func test_range_last30_mapsTo30Days() {
        XCTAssertEqual(TokenStatsRange.last30.days, 30)
    }

    func test_range_all_mapsToNil_forLifetimeTotals() {
        // `nil` is the contract `StatsSnapshot.tokenTotals` uses
        // to mean "sum every recorded day bucket" — lifetime
        // totals. Don't swap to a large finite value (e.g. 9999)
        // because `tokenTotals` walks calendar offsets one-by-one
        // and would silently miss days older than the window.
        XCTAssertNil(TokenStatsRange.all.days)
    }

    func test_allCases_orderingIsTodayLast7Last30All() {
        // The segmented picker renders in `allCases` order. Pin
        // the visual order so an enum reorder is caught.
        XCTAssertEqual(TokenStatsRange.allCases,
                       [.today, .last7, .last30, .all])
    }

    // MARK: - Cache hit rate formatting

    func test_cacheHitRate_zeroInputAndZeroCached_returnsDash() {
        // Divide-by-zero invariant (plan §555): no recorded
        // sessions in the window must NOT render «0%» — the
        // accuracy of «0%» is misleading (it reads as a real
        // 0% hit rate, not "no data"). Show «—» instead.
        let rendered = TokenStatsPanel.formatCacheHitRate(input: 0, cached: 0)
        XCTAssertEqual(rendered, "—")
    }

    func test_cacheHitRate_300of1300_rounds_to23Percent() {
        // Spec example from the plan §572: input=1000, cached=300
        // → 300/(1000+300) = 23.07%, formatted «23%».
        let rendered = TokenStatsPanel.formatCacheHitRate(input: 1000, cached: 300)
        XCTAssertEqual(rendered, "23%")
    }

    func test_cacheHitRate_allCached_returns100Percent() {
        // Pathological-but-possible: a session where every input
        // token hit the implicit cache (rare; would need a stable
        // cache-prefix replay against a recently-warmed shard).
        let rendered = TokenStatsPanel.formatCacheHitRate(input: 0, cached: 500)
        XCTAssertEqual(rendered, "100%")
    }

    func test_cacheHitRate_noCached_returnsZeroPercent() {
        // First session of a new prefix shape — nothing cached
        // yet. «0%» is a real signal here (vs «—» which means
        // "no data"), so distinguish the two by checking
        // input > 0.
        let rendered = TokenStatsPanel.formatCacheHitRate(input: 500, cached: 0)
        XCTAssertEqual(rendered, "0%")
    }

    func test_cacheHitRate_smallNumbers_roundsCorrectly() {
        // 1/2 = 50% exactly; the formatter must not round-down
        // to 49%. Standard `Int(round(...))` covers this — pin
        // it so a later switch to `Int(_:)` truncation is caught.
        XCTAssertEqual(TokenStatsPanel.formatCacheHitRate(input: 1, cached: 1), "50%")
    }

    // MARK: - Integration with StatsSnapshot

    func test_tokenTotals_today_readsTodaysDayBucket() {
        // End-to-end: build a synthetic snapshot with one day
        // bucket for today + one for "yesterday" (3 days ago to
        // avoid timezone edge), confirm `.today` reads only the
        // today bucket.
        let today = Date()
        let cal = Calendar.autoupdatingCurrent
        let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: today)!
        let todayKey = StatsSnapshot.dayKey(for: today, calendar: cal)
        let oldKey   = StatsSnapshot.dayKey(for: threeDaysAgo, calendar: cal)

        var snap = StatsSnapshot.empty
        snap.dayBuckets[todayKey] = DayBucket(
            words: 0, sessions: 1,
            tokenInput: 100, tokenOutput: 50, tokenCached: 20
        )
        snap.dayBuckets[oldKey] = DayBucket(
            words: 0, sessions: 1,
            tokenInput: 999, tokenOutput: 999, tokenCached: 999
        )

        let totals = snap.tokenTotals(overLastDays: TokenStatsRange.today.days,
                                      today: today,
                                      calendar: cal)
        XCTAssertEqual(totals.input,  100)
        XCTAssertEqual(totals.output, 50)
        XCTAssertEqual(totals.cached, 20)
    }

    func test_tokenTotals_all_sumsLifetime() {
        // `.all.days == nil` triggers the lifetime branch — sums
        // every day-bucket regardless of age. Build a snapshot
        // with one ancient bucket (400 days ago) and confirm it
        // contributes.
        let today = Date()
        let cal = Calendar.autoupdatingCurrent
        let ancient = cal.date(byAdding: .day, value: -400, to: today)!
        let ancientKey = StatsSnapshot.dayKey(for: ancient, calendar: cal)

        var snap = StatsSnapshot.empty
        snap.dayBuckets[ancientKey] = DayBucket(
            words: 0, sessions: 1,
            tokenInput: 7, tokenOutput: 3, tokenCached: 1
        )

        let totals = snap.tokenTotals(overLastDays: TokenStatsRange.all.days,
                                      today: today,
                                      calendar: cal)
        XCTAssertEqual(totals.input,  7)
        XCTAssertEqual(totals.output, 3)
        XCTAssertEqual(totals.cached, 1)
    }
}
