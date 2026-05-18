import SwiftUI

/// Settings tab root. Scrolled-with-headers form per plan §118 —
/// internal sidebar was rejected because the main window is locked
/// at 1080×760 and a second nav rail would steal too much horizontal
/// budget. All 5 sections live in one `ScrollView`:
///
///   General · Shortcuts · Microphone & Audio · API · System
///
/// General section content shipped by U2 (this unit). Subsequent
/// units fill in Shortcuts (U3), Microphone & Audio (U4), API (U6),
/// and System (U7 + U8).
struct SettingsTabView: View {
    @Environment(AppState.self)            private var appState
    @Environment(AppearanceController.self) private var appearance
    @Environment(OnboardingState.self)     private var onboarding
    @Environment(UpdateController.self)    private var updates

    @State private var showResetConfirm = false
    @State private var loginItemBusy = false
    @State private var showDeleteAllConfirm = false
    @State private var showRecordingRebind = false
    @State private var showCancelRebind = false

    var body: some View {
        @Bindable var appState = appState
        @Bindable var appearance = appearance

        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s8) {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary)

                DSSettingsSection(title: "General") {
                    generalSectionBody(
                        appState: appState,
                        appearance: appearance
                    )
                }

                DSSettingsSection(title: "Shortcuts") {
                    shortcutsSectionBody()
                }

                DSSettingsSection(title: "Microphone & Audio") {
                    // Filled by U4 (Mic picker, BT toggle, HAL rewrite invisible to UI)
                    sectionPlaceholder()
                }

                // TODO: when SaaS mode lands, gate this section on userMode.
                // v1 ships BYOK-only; API section renders unconditionally.
                DSSettingsSection(title: "API") {
                    GeminiKeyRow()
                    DSSeparator()
                    TokenStatsPanel()
                }

                DSSettingsSection(title: "System") {
                    systemSectionBody(appState: appState)
                }
            }
            .padding(.horizontal, DS.Space.s6)
            .padding(.top, DS.Space.s6)
            .padding(.bottom, DS.Space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // SMAppService.mainApp has no KVO/publisher, so refresh
            // whenever the Settings tab appears — picks up changes the
            // user made in System Settings → Login Items without a
            // restart.
            appState.loginItemController.refresh()
        }
        .confirmationDialog(
            "Reopen the onboarding wizard?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reopen") {
                onboarding.resetWizard()
            }
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
        .sheet(isPresented: $showRecordingRebind) {
            ShortcutRebindSheet(
                kind: .recording,
                currentBinding: appState.hotkeyBinding,
                onCancel: { showRecordingRebind = false },
                onCapture: { binding in
                    appState.applyHotkeyBinding(binding)
                    return nil
                }
            )
        }
        .sheet(isPresented: $showCancelRebind) {
            ShortcutRebindSheet(
                kind: .cancel,
                currentBinding: appState.cancelHotkeyBinding,
                onCancel: { showCancelRebind = false },
                onCapture: { binding in
                    let result = appState.applyCancelHotkeyBinding(binding)
                    switch result {
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

    // MARK: - General section

    @ViewBuilder
    private func generalSectionBody(
        appState: AppState,
        appearance: AppearanceController
    ) -> some View {
        DSSettingsRow(
            title: "Theme",
            subtitle: "Adaptive follows your macOS appearance."
        ) {
            Picker("", selection: Binding(
                get: { appearance.mode },
                set: { appearance.mode = $0 }
            )) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }

        DSSeparator()

        loginItemRow(appState: appState)

        DSSeparator()

        DSSettingsRow(
            title: "Prevent sleep while recording",
            subtitle: "Keeps macOS awake during long dictation sessions."
        ) {
            Toggle("", isOn: Binding(
                get: { appState.preventSleepDuringRecording },
                set: { appState.preventSleepDuringRecording = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }

        DSSeparator()

        DSSettingsRow(
            title: "Reset onboarding",
            subtitle: "Reopen the first-run wizard. Your API key, hotkey, and microphone choice stay put."
        ) {
            DSSecondaryButton(label: "Reset") {
                showResetConfirm = true
            }
        }
    }

    private func loginItemRow(appState: AppState) -> some View {
        let status = appState.loginItemController.status
        let isOn = status.isEnabled
        return VStack(alignment: .leading, spacing: 0) {
            DSSettingsRow(
                title: "Open NoType at login",
                subtitle: status.requiresApproval
                    ? "Approve NoType in System Settings → Login Items to finish enabling."
                    : "Launch automatically when you sign in to your Mac."
            ) {
                HStack(spacing: DS.Space.s2) {
                    if loginItemBusy {
                        ProgressView()
                            .controlSize(.small)
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
                    .disabled(loginItemBusy)
                }
            }
            if status.requiresApproval {
                HStack(spacing: DS.Space.s2) {
                    Spacer()
                    DSLinkButton(label: "Open Login Items in System Settings") {
                        appState.loginItemController.openLoginItemsSettings()
                    }
                }
                .padding(.horizontal, DS.Space.s4)
                .padding(.bottom, DS.Space.s3)
            }
            if let err = appState.loginItemController.lastError {
                Text(err)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.dangerFg)
                    .padding(.horizontal, DS.Space.s4)
                    .padding(.bottom, DS.Space.s3)
            }
        }
    }

    /// Placeholder body used by sections still pending in this branch.
    private func sectionPlaceholder() -> some View {
        Text("Coming soon.")
            .font(DS.Font.body())
            .foregroundStyle(DS.Color.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DS.Space.s2)
    }

    // MARK: - Shortcuts section (U3 Phase 1)
    //
    // Two rebindable shortcuts + an explanation of how the press /
    // release / double-tap state machine works. Hold+Space lock is a
    // Phase 2 extension — the explanation here covers what actually
    // ships today.

    @ViewBuilder
    private func shortcutsSectionBody() -> some View {
        recordingShortcutRow()
        DSSeparator()
        cancelShortcutRow()
        DSSeparator()
        shortcutsExplanation()
    }

    private func recordingShortcutRow() -> some View {
        DSSettingsRow(
            title: "Recording shortcut",
            subtitle: "Hold to record · double-tap or hold + Space to lock the session."
        ) {
            HStack(spacing: DS.Space.s3) {
                ShortcutPill(binding: appState.hotkeyBinding)
                DSSecondaryButton(label: "Change") {
                    showRecordingRebind = true
                }
                .disabled(appState.recordingState != .idle)
            }
        }
    }

    private func cancelShortcutRow() -> some View {
        DSSettingsRow(
            title: "Cancel shortcut",
            subtitle: "Press this key during a recording to abort without pasting. Default: Escape."
        ) {
            HStack(spacing: DS.Space.s3) {
                ShortcutPill(binding: appState.cancelHotkeyBinding)
                DSSecondaryButton(label: "Change") {
                    showCancelRebind = true
                }
                .disabled(appState.recordingState != .idle)
            }
        }
    }

    private func shortcutsExplanation() -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text("How recording works")
                .font(DS.Font.bodySM(.semibold))
                .foregroundStyle(DS.Color.textPrimary)
            ExplanationBullet(
                heading: "Hold to record",
                text: "Press and hold the recording shortcut, release to finalize and paste."
            )
            ExplanationBullet(
                heading: "Double-tap to lock",
                text: "Tap the shortcut twice within 300 ms to keep recording hands-free. Tap once more to finalize and paste."
            )
            ExplanationBullet(
                heading: "Hold + Space to lock",
                text: "While holding the recording shortcut, press Space to lock the session — release and Space won't type into the focused app. Tap the shortcut to finalize and paste."
            )
            ExplanationBullet(
                heading: "Cancel",
                text: "Press the cancel shortcut at any time to abort the in-flight recording without pasting."
            )
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s3 + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - System section (U7)
    //
    // Paste restore delay (`PasteSettings.restoreDelayMs`) lives in
    // code with a 150 ms default — covers AppKit / Slack / Discord /
    // Terminal. Deliberately NOT surfaced in Settings (too technical
    // for the average user). If a user reports "NoType pastes my old
    // clipboard", the support recipe is to bump the UserDefaults key
    // `notype.pasteRestoreDelayMs` to 200–250 ms manually.

    @ViewBuilder
    private func systemSectionBody(appState: AppState) -> some View {
        OutputLanguagePicker()

        DSSeparator()

        DSSettingsRow(
            title: "Delete all transcripts",
            subtitle: "Removes the last-10 transcripts kept in the menu-bar popover. Stats are preserved."
        ) {
            DSSecondaryButton(label: "Delete all") {
                showDeleteAllConfirm = true
            }
        }

        DSSeparator()

        updatesRow()
    }

    // MARK: - Updates row (U8)
    //
    // Manual "Check for updates" affordance + current-version
    // display. The X chip on the sidebar `UpdateBanner` is the
    // per-version skip surface (`SPUUserUpdateChoice.skip` via
    // `UpdateController.skipThisVersion()`); this button just
    // routes through `SPUUpdater.checkForUpdates()` so users
    // don't have to wait for the 24 h scheduled check.

    private func updatesRow() -> some View {
        DSSettingsRow(
            title: "Updates",
            subtitle: "NoType \(Self.currentVersionString) · Checks automatically every 24 hours."
        ) {
            DSPrimaryButton(
                label: updates.phase == .checking ? "Checking…" : "Check for updates",
                size: .small,
                isLoading: updates.phase == .checking,
                isEnabled: updates.phase != .checking,
                accessibilityLabelOverride: "Check for updates"
            ) {
                updates.checkForUpdates()
            }
        }
    }

    private static var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}

// MARK: - Shortcut row helpers

/// Inline pill rendering a `HotkeyBinding` for the Settings rows.
/// Matches the compact size used in the rebind sheet so the row + the
/// sheet's captured-key chip read as the same surface.
private struct ShortcutPill: View {
    let binding: HotkeyBinding

    var body: some View {
        Text(binding.displayWord)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, DS.Space.s2 + 2)
            .padding(.vertical, 4)
            .background(
                DS.Color.bgSurface,
                in: RoundedRectangle(cornerRadius: DS.Radius.sm)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
            )
            .accessibilityLabel(binding.displayWord)
    }
}

/// Single bullet inside the "How recording works" explanation block.
/// Heading and body wrap on overflow so the section keeps a stable
/// width regardless of localised copy length.
private struct ExplanationBullet: View {
    let heading: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            Text("•")
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(heading)
                    .font(DS.Font.bodySM(.medium))
                    .foregroundStyle(DS.Color.textSecondary)
                Text(text)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
