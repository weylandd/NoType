import Foundation

/// Per-Gemini-response token accounting. Sourced from the API's
/// `usageMetadata` and threaded back to the caller via the
/// `GeminiClient.transcribe*WithUsage` overloads. The three fields
/// track Gemini's distinct billing dimensions:
///
///   - `input`  — `promptTokenCount`, the prompt tokens billed for
///     this response (cache hits subtract from `cached` not `input`
///     in our local accounting — see `init(from:)`).
///   - `output` — `candidatesTokenCount`, the tokens the model
///     generated.
///   - `cached` — `cachedContentTokenCount`, the prompt tokens that
///     hit Gemini's implicit cache and are billed at the discounted
///     rate. Always `<= input` (cache hits are a subset of prompt
///     tokens).
///
/// Granularity is **per-request, not per-chunk**: a batched call
/// returns one `usageMetadata` covering the whole batch. We do NOT
/// divide tokens across chunks in a batched response — Gemini's
/// billing model is per-response, and synthesizing a per-chunk
/// breakdown would be a guess. Session-level aggregation sums one
/// `TokenUsage` per Gemini call (single-chunk, batched, lite, or
/// split-retry).
///
/// Failed Gemini calls contribute nothing (`text: nil` responses
/// carry `.zero` for tokens). Retried-then-succeeded calls
/// contribute only the final successful attempt's usage — matches
/// Gemini's per-response billing and avoids double-counting cached
/// tokens implicit-cache hits already include.
struct TokenUsage: Codable, Sendable, Equatable {
    let input: Int
    let output: Int
    let cached: Int

    init(input: Int, output: Int, cached: Int) {
        self.input = input
        self.output = output
        self.cached = cached
    }

    /// Map Gemini's `usageMetadata` shape into our local type.
    /// Missing or nil fields default to 0 — the API sometimes omits
    /// `cachedContentTokenCount` on cold-prefix calls. Returns
    /// `.zero` when the metadata payload itself is missing
    /// (e.g. parse-time error or fully empty response).
    init(from metadata: GeminiAPI.UsageMetadata?) {
        guard let m = metadata else {
            self = .zero
            return
        }
        self.input  = m.promptTokenCount        ?? 0
        self.output = m.candidatesTokenCount    ?? 0
        self.cached = m.cachedContentTokenCount ?? 0
    }

    /// Identity element for accumulation. Sessions that record no
    /// successful Gemini calls (all failed recoverably) still need
    /// to fold into `StatsStore` cleanly — `.zero` is the safe
    /// neutral.
    static let zero = TokenUsage(input: 0, output: 0, cached: 0)

    /// Component-wise sum. Used to fold per-call `TokenUsage` into
    /// session-level totals in `RecordingSession.sessionTokens`.
    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input:  lhs.input  + rhs.input,
            output: lhs.output + rhs.output,
            cached: lhs.cached + rhs.cached
        )
    }
}
