import SwiftUI

/// Sticky header for the Settings content pane — title on the
/// leading edge, mono breadcrumb pill alongside. Sits as a
/// `safeAreaInset(edge: .top)` above the scrolled pane so it
/// overlays the body with a blurred backdrop instead of scrolling
/// with it.
///
/// The blurred backdrop mimics the design's `backdrop-filter: blur(12px)`
/// by layering a translucent `bg-base` plane over an `.ultraThinMaterial`
/// fill. macOS 15's `.ultraThinMaterial` already does the heavy lifting;
/// the tinted overlay nudges the tone toward the design's 88% bg-base
/// look.
struct SettingsContentHeader: View {
    let title: String
    let crumb: String

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s4) {
            Text(title)
                .font(DS.Font.title(.semibold))
                .foregroundStyle(DS.Color.textPrimary)
                .tracking(-0.2)
            CrumbPill(text: crumb)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s7 + 4)
        .padding(.vertical, DS.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .overlay(DS.Color.headerBackdropTint)
        .overlay(
            DS.Color.borderSubtle.frame(height: DS.Border.hairline),
            alignment: .bottom
        )
    }
}

private struct CrumbPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Font.labelMono())
            .foregroundStyle(DS.Color.textTertiary)
            .tracking(0.3)
            .padding(.horizontal, DS.Space.s2 + 3)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.xs)
                    .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
            )
    }
}
