import SwiftUI

/// Live FFT spectrum meter shared by the recording HUD and the onboarding
/// mic-check step. The bar geometry (count, spacing, height, padding,
/// corner radius) is caller-supplied; everything else (decay envelope,
/// peak-hold puck geometry, background, border, bar gradient) is shared
/// so the two surfaces stay visually consistent.
///
/// Frame updates are driven by a `.task` async loop, **not** by
/// `TimelineView`. On macOS 26 the per-tick re-entry into a
/// `@MainActor`-isolated View instance method from inside a TimelineView
/// content closure triggers a runtime executor check
/// (`swift_task_isCurrentExecutorWithFlagsImpl` → `objc_opt_class`) that
/// crashes during layout — see
/// `docs/solutions/runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md`
/// for the full pattern. A `.task` async loop driving `@State` mutation
/// directly side-steps the TimelineView dispatch path.
@MainActor
struct SpectrumMeter: View {
    let samplesProvider: @MainActor () -> [Float]
    let barCount: Int
    let barSpacing: CGFloat
    let padding: EdgeInsets
    let cornerRadius: CGFloat
    let maxBarHeight: CGFloat

    /// ~30 fps frame interval for the `.task` driver loop.
    private static let frameInterval: Duration = .milliseconds(33)
    /// Bar decay per frame. 0.85 ≈ 12 frames from 1.0→0.15.
    private static let levelDecay: Float = 0.85
    /// Peak-marker decay. Much slower so the marker visibly lingers at
    /// the bar's high-water mark for ~½ s before catching up.
    private static let peakDecay: Float = 0.98
    private static let minBarHeight: CGFloat = 2

    @State private var levels: [Float]
    @State private var peaks: [Float]

    init(
        samplesProvider: @escaping @MainActor () -> [Float],
        barCount: Int,
        barSpacing: CGFloat,
        padding: EdgeInsets,
        cornerRadius: CGFloat,
        maxBarHeight: CGFloat
    ) {
        self.samplesProvider = samplesProvider
        self.barCount = barCount
        self.barSpacing = barSpacing
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.maxBarHeight = maxBarHeight
        // @State init runs once per view identity. `barCount` is a `let`
        // on the struct and never changes mid-session for either call
        // site, so the array stays at the right length for the lifetime
        // of the meter.
        _levels = State(initialValue: Array(repeating: 0, count: barCount))
        _peaks  = State(initialValue: Array(repeating: 0, count: barCount))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                SpectrumBar(
                    level: max(Self.minBarHeight, CGFloat(levels[i]) * maxBarHeight),
                    peak: CGFloat(peaks[i]) * maxBarHeight,
                    minBarHeight: Self.minBarHeight,
                    maxBarHeight: maxBarHeight
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(padding)
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
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task {
            // `.task` auto-cancels when the view disappears. No
            // TimelineView, no .onChange — just sample + decay + assign
            // to @State, which triggers normal SwiftUI re-render.
            // Read-before-write (`var next… = levels`) is deliberate: we
            // decay against the snapshot SwiftUI last rendered so a slow
            // frame doesn't compound the decay rate.
            while !Task.isCancelled {
                let samples = samplesProvider()
                let fresh = AudioSpectrum.bands(from: samples, bandCount: barCount)
                var nextLevels = levels
                var nextPeaks  = peaks
                for i in 0..<barCount {
                    let f = fresh[i]
                    nextLevels[i] = max(f, nextLevels[i] * Self.levelDecay)
                    nextPeaks[i]  = max(nextLevels[i], nextPeaks[i] * Self.peakDecay)
                }
                levels = nextLevels
                peaks  = nextPeaks
                try? await Task.sleep(for: Self.frameInterval)
            }
        }
    }
}

/// Pure-presentation bar with peak-hold puck. The parent owns the live
/// magnitude and peak value as `@State` and passes a frozen snapshot in
/// per frame so the bar never reaches back into the parent.
///
/// Puck geometry (2 pt thick, 0.5 pt inset on each side, 1 pt corner
/// radius) is fixed across both surfaces — only the parent's bar height
/// scale and spacing differ.
private struct SpectrumBar: View {
    let level: CGFloat
    let peak: CGFloat
    let minBarHeight: CGFloat
    let maxBarHeight: CGFloat

    private let peakThickness: CGFloat = 2
    private let peakInset: CGFloat = 0.5
    private let peakRadius: CGFloat = 1

    var body: some View {
        ZStack(alignment: .bottom) {
            // Live bar: top corners 2 pt, bottom flat — sits firmly on
            // the meter's baseline like a column rather than a pill.
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

            // Peak-hold marker. Decays much slower than the bar → the
            // puck hangs at the high-water mark while the column drops,
            // then catches up.
            RoundedRectangle(cornerRadius: peakRadius, style: .continuous)
                .fill(DS.Color.accentFg)
                .frame(height: peakThickness)
                .padding(.horizontal, peakInset)
                .offset(y: -min(max(peak - peakThickness, 0), maxBarHeight))
                .opacity(peak > minBarHeight ? 0.9 : 0)
        }
    }
}
