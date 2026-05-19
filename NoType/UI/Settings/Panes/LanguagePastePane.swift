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
            ManageLanguagesSheet(isPresented: $showingManageSheet)
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
        .dsOnHover { isHovering = $0 }
        .accessibilityLabel("Add language")
    }
}

// `ManageLanguagesSheet` lives in `OutputLanguagePicker.swift` (made
// internal in PR #52 — review M-01 / M-02 / C2). Both the legacy
// row picker and this pane mount the same sheet so search /
// multi-select fixes land in one place.
