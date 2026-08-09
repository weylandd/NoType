import AppKit
import SwiftUI

// MARK: - DS (Design System)
// All tokens mirror the Aura Claude Design file (`aura/project/shared/tokens.css`).
// Both `[data-theme="dark"]` and `[data-theme="light"]` variants are
// shipped — every `DS.Color` is a *dynamic* color that auto-switches
// based on the active `NSAppearance`. The user's `AppearanceMode` choice
// in Settings (`.system | .light | .dark`) drives `NSApp.appearance`,
// which propagates here.
//
// oklch → sRGB conversion uses the CSS Color 4 reference algorithm
// (Björn Ottosson's matrices). Resist the urge to "tweak" a value to
// look better — if the spec is off, edit the spec, not the conversion.

enum DS {

    // -------------------------------------------------------------------------
    // MARK: Colors
    // -------------------------------------------------------------------------
    enum Color {

        // Surfaces (bg-*) — dark uses near-black violet-tinted, light uses
        // warm milky off-white (hue=80).
        static let bgCanvas  = SwiftUI.Color.dsDynamic(light: "#F9F6F2", dark: "#07080B")
        static let bgBase    = SwiftUI.Color.dsDynamic(light: "#FEFCF9", dark: "#0D0E11")
        static let bgSurface = SwiftUI.Color.dsDynamic(light: "#FFFFFF", dark: "#141518")
        static let bgOverlay = SwiftUI.Color.dsDynamic(light: "#FFFFFF", dark: "#1B1C1F")
        static let bgInset   = SwiftUI.Color.dsDynamic(light: "#F2F0EC", dark: "#040507")

        // Interactive surfaces — translucent, tint flips white→dark on light.
        static let bgHover    = SwiftUI.Color.dsDynamic(
            lightRGBA: (0.078, 0.071, 0.055, 0.04),     // rgba(20, 18, 14, 0.04)
            darkRGBA:  (1.0,   1.0,   1.0,   0.04)      // rgba(255,255,255,0.04)
        )
        static let bgActive   = SwiftUI.Color.dsDynamic(
            lightRGBA: (0.078, 0.071, 0.055, 0.07),
            darkRGBA:  (1.0,   1.0,   1.0,   0.07)
        )

        // Text — light theme uses cool dark (hue=270), dark theme uses
        // warm off-white (the existing palette).
        static let textPrimary    = SwiftUI.Color.dsDynamic(light: "#15161A", dark: "#F3F3F6")
        static let textSecondary  = SwiftUI.Color.dsDynamic(light: "#4B4D52", dark: "#BBBAC3")
        static let textTertiary   = SwiftUI.Color.dsDynamic(light: "#707176", dark: "#8C8B95")
        static let textQuaternary = SwiftUI.Color.dsDynamic(light: "#909297", dark: "#6E6D76")
        static let textDisabled   = SwiftUI.Color.dsDynamic(light: "#A9ABB0", dark: "#545259")
        static let textOnAccent   = SwiftUI.Color.white

        // Borders — black-on-light, white-on-dark, identical alpha rungs.
        static let borderSubtle  = SwiftUI.Color.dsDynamic(
            lightRGBA: (0.078, 0.071, 0.055, 0.05),
            darkRGBA:  (1.0,   1.0,   1.0,   0.05)
        )
        static let borderDefault = SwiftUI.Color.dsDynamic(
            lightRGBA: (0.078, 0.071, 0.055, 0.09),
            darkRGBA:  (1.0,   1.0,   1.0,   0.09)
        )
        static let borderStrong  = SwiftUI.Color.dsDynamic(
            lightRGBA: (0.078, 0.071, 0.055, 0.16),
            darkRGBA:  (1.0,   1.0,   1.0,   0.16)
        )

        // Accent — violet, slightly darker + more saturated on light theme
        // so it reads as a clear primary against milky surfaces.
        static let accent            = SwiftUI.Color.dsDynamic(light: "#6C50E9", dark: "#7C5CFF")
        static let accentHover       = SwiftUI.Color.dsDynamic(light: "#5F3ED8", dark: "#8A6BFF")
        static let accentPress       = SwiftUI.Color.dsDynamic(light: "#532BC6", dark: "#6B4EE0")
        static let accentFg          = SwiftUI.Color.dsDynamic(light: "#5A37D1", dark: "#9D82FF")
        // Soft tints — same RGB anchor, alpha varies per theme weight.
        static let accentSoft        = SwiftUI.Color.dsDynamic(
            lightRGBA: (108/255, 70/255, 240/255, 0.10),  // rgba(108,70,240,0.10)
            darkRGBA:  (124/255, 92/255, 255/255, 0.16)
        )
        static let accentSoftSubtle  = SwiftUI.Color.dsDynamic(
            lightRGBA: (108/255, 70/255, 240/255, 0.05),
            darkRGBA:  (124/255, 92/255, 255/255, 0.08)
        )
        static let accentSoftHover   = SwiftUI.Color.dsDynamic(
            lightRGBA: (108/255, 70/255, 240/255, 0.16),
            darkRGBA:  (124/255, 92/255, 255/255, 0.22)
        )
        static let accentBorder      = SwiftUI.Color.dsDynamic(
            lightRGBA: (108/255, 70/255, 240/255, 0.28),
            darkRGBA:  (124/255, 92/255, 255/255, 0.32)
        )
        // 40 % accent — the "disabled" fill of the large primary CTA.
        // Reused across every onboarding step's Continue / Complete-setup
        // button so the visual `not-yet-ready` state is shared.
        static let accentDisabled    = SwiftUI.Color.dsDynamic(
            lightRGBA: (108/255, 70/255, 240/255, 0.40),
            darkRGBA:  (124/255, 92/255, 255/255, 0.40)
        )

        // Status — primary + foreground swatches
        static let successBase   = SwiftUI.Color.dsDynamic(light: "#008135", dark: "#3DBE73")
        static let successFg     = SwiftUI.Color.dsDynamic(light: "#006317", dark: "#5CD68A")
        static let warningBase   = SwiftUI.Color.dsDynamic(light: "#B97600", dark: "#FFB340")
        static let warningFg     = SwiftUI.Color.dsDynamic(light: "#935200", dark: "#FFCC73")
        static let dangerBase    = SwiftUI.Color.dsDynamic(light: "#D40924", dark: "#E84040")
        static let dangerFg      = SwiftUI.Color.dsDynamic(light: "#BA0007", dark: "#FF7070")
        static let infoBase      = SwiftUI.Color.dsDynamic(light: "#007CC5", dark: "#3B82F6")
        static let infoFg        = SwiftUI.Color.dsDynamic(light: "#0060A7", dark: "#67A8FF")

        // Status — soft / border stack. RGB anchors come straight from
        // `tokens.css` (the rgba values there are theme-shared); the
        // alpha rungs match the spec (~14% fill, ~30% border).
        static let successSoft   = SwiftUI.Color.dsDynamicSameRGBA(
            r: 70/255, g: 200/255, b: 120/255, alpha: 0.14)
        static let successBorder = SwiftUI.Color.dsDynamicSameRGBA(
            r: 70/255, g: 200/255, b: 120/255, alpha: 0.30)
        static let warningSoft   = SwiftUI.Color.dsDynamicSameRGBA(
            r: 240/255, g: 180/255, b: 70/255, alpha: 0.14)
        static let warningBorder = SwiftUI.Color.dsDynamicSameRGBA(
            r: 240/255, g: 180/255, b: 70/255, alpha: 0.30)
        static let dangerSoft    = SwiftUI.Color.dsDynamicSameRGBA(
            r: 240/255, g: 90/255, b: 80/255, alpha: 0.14)
        static let dangerBorder  = SwiftUI.Color.dsDynamicSameRGBA(
            r: 240/255, g: 90/255, b: 80/255, alpha: 0.30)
        static let infoSoft      = SwiftUI.Color.dsDynamicSameRGBA(
            r: 80/255, g: 160/255, b: 240/255, alpha: 0.14)
        static let infoBorder    = SwiftUI.Color.dsDynamicSameRGBA(
            r: 80/255, g: 160/255, b: 240/255, alpha: 0.30)

        // Inner-highlight stroke painted with `.blendMode(.plusLighter)`
        // on the rim of every solid-accent button (the HUD's
        // `DSPrimaryButton`, the onboarding Continue / Complete-setup
        // CTAs, the PermissionRow Grant button). White at 18 % in both
        // themes — the plus-lighter blend means it reads as a faint
        // raised lip against the violet fill regardless of the surface
        // beneath. Intentionally theme-shared (no dsDynamic wrap).
        static let buttonInnerHighlight = SwiftUI.Color.white.opacity(0.18)

        // Settings primitives — Tier-1 redesign tokens (plan 2026-05-18-003).
        // Each replaces an inline `.opacity(...)` literal flagged by the
        // project-standards reviewer.
        //
        // Three of the four are theme-aware derivatives of existing
        // dynamic colors, so they spell out per-theme RGBA tuples rather
        // than wrapping `Color.opacity(_:)` over a dynamic NSColor at
        // static-let scope — see
        // `solutions/design-patterns/ds-primitives-opt-in-extension-patterns-2026-05-17.md`
        // (Technique 4). `segmentedPressedShadow` is theme-shared black
        // and stays as a single `Color.opacity` literal.
        //
        // `segmentedPressedShadow` — drop shadow under the pressed
        //   `DSSegmented` segment. Theme-shared black @ 18 %.
        // `calloutSurface` — bgInset @ 70 % for the "How recording
        //   works" callout, slightly more diffuse than raw bgInset so
        //   it reads as a recessed card-in-card.
        //   Anchors: bgInset light=#F2F0EC, dark=#040507.
        // `statusDotGlow` — successFg @ 60 % as a glow on the
        //   mic-source pill's active dot.
        //   Anchors: successFg light=#006317, dark=#5CD68A.
        // `headerBackdropTint` — bgBase @ 40 % layered over
        //   `.ultraThinMaterial` for the Settings sticky header.
        //   Anchors: bgBase light=#FEFCF9, dark=#0D0E11.
        static let segmentedPressedShadow = SwiftUI.Color.black.opacity(0.18)
        static let calloutSurface         = SwiftUI.Color.dsDynamic(
            lightRGBA: (242/255, 240/255, 236/255, 0.70),
            darkRGBA:  (  4/255,   5/255,   7/255, 0.70)
        )
        static let statusDotGlow          = SwiftUI.Color.dsDynamic(
            lightRGBA: (  0/255,  99/255,  23/255, 0.60),
            darkRGBA:  ( 92/255, 214/255, 138/255, 0.60)
        )
        static let headerBackdropTint     = SwiftUI.Color.dsDynamic(
            lightRGBA: (254/255, 252/255, 249/255, 0.40),
            darkRGBA:  ( 13/255,  14/255,  17/255, 0.40)
        )

        // 40 % danger — used for the row background of a permission
        // that's in the `denied` state. Reads as a flag tint that the
        // user needs to address. Roughly 7× the effective alpha of the
        // `dangerSoft.opacity(0.4)` literal it replaced (~0.056), which
        // is intentional — the prior value was too washed out to read
        // as a flag against `bgSurface`.
        static let dangerSoftStrong = SwiftUI.Color.dsDynamicSameRGBA(
            r: 240/255, g: 90/255, b: 80/255, alpha: 0.40)

        // Onboarding-chrome derivatives — the centered progress pill
        // background and the pending-dot fill. Expressed as explicit
        // per-theme RGBA so the dynamic NSColor provider re-resolves on
        // appearance flips. (Wrapping a dynamic color in
        // `SwiftUI.Color.opacity(_:)` at static-let scope risks freezing
        // the sRGB at first access — safer to spell out the tuple.)
        // Anchors:
        //   bgBase light=#FEFCF9, dark=#0D0E11 @ 60%
        //   textQuaternary light=#909297, dark=#6E6D76 @ 55%
        static let progressPillFill   = SwiftUI.Color.dsDynamic(
            lightRGBA: (254/255, 252/255, 249/255, 0.60),
            darkRGBA:  ( 13/255,  14/255,  17/255, 0.60)
        )
        static let progressDotPending = SwiftUI.Color.dsDynamic(
            lightRGBA: (144/255, 146/255, 151/255, 0.55),
            darkRGBA:  (110/255, 109/255, 118/255, 0.55)
        )

        // Glass top-edge highlight — a 1pt strip we paint at the top of
        // every HUD shell + the popover. White on dark, black on light
        // (faint) so the "raised" feel works in both themes.
        static let glassTopHighlight = SwiftUI.Color.dsDynamic(
            lightRGBA: (0.0, 0.0, 0.0, 0.04),
            darkRGBA:  (1.0, 1.0, 1.0, 0.06)
        )

        // Broken / retrying history-row slots — the rim of the 28 pt tile
        // that replaces the app icon on a failed row (`app/menu-bar.html`,
        // `.t-err-slot` and its `.rty` variant).
        //
        // The design writes both as
        // `color-mix(in oklab, <base> N%, transparent)` — the theme's own
        // `--danger-base` / `--accent-base` at N % alpha, NOT the
        // theme-shared rgba anchors the `*Soft` / `*Border` family is
        // built from. So they spell out per-theme tuples taken from the
        // `dangerBase` / `accent` hexes above; reusing `dangerBorder`
        // (0.30) or `accentBorder` (0.32) would be wrong on both the
        // anchor and the alpha.
        //
        // Anchors: dangerBase light=#D40924, dark=#E84040 @ 55 %
        //          accent     light=#6C50E9, dark=#7C5CFF @ 45 %
        static let errorSlotBorder = SwiftUI.Color.dsDynamic(
            lightRGBA: (212/255,  9/255,  36/255, 0.55),
            darkRGBA:  (232/255, 64/255,  64/255, 0.55)
        )
        static let retrySlotBorder = SwiftUI.Color.dsDynamic(
            lightRGBA: (108/255, 80/255, 233/255, 0.45),
            darkRGBA:  (124/255, 92/255, 255/255, 0.45)
        )

        // Popover surface — the body fill behind the history list.
        // Solid in both themes so we don't depend on whatever wallpaper
        // sits behind the menu bar (the previous `.ultraThinMaterial`
        // approach made the popover look cloudy on light, washed out on
        // dark). Light = pure white per the spec's `--bg-overlay` in
        // `[data-theme="light"]`. Dark = the spec's `--bg-overlay`.
        static let popoverSurface = bgOverlay

        // Footer surface — visibly darker than the body in both themes.
        // Light: a hairline off-white (#F9F6F2) so the "shelf" reads as
        // gray against the white body. Dark: a hairline darker than the
        // body so the same shelf works in reverse. Tuned per-theme
        // because spec's "bg-base 60% over bg-overlay" gives no visible
        // contrast in light (bg-base is itself near-white).
        static let footerSurface = SwiftUI.Color.dsDynamic(
            light: "#F9F6F2",
            dark:  "#15161A"
        )
    }

    // -------------------------------------------------------------------------
    // MARK: Border widths
    // -------------------------------------------------------------------------
    enum Border {
        static let hairline: CGFloat = 0.5
        /// 1.5 pt — the rim of the broken / retrying history-row slot
        /// (`app/menu-bar.html`, `.t-err-slot`). Thicker than a hairline
        /// on purpose: at 0.5 pt the dashed variant reads as a smudge
        /// rather than as a dashed border.
        static let medium: CGFloat = 1.5
    }

    // -------------------------------------------------------------------------
    // MARK: Spacing  (--space-N, 4-pt base grid)
    // -------------------------------------------------------------------------
    enum Space {
        static let s1:  CGFloat =   2
        static let s2:  CGFloat =   4
        static let s3:  CGFloat =   8
        static let s4:  CGFloat =  12
        static let s5:  CGFloat =  16
        static let s6:  CGFloat =  20
        static let s7:  CGFloat =  24
        static let s8:  CGFloat =  32
        static let s9:  CGFloat =  40
        static let s10: CGFloat =  48
        static let s11: CGFloat =  64
        static let s12: CGFloat =  80
        static let s13: CGFloat = 120
    }

    // -------------------------------------------------------------------------
    // MARK: Radii  (--radius-*)
    // -------------------------------------------------------------------------
    enum Radius {
        static let xs:   CGFloat =   4
        static let sm:   CGFloat =   6
        static let md:   CGFloat =   8
        static let lg:   CGFloat =  12
        static let xl:   CGFloat =  16
        static let pill: CGFloat = 999
    }

    // -------------------------------------------------------------------------
    // MARK: Component heights  (--h-*)
    // -------------------------------------------------------------------------
    enum Size {
        static let hXS: CGFloat = 22
        static let hSM: CGFloat = 28
        static let hMD: CGFloat = 32
        static let hLG: CGFloat = 36
        static let hXL: CGFloat = 44
    }

    // -------------------------------------------------------------------------
    // MARK: Typography  (--fs-* / --lh-*)
    // -------------------------------------------------------------------------
    enum Font {
        static func caption(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: 10, weight: weight)
        }
        static func labelMono(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: 11, weight: weight, design: .monospaced)
        }
        static func label(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: 11, weight: weight)
        }
        static func bodySM(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: 12, weight: weight)
        }
        static func body(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: 13, weight: weight)
        }
        static func bodyMD(_ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: 14, weight: weight)
        }
        static func heading(_ weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: 15, weight: weight)
        }
        /// 18pt — page titles ("Settings", "Home"), prominent stat
        /// values inside cards (`TokenStatsPanel` cells). Default
        /// weight `.semibold` for titles; call with `.medium` for
        /// stat values so they read as content, not as a heading.
        /// Mirrors `--fs-18` from `tokens.css`; the spec also defines
        /// `--lh-18` but we don't currently pair line-heights on any
        /// `DS.Font.*` helper.
        static func title(_ weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: 18, weight: weight)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Motion  (--ease-* / --dur-*)
    // -------------------------------------------------------------------------
    enum Motion {
        static let instant: SwiftUI.Animation = .timingCurve(0.20, 0.80, 0.20, 1.00, duration: 0.080)
        static let fast:    SwiftUI.Animation = .timingCurve(0.20, 0.80, 0.20, 1.00, duration: 0.140)
        static let base:    SwiftUI.Animation = .timingCurve(0.20, 0.80, 0.20, 1.00, duration: 0.200)
        static let slow:    SwiftUI.Animation = .timingCurve(0.20, 0.80, 0.20, 1.00, duration: 0.320)
        static let easeIn:    SwiftUI.Animation = .timingCurve(0.40, 0.00, 1.00, 1.00, duration: 0.140)
        static let easeInOut: SwiftUI.Animation = .timingCurve(0.40, 0.00, 0.20, 1.00, duration: 0.200)
        static let spring:  SwiftUI.Animation = .timingCurve(0.34, 1.32, 0.64, 1.00, duration: 0.260)
    }
}

// MARK: - Color dynamic helpers

extension Color {
    /// Light/dark dynamic color from two hex strings. Rebuilds itself
    /// whenever the active `NSAppearance` changes (system theme flip,
    /// `NSApp.appearance` set by `AppearanceController`, etc).
    static func dsDynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isLightVariant
                ? NSColor(hex: light)
                : NSColor(hex: dark)
        })
    }

    /// Translucent dynamic color — RGBA tuple per theme. Use this for
    /// the `bg-hover`/`bg-active`/`border-*` family where the design
    /// flips the RGB anchor between black-on-light and white-on-dark.
    static func dsDynamic(
        lightRGBA: (CGFloat, CGFloat, CGFloat, CGFloat),
        darkRGBA:  (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b, a) = appearance.isLightVariant ? lightRGBA : darkRGBA
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        })
    }

    /// Translucent color whose RGBA stays identical across themes
    /// (status soft tints — the spec defines them as theme-shared).
    /// Wrapping in a dynamic provider keeps the API consistent and lets
    /// us tweak per-theme alpha later without touching call sites.
    static func dsDynamicSameRGBA(r: CGFloat, g: CGFloat, b: CGFloat, alpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { _ in
            NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        })
    }
}

// MARK: - NSColor / NSAppearance helpers

extension NSColor {
    /// Build an NSColor from a `#RRGGBB` hex string in sRGB. No alpha
    /// channel — opacity is layered separately when needed.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(
            srgbRed: CGFloat((rgb & 0xFF0000) >> 16) / 255,
            green:   CGFloat((rgb & 0x00FF00) >>  8) / 255,
            blue:    CGFloat( rgb & 0x0000FF        ) / 255,
            alpha: 1
        )
    }
}

extension NSAppearance {
    /// `true` for the aqua/light family, `false` for darkAqua and the
    /// vibrant variants. Centralised so every dynamic-color provider
    /// agrees on what "light" means.
    var isLightVariant: Bool {
        bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
    }
}
