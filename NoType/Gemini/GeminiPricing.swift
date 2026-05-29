import Foundation

/// Public Gemini API pricing, **per transcription model** (`GeminiModel`).
/// Constants live here, not inline at the UI layer, so a price change is
/// a single-file edit. Rates: Gemini 3.1 Flash-Lite — $0.25 in / $1.50
/// out; Gemini 3.5 Flash — $1.50 in / $9.00 out. `cached` is the
/// implicit context-cache read rate, billed at 10% of the model's input
/// rate.
///
/// **Exact per-model totals.** `cost(perModel:)` prices each model's
/// token slice at its own rate and sums — so a window that mixes
/// Flash-Lite and Flash dictations bills each correctly. This relies on
/// `StatsStore` bucketing tokens per model (`DayBucket.tokensByModel`,
/// schema v5); the single-model `cost(input:output:cached:model:)`
/// overload remains for callers that already know the model.
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
    /// Per-model billing rates (USD per million tokens).
    struct Rates: Sendable {
        let input: Double
        let output: Double
        let cached: Double
    }

    // MARK: Gemini 3.1 Flash-Lite (default)
    // Kept as top-level constants (not only inside the `flashLite` Rates)
    // because `TokenStatsPanelTests` pins these exact names.
    /// USD per million input tokens (prompts ≤ 200K).
    static let inputPerMillion: Double = 0.25
    /// USD per million output tokens.
    static let outputPerMillion: Double = 1.50
    /// USD per million cached-input tokens (10% of input rate).
    static let cachedPerMillion: Double = 0.025

    // MARK: Gemini 3.5 Flash
    /// USD per million input tokens.
    static let flashInputPerMillion: Double = 1.50
    /// USD per million output tokens.
    static let flashOutputPerMillion: Double = 9.00
    /// USD per million cached-input tokens (10% of input rate).
    static let flashCachedPerMillion: Double = 0.15

    /// Billing rates for a given transcription model.
    static func rates(for model: GeminiModel) -> Rates {
        switch model {
        case .flashLite:
            return Rates(input: inputPerMillion, output: outputPerMillion, cached: cachedPerMillion)
        case .flash:
            return Rates(input: flashInputPerMillion, output: flashOutputPerMillion, cached: flashCachedPerMillion)
        }
    }

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
    static func cost(input: Int, output: Int, cached: Int = 0, model: GeminiModel = .flashLite) -> Double {
        let r = rates(for: model)
        let billableInput = max(0, input - cached)
        let inputCost: Double  = Double(billableInput) * r.input  / 1_000_000
        let cachedCost: Double = Double(cached)        * r.cached / 1_000_000
        let outputCost: Double = Double(output)        * r.output / 1_000_000
        return inputCost + cachedCost + outputCost
    }

    /// Sum the cost of a per-model token breakdown (keyed by
    /// `GeminiModel.rawValue` — e.g. from
    /// `StatsSnapshot.tokenTotalsByModel`). Each model's slice is priced
    /// at its own rate, so a window mixing Flash-Lite and Flash bills
    /// each correctly. An unrecognised key (a model removed/renamed in a
    /// future build) falls back to Flash-Lite rates rather than being
    /// dropped from the total.
    static func cost(perModel totals: [String: ModelTokens]) -> Double {
        totals.reduce(0.0) { acc, kv in
            let model = GeminiModel(rawValue: kv.key) ?? .flashLite
            return acc + cost(
                input: kv.value.input,
                output: kv.value.output,
                cached: kv.value.cached,
                model: model
            )
        }
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
