import SwiftUI

/// Shared shell for every onboarding step.
///
/// Top bar carries a centered pill-shaped progress indicator (with the
/// step-meta label on the right) and an optional back-arrow on the left.
/// The body slot is centered (max width ~720 pt) inside a scrollable
/// container so small windows don't clip long copy. Each step provides
/// its own primary action via the `footer` slot — pass `EmptyView`
/// (or a clear spacer) when the step renders its CTA inside the body.
struct OnboardingChrome<Body: View, Footer: View>: View {
    @Environment(OnboardingState.self) private var onboarding

    let totalSteps: Int = 5            // Welcome → APIKey → Permissions → MicCheck → Hotkey
    let stepIndex: Int                 // 0-based
    var stepLabel: String? = nil       // e.g. "01 — WELCOME"
    var showBack: Bool = true
    /// Max width of the centered content column. The hotkey step
    /// overrides to ~1000 pt so the full Mac keyboard with `command`
    /// labels fits without clipping.
    var contentMaxWidth: CGFloat = 720

    @ViewBuilder var content: () -> Body
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            topBar
            // ViewThatFits picks the centered variant when the window
            // has enough vertical room (the common case), and falls
            // back to a ScrollView when content would otherwise clip
            // below the fold — important on 13" MacBooks where the
            // permissions step's stack of cards can push the Continue
            // button past the window edge.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    contentColumn
                    Spacer(minLength: 0)
                }
                ScrollView {
                    contentColumn
                }
            }
            footerBar
        }
        .background(DS.Color.bgBase.ignoresSafeArea())
    }

    /// The step body, centered and inset. Extracted so both the
    /// `ViewThatFits` branches above can share the same layout.
    private var contentColumn: some View {
        content()
            .frame(maxWidth: contentMaxWidth)
            .padding(.horizontal, DS.Space.s8)
            .padding(.vertical, DS.Space.s7)
            .frame(maxWidth: .infinity)
    }

    private var topBar: some View {
        ZStack {
            // Centered progress pill — independent of the side slots so
            // it stays perfectly centered no matter how wide they grow.
            progressPill

            HStack(spacing: DS.Space.s3) {
                // Back-arrow corner button. Reserved (with clear color)
                // when hidden so the layout doesn't jump between steps.
                if showBack && stepIndex > 0 {
                    BackCornerButton {
                        onboarding.goBack()
                    }
                } else {
                    Color.clear.frame(width: 56, height: 28)
                }

                Spacer()

                if let stepLabel {
                    Text(stepLabel)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .tracking(0.06 * 10.5)
                        .foregroundStyle(DS.Color.textQuaternary)
                        .textCase(.uppercase)
                } else {
                    // Reserve width so the centered pill doesn't shift
                    // between steps that have a label and ones that don't.
                    Color.clear.frame(width: 1, height: 1)
                }
            }
        }
        .padding(.horizontal, DS.Space.s5)
        .padding(.top, DS.Space.s7)        // 24 — clears the OS stoplights
        .padding(.bottom, DS.Space.s4)
    }

    private var progressPill: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { i in
                ProgressDot(state: dotState(for: i))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            DS.Color.progressPillFill,
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
        .animation(DS.Motion.base, value: stepIndex)
    }

    private func dotState(for i: Int) -> ProgressDot.State {
        if i < stepIndex { return .done }
        if i == stepIndex { return .active }
        return .pending
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            footer()
            Spacer()
        }
        .padding(.bottom, DS.Space.s8)     // 32 — generous so the CTA breathes
    }
}

// MARK: - Progress dot
//
// Single `Capsule` whose width + fill animate between states, so the
// SwiftUI `.animation(_, value: stepIndex)` on the wrapper actually
// runs the morph instead of swapping view identities (which would be
// instant, no animation).

private struct ProgressDot: View {
    enum State { case pending, active, done }
    let state: State

    var body: some View {
        Capsule()
            .fill(fillColor)
            .frame(width: width, height: 6)
            .overlay(
                Capsule()
                    .stroke(DS.Color.accentSoft, lineWidth: state == .active ? 3 : 0)
            )
    }

    private var width: CGFloat { state == .active ? 18 : 6 }

    private var fillColor: Color {
        switch state {
        case .pending: return DS.Color.progressDotPending
        case .done:    return DS.Color.accentFg
        case .active:  return DS.Color.accent
        }
    }
}

// MARK: - Back corner button

private struct BackCornerButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back")
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(hovered ? DS.Color.textPrimary : DS.Color.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                hovered ? DS.Color.bgHover : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .dsOnHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
        .accessibilityLabel("Back")
    }
}
