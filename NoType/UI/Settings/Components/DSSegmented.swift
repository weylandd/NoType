import SwiftUI

/// Generic segmented picker matching the design's `.seg` element.
/// Track: `bg-inset` background, hairline border, 7 pt radius, 2 pt
/// internal padding. Pressed segment: `bg-overlay` background + xs
/// shadow + inner hairline ring, primary-text colour. Inactive
/// segments: tertiary text colour, hover bumps to primary.
///
/// Polymorphic on the option type so theme pickers, music-
/// interruption pickers, token-range pickers etc. share one shell.
struct DSSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Segment(
                    label: label(option),
                    isPressed: option == selection,
                    onTap: { selection = option }
                )
            }
        }
        .padding(2)
        .background(
            DS.Color.bgInset,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
        // Container-level a11y so VoiceOver reads the group as a
        // segmented picker ("Theme, Adaptive, 3 options") instead of
        // tabbing through three anonymous buttons.
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(label(selection)))
    }
}

private struct Segment: View {
    let label: String
    let isPressed: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(textColor)
                .tracking(-0.05)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(
                    isPressed ? DS.Color.bgOverlay : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            isPressed ? DS.Color.borderSubtle : .clear,
                            lineWidth: DS.Border.hairline
                        )
                )
                .shadow(
                    color: isPressed ? DS.Color.segmentedPressedShadow : .clear,
                    radius: 0, x: 0, y: 1
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsOnHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isPressed ? [.isSelected] : [])
    }

    private var textColor: Color {
        if isPressed { return DS.Color.textPrimary }
        if hovering  { return DS.Color.textPrimary }
        return DS.Color.textTertiary
    }
}
