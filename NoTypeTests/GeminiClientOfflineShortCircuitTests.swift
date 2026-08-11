import XCTest
@testable import NoType

/// Pins the two halves of the offline fast-fail that a unit test can
/// actually reach: the **shape** of the error a short-circuited request
/// throws, and the **position** of the check that throws it.
///
/// Shape matters because the whole design premise is that a
/// short-circuited request is indistinguishable downstream from the
/// 30-second timeout it replaces — same `GeminiError` case, same status,
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
            NetworkErrorTranslator.extractURLErrorCode(from: body),
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
                NetworkErrorTranslator.extractURLErrorCode(from: body),
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
        let source = try String(
            contentsOf: Self.repoRoot()
                .appendingPathComponent("NoType/Gemini/GeminiClient.swift"),
            encoding: .utf8
        )

        let probeCall = "reachabilityProbe().isDefinitelyOffline()"

        // Uniqueness first. Without it, "the first match sits before the
        // loop" is satisfiable by any stray earlier occurrence while the
        // real check has moved somewhere harmful.
        XCTAssertEqual(
            source.components(separatedBy: probeCall).count - 1, 1,
            "Expected exactly one offline pre-check in GeminiClient.swift. Zero means it was deleted (restoring the 30 s-per-attempt wait); more than one means a copy was added somewhere this guard does not reason about."
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
        // 30 s-per-attempt wait this feature removes. Verified: that
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

    // MARK: - Fixtures pinning the guard above

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
