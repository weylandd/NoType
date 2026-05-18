import XCTest
@testable import NoType

/// Pins:
///
///   1. `TokenStatsRange.days` — the Today/7d/30d/All →
///      `StatsSnapshot.tokenTotals(overLastDays:)` mapping +
///      the `.allCases` ordering rendered by the segmented picker.
///   2. `GeminiPricing.cost(input:output:cached:)` — the
///      cached-as-subset billing math + the rate constants.
///   3. `GeminiPricing.formatCost(_:)` — the four formatter bands
///      ($0 / <$0.01 / two-decimal / one-decimal / integer).
///   4. End-to-end via `StatsSnapshot.tokenTotals(overLastDays:today:calendar:)`
///      — windowed reads of synthetic day buckets feed cleanly into
///      both `Self.formatCount` and the pricing helpers.
///
/// Marked `@MainActor` because `TokenStatsPanel.formatCount(_:)` is
/// a static method on a SwiftUI `View` (and SwiftUI Views are
/// implicitly `@MainActor` under Swift 6 strict concurrency).
@MainActor
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

    // MARK: - Pricing constants

    func test_pricingConstants_areCurrentGeminiFlashLiteRates() {
        // Sanity-pin the rate constants so a "fix the formatter"
        // commit can't silently change pricing math. Source:
        // GeminiPricing.swift doc-comment.
        XCTAssertEqual(GeminiPricing.inputPerMillion,  0.25,  accuracy: 1e-9)
        XCTAssertEqual(GeminiPricing.outputPerMillion, 1.50,  accuracy: 1e-9)
        XCTAssertEqual(GeminiPricing.cachedPerMillion, 0.025, accuracy: 1e-9)
    }

    // MARK: - Cost calculation

    func test_cost_allZero_isZero() {
        XCTAssertEqual(GeminiPricing.cost(input: 0, output: 0, cached: 0),
                       0.0, accuracy: 1e-9)
    }

    func test_cost_pureInputAndOutput_noCached() {
        // 1M input @ $0.25 + 1M output @ $1.50 = $1.75 exactly.
        let cost = GeminiPricing.cost(input: 1_000_000, output: 1_000_000, cached: 0)
        XCTAssertEqual(cost, 1.75, accuracy: 1e-9)
    }

    func test_cost_cachedIsSubsetOfInput_discountedAt10Percent() {
        // 1M input total, of which 300K are cached.
        //   billable input = 700K @ $0.25/M = $0.175
        //   cached         = 300K @ $0.025/M = $0.0075
        //   output         = 500K @ $1.50/M = $0.75
        //   total                            = $0.9325
        let cost = GeminiPricing.cost(input: 1_000_000, output: 500_000, cached: 300_000)
        XCTAssertEqual(cost, 0.9325, accuracy: 1e-9)
    }

    func test_cost_allCached_billsOnlyAtCachedRate() {
        // 1M input all cached, no fresh prompt tokens.
        //   billable input = 0
        //   cached         = 1M @ $0.025/M = $0.025
        //   output         = 0
        let cost = GeminiPricing.cost(input: 1_000_000, output: 0, cached: 1_000_000)
        XCTAssertEqual(cost, 0.025, accuracy: 1e-9)
    }

    func test_cost_cachedGreaterThanInput_clampsBillableToZero() {
        // Pathological — would mean the snapshot is malformed
        // (cached should be a subset of input). Defensive `max(0, …)`
        // floors billable-input at zero rather than producing a
        // negative number that would refund the user against the
        // cached charge.
        let cost = GeminiPricing.cost(input: 100, output: 0, cached: 500)
        // billableInput = 0; cached = 500 @ $0.025/M = $0.0000125
        XCTAssertEqual(cost, 500.0 * 0.025 / 1_000_000, accuracy: 1e-12)
    }

    // MARK: - Cost formatting bands

    func test_formatCost_zero_rendersZeroDollars() {
        XCTAssertEqual(GeminiPricing.formatCost(0), "$0.00")
    }

    func test_formatCost_negative_treatedAsZero() {
        // No path produces a negative cost in production (the
        // `max(0, …)` guard inside `cost(…)` prevents it), but the
        // formatter should still hold the line if anyone passes one.
        XCTAssertEqual(GeminiPricing.formatCost(-1), "$0.00")
    }

    func test_formatCost_subPenny_rendersLessThanOneCent() {
        // Real usage but less than a cent — distinguishes a fresh
        // window with a tiny amount of usage from a fresh window
        // with no usage at all.
        XCTAssertEqual(GeminiPricing.formatCost(0.005),  "<$0.01")
        XCTAssertEqual(GeminiPricing.formatCost(0.0001), "<$0.01")
    }

    func test_formatCost_smallAmounts_useTwoDecimals() {
        XCTAssertEqual(GeminiPricing.formatCost(0.01),  "$0.01")
        XCTAssertEqual(GeminiPricing.formatCost(0.23),  "$0.23")
        XCTAssertEqual(GeminiPricing.formatCost(1.75),  "$1.75")
        XCTAssertEqual(GeminiPricing.formatCost(9.99),  "$9.99")
    }

    func test_formatCost_doubleDigitAmounts_useOneDecimal() {
        // Keeps the three-cell row from breaking layout on width
        // — once you're in $10+ territory, the precision of the
        // hundredths digit is no longer interesting. `printf("%.1f", …)`
        // banker-rounds halves (42.55 → 42.5 because the next exact
        // float is 42.549999…), so the test pins the actual output
        // rather than naive half-up rounding.
        XCTAssertEqual(GeminiPricing.formatCost(10.0),  "$10.0")
        XCTAssertEqual(GeminiPricing.formatCost(42.55), "$42.5")
        // 99.95 stays in the 1-decimal band because the band check
        // is `usd < 100` *before* formatter rounding — band-jumps on
        // pre-rendered values keep the layout boundary predictable.
        XCTAssertEqual(GeminiPricing.formatCost(99.95), "$100.0")
    }

    func test_formatCost_tripleDigitAmounts_dropDecimals() {
        XCTAssertEqual(GeminiPricing.formatCost(100.0),  "$100")
        // `printf("%.0f", 1234.5)` banker-rounds halves to even —
        // 1234 is even so the result is "$1234", not "$1235".
        XCTAssertEqual(GeminiPricing.formatCost(1234.5), "$1234")
        XCTAssertEqual(GeminiPricing.formatCost(1235.5), "$1236") // 1236 is even
    }

    // MARK: - Count formatting

    func test_formatCount_zero_rendersZero() {
        XCTAssertEqual(TokenStatsPanel.formatCount(0), "0")
    }

    func test_formatCount_thousands_useGroupingSeparator() {
        // 1234 → "1,234" in en-US locale. The actual separator
        // varies by `Locale.current` ("." in ru-RU, " " in fr-FR) —
        // we don't pin the literal because the test target inherits
        // the host's locale.
        let rendered = TokenStatsPanel.formatCount(1234)
        XCTAssertTrue(rendered.contains("1") && rendered.contains("234"))
        XCTAssertNotEqual(rendered, "1234", "Expected grouping separator")
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

        // And the panel's cost would be derived from those totals.
        let cost = GeminiPricing.cost(input: totals.input,
                                      output: totals.output,
                                      cached: totals.cached)
        // billable = 80 @ $0.25/M = $0.00002; cached = 20 @ $0.025/M = $0.0000005;
        // output = 50 @ $1.50/M = $0.000075; total ≈ $0.0000955 → formats "<$0.01"
        XCTAssertEqual(GeminiPricing.formatCost(cost), "<$0.01")
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
