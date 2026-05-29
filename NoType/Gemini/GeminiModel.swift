import Foundation

/// Which Gemini model the **transcription** requests target. Switchable
/// in Settings → API & Usage so the user can A/B transcription quality
/// between the fast/cheap Flash-Lite default and the larger Flash.
///
/// Only transcription honours this. The app-categorizer
/// (`GeminiClient.classifyApp`) always runs on `.flashLite` — a cheap
/// background call where the bigger model doesn't move the needle and
/// where keeping the model fixed means the user's transcription choice
/// doesn't quietly change classifier cost.
///
/// The selection is frozen into each `RecordingSession` at start (like
/// every other configurable — instructions, dictionary, languages) and
/// rides into the request URL via `GeminiClient.generateContentURL(for:)`.
/// Freezing has no perceived delay: a setting change applies to the very
/// next dictation. It only guarantees that one dictation = one model, so
/// a multi-chunk session can't straddle two models / implicit-cache
/// namespaces mid-stream. The cache-friendly part *ordering* is
/// unaffected (the model lives in the URL, not the request body), so
/// `GeminiRequestBuilderTests` don't change.
///
/// Per-model billing rates live in `GeminiPricing`; the API & Usage cost
/// cell prices the window at the currently-selected model's rates.
enum GeminiModel: String, CaseIterable, Sendable, Codable {
    /// Default. `gemini-3.1-flash-lite` — fastest, cheapest.
    case flashLite = "gemini-3.1-flash-lite"
    /// `gemini-3.5-flash` — larger, more capable sibling. Pricier, but
    /// in theory more accurate on tricky / accented / noisy audio.
    case flash = "gemini-3.5-flash"

    /// UserDefaults storage key. Persisted as the `rawValue` string; an
    /// unknown stored value decodes to `nil` and the caller falls back
    /// to `.flashLite` (same safe-default shape as `MusicInterruption.Mode`).
    static let userDefaultsKey: String = "notype.geminiModel"

    /// The safe default when nothing is stored or the stored value is
    /// unrecognised.
    static let fallback: GeminiModel = .flashLite

    /// Picker label rendered in Settings → API & Usage.
    var label: String {
        switch self {
        case .flashLite: return "Flash-Lite"
        case .flash:     return "Flash"
        }
    }

    /// Settings row subtitle — what the current selection means. Pure /
    /// static so the Settings pane stays declarative.
    static func subtitle(for model: GeminiModel) -> String {
        switch model {
        case .flashLite:
            return "Gemini 3.1 Flash-Lite — fastest and cheapest. The default, best for everyday dictation."
        case .flash:
            return "Gemini 3.5 Flash — larger, more capable model. Pricier, but may transcribe tricky or accented audio more accurately."
        }
    }
}
