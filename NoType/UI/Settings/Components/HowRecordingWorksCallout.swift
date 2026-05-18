import SwiftUI

/// "How recording works" callout — the four-bullet grid that explains
/// the press / release / double-tap / hold-Space state machine to
/// new users. Lives inside the Recording pane's third card. Lays out
/// each row as a wide description on the leading edge and a right-
/// aligned keycap combo so all the keys line up vertically regardless
/// of description length.
struct HowRecordingWorksCallout: View {
    var body: some View {
        VStack(spacing: DS.Space.s4) {
            row(
                lead: "Hold to record.",
                rest: "Press and hold, speak, release to insert at the cursor.",
                keys: [.text("⌥")]
            )
            row(
                lead: "Double-tap to lock.",
                rest: "Two quick taps within 300 ms enter hands-free mode — no need to keep holding.",
                keys: [.text("⌥"), .small("×2")]
            )
            row(
                lead: "Hold + Space to lock.",
                rest: "While holding the shortcut, tap Space to latch. Space won't be typed.",
                keys: [.text("⌥"), .plus, .text("space")]
            )
            row(
                lead: "Cancel.",
                rest: "Press the cancel shortcut at any time to drop the session.",
                keys: [.text("esc")]
            )
        }
        .padding(DS.Space.s4 + 2)
        .background(
            DS.Color.calloutSurface,
            in: RoundedRectangle(cornerRadius: DS.Radius.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
        .padding(.horizontal, DS.Space.s5 - 2)
        .padding(.vertical, DS.Space.s4 + 2)
    }

    private func row(
        lead: String,
        rest: String,
        keys: [KeyToken]
    ) -> some View {
        HStack(alignment: .center, spacing: DS.Space.s4) {
            descriptionView(lead: lead, rest: rest)
                .frame(maxWidth: .infinity, alignment: .leading)
            keysView(tokens: keys)
        }
    }

    private func descriptionView(lead: String, rest: String) -> some View {
        // Inline lead phrase in textPrimary medium, rest in
        // textSecondary regular. AttributedString keeps it one Text.
        var s = AttributedString(lead + " ")
        s.foregroundColor = DS.Color.textPrimary
        s.font = DS.Font.bodySM(.medium)
        var tail = AttributedString(rest)
        tail.foregroundColor = DS.Color.textSecondary
        tail.font = DS.Font.bodySM()
        s.append(tail)
        return Text(s)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func keysView(tokens: [KeyToken]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .text(let s):
                    DSKeycapPill(label: s, style: .callout)
                case .small(let s):
                    Text(s)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.Color.textTertiary)
                        .padding(.horizontal, 2)
                case .plus:
                    Text("+")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.Color.textTertiary)
                        .padding(.horizontal, 2)
                }
            }
        }
    }

    enum KeyToken {
        case text(String)
        case small(String)
        case plus
    }
}
