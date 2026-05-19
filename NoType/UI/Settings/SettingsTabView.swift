import SwiftUI

/// Settings tab root for the redesigned Settings screen.
/// Two-column shell inside the main window's content pane:
///
///   ┌──────────┬────────────────────────────────────────┐
///   │ Settings │ Sticky header: "<title>"  ·  crumb pill │
///   │ ────────│ ────────────────────────────────────────│
///   │ General │                                          │
///   │ Recording│   ScrollView                            │
///   │ Language │     selected pane (one of 5)            │
///   │ API     │       VStack of DSCards                  │
///   │ About   │                                          │
///   └──────────┴────────────────────────────────────────┘
///
/// Five panes: General · Recording · Language & Paste · API & Usage ·
/// About. Cross-pane state (rebind sheets, confirmation dialogs) is
/// owned here so each pane stays a leaf value.
struct SettingsTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(OnboardingState.self) private var onboarding

    @State private var selectedCategory: SettingsCategory = .general

    @State private var showResetConfirm = false
    @State private var showDeleteAllConfirm = false
    @State private var showDeleteAnalyticsConfirm = false
    @State private var showRecordingRebind = false
    @State private var showCancelRebind = false

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selectedCategory)

            VStack(spacing: 0) {
                SettingsContentHeader(
                    title: selectedCategory.label,
                    crumb: selectedCategory.crumb
                )

                ScrollView {
                    pane(for: selectedCategory)
                        .padding(.horizontal, DS.Space.s7 + 4)
                        .padding(.top, DS.Space.s6)
                        .padding(.bottom, DS.Space.s9)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(DS.Color.bgBase)
            }
        }
        .onAppear {
            // SMAppService.mainApp has no KVO/publisher, so refresh
            // whenever the Settings tab appears — picks up changes
            // the user made in System Settings → Login Items without
            // a restart.
            appState.loginItemController.refresh()
            consumePendingCategorySelection()
        }
        // Three triggers (same belt-and-braces shape as MainWindowView's
        // pendingTabSelection consumer): `.onAppear` covers the case
        // where SettingsTabView is freshly mounted, `.onChange` of
        // pendingSettingsCategory covers the case where the user is
        // already on Settings when the flag flips (e.g., HUD click while
        // Settings → General is on-screen).
        .onChange(of: appState.pendingSettingsCategory) { _, new in
            if new != nil { consumePendingCategorySelection() }
        }
        .confirmationDialog(
            "Reopen the onboarding wizard?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reopen") { onboarding.resetWizard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your API key, hotkey, and microphone choice will be preserved.")
        }
        .confirmationDialog(
            "Delete all transcripts?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                appState.deleteAllHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your usage stats (session counts, word totals, token usage, and app breakdown) will be preserved.")
        }
        .confirmationDialog(
            "Delete all analytics?",
            isPresented: $showDeleteAnalyticsConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                appState.deleteAllStats()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Home dashboard counters, per-app breakdown, and Gemini token totals all reset to zero. Your transcripts and settings are kept.")
        }
        .sheet(isPresented: $showRecordingRebind) {
            ShortcutRebindSheet(
                kind: .recording,
                currentBinding: appState.hotkeyBinding,
                onCancel: { showRecordingRebind = false },
                onCapture: { binding in
                    switch appState.applyHotkeyBinding(binding) {
                    case .applied, .noChange:
                        return nil
                    case .rejectedDuringRecording:
                        return "Can't change the recording shortcut while a recording is in flight."
                    case .rejectedCollidesWithCancel:
                        return "This key is already your cancel shortcut — pick a different one."
                    case .rejectedDisallowedKey:
                        return "This key isn't allowed as a recording shortcut."
                    }
                }
            )
        }
        .sheet(isPresented: $showCancelRebind) {
            ShortcutRebindSheet(
                kind: .cancel,
                currentBinding: appState.cancelHotkeyBinding,
                onCancel: { showCancelRebind = false },
                onCapture: { binding in
                    switch appState.applyCancelHotkeyBinding(binding) {
                    case .applied, .noChange:
                        return nil
                    case .rejectedDuringRecording:
                        return "Can't change the cancel shortcut while a recording is in flight."
                    case .rejectedCollidesWithRecordingHotkey:
                        return "This key is already your recording shortcut — pick a different one."
                    case .rejectedDisallowedKey:
                        return "This key isn't allowed as a cancel shortcut."
                    }
                }
            )
        }
    }

    private func consumePendingCategorySelection() {
        selectedCategory = SettingsCategory.consumePendingSelection(
            pending: &appState.pendingSettingsCategory,
            current: selectedCategory
        )
    }

    @ViewBuilder
    private func pane(for category: SettingsCategory) -> some View {
        switch category {
        case .general:
            GeneralPane(onResetOnboarding: { showResetConfirm = true })
        case .recording:
            RecordingPane(
                onChangeRecordingShortcut: { showRecordingRebind = true },
                onChangeCancelShortcut: { showCancelRebind = true }
            )
        case .languagePaste:
            LanguagePastePane(
                onDeleteAllTranscripts: { showDeleteAllConfirm = true },
                onDeleteAllAnalytics: { showDeleteAnalyticsConfirm = true }
            )
        case .apiUsage:
            APIUsagePane()
        case .about:
            AboutPane()
        }
    }
}
