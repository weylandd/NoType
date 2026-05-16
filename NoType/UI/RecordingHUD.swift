import SwiftUI

/// Floating recording HUD. Mirrors the design's `.rec-hud`:
/// 26 px purple mic with pulse ring, target app name with red blinking dot,
/// mono timer pill, dismiss button, and a 36 px placeholder VU meter row.
struct RecordingHUD: View {
    let startedAt: Date
    let targetAppName: String
    let samplesProvider: @MainActor () -> [Float]
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                DSGlyphChip(severity: .accent, symbol: "mic.fill", withPulse: true)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        BlinkingDot()
                        Text(targetAppName)
                            .font(DS.Font.bodySM(.semibold))
                            .foregroundStyle(DS.Color.textPrimary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TimerPill(startedAt: startedAt)

                // Esc shortcut hint + close button. Visually paired so
                // the user reads them as "press Esc OR click X to cancel".
                HStack(spacing: 4) {
                    Text("Esc")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(DS.Color.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
                        )
                        .accessibilityHidden(true)
                    DSCloseButton(label: "Cancel recording (Esc)", action: onDismiss)
                }
            }

            LiveSpectrumMeter(samplesProvider: samplesProvider)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 11, trailing: 12))
        .frame(width: 300)
        .dsHudChrome()
    }
}

// MARK: - Pieces

private struct BlinkingDot: View {
    @State private var on = true

    var body: some View {
        Circle()
            .fill(DS.Color.dangerBase)
            .frame(width: 6, height: 6)
            .opacity(on ? 1.0 : 0.35)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: on)
            .onAppear { on.toggle() }
    }
}

private struct TimerPill: View {
    let startedAt: Date

    // `format(...)` is static/nonisolated and called via `Self.format` so
    // the per-tick TimelineView body doesn't re-enter @MainActor-isolated
    // dispatch on `self`. See HistoryRowView.TimestampDisplay for the
    // original crash on macOS 26 (incident 4838DA5B-…); same pattern.
    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 0.1)) { ctx in
            Text(Self.format(elapsedFrom: startedAt, to: ctx.date))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(DS.Color.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
                )
        }
    }

    private static func format(elapsedFrom start: Date, to now: Date) -> String {
        let total = max(0, now.timeIntervalSince(start))
        let m = Int(total) / 60
        let s = Int(total) % 60
        let cs = Int((total - floor(total)) * 100)
        return String(format: "%d:%02d.%02d", m, s, cs)
    }
}

/// Live FFT spectrum analyzer. Pulls the trailing 1024 samples from the
/// recorder on each tick (~30 fps), runs a windowed FFT via
/// `AudioSpectrum`, and animates 38 log-spaced bars covering ~100 Hz to
/// 6.4 kHz.
///
/// Each bar carries two animated values:
/// - `level` — the live magnitude. Instant attack, exponential decay so
///   the bar drops fluidly after a transient.
/// - `peak`  — the highest recent magnitude. Same instant attack, but a
///   *much* slower decay — the marker hangs visibly at the top before
///   sliding down, giving the meter the classic "VU peak hold" feel.
///
/// Frame updates are driven by a `.task` async loop, **not** by
/// `TimelineView`. On macOS 26 the per-tick re-entry into a
/// `@MainActor`-isolated View instance method (here: `barColumn(at:)`,
/// `updateLevels()`, the `tickKey` computed property) from inside the
/// `TimelineView` content closure triggered a runtime executor check
/// (`swift_task_isCurrentExecutorWithFlagsImpl` → `objc_opt_class`)
/// that crashed during layout — same pattern that broke
/// `HistoryRowView.TimestampDisplay` (incident 4838DA5B-…) and crashed
/// the tester during onboarding mic-check. A `.task` async loop driving
/// `@State` mutation directly side-steps the TimelineView dispatch path.
private struct LiveSpectrumMeter: View {
    let samplesProvider: @MainActor () -> [Float]

    /// Single source of truth for the bar count. Declared `static let` so
    /// the `@State` initializer for `levels`/`peaks` can reference it —
    /// instance `let`s aren't visible to other instance-property
    /// initializers in Swift.
    private static let barCount = 38
    /// ~30 fps frame interval for the `.task` driver loop.
    private static let frameInterval: Duration = .milliseconds(33)
    /// Bar decay per frame (~30 fps). 0.85 ≈ 12 frames from 1.0→0.15.
    private let levelDecay: Float = 0.85
    /// Peak marker decay. Much slower so the marker visibly lingers at
    /// the bar's high-water mark for ~½ s before catching up.
    private let peakDecay:  Float = 0.98
    private let minBarHeight: CGFloat = 2
    /// Max bar height inside the 36 pt container minus 6 pt vertical
    /// padding (top + bottom = 12) → 24 pt.
    private let maxBarHeight: CGFloat = 24

    @State private var levels: [Float] = Array(repeating: 0, count: Self.barCount)
    @State private var peaks:  [Float] = Array(repeating: 0, count: Self.barCount)

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                LiveSpectrumBar(
                    level: max(minBarHeight, CGFloat(levels[i]) * maxBarHeight),
                    peak:  CGFloat(peaks[i]) * maxBarHeight,
                    minBarHeight: minBarHeight,
                    maxBarHeight: maxBarHeight
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
        .frame(height: 36)
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
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task {
            // `.task` auto-cancels when the HUD goes away. No
            // TimelineView, no .onChange — just sample + decay + assign
            // to @State, which triggers normal SwiftUI re-render.
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
private struct LiveSpectrumBar: View {
    let level: CGFloat
    let peak: CGFloat
    let minBarHeight: CGFloat
    let maxBarHeight: CGFloat

    private let peakThickness: CGFloat = 2
    private let peakInset: CGFloat = 0.5
    private let peakRadius: CGFloat = 1

    var body: some View {
        ZStack(alignment: .bottom) {
            // Live bar: top corners 2 pt, bottom flat — sits firmly
            // on the meter's baseline like a column rather than a pill.
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

            // Peak-hold marker: 2 pt-tall rounded puck, narrower than
            // the bar by `peakInset` on each side. Decays much slower
            // than the bar → the puck hangs at the high-water mark
            // while the column drops, then catches up.
            RoundedRectangle(cornerRadius: peakRadius, style: .continuous)
                .fill(DS.Color.accentFg)
                .frame(height: peakThickness)
                .padding(.horizontal, peakInset)
                .offset(y: -min(max(peak - peakThickness, 0), maxBarHeight))
                .opacity(peak > minBarHeight ? 0.9 : 0)
        }
    }
}
