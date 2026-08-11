import XCTest
@testable import NoType

/// Pins the HTTP-level retry ladder, the fresh-connection predicate, and
/// the two `URLSession` budgets — none of which any test could reach
/// before U1 of
/// `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md`
/// widened them past `private` (KTD3).
///
/// **The widening is the point, not a side effect.** The ladder is the
/// mechanism the whole "how long does a stalled dictation cost the user"
/// question rests on, and it shipped for months as a private method inside
/// an actor with no seam. A constant nothing can read is a constant no
/// mutation test can catch.
///
/// Sweeps rather than enumerations wherever the input is a status code,
/// following `SplitRetryNetworkBoundTests`: the defect these guard against
/// is a *new* status landing in the wrong class, which a case-by-case list
/// cannot see.
final class GeminiRetryPolicyTests: XCTestCase {

    private typealias Client = GeminiClient

    private func decide(_ error: GeminiClient.GeminiError, _ attempt: Int) -> Int? {
        Client.retryDecision(for: error, attempt: attempt).delayMs
    }

    private func http(_ status: Int) -> GeminiClient.GeminiError {
        .http(status: status, body: "body for \(status)")
    }

    /// The non-`.http` cases, in one place so the three sweeps below cannot
    /// drift into covering different subsets of the enum.
    private static let nonHTTPErrors: [(String, GeminiClient.GeminiError)] = [
        ("missingKey", .missingKey),
        ("blocked", .blocked("SAFETY")),
        ("empty", .empty),
        ("decoding", .decoding(NSError(domain: "test", code: 1))),
        ("truncated", .truncated),
    ]

    // MARK: - The stalled-transport arm (status 0)

    /// R21: the network class is retried once and no more. This is the arm
    /// the shortened wait is budgeted against — every extra rung here is
    /// another full inactivity budget the user waits through.
    func test_statusZero_retriesExactlyOnce() {
        XCTAssertEqual(decide(http(0), 1), 500, "A network-class failure must get its one retry on the first attempt.")
        XCTAssertNil(decide(http(0), 2), "The network class is retried once and no more (R21) — a second retry doubles the abandoned-dictation wait.")
        XCTAssertNil(decide(http(0), 3))
        XCTAssertNil(decide(http(0), 9))
    }

    // MARK: - The rate-limit arm (429) — unchanged by R21

    /// R21 binds the stalled-transport class only. A 429 is Gemini
    /// answering over a working connection and telling us to slow down, so
    /// its two-rung backoff is deliberately untouched.
    func test_rateLimit_keepsItsTwoRungLadder() {
        XCTAssertEqual(decide(http(429), 1), 500)
        XCTAssertEqual(decide(http(429), 2), 2_000)
        XCTAssertNil(decide(http(429), 3))
        XCTAssertNil(decide(http(429), 4))
    }

    // MARK: - The server-error arm (5xx) — unchanged by R21

    func test_serverErrors_retryOnce_acrossTheWholeFiveHundredSpace() {
        for status in 500...599 {
            XCTAssertEqual(
                decide(http(status), 1), 500,
                "HTTP \(status) must keep its single retry — it is a per-request server fault, not a dead transport."
            )
            XCTAssertNil(
                decide(http(status), 2),
                "HTTP \(status) must not be retried a second time."
            )
        }
    }

    // MARK: - Client errors never retry

    func test_clientErrors_neverRetry_exceptRateLimit() {
        for status in 400...499 where status != 429 {
            for attempt in 1...3 {
                XCTAssertNil(
                    decide(http(status), attempt),
                    "HTTP \(status) must never retry (attempt \(attempt)) — an identical re-issue gets an identical rejection."
                )
            }
        }
    }

    /// Statuses outside every named arm fall to the no-retry default. 200
    /// and 300 can only arrive here as a parsing-layer wrap, and a 6xx is
    /// not a real HTTP class at all — none of them is evidence that a
    /// re-issue would go differently.
    func test_unclassifiedStatuses_fallToNoRetry() {
        for status in [200, 204, 301, 399, 600, 700, 999, -1] {
            XCTAssertNil(
                decide(http(status), 1),
                "HTTP \(status) is outside every retryable arm and must not retry."
            )
        }
    }

    // MARK: - Terminal and non-retryable error classes

    func test_nonRetryableErrorClasses_returnNoDelay() {
        for (name, error) in Self.nonHTTPErrors {
            for attempt in 1...3 {
                XCTAssertNil(
                    decide(error, attempt),
                    "\(name) must never retry (attempt \(attempt)). `.truncated` in particular re-issues identically and hits the same output cap; it is recovered one layer up as a gap marker."
                )
            }
        }
    }

    // MARK: - Which failures demand a fresh connection (R28 / KTD13)

    /// The predicate is narrower than "should we retry", and the gap
    /// between the two is the whole of KTD13: a 429 and a 5xx are retried
    /// *and* came back over a working connection, so they must not pay for
    /// a fresh TCP + TLS handshake.
    func test_freshConnection_isDemandedByTheNetworkClassAlone() {
        XCTAssertTrue(
            Client.requiresFreshConnection(after: http(0)),
            "A status-0 failure is where every URLError is wrapped — the measured case is a dead pooled connection, so the retry must not reuse it."
        )

        // Starts below zero on purpose: with a `100...` floor the `where`
        // clause below could never fire, and a widening of the predicate to
        // `status <= 0` would have passed every assertion in this file.
        for status in -5...599 where status != 0 {
            XCTAssertFalse(
                Client.requiresFreshConnection(after: http(status)),
                "HTTP \(status) is not the status-0 transport class — dropping the pool for it would cost a handshake to fix nothing."
            )
        }
    }

    func test_freshConnection_isNotDemandedByNonHTTPErrors() {
        for (name, error) in Self.nonHTTPErrors {
            XCTAssertFalse(
                Client.requiresFreshConnection(after: error),
                "\(name) is not a transport failure — it never reaches the flush, and none of these is retried anyway."
            )
        }
    }

    /// `requiresFreshConnection` has a twin one layer up:
    /// `RecordingSession.isNetworkClass(_:)` asks the same "is the transport
    /// down" question to bound `splitRetry`. They are deliberately separate
    /// functions in separate modules, so nothing structural keeps them
    /// agreeing — widen one and the connection-flush decision silently
    /// stops matching the abandon bound. Pinned over the value axis,
    /// because the compiler owns only the case axis (see
    /// `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`).
    func test_freshConnectionPredicate_agreesWithRecordingSessionsNetworkClass() {
        for status in -5...699 {
            XCTAssertEqual(
                Client.requiresFreshConnection(after: http(status)),
                RecordingSession.isNetworkClass(http(status)),
                "HTTP \(status): GeminiClient.requiresFreshConnection and RecordingSession.isNetworkClass disagree about what the network class is."
            )
        }
        for (name, error) in Self.nonHTTPErrors {
            XCTAssertEqual(
                Client.requiresFreshConnection(after: error),
                RecordingSession.isNetworkClass(error),
                "\(name): the two network-class predicates disagree."
            )
        }
    }

    /// The two predicates must not drift into disagreement in the one
    /// direction that matters: anything demanding a fresh connection is a
    /// failure we actually re-issue. A fresh connection for a request that
    /// is never retried would be a pure handshake cost.
    func test_everyFreshConnectionCase_isAlsoRetriedAtLeastOnce() {
        for status in -5...599 where Client.requiresFreshConnection(after: http(status)) {
            XCTAssertNotNil(
                decide(http(status), 1),
                "HTTP \(status) demands a fresh connection but is never retried — the flush would be dead cost."
            )
        }
    }

    // MARK: - The budgets, and the fact that they are the ones that ship

    /// Pins today's values. **`requestInactivityBudget` is the pre-cut
    /// ceiling and R20 still owns cutting it** — KTD2 requires the new
    /// value to clear a measured maximum for a full multi-chunk batch and
    /// a 180 s force-cut chunk, and that measurement has not been taken.
    /// When it is, this assertion changes deliberately and gains the two
    /// the plan asks for: strictly less than `resourceCeiling`, and
    /// strictly greater than the measured maximum.
    func test_budgets_areTheValuesCurrentlyShipped() {
        XCTAssertEqual(
            GeminiClient.requestInactivityBudget, 30,
            "The inactivity budget changed. If this is R20's cut, it must land with the measured maximum recorded in the constant's doc-comment — not chosen from preference."
        )
        XCTAssertEqual(
            GeminiClient.resourceCeiling, 30,
            "KTD1 keeps the whole-transfer ceiling at 30 s. Moving it also invalidates `PauseDetector`'s adaptive-ladder rationale, which cites this budget by name."
        )
    }

    /// The inactivity budget may never exceed the whole-transfer ceiling:
    /// past that point it is unreachable, because the resource timer would
    /// always fire first and the "give up on a stalled transport" behaviour
    /// would silently come from the wrong timer.
    func test_inactivityBudget_neverExceedsTheWholeTransferCeiling() {
        XCTAssertLessThanOrEqual(
            GeminiClient.requestInactivityBudget,
            GeminiClient.resourceCeiling,
            "An inactivity budget above the resource ceiling can never fire. KTD1's cut tightens this to strictly-less-than."
        )
    }

    /// The wiring, not just the constants. A test that pins the values but
    /// not their application stays green when someone edits
    /// `makeSessionConfiguration` to a literal — which is exactly the shape
    /// the hoist was meant to make impossible.
    func test_sessionConfiguration_appliesBothNamedBudgets() {
        let cfg = GeminiClient.makeSessionConfiguration()
        XCTAssertEqual(
            cfg.timeoutIntervalForRequest, GeminiClient.requestInactivityBudget,
            "The session's inactivity timeout is not the named constant — the constant is decorative and the real budget is somewhere else."
        )
        XCTAssertEqual(
            cfg.timeoutIntervalForResource, GeminiClient.resourceCeiling,
            "The session's resource timeout is not the named constant."
        )
    }

    /// `waitsForConnectivity = false` is load-bearing for the reachability
    /// pre-check: with it on, an offline request parks indefinitely instead
    /// of failing, and the short-circuit is what makes that failure fast.
    func test_sessionConfiguration_doesNotWaitForConnectivity() {
        XCTAssertFalse(
            GeminiClient.makeSessionConfiguration().waitsForConnectivity,
            "Turning this on makes an offline request park rather than fail, which changes what the reachability pre-check is compensating for."
        )
    }
}
