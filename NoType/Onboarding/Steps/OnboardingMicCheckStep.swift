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
///
/// Frame updates are driven by a `.task` async loop, **not** by
/// `TimelineView`. On macOS 26 the per-tick re-entry into a
/// `@MainActor`-isolated View instance method (here: `bar(at:)`,
/// `updateLevels()`, the `tickKey` computed property) from inside the
/// `TimelineView` content closure triggered a runtime executor check
/// (`swift_task_isCurrentExecutorWithFlagsImpl` → `objc_opt_class`)
/// that crashed on launch — incident 4838DA5B-…
/// (originally hit by `HistoryRowView.TimestampDisplay` and patched there
/// by inlining + static helpers; this view shipped with the same broken
/// pattern and crashed the tester on the mic-check step of onboarding).
/// A `.task` async loop driving `@State` mutation directly side-steps the
/// TimelineView dispatch path entirely, so no method-boundary executor
/// check fires.
private struct OnboardingSpectrumMeter: View {
    let samplesProvider: @MainActor () -> [Float]

    /// Single source of truth for the bar count. Declared `static let` so
    /// the `@State` initializer for `levels`/`peaks` can reference it —
    /// instance `let`s aren't visible to other instance-property
    /// initializers in Swift, which is what drove the prior `44`/`38`
    /// literal duplication.
    private static let barCount = 44
    /// ~30 fps frame interval for the `.task` driver loop.
    private static let frameInterval: Duration = .milliseconds(33)
    private let levelDecay: Float = 0.85
    private let peakDecay:  Float = 0.98
    private let minBarHeight: CGFloat = 2
    private let maxBarHeight: CGFloat = 56

    @State private var levels: [Float] = Array(repeating: 0, count: Self.barCount)
    @State private var peaks:  [Float] = Array(repeating: 0, count: Self.barCount)

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                OnboardingSpectrumBar(
                    level: max(minBarHeight, CGFloat(levels[i]) * maxBarHeight),
                    peak:  CGFloat(peaks[i]) * maxBarHeight,
                    minBarHeight: minBarHeight,
                    maxBarHeight: maxBarHeight
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(
            LinearGradient(
                colors: [
                    DS.Color.bgInset.opacity(0.8),
                    DS.Color.bgCanvas.opacity(0.6),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .accessibilityHidden(true)
        .task {
            // `.task` auto-cancels when the view disappears (step
            // navigation, window close). No TimelineView, no .onChange —
            // just sample + decay + assign to @State, which re-renders.
            // Read-before-write (`var next… = levels`) is deliberate: we
            // decay against the snapshot SwiftUI last rendered so a slow
            // frame doesn't compound the decay rate.
            while !Task.isCancelled {
                let samples = samplesProvider()
                let fresh = AudioSpectrum.bands(from: samples, bandCount: Self.barCount)
                var nextLevels = levels
                var nextPeaks  = peaks
                for i in 0..<Self.barCount {
                    let f = fresh[i]
                    nextLevels[i] = max(f, nextLevels[i] * levelDecay)
                    nextPeaks[i]  = max(nextLevels[i], nextPeaks[i] * peakDecay)
                }
                levels = nextLevels
                peaks  = nextPeaks
                try? await Task.sleep(for: Self.frameInterval)
            }
        }
    }
}

/// Pure-presentation bar with peak-hold marker. Takes geometry as inputs
/// so the parent can drive it from a frozen snapshot of `@State` without
/// the bar reaching back into `self`.
private struct OnboardingSpectrumBar: View {
    let level: CGFloat
    let peak: CGFloat
    let minBarHeight: CGFloat
    let maxBarHeight: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
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
                .offset(y: -min(max(peak - 2, 0), maxBarHeight))
                .opacity(peak > minBarHeight ? 0.9 : 0)
        }
    }
}
