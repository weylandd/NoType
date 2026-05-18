import SwiftUI

/// Pill rendering of the active mic input — matches the design's
/// `.mic-source` element. Green status dot + Auto-detect/device-name
/// mode label + middle-dot separator + device name. Truncates the
/// device segment on overflow so long Bluetooth product names don't
/// push the trailing Change button off-screen.
///
/// Two visual states off the same shape:
///   - Auto-detect — system default mic with BT-avoidance fallback.
///     Mode reads "Auto-detect"; device renders the effective name.
///   - Pinned     — user explicitly chose a mic via the picker.
///     Mode reads "Manual"; device renders the pinned name.
struct MicSourcePill: View {
    let isAutoDetect: Bool
    let deviceName: String

    var body: some View {
        HStack(spacing: DS.Space.s3) {
            Circle()
                .fill(DS.Color.successFg)
                .frame(width: 6, height: 6)
                .shadow(color: DS.Color.statusDotGlow, radius: 3, x: 0, y: 0)

            Text(mode)
                .font(DS.Font.bodySM(.medium))
                .foregroundStyle(DS.Color.textPrimary)
                .layoutPriority(1)

            Text("·")
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textQuaternary)

            Text(deviceName)
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, DS.Space.s3)
        .padding(.trailing, DS.Space.s3 + 2)
        .padding(.vertical, 4)
        .background(
            DS.Color.bgInset,
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode), \(deviceName)")
    }

    private var mode: String { isAutoDetect ? "Auto-detect" : "Manual" }
}
