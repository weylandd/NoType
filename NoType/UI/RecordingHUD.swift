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
private struct LiveSpectrumMeter: View {
    let samplesProvider: @MainActor () -> [Float]

    private let barCount = 38
    /// Bar decay per frame (~30 fps). 0.85 ≈ 12 frames from 1.0→0.15.
    private let levelDecay: Float = 0.85
    /// Peak marker decay. Much slower so the marker visibly lingers at
    /// the bar's high-water mark for ~½ s before catching up.
    private let peakDecay:  Float = 0.98
    private let minBarHeight: CGFloat = 2
    /// Max bar height inside the 36 pt container minus 6 pt vertical
    /// padding (top + bottom = 12) → 24 pt.
    private let maxBarHeight: CGFloat = 24

    @State private var levels: [Float] = []
    @State private var peaks:  [Float] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    barColumn(at: i)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
            .onChange(of: tickKey) { _, _ in updateLevels() }
        }
        .frame(height: 36)
        .background(meterBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if levels.isEmpty {
                levels = Array(repeating: 0, count: barCount)
                peaks  = Array(repeating: 0, count: barCount)
            }
        }
    }

    /// Vertical gradient `bg-inset → bg-canvas` (each at ~70% opacity)
    /// matches the spec — the meter reads as a recessed slot rather than
    /// a flat tile, which the previous solid bg-inset fill no longer did
    /// after the surrounding HUD glass got lighter.
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

    /// Peak-hold marker geometry. Chubbier than the bar and inset on
    /// both sides so it reads as a separate "puck" floating at the
    /// bar's recent high rather than a stripe glued to the column.
    private let peakHeight_:  CGFloat = 2
    private let peakInset:    CGFloat = 0.5
    private let peakRadius:   CGFloat = 1

    private func barColumn(at index: Int) -> some View {
        let level = barHeight(at: index)
        let peak  = peakHeight(at: index)
        return ZStack(alignment: .bottom) {
            // Live bar: top corners 2 pt, bottom flat — sits firmly
            // on the meter's baseline like a column rather than a pill.
            UnevenRoundedRectangle(
                topLeadingRadius: 2,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 2,
                style: .continuous
            )
            .fill(barGradient)
            .frame(height: level)

            // Peak-hold marker: 4 pt-tall rounded puck, narrower than
            // the bar by `peakInset` on each side. Decays much slower
            // than the bar → the puck hangs at the high-water mark
            // while the column drops, then catches up.
            RoundedRectangle(cornerRadius: peakRadius, style: .continuous)
                .fill(DS.Color.accentFg)
                .frame(height: peakHeight_)
                .padding(.horizontal, peakInset)
                .offset(y: -(peak - peakHeight_).clamped(to: 0...maxBarHeight))
                .opacity(peak > minBarHeight ? 0.9 : 0)
        }
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [DS.Color.accentFg, DS.Color.accent],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Stable per-tick key so `.onChange` fires once per frame; using
    /// `ctx.date` directly would re-fire on every body re-eval.
    private var tickKey: Int {
        Int(Date().timeIntervalSinceReferenceDate * 30)
    }

    private func updateLevels() {
        let samples = samplesProvider()
        let fresh = AudioSpectrum.bands(from: samples, bandCount: barCount)
        if levels.count != barCount {
            levels = Array(repeating: 0, count: barCount)
        }
        if peaks.count != barCount {
            peaks = Array(repeating: 0, count: barCount)
        }
        for i in 0..<barCount {
            let f = fresh[i]
            // Bar: instant attack, exponential decay → snappy onsets,
            // smooth falloff.
            levels[i] = max(f, levels[i] * levelDecay)
            // Peak: instant attack to the bar's value, then a much
            // slower decay so the marker visibly hangs.
            peaks[i]  = max(levels[i], peaks[i] * peakDecay)
        }
    }

    private func barHeight(at index: Int) -> CGFloat {
        guard index < levels.count else { return minBarHeight }
        let v = CGFloat(levels[index])
        return max(minBarHeight, v * maxBarHeight)
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
