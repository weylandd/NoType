import SwiftUI

// MARK: - Layout data
//
// Hard-coded standard ANSI Mac layout that mirrors the design's
// `keyboard-data.js`. `OnboardingKeyboard.layout` is consumed by
// `MacKeyboardView` for rendering and `OnboardingKeyboard.codeForVirtual(_:)`
// goes the other direction — virtual key code → JS-style code — so
// `NSEvent` callbacks can highlight the matching on-screen key.

enum OnboardingKeyboard {

    struct Key {
        let code: String
        var width: CGFloat = 1.0
        var height: CGFloat = 1.0        // function-row keys are shorter
        var content: Content = .single(label: "")
        var labelAlignment: LabelAlignment = .center

        enum Content {
            /// Single primary character or word, centered.
            case single(label: String)
            /// Two stacked glyphs (e.g. `~` over `` ` ``).
            case double(top: String, bottom: String)
            /// Modifier with glyph atop word (`⌥` over `option`).
            case modifier(glyph: String, word: String)
            /// Same shape as `.modifier`, but the top "glyph" is an SF
            /// Symbol rather than a unicode character — used for `fn`'s
            /// globe, which has no clean unicode/SF-fallback that draws
            /// in the same outlined style as ⌃⌥⌘⇧.
            case modifierIcon(systemName: String, word: String)
            /// Word-only key (`tab`, `delete`, `return`, `caps lock`, `fn`).
            case word(String)
            /// Vertical arrow stack used in the half-height ▲▼ key.
            /// The single physical key reports both codes — clicking it
            /// fires the first code; the visualization lights up on
            /// either real press.
            case arrowStack(codeAlt: String)
        }

        enum LabelAlignment { case center, bottomLeft, bottomRight }
    }

    /// Each row is rendered as an `HStack`; keys flex by their `width`.
    static let rows: [[Key]] = [
        // Function row (shorter)
        [
            Key(code: "Escape", height: 0.65, content: .word("esc")),
            Key(code: "F1",  height: 0.65, content: .word("F1")),
            Key(code: "F2",  height: 0.65, content: .word("F2")),
            Key(code: "F3",  height: 0.65, content: .word("F3")),
            Key(code: "F4",  height: 0.65, content: .word("F4")),
            Key(code: "F5",  height: 0.65, content: .word("F5")),
            Key(code: "F6",  height: 0.65, content: .word("F6")),
            Key(code: "F7",  height: 0.65, content: .word("F7")),
            Key(code: "F8",  height: 0.65, content: .word("F8")),
            Key(code: "F9",  height: 0.65, content: .word("F9")),
            Key(code: "F10", height: 0.65, content: .word("F10")),
            Key(code: "F11", height: 0.65, content: .word("F11")),
            Key(code: "F12", height: 0.65, content: .word("F12")),
            Key(code: "Power", height: 0.65, content: .word("pwr"))
        ],
        // Digits row
        [
            Key(code: "Backquote", content: .double(top: "~", bottom: "`")),
            Key(code: "Digit1",    content: .double(top: "!", bottom: "1")),
            Key(code: "Digit2",    content: .double(top: "@", bottom: "2")),
            Key(code: "Digit3",    content: .double(top: "#", bottom: "3")),
            Key(code: "Digit4",    content: .double(top: "$", bottom: "4")),
            Key(code: "Digit5",    content: .double(top: "%", bottom: "5")),
            Key(code: "Digit6",    content: .double(top: "^", bottom: "6")),
            Key(code: "Digit7",    content: .double(top: "&", bottom: "7")),
            Key(code: "Digit8",    content: .double(top: "*", bottom: "8")),
            Key(code: "Digit9",    content: .double(top: "(", bottom: "9")),
            Key(code: "Digit0",    content: .double(top: ")", bottom: "0")),
            Key(code: "Minus",     content: .double(top: "_", bottom: "-")),
            Key(code: "Equal",     content: .double(top: "+", bottom: "=")),
            Key(code: "Backspace", width: 1.6, content: .word("delete"),
                labelAlignment: .bottomRight)
        ],
        // QWERTY row
        [
            Key(code: "Tab",          width: 1.5, content: .word("tab"),
                labelAlignment: .bottomLeft),
            Key(code: "KeyQ", content: .single(label: "Q")),
            Key(code: "KeyW", content: .single(label: "W")),
            Key(code: "KeyE", content: .single(label: "E")),
            Key(code: "KeyR", content: .single(label: "R")),
            Key(code: "KeyT", content: .single(label: "T")),
            Key(code: "KeyY", content: .single(label: "Y")),
            Key(code: "KeyU", content: .single(label: "U")),
            Key(code: "KeyI", content: .single(label: "I")),
            Key(code: "KeyO", content: .single(label: "O")),
            Key(code: "KeyP", content: .single(label: "P")),
            Key(code: "BracketLeft",  content: .double(top: "{", bottom: "[")),
            Key(code: "BracketRight", content: .double(top: "}", bottom: "]")),
            Key(code: "Backslash",    content: .double(top: "|", bottom: "\\"))
        ],
        // ASDF row
        [
            Key(code: "CapsLock", width: 1.75, content: .word("caps lock"),
                labelAlignment: .bottomLeft),
            Key(code: "KeyA", content: .single(label: "A")),
            Key(code: "KeyS", content: .single(label: "S")),
            Key(code: "KeyD", content: .single(label: "D")),
            Key(code: "KeyF", content: .single(label: "F")),
            Key(code: "KeyG", content: .single(label: "G")),
            Key(code: "KeyH", content: .single(label: "H")),
            Key(code: "KeyJ", content: .single(label: "J")),
            Key(code: "KeyK", content: .single(label: "K")),
            Key(code: "KeyL", content: .single(label: "L")),
            Key(code: "Semicolon", content: .double(top: ":", bottom: ";")),
            Key(code: "Quote",     content: .double(top: "\"", bottom: "'")),
            Key(code: "Enter", width: 1.8, content: .word("return"),
                labelAlignment: .bottomRight)
        ],
        // ZXCV row
        [
            Key(code: "ShiftLeft", width: 2.25,
                content: .modifier(glyph: "⇧", word: "shift"),
                labelAlignment: .bottomLeft),
            Key(code: "KeyZ", content: .single(label: "Z")),
            Key(code: "KeyX", content: .single(label: "X")),
            Key(code: "KeyC", content: .single(label: "C")),
            Key(code: "KeyV", content: .single(label: "V")),
            Key(code: "KeyB", content: .single(label: "B")),
            Key(code: "KeyN", content: .single(label: "N")),
            Key(code: "KeyM", content: .single(label: "M")),
            Key(code: "Comma",  content: .double(top: "<", bottom: ",")),
            Key(code: "Period", content: .double(top: ">", bottom: ".")),
            Key(code: "Slash",  content: .double(top: "?", bottom: "/")),
            Key(code: "ShiftRight", width: 2.4,
                content: .modifier(glyph: "⇧", word: "shift"),
                labelAlignment: .bottomRight)
        ],
        // Bottom modifier row
        [
            Key(code: "Fn", width: 1.05,
                content: .modifierIcon(systemName: "globe", word: "fn")),
            Key(code: "ControlLeft", width: 1.1,
                content: .modifier(glyph: "⌃", word: "control")),
            Key(code: "AltLeft", width: 1.1,
                content: .modifier(glyph: "⌥", word: "option")),
            Key(code: "MetaLeft", width: 1.4,
                content: .modifier(glyph: "⌘", word: "command")),
            Key(code: "Space", width: 5.4, content: .word("")),
            Key(code: "MetaRight", width: 1.4,
                content: .modifier(glyph: "⌘", word: "command")),
            Key(code: "AltRight", width: 1.1,
                content: .modifier(glyph: "⌥", word: "option")),
            Key(code: "ArrowLeft", width: 0.85, height: 0.5,
                content: .single(label: "◀")),
            Key(code: "ArrowUp", width: 0.85,
                content: .arrowStack(codeAlt: "ArrowDown")),
            Key(code: "ArrowRight", width: 0.85, height: 0.5,
                content: .single(label: "▶"))
        ]
    ]

    // MARK: virtualKeyCode → code

    /// Reverse lookup for `NSEvent.keyCode` → JS-style code. Generated
    /// once from the binding tables in `HotkeyBinding`; covers every key
    /// in the rendered layout.
    static let codeByVirtual: [UInt16: String] = {
        var map: [UInt16: String] = [:]
        for row in rows {
            for key in row {
                let candidate = HotkeyBinding(code: key.code)
                if let vk = candidate.virtualKeyCode { map[UInt16(vk)] = key.code }
            }
        }
        // Modifiers also fire keyDown / keyUp on macOS via `flagsChanged`
        // events whose `keyCode` is the virtual code of the modifier
        // itself — include them here so the reconciliation path can
        // disambiguate which side of split modifiers changed.
        let modifiers: [(UInt16, String)] = [
            (54, "MetaRight"),
            (55, "MetaLeft"),
            (56, "ShiftLeft"),
            (57, "CapsLock"),
            (58, "AltLeft"),
            (59, "ControlLeft"),
            (60, "ShiftRight"),
            (61, "AltRight"),
            (62, "ControlRight"),
            (63, "Fn")
        ]
        for (vk, code) in modifiers { map[vk] = code }
        return map
    }()

    static func codeForVirtual(_ vk: UInt16) -> String? {
        codeByVirtual[vk]
    }
}

// MARK: - View

struct MacKeyboardView: View {
    let pressedCodes: Set<String>
    let targetCode: String
    let verifiedTarget: Bool
    let isRemap: Bool
    let onKeyTap: (String) -> Void

    /// Frame max-width; chosen to roughly match the design's 920 pt
    /// keyboard width inside an 1180 pt window.
    private let frameMaxWidth: CGFloat = 920
    private let baseKeyHeight: CGFloat = 38
    private let rowSpacing: CGFloat = 4
    private let keySpacing: CGFloat = 4

    var body: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(OnboardingKeyboard.rows.enumerated()), id: \.offset) { _, row in
                let rowMaxHeight = (row.map { $0.height }.max() ?? 1.0)
                KeyboardRowLayout(
                    widths:  row.map { $0.width },
                    heights: row.map { $0.height / rowMaxHeight },
                    spacing: keySpacing
                ) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        KeyCapView(
                            key: key,
                            isTarget:   key.code == targetCode && !verifiedTarget,
                            isVerified: key.code == targetCode && verifiedTarget,
                            isPressed:  pressedCodes.contains(key.code),
                            isRemap:    isRemap,
                            baseHeight: baseKeyHeight,
                            onTap:      { onKeyTap(key.code) }
                        )
                    }
                }
                .frame(height: baseKeyHeight * rowMaxHeight)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 14, trailing: 18))
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        DS.Color.bgSurface.opacity(0.6),
                        DS.Color.bgSurface
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [DS.Color.accent.opacity(0.07), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 360
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
        .frame(maxWidth: frameMaxWidth)
    }
}

// MARK: - Custom row layout
//
// SwiftUI's HStack doesn't do proportional sizing: combining
// `.frame(maxWidth: .infinity)` with `.layoutPriority(width)` makes the
// highest-priority view (e.g. `shift` at 2.25) eat the entire row and
// starve the unit-width keys. A custom `Layout` is the only way to
// distribute width by an arbitrary weight per child.

private struct KeyboardRowLayout: Layout {
    let widths:  [CGFloat]   // proportional horizontal weight per child
    let heights: [CGFloat]   // vertical fraction of row height per child (0.5 = half-height arrow)
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let totalUnits = widths.reduce(0, +)
        guard totalUnits > 0 else { return }
        let availWidth = bounds.width - CGFloat(subviews.count - 1) * spacing
        let unitWidth  = availWidth / totalUnits
        var x = bounds.minX
        for (i, sub) in subviews.enumerated() {
            let kw = unitWidth * widths[indexOrZero(i)]
            let kh = bounds.height * heightAt(i)
            // Bottom-align each subview within the row so half-height
            // keys (arrow ◀ / ▶) sit at the bottom of a tall cell while
            // full-height keys still fill the cell.
            let y = bounds.minY + (bounds.height - kh)
            sub.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: kw, height: kh)
            )
            x += kw + spacing
        }
    }

    private func indexOrZero(_ i: Int) -> Int {
        i < widths.count ? i : 0
    }

    private func heightAt(_ i: Int) -> CGFloat {
        i < heights.count ? heights[i] : 1.0
    }
}

// MARK: - Single key cap

private struct KeyCapView: View {
    let key: OnboardingKeyboard.Key
    let isTarget: Bool
    let isVerified: Bool
    let isPressed: Bool
    let isRemap: Bool
    let baseHeight: CGFloat
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(border, lineWidth: 1)
                )
                .overlay(haloOverlay)
                .offset(y: isPressed ? 1.5 : 0)
                .animation(DS.Motion.fast, value: isPressed)
                .animation(DS.Motion.fast, value: isTarget)
                .animation(DS.Motion.fast, value: isVerified)
                .animation(DS.Motion.fast, value: hovered)
        }
        .buttonStyle(.plain)
        .dsOnHover { hovered = $0 }
    }

    private var cornerRadius: CGFloat { key.height < 1 ? 5 : 7 }

    @ViewBuilder
    private var content: some View {
        switch key.content {
        case .single(let label):
            Text(label)
                .font(.system(size: key.height < 1 ? 10.5 : 13, weight: .medium))
                .foregroundStyle(textColor)
        case .double(let top, let bottom):
            VStack(spacing: 1) {
                Text(top)
                    .foregroundStyle(textColorSecondary)
                Text(bottom)
                    .foregroundStyle(textColor)
            }
            .font(.system(size: 10.5, weight: .medium))
        case .modifier(let glyph, let word):
            VStack(spacing: 1) {
                Text(glyph).font(.system(size: 11))
                Text(word).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(textColorSecondary)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.horizontal, 6)
        case .modifierIcon(let systemName, let word):
            VStack(spacing: 1) {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .regular))
                Text(word).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(textColorSecondary)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.horizontal, 6)
        case .word(let w):
            Text(w)
                .font(.system(size: key.height < 1 ? 10 : 11, weight: .medium))
                .foregroundStyle(textColorSecondary)
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(.horizontal, 6)
        case .arrowStack:
            VStack(spacing: 0) {
                Text("▲")
                Text("▼")
            }
            .font(.system(size: 9))
            .foregroundStyle(textColorSecondary)
        }
    }

    private var alignment: Alignment {
        switch key.labelAlignment {
        case .center:      return .center
        case .bottomLeft:  return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    // MARK: - Look

    private var background: AnyShapeStyle {
        if isPressed {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [DS.Color.accent, DS.Color.accentPress],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        if isVerified {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        DS.Color.successSoft,
                        DS.Color.bgInset
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        if isTarget {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        DS.Color.accent.opacity(0.18),
                        DS.Color.accent.opacity(0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        if isRemap && hovered {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        DS.Color.accent.opacity(0.28),
                        DS.Color.accent.opacity(0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    DS.Color.bgOverlay.opacity(0.7),
                    DS.Color.bgInset.opacity(0.7)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var border: Color {
        if isPressed  { return DS.Color.accent }
        if isVerified { return DS.Color.successBorder }
        if isTarget   { return DS.Color.accentBorder }
        if isRemap && hovered { return DS.Color.accentBorder }
        return DS.Color.borderDefault
    }

    private var textColor: Color {
        if isPressed  { return .white }
        if isVerified { return DS.Color.successFg }
        if isTarget   { return DS.Color.accentFg }
        if isRemap && hovered { return DS.Color.accentFg }
        return DS.Color.textPrimary
    }

    private var textColorSecondary: Color {
        if isPressed  { return .white }
        if isVerified { return DS.Color.successFg }
        if isTarget   { return DS.Color.accentFg }
        if isRemap && hovered { return DS.Color.accentFg }
        return DS.Color.textSecondary
    }

    @ViewBuilder
    private var haloOverlay: some View {
        if isTarget {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(DS.Color.accentSoft, lineWidth: 4)
                .padding(-2)
                .blendMode(.plusLighter)
        } else if isVerified {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(DS.Color.successSoft, lineWidth: 4)
                .padding(-2)
                .blendMode(.plusLighter)
        }
    }
}
