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
        .dsOnHover { isHovered = $0 }
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
        .dsOnHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
        .accessibilityLabel(label)
    }

    private var box:    CGFloat { size == .standard ? 22 : 20 }
    private var radius: CGFloat { size == .standard ? 6  : 5  }
    private var glyph:  CGFloat { size == .standard ? 11 : 10 }
}

// MARK: - Glyph chip
//
// Severity-tinted square + foreground SF symbol used as the leading
// affordance of every HUD content row (26×26 — recording mic, error
// icon, permission glyph) AND of the onboarding permission rows
// (44×44, larger symbol, hairline border, more rounding). All knobs
// have defaults that preserve the HUD's existing look, so the new
// params only kick in for the onboarding tile callers.
//
// Optional outward-pulse ring for the "live" recording state.

struct DSGlyphChip: View {
    enum Severity { case accent, danger, warning, success, info, neutral }

    let severity: Severity
    let symbol: String              // SF symbol name
    var size: CGFloat = 26
    var cornerRadius: CGFloat = 8
    var symbolSize: CGFloat = 13
    var symbolWeight: SwiftUI.Font.Weight = .semibold
    var showBorder: Bool = false
    var withPulse: Bool = false

    var body: some View {
        let chip = ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(tintFill)
                .frame(width: size, height: size)
            if showBorder {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(tintBorder, lineWidth: DS.Border.hairline)
                    .frame(width: size, height: size)
            }
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: symbolWeight))
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

    private var tintBorder: Color {
        switch severity {
        case .accent:  return DS.Color.accentBorder
        case .danger:  return DS.Color.dangerBorder
        case .warning: return DS.Color.warningBorder
        case .success: return DS.Color.successBorder
        case .info:    return DS.Color.infoBorder
        case .neutral: return DS.Color.borderDefault
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
// Accent-filled / bg-inset pill CTAs. Three sizes — `.small` is the
// existing 24 pt HUD pill; `.medium` is the 28 pt inline CTA used by
// the onboarding PermissionRow Grant / Open Settings buttons; `.large`
// is the 36 pt footer CTA used by every onboarding step's Continue /
// Complete-setup button. Defaults preserve the original HUD shape.

struct DSPrimaryButton: View {
    enum Size { case small, medium, large }

    let label: String
    var size: Size = .small
    var trailingSystemSymbol: String? = nil
    /// When `true`, replaces the trailing symbol with a `ProgressView`.
    /// Combined with `isEnabled == false` to express the "validating…"
    /// state of the API-key step's Continue button.
    var isLoading: Bool = false
    /// When `false`, the button reads-as-disabled (dimmed fill, dropped
    /// inner highlight, no hover / press transforms) AND blocks taps.
    /// Centralises the `accent.opacity(0.4)` + overlay-opacity-0 pattern
    /// the onboarding steps were each re-rolling.
    var isEnabled: Bool = true
    /// Optional explicit `minWidth` — onboarding CTAs use 180 / 200 pt
    /// to give the footer button a stable hit-target across labels.
    var minWidth: CGFloat? = nil
    /// Optional VoiceOver-only label override. When `nil`, `label` is
    /// announced. Set when the visible label changes during the
    /// button's lifecycle (e.g. "Continue" → "Validating") but the
    /// announced identity should stay stable.
    var accessibilityLabelOverride: String? = nil
    let action: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: size.contentSpacing) {
                Text(label)
                    .font(.system(size: size.fontSize, weight: .medium))
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DS.Color.textOnAccent)
                } else if let symbol = trailingSystemSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: size.symbolSize, weight: .semibold))
                }
            }
            .foregroundStyle(DS.Color.textOnAccent)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minWidth: minWidth, minHeight: size.height)
            .background(
                fillColor,
                in: RoundedRectangle(cornerRadius: size.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size.cornerRadius)
                    .stroke(DS.Color.buttonInnerHighlight, lineWidth: DS.Border.hairline)
                    .blendMode(.plusLighter)
                    .opacity(isEnabled ? 1 : 0)
            )
            .offset(y: pressed && isEnabled ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .dsOnHover { hovered = $0 && isEnabled }
        // `.onHover` only fires on cursor enter/leave, so if the parent
        // flips `isEnabled` false → true while the cursor was hovering
        // a disabled button, `hovered` stays true and the re-enabled
        // button snaps straight into `accentHover` fill without a real
        // hover event. Clear it on the disable edge so re-enable starts
        // from the neutral `accent` fill.
        .onChange(of: isEnabled) { _, newValue in
            if !newValue { hovered = false }
        }
        .pressEvents(onPress: { pressed = true }, onRelease: { pressed = false })
        .animation(DS.Motion.fast, value: hovered)
        .animation(DS.Motion.fast, value: isEnabled)
        .accessibilityLabel(accessibilityLabelOverride ?? label)
    }

    private var fillColor: Color {
        if !isEnabled { return DS.Color.accentDisabled }
        return hovered ? DS.Color.accentHover : DS.Color.accent
    }
}

struct DSSecondaryButton: View {
    typealias Size = DSPrimaryButton.Size

    let label: String
    var size: Size = .small
    var leadingSystemSymbol: String? = nil
    var trailingSystemSymbol: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: size.contentSpacing) {
                if let symbol = leadingSystemSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: size.symbolSize, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: size.fontSize, weight: .medium))
                if let symbol = trailingSystemSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: size.symbolSize, weight: .semibold))
                }
            }
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .background(hovered ? DS.Color.bgHover : DS.Color.bgInset,
                        in: RoundedRectangle(cornerRadius: size.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: size.cornerRadius)
                    .strokeBorder(hovered ? DS.Color.borderStrong : DS.Color.borderDefault,
                                  lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .dsOnHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
        .accessibilityLabel(label)
    }
}

extension DSPrimaryButton.Size {
    fileprivate var height: CGFloat {
        switch self {
        case .small:  return 24
        case .medium: return 28
        case .large:  return 36
        }
    }
    fileprivate var horizontalPadding: CGFloat {
        switch self {
        case .small:  return 9
        case .medium: return 12
        case .large:  return 14
        }
    }
    fileprivate var fontSize: CGFloat {
        switch self {
        case .small:  return 11.5
        case .medium: return 12.5
        case .large:  return 14
        }
    }
    fileprivate var symbolSize: CGFloat {
        switch self {
        case .small:  return 11
        case .medium: return 11.5
        case .large:  return 12
        }
    }
    // `.small` and `.medium` share the HUD radius / content-spacing; only
    // `.large` (the onboarding footer CTA) bumps up. Expressed as a
    // boolean rather than three identical switch arms so it's obvious
    // when a future medium-tuning change would need a real third value.
    fileprivate var contentSpacing: CGFloat { self == .large ? 6 : 5 }
    fileprivate var cornerRadius:   CGFloat { self == .large ? 8 : 6 }
}

/// Outline secondary button variant in danger red — same shape as
/// `DSSecondaryButton` but tinted by `DS.Color.dangerFg` /
/// `DS.Color.dangerBorder`. Used for destructive confirms like
/// "Delete all transcripts".
struct DSDestructiveButton: View {
    typealias Size = DSPrimaryButton.Size

    let label: String
    var size: Size = .small
    var leadingSystemSymbol: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: size.contentSpacing) {
                if let symbol = leadingSystemSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: size.symbolSize, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: size.fontSize, weight: .medium))
            }
            .foregroundStyle(DS.Color.dangerFg)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .background(
                hovered ? DS.Color.dangerSoft : .clear,
                in: RoundedRectangle(cornerRadius: size.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size.cornerRadius)
                    .strokeBorder(DS.Color.dangerBorder, lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .dsOnHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
        .accessibilityLabel(label)
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
        .dsOnHover { hovered = $0 }
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
        .dsOnHover { hovered = $0 }
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

// MARK: - Settings section + row
//
// New DS primitives shipped by U1 for the Settings tab's
// scrolled-with-headers form. Justified by the project's
// "If a button/chip/pill appears in 2+ surfaces with the same spec, it
// lives in DSComponents.swift" convention — 5 sections × 4–6 rows each
// is well past the threshold. Visual defaults pulled from existing DS
// tokens (DS.Space, DS.Color, DS.Font, DSSeparator); no hard-coded
// padding / hex / alpha at the call site.
//
// Subsequent units (U2–U8) compose section content via DSSettingsRow,
// passing the trailing control as a `@ViewBuilder` closure.

/// Section block: H2-style label + a body slot. Bodies render as a
/// vertical stack with hairline separators between sibling rows. The
/// body is `@ViewBuilder` so callers can drop `DSSettingsRow`s
/// directly OR mix in custom content (e.g. a description, an extra
/// chip strip) without rewriting the section shell.
struct DSSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Text(title)
                .font(DS.Font.bodyMD(.semibold))
                .foregroundStyle(DS.Color.textPrimary)
                .textCase(.none)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            // bgCanvas is the same subtle recess the sidebar uses —
            // makes section bodies read as a contained card without
            // adding a heavyweight shadow / border treatment.
            .background(
                DS.Color.bgCanvas,
                in: RoundedRectangle(cornerRadius: DS.Radius.md)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Single row inside a `DSSettingsSection`: title (+ optional subtitle
/// for context / explanation) on the leading side, an arbitrary
/// trailing control via `@ViewBuilder`. Layout is a pinned HStack
/// with a `Spacer` so the trailing control always docks right.
///
/// Sibling rows inside one section are separated by a hairline
/// `DSSeparator` automatically (rendered by the section's child
/// laying-out — see `DSSettingsSection.body`'s child-spacing rules).
struct DSSettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.body(.medium))
                    .foregroundStyle(DS.Color.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DS.Font.bodySM())
                        .foregroundStyle(DS.Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.s3)
            trailing()
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s3 + 2)  // 10 pt — comfortable for toggles + slider tracks
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - DSKeycapPill
//
// Shared keycap chrome used by Settings → Recording (shortcut row +
// "How recording works" callout). Two emerging call sites in PR #52
// matched the DS convention's 2+ surfaces rule (UI/CLAUDE.md), so
// the shape lives here instead of duplicated as private structs in
// each pane component.
//
// `style` selects between the dense pill used inline next to a
// "Change" button (.compact, 12 pt mono medium) and the larger
// callout chip (.callout, 12 pt mono regular, taller hit area)
// with no behavioural difference — just per-site visual tuning.

struct DSKeycapPill: View {
    enum Style {
        case compact   // shortcut row keycap (24 pt tall, weight medium)
        case callout   // how-recording-works callout (24+ pt, weight regular)
    }

    let label: String
    var style: Style = .compact

    var body: some View {
        Text(label)
            .font(font)
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, padding)
            .frame(minWidth: minWidth, minHeight: minHeight)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(DS.Color.borderDefault, lineWidth: DS.Border.hairline)
            )
            .accessibilityLabel(label)
    }

    private var font: Font {
        switch style {
        case .compact: return .system(size: 12, weight: .medium, design: .monospaced)
        case .callout: return .system(size: 12, design: .monospaced)
        }
    }

    private var padding: CGFloat {
        style == .callout ? 7 : DS.Space.s2 + 2
    }

    private var minWidth: CGFloat {
        style == .callout ? 24 : 0
    }

    private var minHeight: CGFloat {
        style == .callout ? 24 : 22
    }

    private var background: Color {
        style == .callout ? DS.Color.bgOverlay : DS.Color.bgInset
    }
}

// MARK: - DSCard + DSCardRow
//
// Card chrome for the redesigned Settings screen. Each Settings pane
// (General / Recording / Language & Paste / API & Usage / About)
// stacks one or more DSCards; each card contains a head (title +
// optional meta text) and one or more DSCardRows.
//
// Why a second card family alongside the older DSSettingsSection +
// DSSettingsRow pair: the design moved from a flat scroll-with-headers
// form to a card-grouped two-column shell. The card surface needs a
// proper title bar with optional right-side meta (e.g.
// "Disabled while recording"), a slightly elevated background
// (bg-surface, not bg-canvas), and rows that grow internal hairlines
// between siblings — the older primitive's section title sits OUTSIDE
// the card and has no meta slot. Kept side-by-side rather than
// refactored to avoid disturbing surfaces that already consume the
// old pair.

/// Card-style grouping surface used by every pane of the Settings
/// screen. Provides an optional head row (title + optional meta text
/// floated right), a hairline border at radius 10, and a vertical
/// stack body slot. Rows inside the body are separated by hairlines
/// rendered by the row primitive itself — the card doesn't draw
/// dividers, callers do via `DSCardRow` siblings.
struct DSCard<Content: View>: View {
    var title: String? = nil
    var meta: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                head(title: title, meta: meta)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DS.Color.bgSurface,
            in: RoundedRectangle(cornerRadius: DS.Radius.lg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
    }

    private func head(title: String, meta: String?) -> some View {
        HStack(alignment: .center, spacing: DS.Space.s3) {
            Text(title)
                .font(DS.Font.body(.semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Spacer(minLength: DS.Space.s3)
            if let meta, !meta.isEmpty {
                Text(meta)
                    .font(DS.Font.labelMono())
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Color.textQuaternary)
                    .tracking(0.5)
            }
        }
        .padding(.horizontal, DS.Space.s5 - 2)
        .padding(.top, DS.Space.s4 + 2)
        .padding(.bottom, DS.Space.s2 + 2)
    }
}

/// Single row inside a `DSCard`. Two layouts:
/// - `.row`  (default): title + subtitle on the leading side, trailing
///                      control docked right.
/// - `.col`           : title + subtitle on top, trailing control wraps
///                      below — used for chip arrays and other wide
///                      controls.
///
/// Renders a top-edge hairline so siblings inside one card grow
/// dividers between them. The first row sits flush against the card
/// head; if you need a divider above the very first row, the head's
/// own bottom padding plus the row's top border handle it.
struct DSCardRow<Trailing: View>: View {
    enum Layout { case row, col }

    let title: String
    var subtitle: AttributedString? = nil
    var layout: Layout = .row
    /// When true, suppress the top hairline. Use for the first row of
    /// a card with no head, or when stacking custom blocks that own
    /// their own dividers.
    var hideTopBorder: Bool = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hideTopBorder {
                DS.Color.borderSubtle
                    .frame(height: DS.Border.hairline)
            }
            content
                .padding(.horizontal, DS.Space.s5 - 2)
                .padding(.vertical, DS.Space.s4 + 2)
                .frame(minHeight: 56)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .row:
            HStack(alignment: .center, spacing: DS.Space.s5) {
                meta
                Spacer(minLength: DS.Space.s3)
                trailing()
            }
        case .col:
            VStack(alignment: .leading, spacing: DS.Space.s3 + 2) {
                meta
                trailing()
            }
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(DS.Font.body(.medium))
                .foregroundStyle(DS.Color.textPrimary)
            if let subtitle, subtitle.characters.isEmpty == false {
                Text(subtitle)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension DSCardRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: AttributedString? = nil,
        layout: Layout = .row,
        hideTopBorder: Bool = false
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            layout: layout,
            hideTopBorder: hideTopBorder,
            trailing: { EmptyView() }
        )
    }
}

/// Convenience initializer accepting a plain String subtitle. Most
/// rows have plain copy; AttributedString stays available for rows
/// that need inline bold or accented spans (e.g. Music interruption).
extension DSCardRow {
    init(
        title: String,
        subtitle: String?,
        layout: Layout = .row,
        hideTopBorder: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            title: title,
            subtitle: subtitle.map(AttributedString.init),
            layout: layout,
            hideTopBorder: hideTopBorder,
            trailing: trailing
        )
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

// MARK: - Hover wrapper (macOS-26 executor-check workaround)
//
// `.onHover { hovered = $0 }` written inside a `@MainActor` View body
// inherits the body's `@MainActor` isolation per SE-0420. The closure
// prologue then calls `swift_task_isCurrentExecutorWithFlagsImpl` to
// assert the current executor is `MainActor.shared` before running the
// body. On macOS 26.2 the SerialExecutorRef SwiftUI hands the
// concurrency runtime via `HoverResponder.updatePhase(_:)` carries an
// invalid identity (faulting at `0x1`) — the check reads the
// executor's isa via `swift_getObjectType` and SIGSEGV's.
//
// `@Sendable` strips the inherited isolation so the broken closure
// prologue check is omitted entirely (same mechanic as the audio IOProc
// fix in PR #53 / cd36c48 —
// `solutions/runtime-errors/audio-ioproc-mainactor-inheritance-crash-2026-05-19.md`).
// `Task { @MainActor in ... }` then schedules the `@State` write
// through the Swift task scheduler — different machinery from the
// broken closure-prologue path. The executor reference the scheduler
// builds for the MainActor hop is well-formed, so the hop succeeds
// even on macOS 26.2. The async hop costs ~one frame (~8 ms) of
// latency, imperceptible for hover state — `.animation(value:)`
// already smooths the transition.
//
// We deliberately avoid `MainActor.assumeIsolated` here even though
// `NSHostingView.mouseMoved` empirically runs on the main thread today:
// `assumeIsolated` ultimately calls `_taskIsCurrentExecutor` (the same
// function family as the original crash) and traps unconditionally if
// SwiftUI ever dispatches `.onHover` off-main (drag preview, window
// restore, future macOS versions). The `Task` hop is fail-soft.
//
// Hard rule: every `.onHover` in NoType goes through this wrapper — see
// `NoType/UI/CLAUDE.md` and the solutions doc above.

extension View {
    func dsOnHover(_ action: @escaping @MainActor (Bool) -> Void) -> some View {
        onHover { @Sendable isHovering in
            Task { @MainActor in action(isHovering) }
        }
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
