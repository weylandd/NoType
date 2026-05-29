import SwiftUI

/// API & Usage pane of the redesigned Settings screen. Three cards:
///   1. Gemini API — masked key display + Edit. Backed by the
///      existing `GeminiKeyRow` which now renders as a `DSCardRow`.
///   2. Transcription model — Flash-Lite / Flash segmented picker
///      (`GeminiModel`). Lets the user A/B transcription quality.
///   3. Token usage — range picker + 3 stat cells (Input/Output/Cost).
///      Backed by the existing `TokenStatsPanel`.
///
/// Deltas (+18% vs prev 30d) and the cache-hits header indicator are
/// deferred to TECHDEBT — `StatsStore` would need a prior-period
/// rollup and the Gemini client a per-call cache-hit count first.
struct APIUsagePane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            DSCard(title: "Gemini API", meta: "Stored in macOS Keychain") {
                GeminiKeyRow()
            }
            modelCard
            DSCard(title: "Token usage") {
                TokenStatsPanel()
            }
        }
    }

    /// Transcription-model picker. `@Bindable` is scoped to this
    /// computed property (mirrors `RecordingPane.inputDeviceCard`) so
    /// the `$appState.geminiModel` binding is available without making
    /// the whole `body` bindable.
    private var modelCard: some View {
        @Bindable var appState = appState
        return DSCard(title: "Transcription model") {
            DSCardRow(
                title: "Model",
                subtitle: AttributedString(GeminiModel.subtitle(for: appState.geminiModel))
            ) {
                DSSegmented(
                    options: GeminiModel.allCases,
                    selection: $appState.geminiModel,
                    label: { $0.label }
                )
            }
        }
    }
}
