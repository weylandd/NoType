import SwiftUI

/// Instructions tab — global user instruction textarea + per-category
/// list. Drill-in into a row shows `CategoryDetailView`. Mirrors the
/// Home tab's sticky header + scroll body layout.
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
                VStack(alignment: .leading, spacing: DS.Space.s7) {
                    userInstructionPanel
                    categoriesPanel
                }
                .padding(.horizontal, DS.Space.s7)
                .padding(.top, DS.Space.s7)
                .padding(.bottom, DS.Space.s7)
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s4) {
            Text("Instructions")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Text("Style preferences & category prompts")
                .font(DS.Font.labelMono())
                .foregroundStyle(DS.Color.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s7)
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

    private var userInstructionPanel: some View {
        InstructionsPanel(
            title: "Your instruction",
            meta: "GLOBAL — applies to every session"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                DSTextEditor(
                    placeholder: "Your personal preferences for transcription. For example: \"prefer em-dashes over commas\", \"never use semicolons\", \"keep my Russian in the original spelling\".",
                    text: appState.userInstruction,
                    onChange: { newValue in
                        appState.updateUserInstruction(newValue)
                    },
                    minHeight: 120
                )
                Text("Free-form, optional. Applied on top of the base verbatim rules and category-specific formatting.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.bottom, DS.Space.s5)
        }
    }

    private var categoriesPanel: some View {
        InstructionsPanel(
            title: "Categories",
            meta: "FORMATTING PER DESTINATION"
        ) {
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
                        DSSeparator(leadingPadding: DS.Space.s5 + 2)
                    }
                }
            }
        }
    }

    private func appCount(for category: AppCategory) -> Int {
        appState.categoryAssignments.values.reduce(into: 0) { acc, record in
            if record.category == category { acc += 1 }
        }
    }
}

// MARK: - Row

private struct CategoryRow: View {
    let category: AppCategory
    let appCount: Int
    let hasOverride: Bool
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Space.s4) {
                CategoryIconTile(category: category)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.s2 + 1) {
                        Text(category.displayName)
                            .font(DS.Font.body(.semibold))
                            .foregroundStyle(DS.Color.textPrimary)
                        if hasOverride {
                            DSBadge(text: "custom", style: .accent)
                        }
                    }
                    Text(category.blurb)
                        .font(DS.Font.bodySM())
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(countLabel)
                    .font(DS.Font.labelMono())
                    .foregroundStyle(DS.Color.textQuaternary)
                    .tracking(0.6)
                DSIcon(name: .chevronRight, size: 14, color: DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.vertical, DS.Space.s4)
            .background(hovered ? DS.Color.bgHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
    }

    private var countLabel: String {
        if category == .search {
            return "AX-DETECTED"
        }
        if category == .uncategorized {
            return appCount == 1 ? "1 APP" : "\(appCount) APPS"
        }
        return appCount == 1 ? "1 APP" : "\(appCount) APPS"
    }
}

/// 32×32 tinted square + DS line glyph. One per category.
struct CategoryIconTile: View {
    let category: AppCategory
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(DS.Color.accentSoft)
                .frame(width: size, height: size)
            DSIcon(name: glyph, size: size * 0.55, color: DS.Color.accentFg)
        }
    }

    /// Per-category DS-line-icon mapping. Picked from `DSIconName` —
    /// no new SVG assets needed.
    private var glyph: DSIconName {
        switch category {
        case .messaging:     return .chat
        case .email:         return .inbox
        case .social:        return .star
        case .notes:         return .edit
        case .docs:          return .file
        case .code:          return .code
        case .search:        return .search
        case .uncategorized: return .folder
        }
    }
}

// MARK: - Panel chrome (mirrors HomeView.Panel but simpler)
//
// Local copy — HomeView's `Panel` is `private`. Kept tight to a single
// header row + content slot, with the same surface treatment.

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
                        .tracking(0.6)
                }
                trailing()
            }
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.top, DS.Space.s4 + 2)
            .padding(.bottom, DS.Space.s3 + 2)

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

/// Convenience init for the common case where the panel header has no
/// trailing controls. Lets existing call sites stay at
/// `InstructionsPanel(title:, meta:) { … }` without specifying a
/// trailing slot.
extension InstructionsPanel where Trailing == EmptyView {
    init(
        title: String,
        meta: String?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, meta: meta, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - DSTextEditor
//
// Multiline editor that matches our DS surface — recessed `bgInset` fill,
// subtle border, DS-typography. SwiftUI's `TextEditor` ships with an
// opaque background and macOS standard text-view chrome which clash with
// the rest of the surface; we hide the system background and apply our
// own.
//
// Local `@State` mirror keeps typing snappy while parent's `onChange`
// fires on every edit — the AppState methods write to the store
// fire-and-forget, so cheap.

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
