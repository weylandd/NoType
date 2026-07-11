import SwiftUI

/// Compact follow-up to the recording HUD. Shown between the moment the
/// hotkey is released and the moment text is pasted into the focused app.
///
/// Mirrors the design's `.tx-hud`:
/// - Width is wider than the spec's 220 pt — that literal value cropped
///   "Transcribing…" + a target app name across most non-trivial labels.
///   260 pt fits "Transcribing…" + a typical target name without
///   wrapping while still feeling visibly narrower than the 300 pt
///   recording HUD.
/// - 22 pt accent-tinted spinner box on the left.
/// - "Transcribing…" with an animated dots ellipsis + the target app
///   name in mono.
/// - Close button (X) on the top-right — **dismiss only**, does NOT
///   cancel the in-flight Gemini request. The user just hides the HUD
///   if it's in the way; the transcription continues and pastes when
///   ready. Cancelling isn't useful here because the call is already
///   short-lived.
/// - Indeterminate progress sliver at the bottom edge: a 38% segment
///   that slides edge-to-edge over 1.5 s on loop.
struct TranscribingHUD: View {
    let targetAppName: String
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                SpinnerGlyph()

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AnimatedEllipsisLabel()
                    Text(targetAppName)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DSCloseButton(label: "Hide transcribing window", action: onDismiss)
            }

            IndeterminateProgressBar()
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(width: 260)
        .dsHudChrome()
    }
}

// MARK: - Pieces

private struct SpinnerGlyph: View {
    @State private var spin = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(DS.Color.accent.opacity(0.16))
                .frame(width: 22, height: 22)

            // Ghost ring — full circle at 25 % opacity sitting under the
            // rotating arc, per the spec. Without it the trim arc reads
            // as a "broken" segment instead of a moving sweep around a
            // complete ring.
            Circle()
                .stroke(
                    DS.Color.accentFg.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .frame(width: 14, height: 14)

            // 270° arc (3/4 of a circle) — rotating ring is the most
            // legible "processing" cue at this size.
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(
                    DS.Color.accentFg,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(
                    .linear(duration: 1.1).repeatForever(autoreverses: false),
                    value: spin
                )
        }
        .frame(width: 22, height: 22)
        .onAppear { spin = true }
    }
}

/// "Transcribing" + period count cycling 0→1→2→3 every ~350 ms.
private struct AnimatedEllipsisLabel: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { ctx in
            let n = (Int(ctx.date.timeIntervalSinceReferenceDate * (1.0 / 0.35))) % 4
            HStack(spacing: 0) {
                Text("Transcribing")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(String(repeating: ".", count: n))
                    .frame(width: 12, alignment: .leading)  // reserve space so layout doesn't jitter
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DS.Color.textPrimary)
        }
    }
}

/// Indeterminate progress: a 38%-wide segment translates from -100 % to
/// +280 % of the track width over 1.5 s on infinite loop. The faded
/// gradient on either edge gives it a "scanning" feel rather than a
/// hard pill bouncing back and forth.
private struct IndeterminateProgressBar: View {
    @State private var animating = false
    private let cycle: Double = 1.5

    var body: some View {
        GeometryReader { geo in
            let track = geo.size.width
            let sliverWidth = track * 0.38
            let from = -track
            let to   = track * 1.8

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Color.bgInset)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                DS.Color.accent,
                                DS.Color.accentFg,
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: sliverWidth)
                    .offset(x: animating ? to : from)
                    .animation(
                        .easeInOut(duration: cycle).repeatForever(autoreverses: false),
                        value: animating
                    )
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .onAppear { animating = true }
    }
}
