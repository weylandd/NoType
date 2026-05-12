import SwiftUI

/// Step 1 — welcome.
///
/// Brand mark, headline, and two side-by-side path cards: "Sign in"
/// (disabled, "Coming soon") and "Manual setup" (the only working path
/// in v1, advances to the API-key step).
struct OnboardingWelcomeStep: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        OnboardingChrome(stepIndex: 0) {
            VStack(spacing: DS.Space.s7) {
                // Brand mark + headline
                VStack(spacing: DS.Space.s4) {
                    BrandMark(size: 56)
                    VStack(spacing: DS.Space.s3) {
                        Text("NoType — talk.")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(DS.Color.textPrimary)
                        Text("Hold a key, speak, and your words land at the cursor — anywhere on your Mac.")
                            .font(DS.Font.bodyMD())
                            .foregroundStyle(DS.Color.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }
                }

                // Two path cards
                HStack(spacing: DS.Space.s4) {
                    PathCard(
                        icon: .system("lock.fill"),
                        title: "Sign in",
                        detail: "One tap to start dictating, billing handled for you.",
                        comingSoon: true
                    ) {}

                    PathCard(
                        icon: .system("key.fill"),
                        title: "Manual setup",
                        detail: "Bring your own Gemini key. Free, runs locally.",
                        comingSoon: false
                    ) {
                        onboarding.goNext()
                    }
                }
            }
            .padding(.top, DS.Space.s6)
        } footer: {
            // Welcome's CTAs live on the cards themselves — no global
            // continue button.
            Color.clear.frame(height: 24)
        }
    }
}

// MARK: - Path card

private enum PathCardIcon {
    case system(String)  // SF Symbol
}

private struct PathCard: View {
    let icon: PathCardIcon
    let title: String
    let detail: String
    let comingSoon: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: { if !comingSoon { action() } }) {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                HStack {
                    glyph
                    Spacer()
                    if comingSoon {
                        DSBadge(text: "Coming soon", style: .neutral)
                    } else {
                        DSIcon(
                            name: .arrowRight,
                            size: 16,
                            color: hovered ? DS.Color.accentFg : DS.Color.textTertiary
                        )
                    }
                }
                VStack(alignment: .leading, spacing: DS.Space.s2 + 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary)
                    Text(detail)
                        .font(DS.Font.bodySM())
                        .foregroundStyle(DS.Color.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.s5)
            .frame(width: 220, height: 180, alignment: .topLeading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(borderColor, lineWidth: DS.Border.hairline)
            )
            .opacity(comingSoon ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { if !comingSoon { hovered = $0 } }
        .animation(DS.Motion.fast, value: hovered)
        .help(comingSoon ? "Coming soon" : "Set up with your own Gemini key")
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DS.Color.accentFg)
                .frame(width: 36, height: 36)
                .background(DS.Color.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        }
    }

    private var cardBackground: Color {
        if comingSoon { return DS.Color.bgSurface }
        return hovered ? DS.Color.bgOverlay : DS.Color.bgSurface
    }

    private var borderColor: Color {
        if comingSoon { return DS.Color.borderSubtle }
        return hovered ? DS.Color.accentBorder : DS.Color.borderDefault
    }
}
