import SwiftUI

/// Step 2 — system permissions.
///
/// One row per permission (Microphone, Accessibility) with a chip that
/// flips from warning → success as the user grants. The Continue CTA
/// enables when both are granted. `PermissionsViewModel` polls itself
/// every second while anything is missing, so the rows update on their
/// own; the per-row "Re-check" link is a manual fallback for the rare
/// case where polling stalls.
struct OnboardingPermissionsStep: View {
    @Environment(OnboardingState.self)      private var onboarding
    @Environment(PermissionsViewModel.self) private var permissions

    var body: some View {
        OnboardingChrome(stepIndex: 2) {
            VStack(alignment: .leading, spacing: DS.Space.s7) {
                heading

                VStack(spacing: DS.Space.s4) {
                    PermissionRow(
                        title: "Microphone",
                        detail: "NoType records your voice while you hold ⌥ Right Option. Recording stops the moment you let go and audio never touches the disk.",
                        symbol: "mic.fill",
                        granted: permissions.microphone.isGranted,
                        denied:  permissions.microphone == .denied,
                        isOptional: false,
                        primary: { Task { await permissions.requestMicrophone() } },
                        openSettings: { permissions.openMicrophoneSettings() },
                        onRecheck: { permissions.refresh() }
                    )

                    PermissionRow(
                        title: "Accessibility",
                        detail: "Two things at once: catching the global ⌥ Right Option hotkey from any app, and reading the on-screen accessibility tree so Gemini knows which app you're in and gets your jargon right.",
                        symbol: "figure.stand",
                        granted: permissions.accessibility.isGranted,
                        denied:  permissions.accessibility == .denied,
                        isOptional: false,
                        primary: { permissions.requestAccessibility() },
                        openSettings: { permissions.openAccessibilitySettings() },
                        onRecheck: { permissions.refresh() }
                    )

                    PermissionRow(
                        title: "Screen Recording",
                        detail: "Optional. Lets NoType read on-screen text from apps that don't expose it via accessibility — Slack, Discord, browsers, Notion. We only OCR the active window when needed, never store screenshots, and scrub passwords / tokens / cards before anything reaches Gemini. You can skip this and grant later.",
                        symbol: "camera.viewfinder",
                        granted: permissions.screenRecording.isGranted,
                        denied:  permissions.screenRecording == .denied,
                        isOptional: true,
                        primary: { Task { await permissions.requestScreenRecording() } },
                        openSettings: { permissions.openScreenRecordingSettings() },
                        onRecheck: { permissions.refresh() }
                    )
                }
            }
        } footer: {
            DSPrimaryButton(
                label: "Continue",
                trailingSystemSymbol: "arrow.right"
            ) {
                if permissions.allGranted {
                    onboarding.goNext()
                }
            }
            .opacity(permissions.allGranted ? 1.0 : 0.45)
            .disabled(!permissions.allGranted)
        }
        .onAppear {
            permissions.refresh()
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Text("Grant two permissions")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Text("Both are required for NoType to work. They're requested once and the system remembers your answer — you can revoke either in System Settings → Privacy & Security at any time.")
                .font(DS.Font.bodyMD())
                .foregroundStyle(DS.Color.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Row

private struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let denied: Bool
    /// Optional permissions render a neutral chip (not warning) when
    /// ungranted, so they don't look like a blocking item. They also
    /// show an "Optional" pill next to the title.
    let isOptional: Bool
    let primary: () -> Void
    let openSettings: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s4) {
            DSGlyphChip(
                severity: granted ? .success : (isOptional ? .neutral : .warning),
                symbol: symbol
            )
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: DS.Space.s2 + 2) {
                HStack(spacing: DS.Space.s2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary)
                    if isOptional && !granted {
                        Text("Optional")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DS.Color.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DS.Color.bgInset, in: Capsule())
                    }
                }
                Text(detail)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                actionButton
                if !granted {
                    DSLinkButton(label: "Re-check", action: onRecheck)
                }
            }
            .padding(.top, 1)
        }
        .padding(DS.Space.s4 + 2)
        .background(DS.Color.bgSurface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
    }

    @ViewBuilder
    private var actionButton: some View {
        if granted {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.successFg)
                Text("Granted")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Color.successFg)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(DS.Color.successSoft, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(DS.Color.successBorder, lineWidth: DS.Border.hairline)
            )
        } else if denied {
            DSSecondaryButton(label: "Open Settings", action: openSettings)
        } else {
            DSPrimaryButton(label: "Grant", action: primary)
        }
    }
}
