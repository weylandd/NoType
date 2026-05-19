import SwiftUI

/// Instructions tab — global user instruction card + per-category list.
/// Drill-in into a row shows `CategoryDetailView`. Visual language
/// mirrors the design bundle's `app/prompts.html` (renamed Prompts in
/// the design; we keep the tab label as "Instructions").
struct InstructionsView: View {
    @Environment(AppState.self) private var appState

    /// `nil` = list view; non-nil = drill-in to `CategoryDetailView`.
    @State private var selectedCategory: AppCategory?

    var body: some View {
        Group {
            if let selectedCategory {
                CategoryDetailView(
                    category: selectedCategory,
                    onBack: { self.selectedCategory = nil }
                )
            } else {
                listView
            }
        }
    }

    // MARK: - List view

    private var listView: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s6) {
                    SectionHeading(
                        title: "Global instruction",
                        hint: "applied on top of every category prompt"
                    )
                    GlobalInstructionCard()

                    SectionHeading(
                        title: "Categories",
                        hint: "tap to edit the prompt for that style"
                    )
                    .padding(.top, DS.Space.s1)

                    categoryListCard
                }
                .padding(.horizontal, DS.Space.s7 + 4)
                .padding(.top, DS.Space.s7)
                .padding(.bottom, DS.Space.s9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s4) {
            Text("Instructions")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Text("Categories · \(AppCategory.allCases.count)")
                .font(DS.Font.labelMono())
                .foregroundStyle(DS.Color.textTertiary)
                .tracking(0.4)
                .padding(.horizontal, DS.Space.s2 - 1)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.xs)
                        .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
                )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s7 + 4)
        .padding(.top, DS.Space.s5)
        .padding(.bottom, DS.Space.s5)
        .background(
            DS.Color.bgBase
                .overlay(
                    DS.Color.borderSubtle.frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    private var categoryListCard: some View {
        VStack(spacing: 0) {
            let categories = AppCategory.allCases
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                CategoryRow(
                    category: category,
                    appCount: appCount(for: category),
                    hasOverride: appState.categoryPromptOverrides[category] != nil,
                    onTap: { self.selectedCategory = category }
                )
                if index < categories.count - 1 {
                    DS.Color.borderSubtle.frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg - 2))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg - 2)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
    }

    private func appCount(for category: AppCategory) -> Int {
        appState.categoryAssignments.values.reduce(into: 0) { acc, record in
            if record.category == category { acc += 1 }
        }
    }
}

// MARK: - Section heading
//
// Mono caps + neutral hint, sits above each card group ("Global
// instruction" / "Categories"). Mirrors `.section-h` in prompts.html.

struct InstructionsSectionHeading: View {
    let title: String
    let hint: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3 + 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .tracking(1.3)
                .foregroundStyle(DS.Color.textTertiary)
            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Color.textQuaternary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}

/// Local alias kept short for use inside the file.
private typealias SectionHeading = InstructionsSectionHeading

// MARK: - Global instruction card
//
// Sparkle icon tile + "Your personal style" + status pill ("Empty" /
// "Active · N rules"), then a mono textarea. Soft radial accent glow
// in the top-right corner. Mirrors `.global-card` in prompts.html.

private struct GlobalInstructionCard: View {
    @Environment(AppState.self) private var appState

    @State private var draft: String = ""

    var body: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruleCount = trimmed.split(whereSeparator: \.isNewline)
            .filter { !$0.isEmpty }
            .count

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.s3 + 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .fill(DS.Color.accentSoft)
                        .frame(width: 22, height: 22)
                    DSIcon(name: .sparkle, size: 12, color: DS.Color.accentFg)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your personal style")
                        .font(DS.Font.body(.semibold))
                        .foregroundStyle(DS.Color.textPrimary)
                    Text("Optional. Stays the same across every app.")
                        .font(DS.Font.bodySM())
                        .foregroundStyle(DS.Color.textTertiary)
                }
                Spacer(minLength: 0)
                Text(statusText(trimmed: trimmed, ruleCount: ruleCount))
                    .font(DS.Font.labelMono(.medium))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(trimmed.isEmpty
                                     ? DS.Color.textQuaternary
                                     : DS.Color.accentFg)
            }
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.top, DS.Space.s4 + 2)
            .padding(.bottom, DS.Space.s3 + 2)

            PromptTextEditor(
                text: $draft,
                placeholder: globalPlaceholder,
                minHeight: 96,
                isMono: true,
                onCommit: { value in
                    appState.updateUserInstruction(value)
                }
            )
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.bottom, DS.Space.s5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                DS.Color.bgSurface
                // Accent glow — radial gradient sweeping in from top-right.
                RadialGradient(
                    gradient: Gradient(colors: [
                        DS.Color.accent.opacity(0.12),
                        DS.Color.accent.opacity(0)
                    ]),
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 260
                )
                .allowsHitTesting(false)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg - 2))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg - 2)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
        .onAppear {
            // Read once from the source-of-truth on appear; textarea
            // keeps a local mirror to avoid the per-keystroke round-
            // trip through the store actor.
            draft = appState.userInstruction
        }
    }

    private func statusText(trimmed: String, ruleCount: Int) -> String {
        if trimmed.isEmpty { return "Empty" }
        return ruleCount <= 1 ? "Active · 1 rule" : "Active · \(ruleCount) rules"
    }

    private var globalPlaceholder: String {
        "prefer em-dashes over commas\nnever use semicolons\nkeep Russian words in the original alphabet\n…"
    }
}

// MARK: - Category row

private struct CategoryRow: View {
    let category: AppCategory
    let appCount: Int
    let hasOverride: Bool
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Space.s4) {
                CategoryIconTile(category: category, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.s2 + 1) {
                        Text(category.displayName)
                            .font(DS.Font.body(.medium))
                            .foregroundStyle(DS.Color.textPrimary)
                        if hasOverride {
                            CustomisedPill()
                        }
                    }
                    Text(category.blurb)
                        .font(DS.Font.bodySM())
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: DS.Space.s3)
                countLabel
                DSIcon(name: .chevronRight, size: 12, color: DS.Color.textQuaternary)
            }
            .padding(.horizontal, DS.Space.s5 - 2)
            .padding(.vertical, DS.Space.s4 + 2)
            .background(hovered ? DS.Color.bgHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
    }

    @ViewBuilder
    private var countLabel: some View {
        if category == .search {
            Text("Detected automatically")
                .font(DS.Font.labelMono())
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(DS.Color.textTertiary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(appCount)")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Color.textPrimary)
                    .monospacedDigit()
                Text(appCount == 1 ? "APP" : "APPS")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(DS.Color.textQuaternary)
            }
        }
    }
}

// MARK: - Customised pill
//
// Small accent pill with a glowing dot — surfaces on rows that carry a
// user override. Mirrors `.pill-custom` in prompts.html.

struct InstructionsCustomisedPill: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DS.Color.accentFg)
                .frame(width: 5, height: 5)
                .shadow(color: DS.Color.accentFg.opacity(0.7), radius: 3)
            Text("CUSTOMISED")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(DS.Color.accentFg)
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(DS.Color.accentSoft, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.Color.accentBorder, lineWidth: DS.Border.hairline))
    }
}

/// Local alias for in-file use.
private typealias CustomisedPill = InstructionsCustomisedPill

// MARK: - Category icon tile
//
// Tinted square + DS line glyph. One per category. Tint comes from the
// per-category hue defined in the design (`hue` in prompts-data.js); we
// map that to the closest existing DS semantic colour so the palette
// stays themed.

struct CategoryIconTile: View {
    let category: AppCategory
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: tileRadius)
                .fill(CategoryPalette.fill(for: category))
            RoundedRectangle(cornerRadius: tileRadius)
                .strokeBorder(CategoryPalette.border(for: category), lineWidth: DS.Border.hairline)
            DSIcon(
                name: CategoryPalette.glyph(for: category),
                size: size * 0.45,
                color: CategoryPalette.foreground(for: category)
            )
        }
        .frame(width: size, height: size)
    }

    private var tileRadius: CGFloat {
        size >= 40 ? DS.Radius.md + 2 : DS.Radius.md
    }
}

// MARK: - Category palette
//
// Per-category colour family — fill / foreground / border / soft tint
// used by the icon tile and the drill-in banner gradient. Maps each
// category's design hue (235 / 200 / 355 / 85 / 285 / 152 / 55 / 270)
// to a static sRGB approximation of `oklch(0.78 0.14 H)` for the
// foreground and `oklch(0.65 0.18 H / 0.20)` for the soft fill. Light-
// theme variants reduce lightness so the tile reads against the milky
// surface.

enum CategoryPalette {

    static func glyph(for category: AppCategory) -> DSIconName {
        switch category {
        case .messaging:     return .chat
        case .email:         return .send
        case .social:        return .heart
        case .notes:         return .bookmark
        case .docs:          return .file
        case .code:          return .code
        case .search:        return .search
        case .uncategorized: return .folder
        }
    }

    static func foreground(for category: AppCategory) -> Color {
        switch category {
        case .messaging:     return SwiftUI.Color.dsDynamic(light: "#3373D6", dark: "#7AB1FF")
        case .email:         return SwiftUI.Color.dsDynamic(light: "#007A99", dark: "#5BC8E4")
        case .social:        return SwiftUI.Color.dsDynamic(light: "#C04860", dark: "#FF8FA3")
        case .notes:         return SwiftUI.Color.dsDynamic(light: "#7E7C00", dark: "#D9D670")
        case .docs:          return DS.Color.accentFg
        case .code:          return DS.Color.successFg
        case .search:        return SwiftUI.Color.dsDynamic(light: "#9B6700", dark: "#E8B45A")
        case .uncategorized: return DS.Color.textSecondary
        }
    }

    static func fill(for category: AppCategory) -> Color {
        switch category {
        case .messaging:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (51/255, 115/255, 214/255, 0.10),
                darkRGBA:  (122/255, 177/255, 255/255, 0.14)
            )
        case .email:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (0/255, 122/255, 153/255, 0.10),
                darkRGBA:  (91/255, 200/255, 228/255, 0.14)
            )
        case .social:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (192/255, 72/255, 96/255, 0.10),
                darkRGBA:  (255/255, 143/255, 163/255, 0.14)
            )
        case .notes:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (126/255, 124/255, 0/255, 0.10),
                darkRGBA:  (217/255, 214/255, 112/255, 0.14)
            )
        case .docs:
            return DS.Color.accentSoft
        case .code:
            return DS.Color.successSoft
        case .search:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (155/255, 103/255, 0/255, 0.10),
                darkRGBA:  (232/255, 180/255, 90/255, 0.14)
            )
        case .uncategorized:
            return DS.Color.bgActive
        }
    }

    static func border(for category: AppCategory) -> Color {
        switch category {
        case .messaging:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (51/255, 115/255, 214/255, 0.22),
                darkRGBA:  (122/255, 177/255, 255/255, 0.26)
            )
        case .email:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (0/255, 122/255, 153/255, 0.22),
                darkRGBA:  (91/255, 200/255, 228/255, 0.26)
            )
        case .social:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (192/255, 72/255, 96/255, 0.22),
                darkRGBA:  (255/255, 143/255, 163/255, 0.26)
            )
        case .notes:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (126/255, 124/255, 0/255, 0.22),
                darkRGBA:  (217/255, 214/255, 112/255, 0.26)
            )
        case .docs:          return DS.Color.accentBorder
        case .code:          return DS.Color.successBorder
        case .search:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (155/255, 103/255, 0/255, 0.22),
                darkRGBA:  (232/255, 180/255, 90/255, 0.26)
            )
        case .uncategorized: return DS.Color.borderDefault
        }
    }

    /// Soft tint used as the banner gradient inside the drill-in
    /// header. Slightly more transparent than `fill` so it reads as a
    /// glow rather than a flat panel.
    static func glow(for category: AppCategory) -> Color {
        switch category {
        case .messaging:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (51/255, 115/255, 214/255, 0.10),
                darkRGBA:  (122/255, 177/255, 255/255, 0.16)
            )
        case .email:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (0/255, 122/255, 153/255, 0.10),
                darkRGBA:  (91/255, 200/255, 228/255, 0.16)
            )
        case .social:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (192/255, 72/255, 96/255, 0.10),
                darkRGBA:  (255/255, 143/255, 163/255, 0.16)
            )
        case .notes:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (126/255, 124/255, 0/255, 0.10),
                darkRGBA:  (217/255, 214/255, 112/255, 0.16)
            )
        case .docs:          return DS.Color.accentSoft
        case .code:          return DS.Color.successSoft
        case .search:
            return SwiftUI.Color.dsDynamic(
                lightRGBA: (155/255, 103/255, 0/255, 0.10),
                darkRGBA:  (232/255, 180/255, 90/255, 0.16)
            )
        case .uncategorized: return DS.Color.bgActive
        }
    }
}

// MARK: - PromptTextEditor
//
// Editor used by both the global card and the drill-in's category
// prompt editor. Mono-friendly variant matches `.global-textarea` and
// `.prompt-textarea` in prompts.html — bg-inset fill, hairline border,
// accent focus ring on focus.

struct PromptTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 96
    var isMono: Bool = true
    var isHighlighted: Bool = false
    /// Fires on every keystroke. Used to push the value into the store
    /// (debouncing is the caller's responsibility — both writers in
    /// this module just fire-and-forget into an actor).
    var onCommit: (String) -> Void = { _ in }

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(DS.Color.textQuaternary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextEditor(text: $text)
                .font(font)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.clear)
                // Tints the caret (and selection accent) with the
                // brand violet instead of the system blue. Macro hits
                // both the blinking insertion cursor and the
                // selection highlight via `NSTextView.insertionPointColor`.
                .tint(DS.Color.accent)
                .focused($isFocused)
                .onChange(of: text) { _, newValue in
                    onCommit(newValue)
                }
        }
        .frame(minHeight: minHeight, alignment: .topLeading)
        .background(
            isHighlighted ? DS.Color.accentSoft : DS.Color.bgInset,
            in: RoundedRectangle(cornerRadius: DS.Radius.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(borderColor, lineWidth: isFocused ? 1.0 : DS.Border.hairline)
        )
        .overlay(
            // Accent focus ring (3 pt soft halo) — mirrors `box-shadow:
            // 0 0 0 3px var(--accent-soft)` in the design.
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(DS.Color.accentSoft, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
                .blur(radius: 0)
                .allowsHitTesting(false)
        )
        .animation(DS.Motion.fast, value: isFocused)
    }

    private var font: Font {
        isMono
            ? .system(size: 12.5, design: .monospaced)
            : DS.Font.bodySM()
    }

    private var borderColor: Color {
        if isFocused { return DS.Color.accent }
        if isHighlighted { return DS.Color.accentBorder }
        return DS.Color.borderSubtle
    }
}

// MARK: - DSTextEditor (kept for back-compat consumers)
//
// Same multi-line editor that the previous Instructions surface
// exposed. Kept verbatim so any other call sites that still consume it
// (e.g. external tests) keep compiling — the redesigned Instructions
// flow uses `PromptTextEditor` instead.

struct DSTextEditor: View {
    let placeholder: String
    let initialText: String
    let onChange: (String) -> Void
    let minHeight: CGFloat

    @State private var text: String
    @State private var isFocused = false

    init(
        placeholder: String,
        text: String,
        onChange: @escaping (String) -> Void,
        minHeight: CGFloat = 100
    ) {
        self.placeholder = placeholder
        self.initialText = text
        self.onChange = onChange
        self.minHeight = minHeight
        self._text = State(initialValue: text)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(DS.Font.bodySM())
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.clear)
                .tint(DS.Color.accent)
                .onChange(of: text) { _, newValue in
                    onChange(newValue)
                }
        }
        .frame(minHeight: minHeight, alignment: .topLeading)
        .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
    }
}

// MARK: - InstructionsPanel (kept for the drill-in)
//
// Generic shell with a head row (title + optional meta + optional
// trailing slot) and a body slot. Used by the drill-in for the prompt
// editor and the apps card. Mirrors the design's `.card` shell.

struct InstructionsPanel<Content: View, Trailing: View>: View {
    let title: String
    let meta: String?
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer(minLength: 0)
                if let meta {
                    Text(meta)
                        .font(DS.Font.labelMono())
                        .foregroundStyle(DS.Color.textQuaternary)
                        .tracking(0.5)
                        .textCase(.uppercase)
                }
                trailing()
            }
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.top, DS.Space.s4 + 2)
            .padding(.bottom, DS.Space.s3 - 2)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg - 2))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg - 2)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
    }
}

extension InstructionsPanel where Trailing == EmptyView {
    init(
        title: String,
        meta: String?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, meta: meta, trailing: { EmptyView() }, content: content)
    }
}
