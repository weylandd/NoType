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
                    OnboardingSpectrumMeter(samplesProvider: { [probe] in
                        probe.recentSamples(count: AudioSpectrum.fftLength)
                    })
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

// MARK: - Spectrum meter

/// Slimmer port of `LiveSpectrumMeter` from the recording HUD. Same FFT,
/// same animation envelope, sized for the centered 360 × 80 onboarding
/// slot.
private struct OnboardingSpectrumMeter: View {
    let samplesProvider: @MainActor () -> [Float]

    private let barCount = 44
    private let levelDecay: Float = 0.85
    private let peakDecay:  Float = 0.98
    private let minBarHeight: CGFloat = 2
    private let maxBarHeight: CGFloat = 56

    @State private var levels: [Float] = []
    @State private var peaks:  [Float] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    bar(at: i)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .onChange(of: tickKey) { _, _ in updateLevels() }
        }
        .background(meterBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .onAppear {
            if levels.isEmpty {
                levels = Array(repeating: 0, count: barCount)
                peaks  = Array(repeating: 0, count: barCount)
            }
        }
    }

    private var meterBackground: some View {
        LinearGradient(
            colors: [
                DS.Color.bgInset.opacity(0.8),
                DS.Color.bgCanvas.opacity(0.6),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func bar(at index: Int) -> some View {
        let level = barHeight(at: index)
        let peak  = peakHeight(at: index)
        return ZStack(alignment: .bottom) {
            UnevenRoundedRectangle(
                topLeadingRadius: 2,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 2,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [DS.Color.accentFg, DS.Color.accent],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: level)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(DS.Color.accentFg)
                .frame(height: 2)
                .padding(.horizontal, 0.5)
                .offset(y: -(peak - 2).clamped(to: 0...maxBarHeight))
                .opacity(peak > minBarHeight ? 0.9 : 0)
        }
    }

    private var tickKey: Int {
        Int(Date().timeIntervalSinceReferenceDate * 30)
    }

    private func updateLevels() {
        let samples = samplesProvider()
        let fresh = AudioSpectrum.bands(from: samples, bandCount: barCount)
        if levels.count != barCount { levels = Array(repeating: 0, count: barCount) }
        if peaks.count  != barCount { peaks  = Array(repeating: 0, count: barCount) }
        for i in 0..<barCount {
            let f = fresh[i]
            levels[i] = max(f, levels[i] * levelDecay)
            peaks[i]  = max(levels[i], peaks[i] * peakDecay)
        }
    }

    private func barHeight(at index: Int) -> CGFloat {
        guard index < levels.count else { return minBarHeight }
        return max(minBarHeight, CGFloat(levels[index]) * maxBarHeight)
    }

    private func peakHeight(at index: Int) -> CGFloat {
        guard index < peaks.count else { return 0 }
        return CGFloat(peaks[index]) * maxBarHeight
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
