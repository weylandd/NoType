import SwiftUI

// MARK: - Separator
// 1 px hairline matching border-subtle token.
// `leading` offset lets callers indent past the icon column.

struct DSSeparator: View {
    var leadingPadding: CGFloat = 0

    var body: some View {
        DS.Color.borderSubtle
            .frame(height: 1)
            .padding(.leading, leadingPadding)
    }
}

// MARK: - Icon button  (22 × 22 px, radius-xs)
// Matches the action buttons spec in the design:
//   - 22 × 22 px container (h-xs)
//   - border-radius: 4 px (radius-xs)
//   - icon 13 px
//   - bg-active fill on hover
//   - destructive variant: danger-fg icon on hover

struct DSIconButton: View {
    let icon: DSIconName
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            DSIcon(name: icon, size: 13, color: iconColor)
                .frame(width: DS.Size.hXS, height: DS.Size.hXS)
                .background(
                    isHovered ? DS.Color.bgActive : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.xs)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.08), value: isHovered)
    }

    private var iconColor: Color {
        if isDestructive && isHovered { return DS.Color.dangerFg }
        return DS.Color.textSecondary
    }
}

// MARK: - Badge  (inline label pill)
// Used for status markers: "Just now", count indicators, etc.

struct DSBadge: View {
    let text: String
    var style: Style = .accent

    enum Style { case accent, neutral, success, warning, danger }

    var body: some View {
        Text(text)
            .font(DS.Font.caption(.medium))
            .textCase(.uppercase)
            .foregroundStyle(foreground)
            .padding(.horizontal, DS.Space.s2 + 1)
            .padding(.vertical, 1)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.xs - 1))
    }

    private var foreground: Color {
        switch style {
        case .accent:   return DS.Color.accentFg
        case .neutral:  return DS.Color.textSecondary
        case .success:  return DS.Color.successBase
        case .warning:  return DS.Color.warningBase
        case .danger:   return DS.Color.dangerFg
        }
    }

    private var background: Color {
        switch style {
        case .accent:   return DS.Color.accentSoft
        case .neutral:  return DS.Color.bgActive
        case .success:  return DS.Color.successBase.opacity(0.15)
        case .warning:  return DS.Color.warningBase.opacity(0.15)
        case .danger:   return DS.Color.dangerBase.opacity(0.15)
        }
    }
}

// MARK: - Kbd badge  (keyboard shortcut keycap)

struct DSKbd: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Font.labelMono())
            .foregroundStyle(DS.Color.textTertiary)
            .padding(.horizontal, DS.Space.s2 + 1)
            .padding(.vertical, DS.Space.s1)
            .background(DS.Color.bgActive, in: RoundedRectangle(cornerRadius: DS.Radius.xs))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.xs)
                    .strokeBorder(DS.Color.borderDefault, lineWidth: DS.Border.hairline)
            )
    }
}

// MARK: - Close button
//
// The standard top-right "x" that lives in every HUD shell. Two sizes:
//   - .standard (22×22, radius 6, 10pt xmark) — recording / error /
//     permission HUDs and the settings sheet.
//   - .compact  (20×20, radius 5,  9pt xmark) — the smaller transcribing
//     HUD only; the spec deliberately scales it down with the surrounding
//     compact layout.

struct DSCloseButton: View {
    enum Size { case standard, compact }

    var size: Size = .standard
    var label: String = "Dismiss"
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            DSIcon(
                name: .x,
                size: glyph,
                color: hovered ? DS.Color.textPrimary : DS.Color.textTertiary
            )
            .frame(width: box, height: box)
            .background(hovered ? DS.Color.bgHover : .clear,
                        in: RoundedRectangle(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
        .accessibilityLabel(label)
    }

    private var box:    CGFloat { size == .standard ? 22 : 20 }
    private var radius: CGFloat { size == .standard ? 6  : 5  }
    private var glyph:  CGFloat { size == .standard ? 11 : 10 }
}

// MARK: - Glyph chip
//
// The 26×26 tinted-square + foreground SF symbol that opens every HUD's
// content row (recording mic, error icon, permission glyph). Optional
// outward-pulse ring for the "live" recording state.

struct DSGlyphChip: View {
    enum Severity { case accent, danger, warning, success, info, neutral }

    let severity: Severity
    let symbol: String              // SF symbol name
    var size: CGFloat = 26
    var withPulse: Bool = false

    var body: some View {
        let chip = ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(tintFill)
                .frame(width: size, height: size)
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tintFg)
        }

        if withPulse {
            ZStack {
                PulseRing(color: pulseColor)
                    .frame(width: size + 6, height: size + 6)
                chip
            }
            .frame(width: size + 6, height: size + 6)
        } else {
            chip
        }
    }

    private var tintFill: Color {
        switch severity {
        case .accent:  return DS.Color.accent.opacity(0.22)
        case .danger:  return DS.Color.dangerBase.opacity(0.18)
        case .warning: return DS.Color.warningSoft
        case .success: return DS.Color.successSoft
        case .info:    return DS.Color.infoSoft
        case .neutral: return DS.Color.bgActive
        }
    }

    private var tintFg: Color {
        switch severity {
        case .accent:  return DS.Color.accentFg
        case .danger:  return DS.Color.dangerFg
        case .warning: return DS.Color.warningFg
        case .success: return DS.Color.successFg
        case .info:    return DS.Color.infoFg
        case .neutral: return DS.Color.textSecondary
        }
    }

    private var pulseColor: Color {
        switch severity {
        case .accent:  return DS.Color.accent.opacity(0.50)
        case .danger:  return DS.Color.dangerBase.opacity(0.50)
        case .warning: return DS.Color.warningBase.opacity(0.50)
        case .success: return DS.Color.successBase.opacity(0.50)
        case .info:    return DS.Color.infoBase.opacity(0.50)
        case .neutral: return DS.Color.borderStrong
        }
    }
}

private struct PulseRing: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(color, lineWidth: 1)
            .scaleEffect(pulse ? 1.20 : 0.92)
            .opacity(pulse ? 0 : 0.9)
            .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - Action buttons (Primary / Secondary)
//
// 24 pt-tall pill CTA used in every HUD's actions row. Primary is the
// accent-filled call to action; Secondary is the bg-inset neutral
// alternative used when there's a backup action next to it.

struct DSPrimaryButton: View {
    let label: String
    var trailingSystemSymbol: String? = nil
    let action: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                if let symbol = trailingSystemSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(DS.Color.textOnAccent)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                hovered ? DS.Color.accentHover : DS.Color.accent,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.white.opacity(0.18), lineWidth: DS.Border.hairline)
                    .blendMode(.plusLighter)
            )
            .offset(y: pressed ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .pressEvents(onPress: { pressed = true }, onRelease: { pressed = false })
        .animation(DS.Motion.fast, value: hovered)
    }
}

struct DSSecondaryButton: View {
    let label: String
    var leadingSystemSymbol: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol = leadingSystemSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(hovered ? DS.Color.bgHover : DS.Color.bgInset,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(hovered ? DS.Color.borderStrong : DS.Color.borderDefault,
                                  lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
    }
}

/// Quiet text-style secondary action ("View logs", "Learn more"). Used
/// alongside `DSPrimaryButton` / `DSSecondaryButton` in HUD action rows.
struct DSLinkButton: View {
    let label: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(hovered ? DS.Color.textPrimary : DS.Color.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(hovered ? DS.Color.bgHover : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
    }
}

// MARK: - Status pill
//
// hXS (22pt) tinted pill used in the popover header to surface the
// active recording / transcribing state. Tone picks the tint stack;
// the content closure provides the inline body so the pill can carry
// a live timer, a spinner, or arbitrary text.

struct DSStatusPill<Content: View>: View {
    enum Tone { case danger, accent, neutral }

    let tone: Tone
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .font(DS.Font.labelMono(.medium))
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, DS.Space.s3)
            .frame(height: DS.Size.hXS)
            .background(fill, in: RoundedRectangle(cornerRadius: DS.Radius.xs))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.xs)
                    .strokeBorder(border, lineWidth: DS.Border.hairline)
            )
    }

    private var fill: Color {
        switch tone {
        case .danger:  return DS.Color.dangerSoft
        case .accent:  return DS.Color.accentSoft
        case .neutral: return DS.Color.bgActive
        }
    }

    private var border: Color {
        switch tone {
        case .danger:  return DS.Color.dangerBorder
        case .accent:  return DS.Color.accentBorder
        case .neutral: return DS.Color.borderDefault
        }
    }
}

// MARK: - Word chip
//
// Small dismissible pill used in the Dictionary tab for each personal-
// dictionary entry. Two visual presets:
//   - .user — filled accent (sticky entries; reads as the user's own)
//   - .auto — bordered neutral (Gemini-extracted; visually softer)
//
// The X-button is laid out at all times (so the chip doesn't shift on
// hover) and is always visible. The remove glyph rests at ~70 % of the
// chip's text colour and brightens to 100 % on hover via `removeColor`,
// so the user always sees it as an affordance without the
// disappear-on-mouse-leave invisibility that other transient rows use.

struct DSWordChip: View {
    enum Style { case user, auto }

    let text: String
    var style: Style = .user
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onRemove) {
                DSIcon(name: .x, size: 10, color: removeColor)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .strokeBorder(border, lineWidth: DS.Border.hairline)
        )
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
    }

    private var background: Color {
        switch style {
        case .user: return DS.Color.accentSoft
        case .auto: return DS.Color.bgInset
        }
    }
    private var border: Color {
        switch style {
        case .user: return DS.Color.accentBorder
        case .auto: return DS.Color.borderSubtle
        }
    }
    private var textColor: Color {
        switch style {
        case .user: return DS.Color.accentFg
        case .auto: return DS.Color.textSecondary
        }
    }
    private var removeColor: Color {
        switch style {
        case .user: return hovered ? DS.Color.accentFg : DS.Color.accentFg.opacity(0.7)
        case .auto: return hovered ? DS.Color.textPrimary : DS.Color.textTertiary
        }
    }
}

// MARK: - Press-events helper

private extension View {
    func pressEvents(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress() }
                .onEnded   { _ in onRelease() }
        )
    }
}

// MARK: - HUD chrome
//
// Shared chrome applied to every floating HUD root: 14 pt rounded
// corners, hairline border, a 1 pt top-edge highlight that fakes the
// spec's `inset 0 1px 0 rgba(255,255,255,0.06)` glass-raise effect, and
// a spring pop-in animation per the design's `hud-in 260 ms
// cubic-bezier(.34, 1.32, .64, 1)`.
//
// Apply to the outer view of any HUD instead of hand-rolling the
// border + highlight + animation. Single source of truth keeps the
// HUD family visually coherent.

extension View {
    func dsHudChrome(cornerRadius: CGFloat = 14) -> some View {
        modifier(DSHudChromeModifier(cornerRadius: cornerRadius))
    }
}

private struct DSHudChromeModifier: ViewModifier {
    let cornerRadius: CGFloat
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            // Top-edge inset highlight — sits above the content but
            // inside the rounded shape via clipShape on the strip.
            // The highlight color is theme-aware (white-on-dark,
            // black-on-light) so the "raised glass" feel works in
            // both appearances.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(DS.Color.glassTopHighlight)
                    .frame(height: 1)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
            // Hairline border.
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(DS.Color.borderDefault, lineWidth: DS.Border.hairline)
            )
            // Pop-in: translucent + slightly scaled down at first frame,
            // then springs into place.
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.97, anchor: .top)
            .onAppear {
                withAnimation(DS.Motion.spring) {
                    appeared = true
                }
            }
    }
}
