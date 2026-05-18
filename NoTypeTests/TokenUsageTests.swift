import XCTest
@testable import NoType

/// Pure-value tests for `TokenUsage`: the `+` accumulator, `.zero`
/// identity element, mapping from Gemini's `UsageMetadata`, and
/// Codable round-trip. Used by `RecordingSession.sessionTokens` to
/// sum one `TokenUsage` per successful Gemini call (single-chunk,
/// batched, lite, split-retry) and by `StatsStore.record(_:tokens:)`
/// to fold into per-day totals — both depend on this type's
/// arithmetic being component-wise and lossless.
final class TokenUsageTests: XCTestCase {

    // MARK: - Identity

    func test_zero_isAllZeros() {
        XCTAssertEqual(TokenUsage.zero, TokenUsage(input: 0, output: 0, cached: 0))
    }

    // MARK: - + operator

    func test_addition_componentWise() {
        let a = TokenUsage(input: 100, output: 50, cached: 30)
        let b = TokenUsage(input: 200, output: 25, cached: 15)
        XCTAssertEqual(a + b, TokenUsage(input: 300, output: 75, cached: 45))
    }

    func test_addition_withZero_isIdentity() {
        let a = TokenUsage(input: 7, output: 13, cached: 2)
        XCTAssertEqual(a + .zero, a)
        XCTAssertEqual(.zero + a, a)
    }

    func test_addition_isCommutative() {
        // Session-level accumulation runs in dispatch order, so
        // commutativity isn't load-bearing — pinning it anyway
        // because any future "smart" merge logic that breaks this
        // would silently produce different totals depending on
        // chunk arrival order.
        let a = TokenUsage(input: 1, output: 2, cached: 3)
        let b = TokenUsage(input: 4, output: 5, cached: 6)
        XCTAssertEqual(a + b, b + a)
    }

    func test_addition_isAssociative() {
        // `responses.reduce(.zero, +)` patterns (or partial-recovery
        // splits that accumulate in chunks of chunks) depend on this.
        let a = TokenUsage(input: 1, output: 2, cached: 3)
        let b = TokenUsage(input: 10, output: 20, cached: 30)
        let c = TokenUsage(input: 100, output: 200, cached: 300)
        XCTAssertEqual((a + b) + c, a + (b + c))
    }

    // MARK: - GeminiAPI.UsageMetadata mapping

    /// Decode a `GeminiAPI.UsageMetadata` from JSON. `UsageMetadata`
    /// is `Decodable`-only by design (server-shape mirror), so the
    /// tests reach it through the same path production code does.
    private func metadata(_ json: String) throws -> GeminiAPI.UsageMetadata {
        try JSONDecoder().decode(GeminiAPI.UsageMetadata.self, from: Data(json.utf8))
    }

    func test_initFromMetadata_nilPayload_returnsZero() {
        // Defensive path — a malformed response or transient parsing
        // miss should NOT throw when the caller wants the token
        // contribution. `.zero` is correct: nothing was billed
        // (locally) for an unparseable response.
        XCTAssertEqual(TokenUsage(from: nil), .zero)
    }

    func test_initFromMetadata_allFieldsPresent_mapsByName() throws {
        let m = try metadata("""
        {
          "promptTokenCount": 1234,
          "candidatesTokenCount": 500,
          "cachedContentTokenCount": 800
        }
        """)
        XCTAssertEqual(
            TokenUsage(from: m),
            TokenUsage(input: 1_234, output: 500, cached: 800)
        )
    }

    func test_initFromMetadata_missingCached_defaultsToZero() throws {
        // Gemini omits `cachedContentTokenCount` on cold-prefix
        // calls (first call of a session, lite-path responses).
        // The tolerant decode must treat missing as 0, not crash.
        let m = try metadata("""
        {
          "promptTokenCount": 600,
          "candidatesTokenCount": 200
        }
        """)
        XCTAssertEqual(
            TokenUsage(from: m),
            TokenUsage(input: 600, output: 200, cached: 0)
        )
    }

    func test_initFromMetadata_allFieldsMissing_returnsZero() throws {
        let m = try metadata("{}")
        XCTAssertEqual(TokenUsage(from: m), .zero)
    }

    // MARK: - Codable round-trip

    func test_codable_roundTrip_preservesAllFields() throws {
        let original = TokenUsage(input: 1_500, output: 250, cached: 1_200)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_codable_zeroRoundTrip() throws {
        let data = try JSONEncoder().encode(TokenUsage.zero)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        XCTAssertEqual(decoded, .zero)
    }
}
