import XCTest
@testable import NoType

/// Pins the two halves of the offline fast-fail that a unit test can
/// actually reach: the **shape** of the error a short-circuited request
/// throws, and the **position** of the check that throws it.
///
/// Shape matters because the whole design premise is that a
/// short-circuited request is indistinguishable downstream from the
/// timed-out request it replaces — same `GeminiError` case, same status,
/// same recoverable classification, same retention decision, same HUD. Any
/// drift there silently changes which sessions abort and which keep their
/// audio.
///
/// Position matters because `retryDecision` grants a status-0 error one
/// retry. That retry is correct for a genuine timeout and pure wasted
/// latency for a short-circuit. The two are told apart structurally — the
/// short-circuit throws *before* the retry loop — rather than by teaching
/// `retryDecision` to distinguish bodies, which would have cost the
/// genuine-timeout case its retry.
final class GeminiClientOfflineShortCircuitTests: XCTestCase {

    private typealias GErr = GeminiClient.GeminiError

    // MARK: - Error shape

    func test_offlineShortCircuit_isStatusZeroHTTP() {
        guard case let .http(status, body) = GErr.offlineShortCircuit else {
            return XCTFail("Short-circuit must reuse `.http`, not a new error case — `isTerminal` / `shouldRetain` are a pinned complement pair and a new case would need both.")
        }
        XCTAssertEqual(status, 0)
        XCTAssertTrue(body.hasPrefix(GErr.urlErrorBodyPrefix))
    }

    /// The HUD recovers the numeric `URLError` code out of the body. If the
    /// short-circuit's body were not parseable the user would get the
    /// generic "unexpected response" HUD instead of "No internet".
    func test_offlineShortCircuit_bodyYieldsTheOfflineURLErrorCode() {
        guard case let .http(_, body) = GErr.offlineShortCircuit else {
            return XCTFail("expected .http")
        }
        XCTAssertEqual(
            NetworkErrorTranslator.parse(body)?.code,
            URLError.Code.notConnectedToInternet.rawValue
        )
    }

    /// The wrapper both producers share. A real `URLSession` timeout and
    /// the short-circuit must be built by the same function, or the two
    /// bodies drift and only one of them parses.
    func test_wrapURLError_producesTheSameShapeAsTheShortCircuit() {
        guard case let .http(shortStatus, shortBody) = GErr.offlineShortCircuit,
              case let .http(wrapStatus, wrapBody) = GErr.wrapURLError(URLError(.notConnectedToInternet))
        else { return XCTFail("expected .http from both") }
        XCTAssertEqual(shortStatus, wrapStatus)
        XCTAssertEqual(shortBody, wrapBody)
    }

    func test_wrapURLError_carriesTheCodeOfWhicheverURLErrorItWraps() {
        for code in [URLError.Code.timedOut, .cannotFindHost, .networkConnectionLost] {
            guard case let .http(_, body) = GErr.wrapURLError(URLError(code)) else {
                return XCTFail("expected .http")
            }
            XCTAssertEqual(
                NetworkErrorTranslator.parse(body)?.code,
                code.rawValue,
                "wrapURLError must not hard-code one code."
            )
        }
    }

    // MARK: - Downstream classification is unchanged

    /// The critical invariant: a short-circuited request must keep its
    /// audio and continue the session exactly as a timed-out one does.
    func test_offlineShortCircuit_isRecoverableAndRetainable() {
        let err = GErr.offlineShortCircuit
        XCTAssertFalse(
            RecordingSession.isTerminal(err),
            "A short-circuit must not abort the session — that would be a classification change, which the plan names as a stop condition."
        )
        XCTAssertTrue(
            RecordingSession.shouldRetain(err),
            "A short-circuited chunk's audio must be retained, exactly as a timed-out chunk's is."
        )
    }

    // MARK: - Diagnosability of the status-0 description

    /// The gap this fixes: `.http(0, …)` used to render as "Gemini error
    /// 0.", dropping the embedded `URLError code=N`. `RecordingSession`
    /// logs this string at `.public` on every recoverable failure, so
    /// offline, timeout and DNS failure were indistinguishable in Console.
    func test_statusZeroDescription_surfacesTheURLErrorCode() throws {
        let offline = GErr.wrapURLError(URLError(.notConnectedToInternet))
        let timedOut = GErr.wrapURLError(URLError(.timedOut))

        let offlineText = try XCTUnwrap(offline.errorDescription)
        let timedOutText = try XCTUnwrap(timedOut.errorDescription)

        XCTAssertTrue(
            offlineText.contains("\(URLError.Code.notConnectedToInternet.rawValue)"),
            "Offline description lost its URLError code: \(offlineText)"
        )
        XCTAssertTrue(
            timedOutText.contains("\(URLError.Code.timedOut.rawValue)"),
            "Timeout description lost its URLError code: \(timedOutText)"
        )
        XCTAssertNotEqual(
            offlineText, timedOutText,
            "Offline and timeout must be distinguishable in the log — that is the entire point of the arm."
        )
    }

    /// The no-change complement. `validateKey` is the only other producer
    /// of a status-0 error, its body carries no `URLError code=` prefix,
    /// and it *is* surfaced to the user through
    /// `GeminiKeyRow.errorMessage`. Its rendering must be untouched.
    func test_statusZeroWithoutAURLErrorBody_keepsItsExistingUserFacingString() {
        let noResponse = GErr.http(status: 0, body: "no HTTPURLResponse")
        XCTAssertEqual(
            noResponse.errorDescription,
            "Gemini error 0.",
            "The status-0 arm must be gated on the URLError body prefix so it stays log-only."
        )
        XCTAssertEqual(
            GeminiKeyRow.errorMessage(for: noResponse),
            "Gemini error 0.",
            "The one status-0 shape that reaches a user must render exactly as before."
        )
    }

    // MARK: - Position of the check (why it is never retried)

    /// A source guard, in the shape `RaiseSiteScanner`
    /// (`HUDPanelGeometryTests.swift`) established, because the property
    /// being pinned is structural: the short-circuit throws before
    /// `sendRequest`'s `while true` retry loop, which is *how* it avoids
    /// being re-issued.
    ///
    /// The assertions are deliberately scoped **inside `sendRequest`'s own
    /// body**, not to file offsets. A first draft compared whole-file
    /// offsets and stayed green under the exact mutation it exists to
    /// catch: relocating the check into `performOnce` left an earlier,
    /// unrelated match to satisfy the "before the loop" comparison. The
    /// uniqueness assertion below is what closes that hole.
    ///
    /// Limits, recorded so a green run is not over-trusted: this reads one
    /// file and matches literal spellings. Renaming `isDefinitelyOffline`
    /// or restructuring the loop away from `while true` makes it fail
    /// loudly — fine, that is a review trigger, not a false negative.
    func test_shortCircuitThrows_beforeTheRetryLoop_andNotInsidePerformOnce() throws {
        let source = Self.strippingComments(try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("NoType/Gemini/GeminiClient.swift"),
            encoding: .utf8
        ))

        let probeCall = "reachabilityProbe().isDefinitelyOffline()"

        // Uniqueness first. Without it, "the first match sits before the
        // loop" is satisfiable by any stray earlier occurrence while the
        // real check has moved somewhere harmful.
        XCTAssertEqual(
            source.components(separatedBy: probeCall).count - 1, 1,
            "Expected exactly one offline pre-check in GeminiClient.swift. Zero means it was deleted (restoring a full-inactivity-budget wait per attempt); more than one means a copy was added somewhere this guard does not reason about."
        )

        let sendRequest = try XCTUnwrap(
            Self.body(ofFuncNamed: "sendRequest", in: source),
            "Could not parse sendRequest — the guard lost its anchor."
        )
        let performOnce = try XCTUnwrap(
            Self.body(ofFuncNamed: "performOnce", in: source),
            "Could not parse performOnce — the guard lost its anchor."
        )

        // Presence, inside the right function.
        let probeIdx = try XCTUnwrap(
            sendRequest.range(of: probeCall),
            "The offline pre-check is not in sendRequest's body."
        ).lowerBound

        // The retry loop's anchor, also scoped to sendRequest.
        let loopIdx = try XCTUnwrap(
            sendRequest.range(of: "while true {"),
            "sendRequest no longer contains the `while true {` retry loop — the position anchor is gone."
        ).lowerBound

        XCTAssertLessThan(
            probeIdx, loopIdx,
            "The offline pre-check must sit before sendRequest's retry loop. Inside it, `retryDecision`'s status-0 arm would re-issue the short-circuit, doubling the very latency this removes."
        )

        // The specific regression: relocating the check into the
        // per-attempt function, which puts it under the retry loop.
        XCTAssertFalse(
            performOnce.contains("isDefinitelyOffline"),
            "The offline check must not live in performOnce — that body runs once per retry attempt."
        )

        // Presence complement for the *result*, not just the call. Position
        // and uniqueness both stay satisfied by `_ = await
        // reachabilityProbe().isDefinitelyOffline()` — a probe that runs,
        // is correctly placed, and throws nothing, silently restoring the
        // full-budget-per-attempt wait this feature removes. Verified: that
        // mutation passed every other assertion in this file.
        let throwIdx = try XCTUnwrap(
            sendRequest.range(of: "throw offline"),
            "sendRequest calls the reachability probe but never throws on its verdict — the pre-check is a no-op and the offline wait is back."
        ).lowerBound
        XCTAssertGreaterThan(
            throwIdx, probeIdx,
            "The offline throw must follow the probe it is gated on."
        )
        XCTAssertLessThan(
            throwIdx, loopIdx,
            "The offline throw must still sit ahead of the retry loop."
        )
    }

    // MARK: - No transcription failure escapes as a bare status 0 (R17)

    /// A source guard, because **no value test can see this**. The bare
    /// `GeminiError.http(status: 0, body: "no HTTPURLResponse")` is still a
    /// perfectly constructible error — `validateKey` and `classifyApp`
    /// legitimately throw it, and `test_statusZeroDescription_isLogOnly`
    /// above asserts what it renders. So reverting `performOnce`'s
    /// no-`HTTPURLResponse` guard to that bare form changes no value any
    /// test can reach, and silently restores the HUD photographed on
    /// 0.1.13-rc2: **"Gemini rejected the request / Unexpected response
    /// (HTTP 0) / ERR_GEMINI · 0"**.
    ///
    /// The two halves are complementary, per
    /// `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`
    /// — absence alone is green on a file where the guard was deleted
    /// outright, which would be a different bug with the same symptom:
    ///
    /// - **Absence:** `performOnce` raises no `status: 0` of its own.
    /// - **Presence:** it still refuses a non-`HTTPURLResponse`, through
    ///   the wrapper that makes the failure parseable downstream.
    ///
    /// Limits: this matches literal spellings in one function of one file.
    /// Renaming `wrapURLError` or changing the argument label fails it
    /// loudly — a review trigger, not a false negative. It proves the
    /// wrapper is *in* `performOnce`'s body, not that this particular
    /// `guard` is what calls it; the sibling scans in this file rely on the
    /// same bound.
    func test_performOnce_throwsNoBareStatusZero() throws {
        let source = Self.strippingComments(try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("NoType/Gemini/GeminiClient.swift"),
            encoding: .utf8
        ))
        let performOnce = try XCTUnwrap(
            Self.body(ofFuncNamed: "performOnce", in: source),
            "Could not parse performOnce — the guard lost its anchor."
        )

        XCTAssertFalse(
            performOnce.contains("status: 0"),
            "performOnce raises a bare status-0 GeminiError. Its body carries no `URLError code=` prefix, so `NetworkErrorTranslator.parse` returns nil, the network branch of `payloadForSessionFailure` is skipped, and the user is told 'Gemini rejected the request — Unexpected response (HTTP 0)' about a request that never reached Gemini. Throw it through `GeminiError.wrapURLError` instead."
        )
        XCTAssertTrue(
            performOnce.contains("response as? HTTPURLResponse"),
            "performOnce no longer checks the response type at all — the absence assertion above is now green for the wrong reason."
        )
        XCTAssertTrue(
            performOnce.contains("wrapURLError(URLError(.badServerResponse))"),
            "performOnce checks the response type but no longer wraps the failure, so whatever it throws instead is unparseable downstream."
        )
    }

    // MARK: - Position of the fresh-connection drop (R28 / KTD13)

    /// A source guard in the same shape as the one above, for the same
    /// reason: the property is structural. `GeminiRetryPolicyTests` proves
    /// `requiresFreshConnection` answers correctly, but a predicate nobody
    /// calls is a predicate that answers correctly into the void — and the
    /// failure mode is silent, because a retry over the dead pooled
    /// connection still *looks* like a retry. It just re-inherits the
    /// stall.
    ///
    /// Absence assertions alone would be green on a file where the flush
    /// was deleted, so this pins the destination too, per
    /// `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`:
    /// the helper exists, the retry loop calls it, the call is *gated* on
    /// the predicate, and it happens before the re-issue rather than after.
    /// Three of those assertions are narrower than they look, and each is
    /// narrow because the wider form was **verified green** under a live
    /// mutation rather than reasoned about. The gate needle carries its
    /// `if ` — without it, inverting the gate to `if !…` (which flushes on
    /// 429 and 5xx and never on the class R28 is about) passes everything
    /// here. The `session.flush` check reads `flushPooledConnections`'s own
    /// body rather than the whole file. And every needle runs against
    /// comment-stripped source, because body-scoping alone was *still*
    /// green on a helper hollowed out with the old call left in the note —
    /// see `strippingComments`.
    ///
    /// Limits, recorded so a green run is not over-trusted: this reads one
    /// file and matches literal spellings, and it proves the call is
    /// *present and ordered*, not that it is reached at runtime. Renaming
    /// `flushPooledConnections` or `requiresFreshConnection` fails it
    /// loudly — a review trigger, not a false negative.
    func test_networkClassRetry_dropsThePooledConnection_beforeReissuing() throws {
        let source = Self.strippingComments(try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("NoType/Gemini/GeminiClient.swift"),
            encoding: .utf8
        ))

        let sendRequest = try XCTUnwrap(
            Self.body(ofFuncNamed: "sendRequest", in: source),
            "Could not parse sendRequest — the guard lost its anchor."
        )

        // Destination: the helper actually exists. Without this, deleting
        // it and its call site leaves every absence assertion green.
        XCTAssertTrue(
            source.contains("private func flushPooledConnections() async"),
            "GeminiClient no longer declares flushPooledConnections — a network-class retry now reuses the connection that just went silent (R28)."
        )
        // Scoped to the helper's own body, not the file. A file-wide
        // `contains` is green on a hollowed helper whose body was commented
        // out with the old call left in the note — a routine "disable while
        // investigating" shape that kills R28 silently.
        let flushBody = try XCTUnwrap(
            Self.body(ofFuncNamed: "flushPooledConnections", in: source),
            "Could not parse flushPooledConnections — the guard lost its anchor."
        )
        XCTAssertTrue(
            flushBody.contains("session.flush"),
            "flushPooledConnections no longer calls session.flush — it is a no-op and the retry re-inherits the dead pooled connection."
        )

        // The call, scoped to the retry loop's own function. The `if ` is
        // part of the needle on purpose: without it, inverting the gate to
        // `if !Self.requiresFreshConnection(...)` — which flushes on 429 and
        // 5xx and never on the class R28 is about — satisfies every
        // assertion below.
        let gateIdx = try XCTUnwrap(
            sendRequest.range(of: "if Self.requiresFreshConnection(after: error) {"),
            "sendRequest's retry path no longer gates on requiresFreshConnection in the expected shape — the drop may have become unconditional (a handshake cost on every 429 and 5xx), inverted, or removed."
        ).lowerBound
        let flushIdx = try XCTUnwrap(
            sendRequest.range(of: "await flushPooledConnections()"),
            "sendRequest never drops the pooled connections — the single network-class retry merely halves the wait instead of being able to succeed."
        ).lowerBound

        XCTAssertGreaterThan(
            flushIdx, gateIdx,
            "The flush must sit under the requiresFreshConnection gate, not ahead of it."
        )

        // Ordering against the re-issue. The drop is only useful before the
        // next attempt goes out; after the sleep-and-loop it would apply to
        // the attempt *after* the one it was meant to rescue.
        let sleepIdx = try XCTUnwrap(
            sendRequest.range(of: "try await Task.sleep(for: .milliseconds(delayMs))"),
            "sendRequest's backoff sleep is gone — the ordering anchor for the connection drop is lost."
        ).lowerBound
        XCTAssertLessThan(
            flushIdx, sleepIdx,
            "The connection drop must sit ahead of the backoff sleep, which is the only fixed landmark between it and the re-issue. Below the sleep there is nothing left to pin it against, and a drop that slides past the loop edge would apply to the attempt after the one it was meant to rescue."
        )

        // The gate belongs to the retry loop, not to the pre-flight region
        // the offline short-circuit occupies.
        let loopIdx = try XCTUnwrap(
            sendRequest.range(of: "while true {"),
            "sendRequest no longer contains the `while true {` retry loop — the position anchor is gone."
        ).lowerBound
        XCTAssertGreaterThan(
            gateIdx, loopIdx,
            "The fresh-connection gate must live inside the retry loop; ahead of it, it would fire on a request that has not failed yet."
        )
    }

    // MARK: - The shipped session derives from the named budgets

    /// `GeminiRetryPolicyTests` proves `makeSessionConfiguration()` applies
    /// `requestInactivityBudget` and `resourceCeiling`. Nothing proved the
    /// `URLSession` the app actually uses comes *from* that factory — and a
    /// factory nobody calls is the mirror image of the absence-only trap in
    /// `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`
    /// ("a test that only asserts 'not at A' is satisfied by 'nowhere at
    /// all'"). Here: a test that proves the factory is right is satisfied by
    /// nothing calling the factory.
    ///
    /// The mutation this closes: give `init()` its own configuration with a
    /// literal timeout. Every assertion in `GeminiRetryPolicyTests` stays
    /// green, `makeSessionConfiguration()` becomes dead code, and a stalled
    /// chunk costs whatever the literal says. That is exactly where R20's
    /// cut would land — it would move a constant nothing reads.
    ///
    /// A source assertion rather than a behavioural one because `session` is
    /// `private`; widening it to read `.configuration` from a test would
    /// trade an encapsulation boundary for the same fact. Same trade, and
    /// the same shape, as
    /// `LaunchOrderingTests.test_launchWork_isActuallyWiredUp_fromNoTypeAppInit`.
    func test_shippedSession_isBuiltFromTheNamedBudgetFactory() throws {
        let source = Self.strippingComments(try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("NoType/Gemini/GeminiClient.swift"),
            encoding: .utf8
        ))

        XCTAssertTrue(
            source.contains("self.session = URLSession(configuration: Self.makeSessionConfiguration())"),
            "GeminiClient's URLSession is no longer derived from makeSessionConfiguration(). The named budgets are then decorative — the factory's own tests stay green while the shipped session carries whatever was built by hand."
        )

        // Uniqueness, so the assertion above cannot be satisfied by a
        // surviving call beside a second session that carries its own
        // budgets and is the one that actually ships.
        XCTAssertEqual(
            source.components(separatedBy: "URLSession(configuration:").count - 1, 1,
            "Expected exactly one URLSession construction in GeminiClient.swift. A second one would carry its own budgets, unreached by every test that pins the named ones."
        )
    }

    // MARK: - Every request declares its own inactivity budget

    /// The transcription budget is derived **per request**, from the number
    /// of audio parts, because that is the axis the 2026-08-13 measurement
    /// found latency tracks. `GeminiRetryPolicyTests` proves the function
    /// returns the right number; this proves the number reaches a request.
    ///
    /// Two failure modes, both silent, and the second is why this guard scans
    /// counts rather than a single needle:
    ///
    /// 1. `sendRequest` stops setting `timeoutInterval` at all. Every budget
    ///    test stays green and every transcription silently falls back to the
    ///    session configuration's `auxiliaryRequestBudget` — 30 s for a
    ///    single chunk (too long, the wait this plan removes) and 30 s for a
    ///    4-part batch (too short, a killed request and a `[…]` in text
    ///    already pasted).
    /// 2. A *new* request path is added without a budget of its own and
    ///    quietly inherits the same default. Nothing about the existing
    ///    needles notices, so the count of `URLRequest(url:` constructions is
    ///    pinned against the count of `timeoutInterval` assignments: adding a
    ///    request without a budget breaks the equality.
    ///
    /// Limits, recorded so the green is not over-trusted: this is a source
    /// scan over one file matching literal spellings, against
    /// comment-stripped text. It proves the assignment is *present and
    /// derived from `audios.count`*, not that it is reached at runtime — and
    /// a request built in some other file would be invisible to it. Renaming
    /// `requestInactivityBudget` fails it loudly, which is a review trigger
    /// rather than a false negative.
    func test_everyRequest_setsItsOwnInactivityBudget_andTranscriptionDerivesItFromThePartCount() throws {
        let source = Self.strippingComments(try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("NoType/Gemini/GeminiClient.swift"),
            encoding: .utf8
        ))

        let requestCount = source.components(separatedBy: "URLRequest(url:").count - 1
        let budgetCount = source.components(separatedBy: "timeoutInterval =").count - 1
        XCTAssertGreaterThan(requestCount, 0, "No URLRequest is built in GeminiClient.swift — the guard lost its subject.")
        XCTAssertEqual(
            budgetCount, requestCount,
            "\(requestCount) URLRequest(s) are built in GeminiClient.swift but \(budgetCount) set a timeoutInterval. A request without one inherits the session default, which is sized for the audio-less calls — too long for a single chunk and too short for a batch."
        )

        // The transcription path's budget comes from the part count, not from
        // a literal and not from the auxiliary constant. This is the needle
        // that a "just put 30 back" edit trips.
        let sendRequest = try XCTUnwrap(
            Self.body(ofFuncNamed: "sendRequest", in: source),
            "Could not parse sendRequest — the guard lost its anchor."
        )
        XCTAssertTrue(
            sendRequest.contains("req.timeoutInterval = Self.requestInactivityBudget(audioPartCount: audios.count)"),
            "sendRequest no longer derives its inactivity budget from the number of audio parts. A flat value is exactly what the measurement rejected: the 4-part batch needed 26.85 s where the single-part force-cut needed 7.62 s."
        )

        // Ordering: the budget must be on the request before the retry loop
        // issues it. Set inside the loop it would still work; set *after* the
        // loop it would not be on any attempt at all.
        let budgetIdx = try XCTUnwrap(sendRequest.range(of: "req.timeoutInterval =")).lowerBound
        let loopIdx = try XCTUnwrap(
            sendRequest.range(of: "while true {"),
            "sendRequest no longer contains the `while true {` retry loop — the position anchor is gone."
        ).lowerBound
        XCTAssertLessThan(
            budgetIdx, loopIdx,
            "The per-request budget must be assigned before the retry loop issues the request."
        )
    }

    // MARK: - Fixtures pinning the guard above

    /// The mutation that defeated this guard's first draft, as a fixture:
    /// a commented-out call must not satisfy a needle, and a URL literal
    /// must survive the stripper.
    func test_commentStripper_dropsTextThatDoesNotRun_andKeepsURLLiterals() {
        let source = """
        private func flushPooledConnections() async {
            // Disabled while investigating: session.flush { continuation.resume() }
        }
        /* an older copy: session.flush { } */
        let endpoint = URL(string: "https://example.com/v1beta/models")!
        func live() { session.flush { } }
        """
        let stripped = Self.strippingComments(source)

        XCTAssertEqual(
            stripped.components(separatedBy: "session.flush").count - 1, 1,
            "Only the one live call may survive. The line-commented and block-commented copies are exactly the mutation this stripper exists to catch."
        )
        XCTAssertTrue(
            stripped.contains("https://example.com/v1beta/models"),
            "A URL literal's `//` must not be read as a comment — GeminiClient.swift carries endpoint literals."
        )
    }

    func test_bodyExtractor_stopsAtTheFunctionsClosingBrace() throws {
        let source = """
        func a() {
            let x = 1
            if x > 0 { print(x) }
        }

        private func b(
            arg: Int = 0
        ) async throws -> Int {
            isDefinitelyOffline()
        }
        """
        let a = try XCTUnwrap(Self.body(ofFuncNamed: "a", in: source))
        XCTAssertTrue(a.contains("let x = 1"))
        XCTAssertFalse(
            a.contains("isDefinitelyOffline"),
            "The extractor ran past `a`'s closing brace — the performOnce assertion would be vacuous."
        )

        // Multi-line signature with a default argument: the shape both
        // real functions have, and the one a naive "first `{` on the decl
        // line" extractor would miss.
        let b = try XCTUnwrap(Self.body(ofFuncNamed: "b", in: source))
        XCTAssertTrue(b.contains("isDefinitelyOffline"))
        XCTAssertFalse(b.contains("let x = 1"))
    }

    /// The scanned source with comments removed, so a needle can only match
    /// code that actually runs.
    ///
    /// **Added because scoping was not enough.** The `session.flush` check
    /// below was first scoped to `flushPooledConnections`'s own body, which
    /// looked sufficient — and a live mutation walked straight through it:
    /// comment the body out, leave `// Disabled while investigating:
    /// session.flush { … }` in its place, and the assertion still matched,
    /// inside the right function, on text that no longer executes. Every
    /// other needle in this file had the same hole. "Disable while
    /// investigating" is the routine way matching-text and
    /// matching-behaviour come apart, per
    /// `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`.
    ///
    /// Limits, recorded so the green is not over-trusted: block comments are
    /// stripped non-recursively (Swift permits nesting), and `//` inside a
    /// string literal is stripped too — except the `://` of a URL, which is
    /// protected, because `GeminiClient.swift` carries endpoint literals.
    /// No needle in this file sits on a line with another `//`-bearing
    /// literal. It is deliberately naive: a wrong parse here fails *loud*
    /// (the anchor stops resolving), which is the safe direction.
    private static func strippingComments(_ source: String) -> String {
        // The sentinel must not itself contain `//`, or the line pass below
        // truncates every URL literal at the scheme. (It did, on the first
        // draft; the fixture test is what caught it.)
        let urlSchemeSentinel = "\u{1}"
        var s = source.replacingOccurrences(of: "://", with: urlSchemeSentinel)

        while let open = s.range(of: "/*"),
              let close = s.range(of: "*/", range: open.upperBound..<s.endIndex) {
            s.replaceSubrange(open.lowerBound..<close.upperBound, with: "")
        }

        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let comment = line.range(of: "//") else { return line }
            return line[line.startIndex..<comment.lowerBound]
        }

        return lines.joined(separator: "\n")
            .replacingOccurrences(of: urlSchemeSentinel, with: "://")
    }

    /// Brace-balanced slice of a named function's body: locate `func
    /// <name>(`, take the first `{` after it as the body opener, and return
    /// through its matching close. Handles multi-line signatures (both
    /// functions here have one). Naive about braces inside string literals;
    /// adequate for the one Swift file it reads, and the fixture above
    /// proves it starts and stops where it should.
    private static func body(ofFuncNamed name: String, in source: String) -> String? {
        guard let decl = source.range(of: "func \(name)(") else { return nil }
        guard let open = source.range(of: "{", range: decl.upperBound..<source.endIndex) else { return nil }
        var depth = 0
        var idx = open.lowerBound
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: open.lowerBound)...idx])
                }
            }
            idx = source.index(after: idx)
        }
        return nil
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NoTypeTests/
            .deletingLastPathComponent()    // repo root
    }
}
