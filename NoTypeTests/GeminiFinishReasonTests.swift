import XCTest
@testable import NoType

/// Pins `GeminiClient.finishReasonError(_:)` — the pure map from a
/// candidate's `finishReason` to a `GeminiError` (or `nil` to keep the
/// text). The load-bearing behaviour:
///
/// - `STOP` / absent / blank / unknown → `nil` (a clean or
///   don't-reject-over-it completion; the caller keeps the text).
/// - content-block reasons (`SAFETY` / `RECITATION` / …) → `.blocked`
///   (terminal, same as a prompt-level block), carrying the reason.
/// - `MAX_TOKENS` → `.truncated` (recoverable → `[…]` gap marker).
///
/// `GeminiError` is not `Equatable`, so cases are matched structurally.
final class GeminiFinishReasonTests: XCTestCase {

    // MARK: - Keeps the text (nil)

    func test_stop_returnsNil() {
        XCTAssertNil(GeminiClient.finishReasonError("STOP"))
    }

    func test_nil_returnsNil() {
        XCTAssertNil(GeminiClient.finishReasonError(nil))
    }

    func test_empty_returnsNil() {
        XCTAssertNil(GeminiClient.finishReasonError(""))
    }

    func test_whitespaceOnly_returnsNil() {
        XCTAssertNil(GeminiClient.finishReasonError("   "))
    }

    func test_unknownReason_keepsText() {
        // A future / unrecognised reason (OTHER, LANGUAGE, …) must not
        // reject a usable transcript — the caller logs it instead.
        XCTAssertNil(GeminiClient.finishReasonError("OTHER"))
        XCTAssertNil(GeminiClient.finishReasonError("LANGUAGE"))
    }

    // MARK: - Truncation (recoverable)

    func test_maxTokens_mapsToTruncated() {
        guard case .truncated? = GeminiClient.finishReasonError("MAX_TOKENS") else {
            return XCTFail("MAX_TOKENS should map to .truncated")
        }
    }

    func test_maxTokens_caseInsensitive() {
        guard case .truncated? = GeminiClient.finishReasonError("max_tokens") else {
            return XCTFail("lowercase max_tokens should map to .truncated")
        }
    }

    func test_maxTokens_trimsWhitespace() {
        guard case .truncated? = GeminiClient.finishReasonError("  MAX_TOKENS\n") else {
            return XCTFail("padded MAX_TOKENS should map to .truncated")
        }
    }

    // MARK: - Content blocks (terminal)

    func test_safety_mapsToBlocked_withReason() {
        guard case .blocked(let reason)? = GeminiClient.finishReasonError("SAFETY") else {
            return XCTFail("SAFETY should map to .blocked")
        }
        XCTAssertEqual(reason, "SAFETY")
    }

    func test_recitation_mapsToBlocked() {
        guard case .blocked? = GeminiClient.finishReasonError("RECITATION") else {
            return XCTFail("RECITATION should map to .blocked")
        }
    }

    func test_prohibitedContent_mapsToBlocked() {
        guard case .blocked? = GeminiClient.finishReasonError("PROHIBITED_CONTENT") else {
            return XCTFail("PROHIBITED_CONTENT should map to .blocked")
        }
    }

    func test_block_carriesTrimmedOriginalCasing() {
        // Matching is case-insensitive, but the surfaced reason keeps the
        // trimmed original the server sent.
        guard case .blocked(let reason)? = GeminiClient.finishReasonError("  Blocklist ") else {
            return XCTFail("BLOCKLIST should map to .blocked")
        }
        XCTAssertEqual(reason, "Blocklist")
    }
}
