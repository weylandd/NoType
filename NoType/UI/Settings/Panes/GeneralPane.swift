import SwiftUI

/// General pane of the redesigned Settings screen. Three cards:
///   1. Appearance — theme picker (Adaptive / Light / Dark).
///   2. Startup & sessions — Login-item toggle + Prevent-sleep toggle.
///   3. Onboarding — Reset onboarding row.
///
/// Pane-level state stays out of view-models per the project
/// convention; bindings reach through `@Environment` services.
/// Dialogs that live across panes (Reset confirmation) are owned by
/// the parent shell and fired through the `onResetOnboarding`
/// callback.
struct GeneralPane: View {
    @Environment(AppState.self)             private var appState
    @Environment(AppearanceController.self) private var appearance

    /// Fired when the user clicks Reset. Parent owns the
    /// confirmation dialog so cross-pane state has one home.
    let onResetOnboarding: () -> Void

    @State private var loginItemBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            appearanceCard
            startupCard
            onboardingCard
        }
    }

    // MARK: - Appearance

    private var appearanceCard: some View {
        DSCard(title: "Appearance") {
            DSCardRow(
                title: "Theme",
                subtitle: "Adaptive follows your macOS appearance."
            ) {
                DSSegmented(
                    options: AppearanceMode.allCases,
                    selection: Binding(
                        get: { appearance.mode },
                        set: { appearance.mode = $0 }
                    ),
                    label: { $0.label }
                )
            }
        }
    }

    // MARK: - Startup & sessions

    private var startupCard: some View {
        DSCard(title: "Startup & sessions") {
            loginItemRow
            preventSleepRow
        }
    }

    private var loginItemRow: some View {
        let status = appState.loginItemController.status
        let isOn = status.isEnabled
        let subtitle = status.requiresApproval
            ? "Approve NoType in System Settings → Login Items to finish enabling."
            : "Launch automatically when you sign in to your Mac."
        return VStack(alignment: .leading, spacing: 0) {
            DSCardRow(title: "Open NoType at login", subtitle: subtitle) {
                HStack(spacing: DS.Space.s2) {
                    if loginItemBusy {
                        ProgressView().controlSize(.small)
                    }
                    Toggle("", isOn: Binding(
                        get: { isOn },
                        set: { newValue in
                            loginItemBusy = true
                            Task { @MainActor in
                                await appState.loginItemController.setEnabled(newValue)
                                loginItemBusy = false
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(DS.Color.accent)
                    .disabled(loginItemBusy)
                }
            }
            if status.requiresApproval {
                HStack(spacing: 0) {
                    Spacer()
                    DSLinkButton(label: "Open Login Items in System Settings") {
                        appState.loginItemController.openLoginItemsSettings()
                    }
                }
                .padding(.horizontal, DS.Space.s5 - 2)
                .padding(.bottom, DS.Space.s3)
            }
            if let err = appState.loginItemController.lastError {
                Text(err)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.dangerFg)
                    .padding(.horizontal, DS.Space.s5 - 2)
                    .padding(.bottom, DS.Space.s3)
            }
        }
    }

    private var preventSleepRow: some View {
        @Bindable var appState = appState
        return DSCardRow(
            title: "Prevent sleep while recording",
            subtitle: "Keeps macOS awake during long dictation sessions."
        ) {
            Toggle("", isOn: $appState.preventSleepDuringRecording)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(DS.Color.accent)
        }
    }

    // MARK: - Onboarding

    private var onboardingCard: some View {
        DSCard(title: "Onboarding") {
            DSCardRow(
                title: "Reset onboarding",
                subtitle: "Reopen the first-run wizard. Your API key, hotkey, and microphone choice stay put."
            ) {
                DSSecondaryButton(
                    label: "Reset",
                    leadingSystemSymbol: "arrow.clockwise",
                    action: onResetOnboarding
                )
            }
        }
    }
}
