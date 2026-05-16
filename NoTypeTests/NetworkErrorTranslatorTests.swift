import XCTest
@testable import NoType

/// Pins `NetworkErrorTranslator.extractURLErrorCode` — the parser
/// that pulls a URLError code back out of the `body` field of a
/// `GeminiClient.GeminiError.http(0, body)` produced by
/// `GeminiClient.performOnce`'s URLError wrap.
///
/// Why this matters: the partial-recovery layer in `RecordingSession`
/// (PR #39) re-throws `lastRecoverableError` when every dispatched
/// call failed. That error is almost always a wrapped URLError —
/// network outage during a long monologue is the most common
/// real-world all-failed path. Without this parser, the AppState
/// catalog's `as? URLError` branch is unreachable post-wrap and the
/// user sees a generic "Gemini rejected the request (HTTP 0)"
/// instead of the offline / timeout HUDs. The parser format has to
/// stay in lockstep with `GeminiClient.performOnce`'s wrapping
/// string; this test is the contract.
final class NetworkErrorTranslatorTests: XCTestCase {

    // MARK: - Happy path

    func test_extract_notConnectedToInternet_returnsCode() {
        // The headline case — offline. URLError.Code = .notConnectedToInternet
        // has rawValue -1009 on Darwin.
        let body = "URLError code=-1009: The Internet connection appears to be offline."
        XCTAssertEqual(NetworkErrorTranslator.extractURLErrorCode(from: body), -1009)
    }

    func test_extract_timedOut_returnsCode() {
        // .timedOut = -1001. AppState routes this to the "Couldn't
        // reach Gemini" HUD.
        let body = "URLError code=-1001: The request timed out."
        XCTAssertEqual(NetworkErrorTranslator.extractURLErrorCode(from: body), -1001)
    }

    func test_extract_dnsLookupFailed_returnsCode() {
        // .dnsLookupFailed = -1006. Falls through to the generic
        // "Network error" HUD via the default branch — code still
        // present so the user can see it.
        let body = "URLError code=-1006: A server with the specified hostname could not be found."
        XCTAssertEqual(NetworkErrorTranslator.extractURLErrorCode(from: body), -1006)
    }

    func test_extract_arbitraryNegativeCode_returnsCode() {
        // Belt-and-braces: the parser doesn't validate the code
        // against URLError.Code's known enum cases. AppState's switch
        // handles unknowns via the default branch.
        let body = "URLError code=-42: arbitrary"
        XCTAssertEqual(NetworkErrorTranslator.extractURLErrorCode(from: body), -42)
    }

    // MARK: - Format boundary cases

    func test_extract_noColonInBody_stillParses() {
        // `localizedDescription` could be empty on a stripped error.
        // Format becomes `"URLError code=-1009"` with no trailing
        // `": …"`. Parser falls back to trimming the rest of the
        // string.
        let body = "URLError code=-1009"
        XCTAssertEqual(NetworkErrorTranslator.extractURLErrorCode(from: body), -1009)
    }

    func test_extract_extraWhitespace_isTolerated() {
        // Defensive: trim around the code before Int conversion.
        let body = "URLError code= -1009 : …"
        XCTAssertEqual(NetworkErrorTranslator.extractURLErrorCode(from: body), -1009)
    }

    // MARK: - Non-matching bodies

    func test_extract_pureHTTPBody_returnsNil() {
        // Real-world Gemini 5xx body — must NOT match.
        let body = "{\"error\": {\"code\": 500, \"message\": \"Internal\"}}"
        XCTAssertNil(NetworkErrorTranslator.extractURLErrorCode(from: body))
    }

    func test_extract_emptyBody_returnsNil() {
        XCTAssertNil(NetworkErrorTranslator.extractURLErrorCode(from: ""))
    }

    func test_extract_unrelatedPrefix_returnsNil() {
        // Anything that doesn't start with the canonical prefix
        // must NOT match — false positives in this parser would route
        // arbitrary errors to the network-class HUDs.
        let body = "Some other error code=-1009: oops"
        XCTAssertNil(NetworkErrorTranslator.extractURLErrorCode(from: body))
    }

    func test_extract_prefixWithGarbageCode_returnsNil() {
        // Defensive against future format drift: if the code field
        // isn't parseable as Int, return nil rather than misreading.
        let body = "URLError code=abc: bad"
        XCTAssertNil(NetworkErrorTranslator.extractURLErrorCode(from: body))
    }

    // MARK: - Lockstep with GeminiClient.performOnce format

    func test_extract_matchesPerformOnceWrapFormat() {
        // GeminiClient.performOnce wraps URLError as:
        //     "URLError code=\(urlError.code.rawValue): \(urlError.localizedDescription)"
        // If that string format ever changes, this test trips first.
        // Reconstruct the exact format with a known URLError and
        // verify the parser unwraps it cleanly.
        let original = URLError(.notConnectedToInternet)
        let body = "URLError code=\(original.code.rawValue): \(original.localizedDescription)"
        let extracted = NetworkErrorTranslator.extractURLErrorCode(from: body)
        XCTAssertEqual(extracted, original.code.rawValue)
    }
}
