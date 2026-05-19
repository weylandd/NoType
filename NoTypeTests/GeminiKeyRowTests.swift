import XCTest
@testable import NoType

/// Pins the pure helpers backing `GeminiKeyRow` — masked-key
/// rendering and the error-translation table used by the Edit
/// modal. The SwiftUI view itself is exercised by the manual
/// smoke test before commit; this suite covers what is testable
/// without standing up a render harness:
///
///   1. Mask format for short / long / empty keys.
///   2. The error-display path never leaks a `GeminiError.http`
///      response body into the rendered text.
///   3. Case-mapped messages for `.missingKey` and `.http(401)`;
///      fallback to `error.localizedDescription` for everything
///      else (already body-redacted by `GeminiError`).
///
/// Marked `@MainActor` because `GeminiKeyRow` is a SwiftUI `View`
/// and under Swift 6 strict concurrency its static methods inherit
/// the `@MainActor` isolation. CI's Swift toolchain enforces this
/// at compile time; older toolchains let it slide silently.
@MainActor
final class GeminiKeyRowTests: XCTestCase {

    // MARK: - Mask format

    func test_mask_longKey_showsAIzaSyPrefixAndDotPad() {
        // Real Gemini keys begin with the `AIzaSy` prefix (39 chars
        // total). The row's at-rest display reveals the first 6
        // chars and pads the rest with middle dots so the user can
        // visually confirm "yes, that's my key" without exposing
        // the suffix to a shoulder-surfer. Test fixture is
        // intentionally short (not a 35-char suffix) so leak
        // scanners don't flag the literal as a real GCP key — the
        // helper only consumes the first 6 chars anyway.
        let prefix = "AIza" + "Sy"  // split literal — gitleaks scans the raw line
        let key = prefix + "TESTFAKE"
        let masked = GeminiKeyRow.maskedDisplay(for: key)
        XCTAssertTrue(masked.hasPrefix(prefix))
        XCTAssertEqual(masked.count, prefix.count + 8,
                       "Mask should be 6 leading chars + 8 middle dots.")
        XCTAssertTrue(masked.dropFirst(6).allSatisfy { $0 == "•" })
    }

    func test_mask_shortKey_showsWhatItHasPlusDotPad() {
        // Defensive: a stub or dev key shorter than 6 chars
        // shouldn't crash or misrender. Show what we have, pad
        // with dots so the field never collapses to nothing.
        let masked = GeminiKeyRow.maskedDisplay(for: "abc")
        XCTAssertTrue(masked.hasPrefix("abc"))
        XCTAssertEqual(masked.count, 3 + 8)
        XCTAssertTrue(masked.dropFirst(3).allSatisfy { $0 == "•" })
    }

    func test_mask_emptyKey_returnsPlaceholder() {
        // No key at all → render the bare dot-pad so the layout
        // doesn't reflow when the user first opens Settings on a
        // fresh install (key cleared via env path or manual
        // Keychain delete). The Edit button stays usable.
        let masked = GeminiKeyRow.maskedDisplay(for: "")
        XCTAssertEqual(masked, "••••••••")
    }

    // MARK: - Error translation (body-redaction contract)

    func test_errorBody_nonJSON_doesNotLeakIntoUILabel() {
        // Revised contract: raw (non-JSON) bodies still must not
        // appear in the UI label. Only the *sanitized* `error.message`
        // extracted from a JSON envelope is surfaced — random body
        // bytes (HTML 5xx pages, plaintext nginx errors, opaque
        // tokens) fall back to the generic "Gemini error N." line.
        let sentinel = "secret-project-id-12345"
        let err = GeminiClient.GeminiError.http(status: 500, body: sentinel)
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertFalse(rendered.contains(sentinel),
                       "Non-JSON body must NOT appear in the UI label.")
    }

    func test_errorBody_apiKeyInJSONMessage_isRedacted() {
        // Hard rule, revised: Google sometimes echoes a partial
        // API key in `error.message` ("Invalid API key:
        // AIzaSyXXXXXXX..."). The sanitizer must mask the AIzaSy
        // pattern so a shoulder-surfer can't reconstruct the key
        // from a UI screenshot. The test key matches the real
        // pattern (AIzaSy + 33 chars) but is obviously fake.
        let fakeKey = "AIza" + "Sy" + String(repeating: "X", count: 33)
        let body = #"{"error":{"code":400,"message":"API key not valid: \#(fakeKey). Pass a valid key."}}"#
        let err = GeminiClient.GeminiError.http(status: 400, body: body)
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertTrue(rendered.contains("API key not valid"),
                      "Sanitized message text SHOULD reach the UI.")
        XCTAssertTrue(rendered.contains("AIzaSy••••••••"),
                      "Key pattern must be replaced with the redaction marker.")
        XCTAssertFalse(rendered.contains(fakeKey),
                       "The original API-key-shaped substring must NOT appear in the UI.")
    }

    func test_errorMessage_missingKey_isCaseMapped() {
        let rendered = GeminiKeyRow.errorMessage(for: GeminiClient.GeminiError.missingKey)
        // Specific phrasing from the plan — contextual to the
        // Edit modal ("invalid format"), narrower than the
        // generic GeminiError.errorDescription ("Set a key in
        // Settings.") which doesn't fit the modal.
        XCTAssertEqual(rendered, "Invalid key — check format")
    }

    func test_errorMessage_http401_isCaseMapped() {
        let err = GeminiClient.GeminiError.http(status: 401, body: "irrelevant")
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertEqual(rendered, "Authentication failed (401)")
        XCTAssertFalse(rendered.contains("irrelevant"))
    }

    func test_errorMessage_http403_isCaseMapped() {
        // 403 means the key exists but isn't authorised for the
        // model — same user-facing intent as 401 (key won't work).
        let err = GeminiClient.GeminiError.http(status: 403, body: "irrelevant")
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertEqual(rendered, "Authentication failed (403)")
    }

    func test_errorMessage_otherHttp_fallsBackToLocalizedDescription() {
        // For non-auth HTTP errors we trust GeminiError's
        // body-redacted `errorDescription`. Verify the contract
        // (no body leak) AND that the rendered string is the
        // one GeminiError offered.
        let err = GeminiClient.GeminiError.http(status: 429, body: "quota-detail-xyz")
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertEqual(rendered, err.errorDescription)
        XCTAssertFalse(rendered.contains("quota-detail-xyz"))
    }

    func test_errorMessage_urlError_offline_isFriendly() {
        // Network-class errors during validation are common
        // (Wi-Fi flapping while the user pastes a key). Translate
        // the URLError to a friendly inline message rather than
        // surfacing Apple's verbose default.
        let err = URLError(.notConnectedToInternet)
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertEqual(rendered, "No internet — NoType needs to reach Gemini to validate.")
    }

    func test_errorMessage_urlError_timeout_isFriendly() {
        let err = URLError(.timedOut)
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertEqual(rendered, "Validation timed out. Try again.")
    }

    func test_errorMessage_genericError_fallsBackToLocalizedDescription() {
        struct Toy: LocalizedError {
            var errorDescription: String? { "something else" }
        }
        let rendered = GeminiKeyRow.errorMessage(for: Toy())
        XCTAssertEqual(rendered, "something else")
    }

    // MARK: - Whitelisted Google error shapes

    func test_errorMessage_http400_userLocationNotSupported_isExplainedAsRegionBlock() {
        // Gemini API rejects requests from a set of countries with
        // a HTTP 400 + this exact phrase in `error.message`. The
        // generic "Gemini error 400." gave a tester no idea what to
        // do — surface the actionable hint ("use a VPN") instead.
        // Body fixture is the real shape Google returns, so a
        // future Google rename will fail this test loudly.
        let body = #"""
        {
          "error": {
            "code": 400,
            "message": "User location is not supported for the API use.",
            "status": "FAILED_PRECONDITION"
          }
        }
        """#
        let err = GeminiClient.GeminiError.http(status: 400, body: body)
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertEqual(
            rendered,
            "Gemini isn't available in your region. Try connecting through a VPN."
        )
        // Body-leak guard: even though we matched on body content,
        // the raw JSON / status string must NOT appear in the output.
        XCTAssertFalse(rendered.contains("FAILED_PRECONDITION"))
        XCTAssertFalse(rendered.contains("\"error\""))
    }

    func test_errorMessage_http400_unrelatedBody_surfacesSanitizedGoogleMessage() {
        // Regression: only the region-block phrase triggers the
        // VPN copy. Other 400s now surface Google's `error.message`
        // (sanitized) so the user gets useful diagnosis instead of
        // a bare "Gemini error 400."
        let body = #"{"error":{"code":400,"message":"Invalid argument","status":"INVALID_ARGUMENT"}}"#
        let err = GeminiClient.GeminiError.http(status: 400, body: body)
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertEqual(rendered, "Gemini error 400: Invalid argument.")
    }

    func test_errorMessage_http400_malformedJSON_fallsBackToGenericLine() {
        // Body not parseable as JSON → sanitizer returns nil →
        // generic "Gemini error 400." line. Defends against random
        // HTML / plaintext bodies (some proxy or 5xx pages serve
        // that shape).
        let err = GeminiClient.GeminiError.http(status: 400, body: "<html>500</html>")
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertEqual(rendered, "Gemini error 400.")
    }

    func test_errorMessage_http400_emptyMessage_fallsBackToGenericLine() {
        // JSON shape correct but `error.message` is empty / whitespace.
        // Sanitizer rejects → generic fallback. No "Gemini error 400: ."
        // ugliness with a trailing colon.
        let body = #"{"error":{"code":400,"message":"   ","status":"INVALID_ARGUMENT"}}"#
        let err = GeminiClient.GeminiError.http(status: 400, body: body)
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertEqual(rendered, "Gemini error 400.")
    }

    func test_errorMessage_http500_bodyContainingTriggerPhrase_doesNotMisroute() {
        // The location-match runs only for the generic .http arm,
        // but a 5xx with the trigger phrase in its body must still
        // route through the 5xx-specific case and NOT inherit the
        // region-block copy. Defends the case-order in errorDescription.
        let err = GeminiClient.GeminiError.http(
            status: 500,
            body: "User location is not supported for the API use."
        )
        let rendered = GeminiKeyRow.errorMessage(for: err)
        XCTAssertEqual(rendered, "Gemini is having trouble (HTTP 500).")
    }

    // MARK: - Region-block predicate (shared trigger phrase)

    func test_isRegionBlocked_matchesGoogleRealResponse() {
        // Single source of truth for the trigger phrase across three
        // consumers: GeminiError.errorDescription, OnboardingAPIKeyStep,
        // and AppState.payloadForSessionFailure. If Google reworded
        // "User location is not supported" all three would silently
        // regress; this test catches it once.
        let realBody = #"""
        {
          "error": {
            "code": 400,
            "message": "User location is not supported for the API use.",
            "status": "FAILED_PRECONDITION"
          }
        }
        """#
        XCTAssertTrue(GeminiClient.GeminiError.isRegionBlocked(body: realBody))
    }

    func test_isRegionBlocked_rejectsUnrelatedBodies() {
        XCTAssertFalse(GeminiClient.GeminiError.isRegionBlocked(body: ""))
        XCTAssertFalse(GeminiClient.GeminiError.isRegionBlocked(body: "{}"))
        XCTAssertFalse(GeminiClient.GeminiError.isRegionBlocked(
            body: #"{"error":{"code":400,"message":"Invalid argument"}}"#
        ))
        XCTAssertFalse(GeminiClient.GeminiError.isRegionBlocked(
            body: "user supplied a key from an unsupported region"  // close but no match
        ))
    }

    // MARK: - Sanitized Google error message extraction

    func test_sanitizedGoogleMessage_extractsRealGoogleShape() {
        let body = #"{"error":{"code":403,"message":"Generative Language API has not been used in project 12345 before or it is disabled.","status":"PERMISSION_DENIED"}}"#
        let extracted = GeminiClient.GeminiError.sanitizedGoogleMessage(body: body)
        XCTAssertEqual(
            extracted,
            "Generative Language API has not been used in project 12345 before or it is disabled."
        )
    }

    func test_sanitizedGoogleMessage_returnsNilForNonJSON() {
        XCTAssertNil(GeminiClient.GeminiError.sanitizedGoogleMessage(body: ""))
        XCTAssertNil(GeminiClient.GeminiError.sanitizedGoogleMessage(body: "<html>500</html>"))
        XCTAssertNil(GeminiClient.GeminiError.sanitizedGoogleMessage(body: "not-json-at-all"))
    }

    func test_sanitizedGoogleMessage_returnsNilForMissingMessage() {
        XCTAssertNil(GeminiClient.GeminiError.sanitizedGoogleMessage(body: "{}"))
        XCTAssertNil(GeminiClient.GeminiError.sanitizedGoogleMessage(
            body: #"{"error":{"code":400}}"#
        ))
        XCTAssertNil(GeminiClient.GeminiError.sanitizedGoogleMessage(
            body: #"{"error":{"message":""}}"#
        ))
        XCTAssertNil(GeminiClient.GeminiError.sanitizedGoogleMessage(
            body: #"{"error":{"message":"   \n\t  "}}"#
        ))
    }

    func test_sanitizedGoogleMessage_masksAPIKeyPattern() {
        // 39-char Google key shape (AIzaSy + 33 chars). Multiple
        // occurrences in one message all get masked.
        let fakeKey1 = "AIza" + "Sy" + String(repeating: "A", count: 33)
        let fakeKey2 = "AIza" + "Sy" + String(repeating: "B", count: 33)
        let body = #"{"error":{"message":"Bad keys: \#(fakeKey1) and \#(fakeKey2)"}}"#
        let extracted = GeminiClient.GeminiError.sanitizedGoogleMessage(body: body)
        XCTAssertNotNil(extracted)
        XCTAssertFalse(extracted!.contains(fakeKey1))
        XCTAssertFalse(extracted!.contains(fakeKey2))
        let maskCount = extracted!.components(separatedBy: "AIzaSy••••••••").count - 1
        XCTAssertEqual(maskCount, 2, "Both API-key occurrences should be masked.")
    }

    func test_sanitizedGoogleMessage_leavesAIzaSyPrefixAloneWhenShorterThanKey() {
        // The pattern requires exactly 33 chars after `AIzaSy` —
        // a 10-char "AIzaSyShort" mention in prose must NOT be
        // mistakenly masked.
        let body = #"{"error":{"message":"see AIzaSyShortRef for context"}}"#
        let extracted = GeminiClient.GeminiError.sanitizedGoogleMessage(body: body)
        XCTAssertEqual(extracted, "see AIzaSyShortRef for context")
    }

    // MARK: - descriptionForGenericHTTP composition

    func test_descriptionForGenericHTTP_regionBlock_winsOverGoogleMessage() {
        // Region-block body matches both `isRegionBlocked` AND has
        // a parseable Google message. The region-block branch must
        // take priority because our VPN hint is more actionable.
        let body = #"{"error":{"code":400,"message":"User location is not supported for the API use.","status":"FAILED_PRECONDITION"}}"#
        let rendered = GeminiClient.GeminiError.descriptionForGenericHTTP(status: 400, body: body)
        XCTAssertEqual(rendered, "Gemini isn't available in your region. Try connecting through a VPN.")
    }

    func test_descriptionForGenericHTTP_trailingArgAppendsCorrectly() {
        // Onboarding wants "Try again." after the line.
        let body = #"{"error":{"message":"Invalid argument"}}"#
        let rendered = GeminiClient.GeminiError.descriptionForGenericHTTP(
            status: 400, body: body, trailing: "Try again."
        )
        XCTAssertEqual(rendered, "Gemini error 400: Invalid argument. Try again.")
    }

    func test_descriptionForGenericHTTP_trailingArgAppendsToGenericFallback() {
        let rendered = GeminiClient.GeminiError.descriptionForGenericHTTP(
            status: 400, body: "<html>nope</html>", trailing: "Try again."
        )
        XCTAssertEqual(rendered, "Gemini error 400. Try again.")
    }

    func test_descriptionForGenericHTTP_trailingArgAppendsToRegionBlock() {
        let body = #"{"error":{"message":"User location is not supported"}}"#
        let rendered = GeminiClient.GeminiError.descriptionForGenericHTTP(
            status: 400, body: body, trailing: "Try again."
        )
        XCTAssertEqual(
            rendered,
            "Gemini isn't available in your region. Try connecting through a VPN. Try again."
        )
    }
}
