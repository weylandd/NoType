import SwiftUI

/// Settings tab root. Scrolled-with-headers form per plan §118 —
/// internal sidebar was rejected because the main window is locked
/// at 1080×760 and a second nav rail would steal too much horizontal
/// budget. All 5 sections live in one `ScrollView`:
///
///   General · Shortcuts · Microphone & Audio · API · System
///
/// Section content is filled in by subsequent implementation units
/// (U2 General, U3 Shortcuts, U4 Microphone & Audio, U6 API, U7 + U8
/// System). This unit (U1) ships the scaffold + section headers
/// only — every section currently renders as an empty placeholder.
struct SettingsTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s8) {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary)

                DSSettingsSection(title: "General") {
                    // Filled by U2 (Theme, Open on login, Prevent sleep, Reset onboarding)
                    sectionPlaceholder()
                }

                DSSettingsSection(title: "Shortcuts") {
                    // Filled by U3 (Hotkey binding, Recording mode, Cancel shortcut)
                    sectionPlaceholder()
                }

                DSSettingsSection(title: "Microphone & Audio") {
                    // Filled by U4 (Mic picker, BT toggle, HAL rewrite invisible to UI)
                    sectionPlaceholder()
                }

                // TODO: when SaaS mode lands, gate this section on userMode.
                // v1 ships BYOK-only; API section renders unconditionally.
                DSSettingsSection(title: "API") {
                    // Filled by U6 (Gemini key + Edit modal, Token stats panel)
                    sectionPlaceholder()
                }

                DSSettingsSection(title: "System") {
                    // Filled by U7 (Output language, Delete all transcripts, Paste delay)
                    // and U8 (Version + Check for updates button).
                    sectionPlaceholder()
                }
            }
            .padding(.horizontal, DS.Space.s6)
            .padding(.top, DS.Space.s6)
            .padding(.bottom, DS.Space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Temporary placeholder body. Each section overrides this with
    /// real content as subsequent units land.
    private func sectionPlaceholder() -> some View {
        Text("Coming soon.")
            .font(DS.Font.body())
            .foregroundStyle(DS.Color.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DS.Space.s2)
    }
}
