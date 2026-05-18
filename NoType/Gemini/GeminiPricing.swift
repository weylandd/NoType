import Foundation

/// Public Gemini API pricing for the model NoType ships with
/// (`gemini-3.1-flash-lite-preview`, `NoType/Gemini/GeminiClient.swift`
/// modelID). Constants live here, not inline at the UI layer, so a
/// price change is a single-file edit.
///
/// **Source:** Google Cloud Vertex AI pricing page, verified
/// 2026-05-18 via aggregator cross-check (Magica, pricepertoken,
/// typingmind). Gemini pricing historically does not move often;
/// when it does, update this file and the timestamp above.
///
/// `cached` is billed at 10% of the standard input rate (Google's
/// implicit context-cache discount). We do not surface the
/// cached-token count in the Settings UI — but we factor it into
/// the cost calculation so the displayed dollar figure matches the
/// user's actual bill rather than overcounting cache hits.
enum GeminiPricing {
    /// USD per million input tokens (prompts ≤ 200K).
    static let inputPerMillion: Double = 0.25
    /// USD per million output tokens.
    static let outputPerMillion: Double = 1.50
    /// USD per million cached-input tokens (10% of input rate).
    static let cachedPerMillion: Double = 0.025

    /// Compute USD cost of a token window at current rates.
    ///
    /// Gemini's `usageMetadata` reports `cachedContentTokenCount` as
    /// a **subset** of `promptTokenCount` (cached tokens are *also*
    /// counted in the input total). To avoid double-billing the
    /// cache hit we split:
    ///
    /// - `billableInput = max(0, input - cached)` at the standard
    ///   input rate
    /// - `cached` at the discounted cache-read rate
    /// - `output` at the standard output rate
    ///
    /// `max(0, …)` defends against a malformed snapshot where
    /// `cached > input` (shouldn't happen but the type system
    /// doesn't enforce the subset invariant).
    static func cost(input: Int, output: Int, cached: Int = 0) -> Double {
        let billableInput = max(0, input - cached)
        return Double(billableInput) * inputPerMillion  / 1_000_000
             + Double(cached)        * cachedPerMillion / 1_000_000
             + Double(output)        * outputPerMillion / 1_000_000
    }

    /// Format a USD cost for the Token usage panel. Returns:
    ///
    ///   - `"$0.00"` when no tokens have been billed yet
    ///   - `"<$0.01"` when there's been usage but it rounds below a cent
    ///   - `"$X.XX"` for amounts < $10 (2 decimals)
    ///   - `"$X.X"` for amounts < $100 (1 decimal — keeps the
    ///     three-cell layout from breaking on width)
    ///   - `"$X"` for amounts ≥ $100 (no decimals)
    ///
    /// `<$0.01` distinguishes "real usage that's just very cheap"
    /// from "no usage" — useful early in a fresh window where the
    /// user wonders whether anything has been counted yet.
    static func formatCost(_ usd: Double) -> String {
        if usd <= 0 {
            return "$0.00"
        }
        if usd < 0.01 {
            return "<$0.01"
        }
        if usd < 10 {
            return String(format: "$%.2f", usd)
        }
        if usd < 100 {
            return String(format: "$%.1f", usd)
        }
        return String(format: "$%.0f", usd)
    }
}
