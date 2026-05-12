import SwiftUI

/// Shared shell for every onboarding step.
///
/// Top bar carries the optional back button and the step-pip indicator.
/// The body slot is centered (max width ~520 pt) inside a scrollable
/// container so small windows don't clip long copy. Each step provides
/// its own primary action via the `footer` slot — keeps button enable
/// state and label local to the step.
struct OnboardingChrome<Body: View, Footer: View>: View {
    @Environment(OnboardingState.self) private var onboarding

    let totalSteps: Int = 5  // Welcome → APIKey → Permissions → MicCheck → Hotkey
    let stepIndex: Int       // 0-based

    @ViewBuilder var content: () -> Body
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            ScrollView {
                content()
                    .frame(maxWidth: 520)
                    .padding(.horizontal, DS.Space.s7)
                    .padding(.vertical, DS.Space.s7)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            Spacer(minLength: 0)
            footerBar
        }
        .background(DS.Color.bgBase.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: DS.Space.s3) {
            // Always reserve the back-button slot so the pip indicator
            // doesn't shift between steps.
            ZStack(alignment: .leading) {
                if stepIndex > 0 {
                    DSLinkButton(label: "← Back") {
                        onboarding.goBack()
                    }
                }
            }
            .frame(width: 80, alignment: .leading)

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i <= stepIndex ? DS.Color.accent : DS.Color.borderDefault)
                        .frame(width: i == stepIndex ? 18 : 6, height: 6)
                        .animation(DS.Motion.base, value: stepIndex)
                }
            }

            Spacer()

            // Symmetric spacer matching the back-button column so the
            // pip indicator stays visually centred.
            Color.clear.frame(width: 80, height: 1)
        }
        .padding(.horizontal, DS.Space.s5)
        .padding(.top, DS.Space.s7)        // 24 — clears the OS stoplights
        .padding(.bottom, DS.Space.s4)
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
