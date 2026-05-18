import SwiftUI

/// Language & Paste pane of the redesigned Settings screen. Three cards:
///   1. Output languages — wrapping accent-soft chip strip with an
///      inline "Add language" affordance opening the existing
///      `ManageLanguagesSheet` (via `OutputLanguagePicker` machinery).
///   2. Transcripts history — Delete-all row that wipes the last-10
///      menu-bar transcripts only. Stats are preserved.
///   3. Analytics — Delete-all row that wipes the aggregate stats
///      (Home dashboard + Token usage panel). Transcripts are
///      preserved. The two wipes are deliberately separate so the
///      user can scrub one source without the other.
struct LanguagePastePane: View {
    @Environment(AppState.self) private var appState

    let onDeleteAllTranscripts: () -> Void
    let onDeleteAllAnalytics: () -> Void

    @State private var showingManageSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            languagesCard
            historyCard
            analyticsCard
        }
        .sheet(isPresented: $showingManageSheet) {
            ManageLanguagesSheetWrapper(isPresented: $showingManageSheet)
                .environment(appState)
        }
    }

    // MARK: - Languages

    private var languagesCard: some View {
        let codes = appState.outputLanguages
        var subtitle = AttributedString("Frozen at session start and sent as the ")
        subtitle.foregroundColor = DS.Color.textTertiary
        var section = AttributedString("User languages")
        section.font = DS.Font.bodySM(.medium)
        section.foregroundColor = DS.Color.textSecondary
        subtitle.append(section)
        var tail = AttributedString(" section of the cache prefix. Order doesn't matter.")
        tail.foregroundColor = DS.Color.textTertiary
        subtitle.append(tail)

        return DSCard(title: "Output languages", meta: "Sent to Gemini") {
            DSCardRow(
                title: "Languages you speak & write in",
                subtitle: subtitle,
                layout: .col
            ) {
                LanguageChipsRow(
                    codes: codes,
                    onRemove: { code in
                        appState.outputLanguages.removeAll { $0 == code }
                    },
                    onAdd: { showingManageSheet = true }
                )
            }
        }
    }

    // MARK: - History

    private var historyCard: some View {
        DSCard(title: "Transcripts history", meta: "Last 10 sessions") {
            DSCardRow(
                title: "Delete all transcripts",
                subtitle: Self.deleteSubtitle
            ) {
                DSDestructiveButton(label: "Delete all", action: onDeleteAllTranscripts)
            }
        }
    }

    private static var deleteSubtitle: AttributedString {
        var s = AttributedString("Wipes the last 10 transcripts shown in the menu-bar popover. Usage stats — session count, words, tokens, per-app breakdown — are ")
        s.foregroundColor = DS.Color.textTertiary
        var kept = AttributedString("kept")
        kept.font = DS.Font.bodySM(.medium)
        kept.foregroundColor = DS.Color.textSecondary
        s.append(kept)
        var tail = AttributedString(".")
        tail.foregroundColor = DS.Color.textTertiary
        s.append(tail)
        return s
    }

    // MARK: - Analytics

    private var analyticsCard: some View {
        DSCard(title: "Analytics", meta: "Local only") {
            DSCardRow(
                title: "Delete all analytics",
                subtitle: Self.analyticsSubtitle
            ) {
                DSDestructiveButton(label: "Delete all", action: onDeleteAllAnalytics)
            }
        }
    }

    private static var analyticsSubtitle: AttributedString {
        var s = AttributedString("Resets the Home dashboard and the Token usage panel — session counts, word totals, time-saved, per-app breakdown, and Gemini token totals all return to zero. Transcripts in the menu-bar popover are ")
        s.foregroundColor = DS.Color.textTertiary
        var kept = AttributedString("kept")
        kept.font = DS.Font.bodySM(.medium)
        kept.foregroundColor = DS.Color.textSecondary
        s.append(kept)
        var tail = AttributedString(".")
        tail.foregroundColor = DS.Color.textTertiary
        s.append(tail)
        return s
    }
}

// MARK: - Chips row

private struct LanguageChipsRow: View {
    let codes: [String]
    let onRemove: (String) -> Void
    let onAdd: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)
    ]

    var body: some View {
        let chips = OutputLanguagePicker.displayChips(for: codes)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(chips, id: \.code) { entry in
                LanguageChip(
                    code: entry.code,
                    label: entry.label,
                    onRemove: { onRemove(entry.code) }
                )
            }
            AddLanguageChip(action: onAdd)
        }
    }
}

private struct LanguageChip: View {
    let code: String
    let label: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(LanguageEmoji.flag(for: code))
                .font(.system(size: 13))
            Text(label)
                .font(DS.Font.bodySM(.medium))
                .foregroundStyle(DS.Color.accentFg)
            Button(action: onRemove) {
                DSIcon(name: .x, size: 9, color: DS.Color.accentFg)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.55)
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(DS.Color.accentSoft, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.Color.accentBorder, lineWidth: DS.Border.hairline))
    }

}

private struct AddLanguageChip: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                DSIcon(name: .plus, size: 11, color: isHovering ? DS.Color.textPrimary : DS.Color.textSecondary)
                Text("Add language")
                    .font(DS.Font.bodySM(.medium))
                    .foregroundStyle(isHovering ? DS.Color.textPrimary : DS.Color.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                isHovering ? DS.Color.bgHover : .clear,
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(DS.Color.borderDefault, lineWidth: DS.Border.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Add language")
    }
}

// MARK: - Manage sheet wrapper
//
// The existing `ManageLanguagesSheet` is private to OutputLanguagePicker.
// Rather than refactor visibility, we re-host the same sheet content
// here through the public `OutputLanguagePicker` shell — when the user
// taps "Add language" we mount a transparent host view that drives the
// existing `showingSheet` path. To avoid that indirection mess we
// inline a thin re-implementation: a wrapper that puts up the same
// `ManageLanguagesSheet` via OutputLanguagePicker's API.
//
// Trick: render OutputLanguagePicker invisibly with a programmatic
// open binding, then route showingManageSheet through it. The picker
// already exposes the sheet on its body; mounting it offscreen gives
// us the same sheet without duplicating the multi-select grid.

private struct ManageLanguagesSheetWrapper: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool

    var body: some View {
        // The original picker's ManageLanguagesSheet is private. To
        // avoid duplicating ~150 lines of multi-select UI we reuse
        // the picker by handing it the same environment and an
        // explicit open trigger via reflection-style state. Cheapest
        // route: just present OutputLanguagePicker.ManageLanguagesSheet
        // by routing through the picker's existing sheet, which
        // happens via mounting the picker invisibly. We can't reach
        // the private type — so this wrapper renders an inline
        // version sufficient for v1 (search + scrolling multi-select),
        // matching the design's "add language" intent.
        ManageLanguagesInlineSheet(isPresented: $isPresented)
            .environment(appState)
    }
}

/// Lightweight re-skin of ManageLanguagesSheet, scoped to this pane.
/// Keeps the search + scrolling multi-select interaction without
/// reaching into OutputLanguagePicker's private types.
private struct ManageLanguagesInlineSheet: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Output languages")
                    .font(DS.Font.bodyMD(.semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer()
                DSCloseButton { isPresented = false }
                    .accessibilityLabel("Close")
            }

            Text("Pick the languages you dictate in. Sent to Gemini on every transcription as a hint — empty is fine (the model will detect language from audio).")
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Space.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Color.textTertiary)
                TextField("Search languages", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.vertical, DS.Space.s2 + 2)
            .background(DS.Color.bgInset,
                        in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(DS.Color.borderDefault, lineWidth: DS.Border.hairline)
            )

            let filtered = SupportedLanguages.filter(SupportedLanguages.all, query: query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.code) { language in
                        languageRow(
                            language: language,
                            isSelected: appState.outputLanguages.contains(language.code)
                        )
                        DSSeparator()
                    }
                    if filtered.isEmpty {
                        Text("No languages match \u{201C}\(query)\u{201D}.")
                            .font(DS.Font.bodySM())
                            .foregroundStyle(DS.Color.textTertiary)
                            .padding(.vertical, DS.Space.s4)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .frame(maxHeight: 320)
            .background(DS.Color.bgCanvas,
                        in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
            )

            HStack {
                Spacer()
                DSPrimaryButton(label: "Done") { isPresented = false }
            }
        }
        .padding(DS.Space.s5)
        .frame(width: 480, height: 560)
        .onAppear { searchFocused = true }
    }

    private func languageRow(language: SupportedLanguage, isSelected: Bool) -> some View {
        @Bindable var appState = appState
        return Button(action: { toggle(language.code) }) {
            HStack(spacing: DS.Space.s3) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? DS.Color.accentFg : DS.Color.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.name)
                        .font(DS.Font.body(.medium))
                        .foregroundStyle(DS.Color.textPrimary)
                    Text("\(language.englishName) · \(language.code)")
                        .font(DS.Font.bodySM())
                        .foregroundStyle(DS.Color.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.vertical, DS.Space.s2 + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(language.englishName), \(isSelected ? "selected" : "not selected")")
    }

    private func toggle(_ code: String) {
        if let idx = appState.outputLanguages.firstIndex(of: code) {
            appState.outputLanguages.remove(at: idx)
        } else {
            appState.outputLanguages.append(code)
        }
    }
}
