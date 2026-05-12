import SwiftUI

/// Step 4 — verify the global hotkey works.
///
/// Registers press/release observers on `AppState` that intercept the
/// CGEventTap callback. When set, `handleHotkeyPress` short-circuits
/// before starting a recording session, so pressing Right Option here
/// only flips the visual state and unlocks Continue.
///
/// AX permission is granted by step 2, so the existing `HotkeyMonitor`
/// instance is already installed by the time the user reaches this step.
struct OnboardingHotkeyStep: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(AppState.self)        private var appState

    @State private var isHeld:   Bool = false
    @State private var detected: Bool = false

    var body: some View {
        OnboardingChrome(stepIndex: 4) {
            VStack(spacing: DS.Space.s7) {
                heading
                Keycap(isHeld: isHeld)
                    .padding(.vertical, DS.Space.s4)
                statusLine
            }
        } footer: {
            DSPrimaryButton(
                label: "Continue",
                trailingSystemSymbol: "arrow.right"
            ) {
                if detected { onboarding.goNext() }
            }
            .opacity(detected ? 1.0 : 0.45)
            .disabled(!detected)
        }
        .onAppear {
            appState.onboardingHotkeyPressObserver = {
                isHeld = true
                detected = true
            }
            appState.onboardingHotkeyReleaseObserver = {
                isHeld = false
            }
        }
        .onDisappear {
            appState.onboardingHotkeyPressObserver = nil
            appState.onboardingHotkeyReleaseObserver = nil
        }
    }

    private var heading: some View {
        VStack(spacing: DS.Space.s3) {
            Text("Let's check your shortcut")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Text("Press the Right Option key to verify.")
                .font(DS.Font.bodyMD())
                .foregroundStyle(DS.Color.textSecondary)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if detected {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.successFg)
                Text("Detected — you're set.")
                    .font(DS.Font.bodySM(.medium))
                    .foregroundStyle(DS.Color.successFg)
            }
            .padding(.horizontal, DS.Space.s3 + 2)
            .frame(height: 26)
            .background(DS.Color.successSoft, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(DS.Color.successBorder, lineWidth: DS.Border.hairline)
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else {
            Text("Waiting for ⌥ Right Option…")
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textTertiary)
        }
    }
}

// MARK: - Keycap

private struct Keycap: View {
    let isHeld: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text("⌥")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(isHeld ? DS.Color.accentFg : DS.Color.textSecondary)
            Text("Right Option")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isHeld ? DS.Color.textPrimary : DS.Color.textSecondary)
        }
        .padding(.horizontal, DS.Space.s7)
        .frame(width: 280, height: 96)
        .background(fill, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(border, lineWidth: isHeld ? 1 : DS.Border.hairline)
        )
        .scaleEffect(isHeld ? 0.985 : 1.0)
        .offset(y: isHeld ? 1 : 0)
        .animation(DS.Motion.fast, value: isHeld)
    }

    private var fill: Color {
        isHeld ? DS.Color.accentSoft : DS.Color.bgInset
    }

    private var border: Color {
        isHeld ? DS.Color.accentBorder : DS.Color.borderDefault
    }
}
