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

    // MARK: - The budget, against the measurement that set it

    /// The 2026-08-13 measurement, as a fixture. Four repetitions of each
    /// shape against the live API with the real request shape and real AAC
    /// encoding; the value is the worst **total** wall-clock observed.
    ///
    /// This is the table `requestInactivityBudget(audioPartCount:)` was
    /// derived from, restated here so the derivation is checkable rather than
    /// merely asserted. It is also the finding that killed the flat cut R20
    /// originally asked for: the 4-part batch carries *less* audio (159 s vs
    /// 180 s) and *fewer* bytes (653 KB vs 735 KB) than the single-part
    /// force-cut, and takes roughly four times as long — so latency tracks
    /// the part count, and no single constant serves both shapes.
    private static let measuredMaxima: [(parts: Int, seconds: TimeInterval, shape: String)] = [
        (1, 7.81, "180 s force-cut chunk, 735 KB"),
        (4, 27.16, "4-chunk batch, 159 s of audio, 653 KB"),
    ]

    /// The safety factor the budget must keep over every measured maximum.
    ///
    /// Deliberately generous rather than tight — four runs per shape on one
    /// machine and one network is a sample, not a distribution — and the cost
    /// of being wrong is asymmetric: too generous and the user waits, too
    /// tight and a legitimate request is killed, which becomes a `[…]` in
    /// text already pasted into the user's document, where no retry reaches.
    private static let minimumSafetyFactor: TimeInterval = 1.4

    /// The load-bearing assertion of this file: the budget clears what was
    /// actually measured, with margin, at every shape that was measured.
    ///
    /// Written against the measurement rather than against the literals so a
    /// future re-tune has to argue with the data. Both terms of the model
    /// (`requestBudgetFixedOverhead`, `requestBudgetPerAudioPart`) fail this
    /// when mutated downward.
    func test_requestBudget_clearsEveryMeasuredMaximum_withMargin() {
        for m in Self.measuredMaxima {
            let budget = GeminiClient.requestInactivityBudget(audioPartCount: m.parts)
            XCTAssertGreaterThan(
                budget, m.seconds,
                "\(m.parts)-part request (\(m.shape)) measured \(m.seconds) s and the budget is \(budget) s — a healthy request would be killed, and the `[…]` it produces lands in text the user has already had pasted."
            )
            XCTAssertGreaterThanOrEqual(
                budget, m.seconds * Self.minimumSafetyFactor,
                "\(m.parts)-part request: budget \(budget) s is only \(budget / m.seconds)× the measured maximum \(m.seconds) s, below the \(Self.minimumSafetyFactor)× the sample size demands."
            )
        }
    }

    /// The factor is *near-uniform* across the measured shapes, which is what
    /// makes the two-term model honest rather than two numbers that happen to
    /// fit. Collapsing the fixed term into the slope (or vice versa) skews it.
    func test_requestBudget_safetyFactorIsUniformAcrossTheMeasuredShapes() {
        let factors = Self.measuredMaxima.map {
            GeminiClient.requestInactivityBudget(audioPartCount: $0.parts) / $0.seconds
        }
        guard let lo = factors.min(), let hi = factors.max() else {
            return XCTFail("no measured shapes")
        }
        XCTAssertLessThan(
            hi - lo, 0.25,
            "Safety factors across the measured shapes spread from \(lo)× to \(hi)×. A budget that is generous at one part count and tight at another is not a model of the latency, it is a coincidence."
        )
    }

    /// Latency tracks the part count, so the budget must too — and monotonically.
    func test_requestBudget_growsWithThePartCount() {
        for parts in 0..<12 {
            XCTAssertLessThanOrEqual(
                GeminiClient.requestInactivityBudget(audioPartCount: parts),
                GeminiClient.requestInactivityBudget(audioPartCount: parts + 1),
                "Adding an audio part must never shrink the budget: \(parts) → \(parts + 1)."
            )
        }
        XCTAssertGreaterThan(
            GeminiClient.requestInactivityBudget(audioPartCount: 4),
            GeminiClient.requestInactivityBudget(audioPartCount: 1),
            "A 4-part batch must get strictly more room than a single chunk — that difference is the entire finding the function exists for."
        )
    }

    /// The floor guards the slope, not the part count. It binds only for a
    /// request carrying no audio, which `sendRequest` cannot produce today
    /// but a refactor could — and the fixed term alone would be two seconds.
    func test_requestBudget_neverFallsBelowTheFloor() {
        for parts in [-3, 0] {
            XCTAssertEqual(
                GeminiClient.requestInactivityBudget(audioPartCount: parts),
                GeminiClient.requestBudgetFloor,
                "An audio-less request must clamp up to the floor, not compute the bare fixed term."
            )
        }
        XCTAssertGreaterThanOrEqual(
            GeminiClient.requestInactivityBudget(audioPartCount: 1),
            GeminiClient.requestBudgetFloor,
            "Every real request is at or above the floor."
        )
    }

    /// The ceiling bounds a pathological batch. Without it the derived budget
    /// is unbounded in the part count, and a runaway batch freezes the hotkey
    /// for the whole of it.
    func test_requestBudget_isCappedForAPathologicalPartCount() {
        for parts in [50, 500, 10_000] {
            XCTAssertEqual(
                GeminiClient.requestInactivityBudget(audioPartCount: parts),
                GeminiClient.requestBudgetCeiling,
                "\(parts) parts must clamp to the ceiling — an uncapped budget lets a defective batch hold the hotkey for minutes."
            )
        }
        XCTAssertGreaterThanOrEqual(
            GeminiClient.requestBudgetCeiling,
            GeminiClient.requestInactivityBudget(audioPartCount: 8),
            "The ceiling must still serve 8 parts at the full derived budget — beyond the chunker's realistic maximum, so the cap bounds defects rather than sessions."
        )
    }

    // MARK: - The whole-transfer ceiling above it

    /// The resource ceiling must clear the *largest* budget the function can
    /// derive, by the upload allowance, for every part count. It is an
    /// additional ceiling and never a fallback (KTD1): if it could fire first
    /// it would kill a request the inactivity timer would have allowed, and
    /// the give-up behaviour would silently come from the wrong timer.
    func test_resourceCeiling_staysAboveEveryDerivedBudget_byTheUploadAllowance() {
        for parts in 0...64 {
            let budget = GeminiClient.requestInactivityBudget(audioPartCount: parts)
            XCTAssertGreaterThanOrEqual(
                GeminiClient.resourceCeiling - budget,
                GeminiClient.uploadAllowance,
                "At \(parts) parts the whole-transfer ceiling leaves less than the upload allowance above the inactivity budget — a slow uplink would be killed by the resource timer before the request had its silence budget at all."
            )
        }
    }

    /// The upload allowance is derived, not preferred: it must cover the
    /// largest payload the measurement saw, uploaded over a link two orders
    /// of magnitude slower than the one it was measured on.
    ///
    /// Without this the constant has no mutation coverage at all — it appears
    /// on both sides of `resourceCeiling`'s own derivation, so shrinking it
    /// shrinks the ceiling in step and every margin assertion stays green
    /// while the ceiling quietly stops clearing a slow upload.
    func test_uploadAllowance_coversTheLargestMeasuredPayloadOnASlowUplink() {
        let largestMeasuredPayloadBytes: TimeInterval = 735_000   // the 180 s force-cut chunk
        let slowUplinkBytesPerSecond: TimeInterval = 25_000       // ~200 kbit/s
        XCTAssertGreaterThanOrEqual(
            GeminiClient.uploadAllowance,
            largestMeasuredPayloadBytes / slowUplinkBytesPerSecond,
            "The upload allowance no longer covers the largest measured payload at ~200 kbit/s. Below that the whole-transfer ceiling can fire on a live, progressing upload — which is the one thing KTD1 says it must never do."
        )
    }

    /// The classifier's budget is deliberately *not* collateral of the
    /// transcription cut. It is a grounded (`google_search`) call whose
    /// latency was never measured here, so it holds the value the whole
    /// client used before the derivation landed. Changing it is a separate
    /// decision with its own evidence, not a side effect of this one.
    func test_auxiliaryBudget_isUnchangedByTheTranscriptionCut() {
        XCTAssertEqual(
            GeminiClient.auxiliaryRequestBudget, 30,
            "The audio-less request budget moved. `classifyApp` is a grounded call with no measurement behind it here — shortening it is a separate change needing its own evidence, and lengthening it makes a fire-and-forget background call hold a connection longer."
        )
    }

    /// The defect the measurement uncovered: the retired 30 s resource
    /// ceiling sat *below* the measured total for a 4-part batch's successor.
    /// A 5-part batch was already exceeding it, killing a legitimate request
    /// and producing a silent `[…]`.
    func test_resourceCeiling_clearsTheMeasuredTotals_whichTheRetiredThirtySecondsDidNot() {
        for m in Self.measuredMaxima {
            XCTAssertGreaterThan(
                GeminiClient.resourceCeiling, m.seconds,
                "The whole-transfer ceiling must clear the measured total for a \(m.parts)-part request."
            )
        }
        XCTAssertGreaterThan(
            GeminiClient.resourceCeiling, 30,
            "The retired 30 s ceiling is the live defect this fixes: the 4-part batch measured 27.16 s against it, so a 5-part batch already exceeded it."
        )
    }

    // MARK: - What a stalled dictation now costs the user (AE11)

    /// AE11, restated honestly. "Well under half the retired ceiling" holds
    /// for the **single-part** case — the common one — and no longer holds
    /// for a large batch, because the batch genuinely needs the room.
    ///
    /// Retired cost of a stalled request: 30 s + 500 ms backoff + 30 s.
    func test_stalledSinglePartRequest_costsWellUnderHalfOfTheRetiredWait() {
        let retiredWait: TimeInterval = 30 + 0.5 + 30
        let single = GeminiClient.requestInactivityBudget(audioPartCount: 1)
        let cost = single + 0.5 + single

        XCTAssertLessThan(
            cost, retiredWait / 2,
            "A stalled single-part dictation costs \(cost) s across its two attempts, against \(retiredWait) s before — R22 asks for well under half."
        )
        XCTAssertLessThan(
            cost, 25,
            "The single-part two-attempt cost drifted above 25 s. That is the number the 'give up in seconds, not a minute' promise rests on."
        )
    }

    /// The other half of the honest restatement: a batch costs more, and the
    /// test says so out loud rather than leaving it to be discovered.
    func test_stalledBatchRequest_costsMoreThanASingleChunk_deliberately() {
        let batch = GeminiClient.requestInactivityBudget(audioPartCount: 4)
        XCTAssertGreaterThan(
            batch, 30,
            "A 4-part batch's budget is below the retired flat ceiling, which the measurement says is not enough for it (26.85 s idle observed). The flat cut is exactly what KTD2's stop condition rejected."
        )
    }

    // MARK: - The wiring: that these are the values that ship

    /// A per-request `timeoutInterval` is only worth deriving if it actually
    /// overrides the session configuration — a value the config silently
    /// clamped would leave every assertion above green while nothing changed.
    ///
    /// Measured rather than assumed, against a listening socket that is never
    /// `accept()`ed: the kernel completes the handshake into the backlog, so
    /// the request goes out and nothing ever answers, which is precisely the
    /// stall the budget exists for. The session is configured with a
    /// *shorter* timeout than the request asks for, so a clamping platform
    /// fails the task early and this test fails.
    ///
    /// Limits: this pins Foundation's precedence rule, not our code. It fails
    /// loudly if Apple ever changes it — which is the point, because the
    /// per-request derivation is unimplementable if they do.
    func test_perRequestTimeout_overridesTheSessionConfiguration_soAWidenedBudgetIsReal() throws {
        let listener = try StallingListener()
        defer { listener.close() }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 1          // deliberately shorter
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        var req = URLRequest(url: listener.url)
        req.httpMethod = "POST"
        req.httpBody = Data(repeating: 0x41, count: 512)
        req.timeoutInterval = 4                    // deliberately longer

        let done = expectation(description: "request fails on its own timeout")
        let start = Date()
        var elapsed: TimeInterval = 0
        session.dataTask(with: req) { _, _, _ in
            elapsed = Date().timeIntervalSince(start)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)

        XCTAssertGreaterThan(
            elapsed, 3.0,
            "The request failed after \(elapsed) s — the session configuration's shorter timeout won. Every derived budget above a session default would then be decorative, and a batch would be killed at the default while the tests stayed green."
        )
        XCTAssertLessThan(
            elapsed, 8.0,
            "The request outlived its own timeout by a wide margin — neither timer is behaving as the budget model assumes."
        )
    }

    /// The wiring, not just the constants. A test that pins the values but
    /// not their application stays green when someone edits
    /// `makeSessionConfiguration` to a literal — which is exactly the shape
    /// the hoist was meant to make impossible.
    ///
    /// Note what the session's request timeout is now: the **default** for a
    /// request that sets none of its own, which after this change is nothing
    /// in this file. `GeminiClientOfflineShortCircuitTests` pins that every
    /// request sets its own, so this value is a backstop for a future path
    /// that forgets — and it is the auxiliary budget rather than a
    /// transcription one on purpose.
    func test_sessionConfiguration_appliesTheAuxiliaryDefaultAndTheResourceCeiling() {
        let cfg = GeminiClient.makeSessionConfiguration()
        XCTAssertEqual(
            cfg.timeoutIntervalForRequest, GeminiClient.auxiliaryRequestBudget,
            "The session's default inactivity timeout is not the named constant — the constant is decorative and the real default is somewhere else."
        )
        XCTAssertEqual(
            cfg.timeoutIntervalForResource, GeminiClient.resourceCeiling,
            "The session's resource timeout is not the named constant. It is the only place the whole-transfer ceiling can be set — there is no URLRequest counterpart."
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

/// A loopback TCP socket that listens and is never `accept()`ed.
///
/// The kernel completes the handshake into the listen backlog, so a client
/// connects, sends its request into the socket buffer, and then waits forever
/// — a stall indistinguishable from the one the budget exists for, with no
/// accept loop, no thread and no HTTP server. Port 0 lets the kernel pick, so
/// concurrent test runs cannot collide.
private struct StallingListener {
    let fd: Int32
    let url: URL

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw NSError(domain: "StallingListener", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 16) == 0 else {
            Darwin.close(socketFD)
            throw NSError(domain: "StallingListener", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind/listen failed"])
        }

        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &len) }
        }
        let port = UInt16(bigEndian: assigned.sin_port)
        guard port != 0, let u = URL(string: "http://127.0.0.1:\(port)/stall") else {
            Darwin.close(socketFD)
            throw NSError(domain: "StallingListener", code: 3, userInfo: [NSLocalizedDescriptionKey: "no port assigned"])
        }
        fd = socketFD
        url = u
    }

    func close() { _ = Darwin.close(fd) }
}
