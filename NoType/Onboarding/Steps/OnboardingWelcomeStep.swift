import SwiftUI

/// Step 1 — welcome.
///
/// Floating hero mark, large two-tone wordmark, and two stacked path
/// cards. The primary path advances to the API-key step; the secondary
/// "Sign in with NoType" path is disabled and shows a "Coming soon" tag.
struct OnboardingWelcomeStep: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        OnboardingChrome(stepIndex: 0, stepLabel: "01 — WELCOME", showBack: false) {
            VStack(spacing: DS.Space.s7) {
                HeroMark()
                HeroTitle()
                PathStack(onManualTap: { onboarding.goNext() })
            }
            .frame(maxWidth: .infinity)
        } footer: {
            // Welcome's CTAs live on the cards themselves — no global
            // continue button.
            Color.clear.frame(height: 24)
        }
    }
}

// MARK: - Hero mark
//
// The real app icon (`AppIconBadge` pulls `NSApp.applicationIconImage`)
// rendered at 92 pt with a soft drop shadow and the floating animation
// from the design's `floaty` keyframe. Falls back to the synthetic
// `BrandMark` while AppKit is still wiring up the icon image on the
// first frame after launch.

private struct HeroMark: View {
    @State private var floating = false

    var body: some View {
        AppIconBadge(size: 92)
            .shadow(color: DS.Color.accent.opacity(0.30), radius: 30, x: 0, y: 18)
            .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 4)
            .offset(y: floating ? -4 : 0)
            .animation(
                .easeInOut(duration: 3.0).repeatForever(autoreverses: true),
                value: floating
            )
            .onAppear { floating = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Hero title
//
// "No Type. Just talk." — the second clause carries the accent gradient.
// Wraps to two lines on narrow widths (the `&nbsp;` between Just and
// talk is reproduced via a non-breaking space so they stay together).

private struct HeroTitle: View {
    var body: some View {
        let nbsp: String = "\u{00A0}"
        HStack(spacing: 14) {
            Text("No Type.")
                .foregroundStyle(DS.Color.textPrimary)
            Text("Just" + nbsp + "talk.")
                .foregroundStyle(
                    LinearGradient(
                        colors: [DS.Color.textPrimary, DS.Color.accentFg.opacity(0.95)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .font(.system(size: 64, weight: .medium))
        .tracking(-0.035 * 64)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Path stack

private struct PathStack: View {
    let onManualTap: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            PathCard(
                icon: PathCard.Icon.gear,
                title: "Set up using your Gemini API Key",
                isPrimary: true,
                tag: nil,
                action: onManualTap
            )
            PathCard(
                icon: PathCard.Icon.person,
                title: "Sign in with NoType",
                isPrimary: false,
                tag: "(soon)",
                action: nil
            )
        }
        .frame(maxWidth: 420)
        .padding(.top, 2)
    }
}

private struct PathCard: View {
    enum Icon { case gear, person }

    let icon: Icon
    let title: String
    let isPrimary: Bool
    let tag: String?            // non-nil ⇒ disabled
    let action: (() -> Void)?

    @State private var hovered = false

    private var isDisabled: Bool { action == nil || tag != nil }

    var body: some View {
        Button(action: { action?() }) {
            HStack(spacing: 12) {
                pico
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .tracking(-0.01 * 13.5)
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1)
                    if let tag {
                        Text(tag)
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Color.textQuaternary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(arrowColor)
                    .offset(x: hovered && !isDisabled ? 3 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .offset(y: hovered && !isDisabled ? -1 : 0)
            .opacity(isDisabled ? 0.78 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .dsOnHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
        .help(isDisabled ? "Coming soon" : "")
    }

    private var pico: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(picoFill)
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(picoBorder, lineWidth: DS.Border.hairline)
            picoGlyph
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(picoColor)
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private var picoGlyph: some View {
        switch icon {
        case .gear:
            Image(systemName: "gearshape.fill")
        case .person:
            Image(systemName: "person.fill")
        }
    }

    private var cardBackground: AnyShapeStyle {
        if isPrimary {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        DS.Color.accent.opacity(0.24),
                        DS.Color.bgSurface
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        return AnyShapeStyle(DS.Color.bgSurface)
    }

    private var borderColor: Color {
        if isPrimary {
            return hovered ? DS.Color.accent : DS.Color.accentBorder
        }
        if isDisabled {
            return DS.Color.borderDefault
        }
        return hovered ? DS.Color.borderStrong : DS.Color.borderDefault
    }

    private var picoFill: Color {
        isPrimary ? DS.Color.accent : DS.Color.bgInset
    }
    private var picoBorder: Color {
        isPrimary ? .clear : DS.Color.borderSubtle
    }
    private var picoColor: Color {
        isPrimary ? DS.Color.textOnAccent : DS.Color.textSecondary
    }
    private var arrowColor: Color {
        if isDisabled { return DS.Color.textQuaternary }
        if isPrimary  { return DS.Color.textPrimary }
        return DS.Color.textSecondary
    }
}
