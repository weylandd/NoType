import SwiftUI

/// Step 4 — microphone check.
///
/// Spins up a `MicProbe` (its own AVAudioEngine, no VAD / Gemini), feeds
/// the trailing samples into the shared `SpectrumMeter` FFT renderer the
/// recording HUD uses, and lets the user pick an input device with the
/// `MicInputPicker` large variant. Continue is always enabled — verifying
/// audio reaches us is a self-check the user does by watching the wave.
struct OnboardingMicCheckStep: View {
    @Environment(OnboardingState.self) private var onboarding
    @State private var probe = MicProbe()

    var body: some View {
        OnboardingChrome(stepIndex: 3, stepLabel: "04 — MICROPHONE") {
            VStack(spacing: DS.Space.s7) {
                headBlock

                MicInputPicker(size: .large)

                waveCard

                continueButton
            }
            .frame(maxWidth: .infinity)
        } footer: {
            Color.clear.frame(height: 8)
        }
        .onAppear { probe.start() }
        .onDisappear { probe.stop() }
    }

    private var headBlock: some View {
        VStack(spacing: 10) {
            Text("Test your microphone")
                .font(.system(size: 34, weight: .medium))
                .tracking(-0.02 * 34)
                .foregroundStyle(DS.Color.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Say something — if you see the waveform reacting, you're good to go. Need a different device? Select it from the dropdown.")
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(DS.Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var waveCard: some View {
        // SpectrumMeter already paints its own gradient + hairline
        // border + clip, so we render it standalone (no outer card).
        SpectrumMeter(
            samplesProvider: { [probe] in
                probe.recentSamples(count: AudioSpectrum.fftLength)
            },
            barCount: 44,
            barSpacing: 3,
            padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
            cornerRadius: DS.Radius.lg,
            maxBarHeight: 70
        )
        .frame(width: 420, height: 100)
    }

    private var continueButton: some View {
        Button(action: { onboarding.goNext() }) {
            HStack(spacing: 6) {
                Text("Continue")
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(DS.Color.textOnAccent)
            .padding(.horizontal, 14)
            .frame(minWidth: 180, minHeight: 36)
            .background(DS.Color.accent, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.18), lineWidth: DS.Border.hairline)
                    .blendMode(.plusLighter)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue")
    }
}
