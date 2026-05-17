import SwiftUI

/// Step 3 — system permissions.
///
/// One row per permission (Microphone, Accessibility, Screen Recording).
/// Each row carries a severity-tinted 44 pt glyph, the title with a
/// status tag (Required / Optional / Granted / Denied), a short
/// description, and a CTA column on the right (Grant / Open Settings /
/// Granted pill) with a Re-check link beneath. The footnote line below
/// the stack tracks how many required permissions are still missing,
/// and Continue enables only once both required ones are granted.
/// `PermissionsViewModel` polls itself every second while anything is
/// missing, so rows update on their own.
struct OnboardingPermissionsStep: View {
    @Environment(OnboardingState.self)      private var onboarding
    @Environment(PermissionsViewModel.self) private var permissions

    var body: some View {
        OnboardingChrome(stepIndex: 2, stepLabel: "03 — PERMISSIONS") {
            VStack(spacing: DS.Space.s7) {
                Text("Enable required permissions")
                    .font(.system(size: 34, weight: .medium))
                    .tracking(-0.02 * 34)
                    .foregroundStyle(DS.Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                permissionStack
                    .frame(maxWidth: 640)

                VStack(spacing: 14) {
                    footnoteText

                    continueButton
                }
            }
            .frame(maxWidth: .infinity)
        } footer: {
            Text("NoType is open-source and transparent — we prioritize your privacy and local data handling.")
                .font(.system(size: 11.5))
                .lineSpacing(3)
                .foregroundStyle(DS.Color.textQuaternary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            permissions.refresh()
        }
    }

    private var permissionStack: some View {
        VStack(spacing: 8) {
            PermissionRow(
                title: "Microphone",
                detailParts: [
                    .plain("So NoType can hear you. Audio is processed "),
                    .bold("locally"),
                    .plain(" and discarded immediately after transcription — "),
                    .bold("nothing is ever written to disk"),
                    .plain(".")
                ],
                symbol: "mic.fill",
                isRequired: true,
                granted: permissions.microphone.isGranted,
                denied:  permissions.microphone == .denied,
                primary: { Task { await permissions.requestMicrophone() } },
                openSettings: { permissions.openMicrophoneSettings() },
                onRecheck: { permissions.refresh() }
            )

            PermissionRow(
                title: "Accessibility",
                detailParts: [
                    .plain("Allows NoType to detect your shortcut and read the focused app's accessibility tree for context-aware, accurate transcriptions.")
                ],
                symbol: "figure.stand",
                isRequired: true,
                granted: permissions.accessibility.isGranted,
                denied:  permissions.accessibility == .denied,
                primary: { permissions.requestAccessibility() },
                openSettings: { permissions.openAccessibilitySettings() },
                onRecheck: { permissions.refresh() }
            )

            PermissionRow(
                title: "Screen Recording",
                detailParts: [
                    .plain("Boosts accuracy by reading on-screen labels when accessibility data is limited. This is optional and can be enabled later in Settings.")
                ],
                symbol: "rectangle.dashed.badge.record",
                isRequired: false,
                granted: permissions.screenRecording.isGranted,
                denied:  permissions.screenRecording == .denied,
                primary: { Task { await permissions.requestScreenRecording() } },
                openSettings: { permissions.openScreenRecordingSettings() },
                onRecheck: { permissions.refresh() }
            )
        }
    }

    // MARK: - Footnote + Continue

    private var requiredGrantedCount: Int {
        var n = 0
        if permissions.microphone.isGranted    { n += 1 }
        if permissions.accessibility.isGranted { n += 1 }
        return n
    }

    private var footnoteText: some View {
        let msg: String
        switch requiredGrantedCount {
        case 2:  msg = "ALL REQUIRED PERMISSIONS GRANTED — PRESS CONTINUE"
        case 1:  msg = "ONE MORE REQUIRED PERMISSION TO GO"
        default: msg = "ALLOW BOTH REQUIRED PERMISSIONS TO CONTINUE"
        }
        return Text(msg)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .tracking(0.04 * 10.5)
            .foregroundStyle(DS.Color.textQuaternary)
            .animation(DS.Motion.fast, value: requiredGrantedCount)
    }

    private var continueButton: some View {
        let enabled = permissions.allGranted
        return Button(action: {
            if enabled { onboarding.goNext() }
        }) {
            HStack(spacing: 6) {
                Text("Continue")
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(DS.Color.textOnAccent)
            .padding(.horizontal, 14)
            .frame(minWidth: 180, minHeight: 36)
            .background(
                enabled ? DS.Color.accent : DS.Color.accent.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.18), lineWidth: DS.Border.hairline)
                    .blendMode(.plusLighter)
                    .opacity(enabled ? 1 : 0)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Continue")
    }
}

// MARK: - Permission row

private struct PermissionRow: View {
    enum DetailPart {
        case plain(String)
        case bold(String)
    }

    let title: String
    let detailParts: [DetailPart]
    let symbol: String
    let isRequired: Bool
    let granted: Bool
    let denied: Bool
    let primary: () -> Void
    let openSettings: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            glyph

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(-0.005 * 14.5)
                        .foregroundStyle(DS.Color.textPrimary)
                    StatusTag(state: tagState)
                }
                Text(detailString)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ctaColumn
                .frame(minWidth: 168, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(rowBorder, lineWidth: 1)
        )
        .animation(DS.Motion.base, value: granted)
        .animation(DS.Motion.base, value: denied)
    }

    // MARK: visual states

    private var tagState: StatusTag.State {
        if granted { return .granted }
        if denied  { return .denied }
        return isRequired ? .required : .optional
    }

    private var glyphSeverity: GlyphSeverity {
        if granted { return .success }
        if denied  { return .danger }
        return isRequired ? .warning : .neutral
    }

    private var rowBackground: AnyShapeStyle {
        if denied {
            return AnyShapeStyle(DS.Color.dangerSoft.opacity(0.4))
        }
        return AnyShapeStyle(DS.Color.bgSurface)
    }

    private var rowBorder: Color {
        if granted { return DS.Color.successBorder }
        if denied  { return DS.Color.dangerBorder }
        return DS.Color.borderDefault
    }

    // MARK: glyph

    @ViewBuilder
    private var glyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(glyphFill)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(glyphBorder, lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(glyphFg)
        }
        .frame(width: 44, height: 44)
    }

    private var glyphFill: Color {
        switch glyphSeverity {
        case .success: return DS.Color.successSoft
        case .danger:  return DS.Color.dangerSoft
        case .warning: return DS.Color.warningSoft
        case .neutral: return DS.Color.bgInset
        }
    }

    private var glyphBorder: Color {
        switch glyphSeverity {
        case .success: return DS.Color.successBorder
        case .danger:  return DS.Color.dangerBorder
        case .warning: return DS.Color.warningBorder
        case .neutral: return DS.Color.borderDefault
        }
    }

    private var glyphFg: Color {
        switch glyphSeverity {
        case .success: return DS.Color.successFg
        case .danger:  return DS.Color.dangerFg
        case .warning: return DS.Color.warningFg
        case .neutral: return DS.Color.textTertiary
        }
    }

    // MARK: detail

    private var detailString: AttributedString {
        var attr = AttributedString()
        for part in detailParts {
            switch part {
            case .plain(let s):
                attr += AttributedString(s)
            case .bold(let s):
                var run = AttributedString(s)
                run.font = .system(size: 12.5, weight: .semibold)
                run.foregroundColor = DS.Color.textPrimary
                attr += run
            }
        }
        return attr
    }

    // MARK: CTA

    @ViewBuilder
    private var ctaColumn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if granted {
                grantedPill
            } else if denied {
                Button(action: openSettings) {
                    ctaLabel("Open Settings", style: .secondary)
                }
                .buttonStyle(.plain)
                RecheckLink(action: onRecheck)
            } else {
                Button(action: primary) {
                    ctaLabel("Grant", style: isRequired ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                RecheckLink(action: onRecheck)
            }
        }
    }

    private var grantedPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
            Text("Granted")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(DS.Color.successFg)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(DS.Color.successSoft, in: Capsule())
        .overlay(
            Capsule().strokeBorder(DS.Color.successBorder, lineWidth: DS.Border.hairline)
        )
    }

    private enum CtaStyle { case primary, secondary }

    private func ctaLabel(_ text: String, style: CtaStyle) -> some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
        }
        .foregroundStyle(style == .primary ? DS.Color.textOnAccent : DS.Color.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            style == .primary ? AnyShapeStyle(DS.Color.accent) : AnyShapeStyle(DS.Color.bgInset),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    style == .primary ? Color.white.opacity(0.18) : DS.Color.borderDefault,
                    lineWidth: DS.Border.hairline
                )
                .blendMode(style == .primary ? .plusLighter : .normal)
        )
    }
}

// MARK: - Severity

private enum GlyphSeverity { case warning, neutral, success, danger }

// MARK: - Status tag

private struct StatusTag: View {
    enum State { case required, optional, granted, denied }
    let state: State

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .tracking(0.04 * 10.5)
                .textCase(.uppercase)
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(bg, in: Capsule())
        .overlay(
            Capsule().strokeBorder(border, lineWidth: DS.Border.hairline)
        )
    }

    private var label: String {
        switch state {
        case .required: return "Required"
        case .optional: return "Optional"
        case .granted:  return "Granted"
        case .denied:   return "Denied"
        }
    }

    private var textColor: Color {
        switch state {
        case .required: return DS.Color.warningFg
        case .optional: return DS.Color.textTertiary
        case .granted:  return DS.Color.successFg
        case .denied:   return DS.Color.dangerFg
        }
    }

    private var dotColor: Color {
        switch state {
        case .required: return DS.Color.warningFg
        case .optional: return DS.Color.textQuaternary
        case .granted:  return DS.Color.successFg
        case .denied:   return DS.Color.dangerFg
        }
    }

    private var bg: Color {
        switch state {
        case .required: return DS.Color.warningSoft
        case .optional: return DS.Color.bgBase
        case .granted:  return DS.Color.successSoft
        case .denied:   return DS.Color.dangerSoft
        }
    }

    private var border: Color {
        switch state {
        case .required: return DS.Color.warningBorder
        case .optional: return DS.Color.borderSubtle
        case .granted:  return DS.Color.successBorder
        case .denied:   return DS.Color.dangerBorder
        }
    }
}

// MARK: - Re-check link

private struct RecheckLink: View {
    let action: () -> Void
    @State private var hovered = false
    @State private var spinning = false

    var body: some View {
        Button(action: {
            guard !spinning else { return }
            spinning = true
            action()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                spinning = false
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(
                        spinning
                            ? .linear(duration: 0.7).repeatForever(autoreverses: false)
                            : .default,
                        value: spinning
                    )
                Text("Re-check")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(
                spinning ? DS.Color.accentFg
                         : (hovered ? DS.Color.textPrimary : DS.Color.textTertiary)
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
        .accessibilityLabel("Re-check permission")
    }
}
