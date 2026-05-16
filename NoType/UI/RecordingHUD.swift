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

            SpectrumMeter(
                samplesProvider: samplesProvider,
                barCount: 38,
                barSpacing: 2,
                padding: EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4),
                cornerRadius: DS.Radius.md,
                maxBarHeight: 24
            )
            .frame(height: 36)
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

// The live FFT spectrum meter is the shared `SpectrumMeter` view
// (`NoType/UI/SpectrumMeter.swift`). The HUD instantiates it inside its
// `body` with HUD-specific geometry (38 bars, tighter padding, 36 pt
// fixed height); the onboarding mic-check step uses the same component
// at 44 bars + larger padding.
