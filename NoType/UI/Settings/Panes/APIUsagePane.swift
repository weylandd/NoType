import SwiftUI

/// API & Usage pane of the redesigned Settings screen. Two cards:
///   1. Gemini API — masked key display + Edit. Backed by the
///      existing `GeminiKeyRow` which now renders as a `DSCardRow`.
///   2. Token usage — range picker + 3 stat cells (Input/Output/Cost).
///      Backed by the existing `TokenStatsPanel`.
///
/// Deltas (+18% vs prev 30d) and the cache-hits header indicator are
/// deferred to TECHDEBT — `StatsStore` would need a prior-period
/// rollup and the Gemini client a per-call cache-hit count first.
struct APIUsagePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            DSCard(title: "Gemini API", meta: "Stored in macOS Keychain") {
                GeminiKeyRow()
            }
            DSCard(title: "Token usage") {
                TokenStatsPanel()
            }
        }
    }
}
