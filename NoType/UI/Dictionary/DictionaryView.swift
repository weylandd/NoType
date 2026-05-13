import SwiftUI

/// Dictionary tab — two side-by-side concerns under one tab:
///
/// 1. **Auto-replacement** — find/replace pairs applied to the final
///    transcript before paste (pure client-side, see
///    `TextReplacementEngine`).
/// 2. **Personal dictionary** — canonical spellings shipped in the
///    `User dictionary:` Gemini cache-prefix section to bias
///    transcription. Mix of user-typed (sticky) and auto-extracted
///    (FIFO trim past 100 total) entries; once the user has ≥80 manual
///    entries, auto-extraction pauses entirely (ADR-016).
///
/// Mirrors the Instructions tab's sticky-header + scroll body layout
/// and reuses `InstructionsPanel` for the panel chrome.
struct DictionaryView: View {
    @Environment(AppState.self) private var appState

    @State private var draftFrom: String = ""
    @State private var draftTo: String = ""
    @State private var draftWord: String = ""

    /// Visual sort: newest user entries first, then newest auto entries.
    private var sortedEntries: [DictionaryEntry] {
        let users = appState.dictionaryEntries
            .filter { $0.source == .user }
            .sorted { $0.addedAt > $1.addedAt }
        let autos = appState.dictionaryEntries
            .filter { $0.source == .auto }
            .sorted { $0.addedAt > $1.addedAt }
        return users + autos
    }

    private var userCount: Int { appState.dictionaryUserEntryCount }
    private var autoCount: Int { appState.dictionaryEntries.count - userCount }
    private var totalCount: Int { appState.dictionaryEntries.count }
    private var autoExtractionPaused: Bool {
        userCount >= DictionarySnapshot.maxTotalEntries
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s7) {
                    replacementsPanel
                    dictionaryPanel
                }
                .padding(.horizontal, DS.Space.s7)
                .padding(.top, DS.Space.s7)
                .padding(.bottom, DS.Space.s7)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.s4) {
            Text("Dictionary")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Text("Replacements & canonical spellings")
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

    // MARK: - Replacements panel

    private var replacementsPanel: some View {
        InstructionsPanel(
            title: "Auto-replacement",
            meta: "APPLIED AFTER TRANSCRIPTION"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(appState.dictionaryReplacements) { pair in
                    ReplacementRow(
                        replacement: pair,
                        onRemove: { appState.removeReplacement(id: pair.id) }
                    )
                    DSSeparator(leadingPadding: DS.Space.s5 + 2)
                }

                addReplacementRow

                Text("Each pair is matched on whole words. When the search side starts with a lowercase letter, the capitalized variant is auto-applied — a pair \u{201C}that is\u{201D} \u{2192} \u{201C}i.e.\u{201D} also matches \u{201C}That is\u{201D} and replaces it with the capitalized \u{201C}I.e.\u{201D}")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.s5 + 2)
                    .padding(.top, DS.Space.s3)
                    .padding(.bottom, DS.Space.s5)
            }
        }
    }

    private var addReplacementRow: some View {
        HStack(spacing: DS.Space.s3) {
            DSInlineTextField(
                placeholder: "find phrase",
                text: $draftFrom,
                onCommit: addPair
            )
            .frame(minWidth: 140)

            DSIcon(name: .arrowRight, size: 13, color: DS.Color.textTertiary)

            DSInlineTextField(
                placeholder: "replace with",
                text: $draftTo,
                onCommit: addPair
            )
            .frame(minWidth: 140)

            DSPrimaryButton(label: "Add", action: addPair)
                .disabled(draftFrom.trimmingCharacters(in: .whitespaces).isEmpty
                       || draftTo.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, DS.Space.s5 + 2)
        .padding(.vertical, DS.Space.s4)
    }

    private func addPair() {
        let f = draftFrom.trimmingCharacters(in: .whitespaces)
        let t = draftTo.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty else { return }
        appState.addReplacement(from: f, to: t)
        draftFrom = ""
        draftTo = ""
    }

    // MARK: - Dictionary panel

    private var dictionaryPanel: some View {
        InstructionsPanel(
            title: "Dictionary (\(totalCount)/100)",
            meta: autoExtractionPaused
                ? "AUTO-EXTRACTION PAUSED"
                : "SPELLING REFERENCE FOR GEMINI"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                addEntryRow

                if autoExtractionPaused {
                    pausedHint
                }

                if totalCount == 0 {
                    emptyState
                } else {
                    tagCloud
                }
            }
        }
    }

    private var addEntryRow: some View {
        HStack(spacing: DS.Space.s3) {
            DSInlineTextField(
                placeholder: "Add a term, brand, or name…",
                text: $draftWord,
                onCommit: addEntry,
                maxLength: DictionarySnapshot.maxEntryLength
            )
            DSPrimaryButton(label: "Add", action: addEntry)
                .disabled(draftWord.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer(minLength: 0)
            Text("\(DictionarySnapshot.maxEntryLength - draftWord.count) chars left")
                .font(DS.Font.labelMono())
                .foregroundStyle(draftWord.count > DictionarySnapshot.maxEntryLength
                    ? DS.Color.dangerFg
                    : DS.Color.textQuaternary)
                .tracking(0.4)
                .monospacedDigit()
        }
        .padding(.horizontal, DS.Space.s5 + 2)
        .padding(.vertical, DS.Space.s4)
    }

    private func addEntry() {
        let w = draftWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, w.count <= DictionarySnapshot.maxEntryLength else { return }
        appState.addUserDictionaryEntry(w)
        draftWord = ""
    }

    private var pausedHint: some View {
        HStack(alignment: .top, spacing: DS.Space.s3) {
            DSIcon(name: .info, size: 14, color: DS.Color.warningFg)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictionary full")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Text("All \(DictionarySnapshot.maxTotalEntries) slots are taken by your manual entries. Auto-harvest can't add new words until you remove some.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DS.Space.s5 + 2)
        .padding(.vertical, DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.warningSoft.opacity(0.6))
        .overlay(
            DS.Color.warningBorder.frame(height: 1),
            alignment: .top
        )
        .overlay(
            DS.Color.warningBorder.frame(height: 1),
            alignment: .bottom
        )
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.s2) {
            DSIcon(name: .bookmark, size: 24, color: DS.Color.textQuaternary)
            Text("No terms yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Color.textSecondary)
            Text("Add brands, names, or jargon you dictate often. Gemini will pick up canonical spellings the same way.")
                .font(.system(size: 11))
                .foregroundStyle(DS.Color.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Space.s5)
        .padding(.top, DS.Space.s5)
        .padding(.bottom, DS.Space.s6)
    }

    private var tagCloud: some View {
        FlowLayout(spacing: 6, runSpacing: 6) {
            ForEach(sortedEntries) { entry in
                DSWordChip(
                    text: entry.word,
                    style: entry.source == .user ? .user : .auto,
                    onRemove: { appState.removeDictionaryEntry(id: entry.id) }
                )
            }
        }
        .padding(.horizontal, DS.Space.s5 + 2)
        .padding(.bottom, DS.Space.s5)
    }
}

// MARK: - Replacement row

private struct ReplacementRow: View {
    let replacement: DictionaryReplacement
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: DS.Space.s3) {
            Text(replacement.from)
                .font(DS.Font.body())
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            DSIcon(name: .arrowRight, size: 13, color: DS.Color.textTertiary)

            Text(replacement.to)
                .font(DS.Font.body())
                .foregroundStyle(DS.Color.accentFg)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: DS.Space.s3)

            DSIconButton(icon: .trash, isDestructive: true, action: onRemove)
                .opacity(hovered ? 1 : 0.4)
        }
        .padding(.horizontal, DS.Space.s5 + 2)
        .padding(.vertical, DS.Space.s3)
        .background(hovered ? DS.Color.bgHover : .clear)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
    }
}

// MARK: - Inline text field

/// Single-line text field that fits the DS surface: 30 pt tall pill,
/// recessed `bgInset` fill, hairline border, DS typography. Optional
/// length cap is enforced live (clamps the bound `text`).
private struct DSInlineTextField: View {
    let placeholder: String
    @Binding var text: String
    var onCommit: () -> Void = {}
    var maxLength: Int? = nil

    @State private var focused = false

    var body: some View {
        TextField(placeholder, text: $text, onCommit: onCommit)
            .textFieldStyle(.plain)
            .font(DS.Font.bodySM())
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? DS.Color.accentBorder : DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
            )
            .onChange(of: text) { _, newValue in
                if let cap = maxLength, newValue.count > cap {
                    text = String(newValue.prefix(cap))
                }
            }
    }
}

// MARK: - Flow layout

/// Minimal CSS-flexbox-style wrap layout. Lays subviews left-to-right
/// in rows, wrapping to a new row when the next subview would overflow
/// the parent's width. Used for the dictionary tag cloud; trivial enough
/// not to need an external library.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var runSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return layout(in: maxWidth, subviews: subviews).bounds.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lay = layout(in: bounds.width, subviews: subviews)
        for (i, frame) in lay.frames.enumerated() {
            let origin = CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY)
            subviews[i].place(at: origin, proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private struct Result {
        let frames: [CGRect]
        let bounds: CGRect
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> Result {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + runSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        let totalSize = CGSize(width: maxX, height: y + rowHeight)
        return Result(frames: frames, bounds: CGRect(origin: .zero, size: totalSize))
    }
}
