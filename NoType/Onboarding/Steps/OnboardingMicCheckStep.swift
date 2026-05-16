import SwiftUI

/// Step 3 — microphone check.
///
/// Spins up a `MicProbe` (own AVAudioEngine, no VAD/Gemini), feeds the
/// trailing samples into the same FFT renderer the recording HUD uses,
/// and lets the user pick an input device with the shared
/// `MicInputPicker`. Continue is always enabled — verifying audio
/// reaches us is a self-check the user does by watching the wave move.
struct OnboardingMicCheckStep: View {
    @Environment(OnboardingState.self) private var onboarding
    @State private var probe = MicProbe()

    var body: some View {
        OnboardingChrome(stepIndex: 3) {
            VStack(spacing: DS.Space.s7) {
                heading

                VStack(spacing: DS.Space.s5) {
                    SpectrumMeter(
                        samplesProvider: { [probe] in
                            probe.recentSamples(count: AudioSpectrum.fftLength)
                        },
                        barCount: 44,
                        barSpacing: 3,
                        padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12),
                        cornerRadius: DS.Radius.md,
                        maxBarHeight: 56
                    )
                    .frame(width: 360, height: 80)

                    MicInputPicker()
                }
            }
        } footer: {
            DSPrimaryButton(
                label: "Continue",
                trailingSystemSymbol: "arrow.right"
            ) {
                onboarding.goNext()
            }
        }
        .onAppear { probe.start() }
        .onDisappear { probe.stop() }
    }

    private var heading: some View {
        VStack(spacing: DS.Space.s3) {
            Text("Let's check your microphone")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Text("Say something — do you see the wave reacting?")
                .font(DS.Font.bodyMD())
                .foregroundStyle(DS.Color.textSecondary)
        }
    }
}

// The 360 × 80 onboarding spectrum is rendered by the shared
// `SpectrumMeter` view (`NoType/UI/SpectrumMeter.swift`). The recording
// HUD uses the same component with a smaller bar count and tighter
// padding.
