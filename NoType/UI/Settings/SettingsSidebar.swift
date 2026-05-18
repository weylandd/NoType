import SwiftUI

/// Secondary navigation rail for the redesigned Settings screen.
/// Sits between the primary 220 pt sidebar (Home/Instructions/
/// Dictionary/Settings) and the right-side content pane. Width 200
/// matches the design — narrow enough to leave the content pane
/// breathing room inside the 1180-wide canvas.
///
/// Visual contract: header label "Settings", then 5 nav items
/// (icon + label, 30 pt tall, 6 pt radius). Hover and active states
/// pull from `DS.Color.bgHover` / `DS.Color.bgActive`; the active
/// item also recolours its icon to `DS.Color.accentFg`.
struct SettingsSidebar: View {
    @Binding var selection: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(spacing: 1) {
                ForEach(SettingsCategory.allCases) { category in
                    NavItem(
                        category: category,
                        isActive: selection == category,
                        onTap: { selection = category }
                    )
                }
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.bottom, DS.Space.s5)

            Spacer(minLength: 0)
        }
        .frame(width: 200)
        .background(DS.Color.bgBase)
        .overlay(
            DS.Color.borderSubtle.frame(width: DS.Border.hairline),
            alignment: .trailing
        )
    }

    private var header: some View {
        Text("Settings")
            .font(DS.Font.body(.semibold))
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.top, DS.Space.s5)
            .padding(.bottom, DS.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NavItem: View {
    let category: SettingsCategory
    let isActive: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Space.s3 + 2) {
                DSIcon(name: category.icon, size: 14, color: iconColor)
                Text(category.label)
                    .font(DS.Font.body())
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: 30)
            .background(
                backgroundFill,
                in: RoundedRectangle(cornerRadius: DS.Radius.sm)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(category.label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var backgroundFill: Color {
        if isActive { return DS.Color.bgActive }
        if isHovering { return DS.Color.bgHover }
        return .clear
    }

    private var textColor: Color {
        isActive || isHovering ? DS.Color.textPrimary : DS.Color.textSecondary
    }

    private var iconColor: Color {
        if isActive { return DS.Color.accentFg }
        if isHovering { return DS.Color.textSecondary }
        return DS.Color.textTertiary
    }
}
