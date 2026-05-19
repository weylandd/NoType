import SwiftUI

/// Dictionary tab — two side-by-side concerns under one tab:
///
/// 1. **Auto-replacement** — find/replace pairs applied to the final
///    transcript before paste (pure client-side, see
///    `TextReplacementEngine`). Local-only — never sent to Gemini.
/// 2. **Personal dictionary** — canonical spellings shipped in the
///    `User dictionary:` Gemini cache-prefix section to bias
///    transcription. Mix of user-typed (sticky) and auto-extracted
///    (FIFO trim past 100 total) entries; once the user has all
///    `DictionarySnapshot.maxTotalEntries` (100) slots filled with
///    manual entries, auto-extraction pauses entirely (ADR-016). The
///    count chip turns warning-coloured at ≥80 manual entries as an
///    earlier soft signal, but only the 100-mark gates the harvester.
///
/// Layout: header → two section blocks. Each block has a mono section
/// heading (label + short hint + a trailing scope pill) and a
/// `bg-surface` card body grouping rows, an add row, and a footer.
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
                VStack(alignment: .leading, spacing: DS.Space.s6 + 2) {
                    replacementsSection
                    dictionarySection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.s7 + 4)
                .padding(.top, DS.Space.s7)
                .padding(.bottom, DS.Space.s9)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.s4) {
            Text("Dictionary")
                .font(DS.Font.title(.semibold))
                .foregroundStyle(DS.Color.textPrimary)
            DictScopeCrumb(text: "Vocabulary · Auto-replace")
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

    // MARK: - Auto-replacement section

    private var replacementsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3 + 2) {
            DictSectionHeader(
                title: "Auto-replacement",
                hint: "find \u{2192} replace, whole words, applied before paste",
                scope: .localOnly
            )
            DictCard {
                cardHead(
                    title: "Pairs",
                    count: "\(appState.dictionaryReplacements.count)",
                    trailing: AnyView(
                        Text("Lowercase keys auto-match capitalised forms")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DS.Color.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    )
                )

                if appState.dictionaryReplacements.isEmpty {
                    replacementsEmpty
                } else {
                    VStack(spacing: 0) {
                        ForEach(appState.dictionaryReplacements) { pair in
                            ReplacementRow(
                                replacement: pair,
                                onRemove: { appState.removeReplacement(id: pair.id) }
                            )
                        }
                    }
                }

                addReplacementRow

                cardFootNote(
                    icon: .lock,
                    bold: "Local.",
                    rest: " Pairs are applied on your Mac after the transcript comes back. Never sent to Gemini."
                )
            }
        }
    }

    private var replacementsEmpty: some View {
        VStack(spacing: 4) {
            Text("No replacements yet")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.Color.textSecondary)
            Text("Add shortcuts you type a lot — they'll be expanded after the transcript comes back from Gemini.")
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Color.textQuaternary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .overlay(DS.Color.borderSubtle.frame(height: 1), alignment: .top)
    }

    private var addReplacementRow: some View {
        HStack(alignment: .center, spacing: DS.Space.s4) {
            DictAddTextField(
                placeholder: "btw",
                text: $draftFrom,
                monospaced: true,
                onCommit: addPair
            )
            DSIcon(name: .arrowRight, size: 13, color: DS.Color.textQuaternary)
                .frame(width: 18, alignment: .center)
            DictAddTextField(
                placeholder: "by the way",
                text: $draftTo,
                monospaced: false,
                onCommit: addPair
            )
            DSPrimaryButton(
                label: "Add",
                size: .medium,
                action: addPair
            )
            .disabled(draftFrom.trimmingCharacters(in: .whitespaces).isEmpty
                   || draftTo.trimmingCharacters(in: .whitespaces).isEmpty)
            .frame(width: Self.trailingGutter, alignment: .trailing)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, DS.Space.s4 - 1)
        .background(DS.Color.bgInset.opacity(0.30))
        .overlay(DS.Color.borderSubtle.frame(height: 1), alignment: .top)
    }

    /// Shared right-side column width used by both `ReplacementRow` and
    /// `addReplacementRow`. Keeping the trailing slot a fixed width
    /// guarantees the two arrows sit at the same X column across the
    /// list rows and the inline add form.
    fileprivate static let trailingGutter: CGFloat = 64

    private func addPair() {
        let f = draftFrom.trimmingCharacters(in: .whitespaces)
        let t = draftTo.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty else { return }
        appState.addReplacement(from: f, to: t)
        draftFrom = ""
        draftTo = ""
    }

    // MARK: - Dictionary section

    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3 + 2) {
            DictSectionHeader(
                title: "Dictionary",
                hint: "canonical spellings sent to Gemini as a hint",
                scope: appState.dictionaryEnabled ? .sentToGemini : .paused
            )
            DictCard {
                cardHead(
                    title: "Words",
                    count: "\(totalCount)",
                    countSuffix: "/\(DictionarySnapshot.maxTotalEntries)",
                    countIsNear: userCount >= 80,
                    trailing: AnyView(useDictionaryToggle)
                )

                Group {
                    if autoExtractionPaused {
                        warnBanner
                    }

                    addEntryRow

                    if totalCount == 0 {
                        emptyDictionary
                    } else {
                        legend
                        chipCloud
                    }

                    dictionaryFoot
                }
                .opacity(appState.dictionaryEnabled ? 1 : 0.45)
                .animation(DS.Motion.base, value: appState.dictionaryEnabled)
            }
        }
    }

    private var useDictionaryToggle: some View {
        HStack(spacing: DS.Space.s3) {
            Text("Use dictionary")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary)
            Toggle(
                "Use dictionary",
                isOn: Binding(
                    get: { appState.dictionaryEnabled },
                    set: { appState.setDictionaryEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(DS.Color.accent)
            .help("Ship the dictionary in Gemini's prompt to bias transcription toward these spellings. Off keeps your terms saved but stops sending them.")
        }
    }

    private var warnBanner: some View {
        HStack(alignment: .top, spacing: DS.Space.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(DS.Color.warningSoft)
                    .frame(width: 22, height: 22)
                DSIcon(name: .warning, size: 12, color: DS.Color.warningFg)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictionary full of manual entries.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Text("Auto-harvest is paused — remove a few words to let NoType pick up new ones again.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(DS.Color.warningSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(DS.Color.warningBorder, lineWidth: DS.Border.hairline)
        )
        .padding(.horizontal, 18)
        .padding(.top, DS.Space.s4 - 1)
    }

    private var addEntryRow: some View {
        HStack(alignment: .center, spacing: DS.Space.s3 + 2) {
            DictAddEntryField(
                placeholder: "Add a word — brand, name, jargon",
                text: $draftWord,
                onCommit: addEntry,
                maxLength: DictionarySnapshot.maxEntryLength
            )
            DSPrimaryButton(
                label: "Add",
                size: .medium,
                action: addEntry
            )
            .disabled(draftWord.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, DS.Space.s4 - 1)
        .overlay(DS.Color.borderSubtle.frame(height: 1), alignment: .top)
    }

    private func addEntry() {
        let w = draftWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, w.count <= DictionarySnapshot.maxEntryLength else { return }
        appState.addUserDictionaryEntry(w)
        draftWord = ""
    }

    private var emptyDictionary: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(DS.Color.bgInset)
                    .frame(width: 36, height: 36)
                DSIcon(name: .bookmark, size: 14, color: DS.Color.textTertiary)
            }
            .padding(.bottom, 2)
            Text("Build your dictionary")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Color.textSecondary)
            Text("Add brands, names and jargon you dictate often — Gemini will spell them the way you wrote them (GitHub, not git hub; Cursor, not курсор).")
                .font(.system(size: 12))
                .foregroundStyle(DS.Color.textQuaternary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 32)
        .overlay(DS.Color.borderSubtle.frame(height: 1), alignment: .top)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(label: "You added", style: .user)
            legendItem(label: "Auto-harvested", style: .auto)
        }
        .font(.system(size: 10, design: .monospaced))
        .tracking(0.6)
        .textCase(.uppercase)
        .foregroundStyle(DS.Color.textQuaternary)
        .padding(.horizontal, 18)
        .padding(.top, DS.Space.s3)
        .padding(.bottom, 2)
    }

    private func legendItem(label: String, style: DictEntryStyle) -> some View {
        HStack(spacing: 6) {
            Group {
                switch style {
                case .user:
                    Circle()
                        .fill(DS.Color.accentSoft)
                        .overlay(Circle().strokeBorder(DS.Color.accentBorder, lineWidth: DS.Border.hairline))
                case .auto:
                    Circle()
                        .fill(Color.clear)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    DS.Color.borderDefault,
                                    style: StrokeStyle(lineWidth: DS.Border.hairline + 0.2, dash: [1.2, 1.2])
                                )
                        )
                }
            }
            .frame(width: 10, height: 10)
            Text(label)
        }
    }

    private var chipCloud: some View {
        FlowLayout(spacing: 6, runSpacing: 6) {
            ForEach(sortedEntries) { entry in
                DictChip(
                    text: entry.word,
                    style: entry.source == .user ? .user : .auto,
                    onRemove: { appState.removeDictionaryEntry(id: entry.id) }
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, DS.Space.s3 + 2)
        .padding(.bottom, DS.Space.s5)
    }

    @ViewBuilder
    private var dictionaryFoot: some View {
        let active = appState.dictionaryEnabled
        let metaText = active
            ? "Active · attached as cache prefix"
            : "Paused · words kept, not sent to Gemini"
        let canClear = totalCount > 0

        HStack(spacing: DS.Space.s3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? DS.Color.accentFg : DS.Color.textQuaternary)
                    .frame(width: 5, height: 5)
                    // Accent-tinted halo matching the design's
                    // `box-shadow: 0 0 6px var(--accent-fg)` on the
                    // active dot. Same shape as the existing
                    // `statusDotGlow` token but in the accent hue;
                    // not promoted to a token until a second site
                    // wants the same glow.
                    .shadow(color: active ? DS.Color.accentFg.opacity(0.6) : .clear, radius: 3)
                Text(metaText)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(DS.Color.textQuaternary)
            Spacer(minLength: DS.Space.s3)
            if canClear {
                ClearStagedButton(
                    label: clearButtonLabel,
                    destructive: autoCount == 0,
                    action: clearAllStaged
                )
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, DS.Space.s3)
        .overlay(DS.Color.borderSubtle.frame(height: 1), alignment: .top)
    }

    private var clearButtonLabel: String {
        if autoCount > 0 { return "Clear \(autoCount) auto-harvested" }
        if userCount > 0 { return "Clear all \(userCount)" }
        return "Clear"
    }

    /// Stage 1 (auto entries present) → wipe auto.
    /// Stage 2 (only user entries left) → wipe user.
    /// Stage 0 (nothing) — button is hidden so this is unreachable.
    private func clearAllStaged() {
        if autoCount > 0 {
            appState.clearAutoDictionaryEntries()
        } else if userCount > 0 {
            appState.clearUserDictionaryEntries()
        }
    }

    // MARK: - Card chrome helpers

    @ViewBuilder
    private func cardHead(
        title: String,
        count: String,
        countSuffix: String? = nil,
        countIsNear: Bool = false,
        trailing: AnyView
    ) -> some View {
        HStack(alignment: .center, spacing: DS.Space.s3) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                HStack(spacing: 0) {
                    Text(count)
                        .foregroundStyle(countIsNear ? DS.Color.warningFg : DS.Color.textTertiary)
                    if let suffix = countSuffix {
                        Text(suffix)
                            .foregroundStyle(DS.Color.textQuaternary)
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
            }
            Spacer(minLength: DS.Space.s3)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.top, DS.Space.s4 + 2)
        .padding(.bottom, DS.Space.s4 - 2)
    }

    @ViewBuilder
    private func cardFootNote(icon: DSIconName, bold: String, rest: String) -> some View {
        HStack(spacing: 6) {
            DSIcon(name: icon, size: 11, color: DS.Color.textQuaternary)
            (Text(bold).foregroundStyle(DS.Color.textSecondary)
              + Text(rest).foregroundStyle(DS.Color.textQuaternary))
                .font(.system(size: 10.5, design: .monospaced))
                .tracking(0.4)
        }
        .padding(.horizontal, 18)
        .padding(.top, DS.Space.s3)
        .padding(.bottom, DS.Space.s3 + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(DS.Color.borderSubtle.frame(height: 1), alignment: .top)
    }
}

// MARK: - Dict card chrome

/// `bg-surface` card with hairline border, radius 10, overflow clipped.
/// Differs from `DSCard` in that it doesn't render a head — callers
/// stack their own head row + content rows + footer with hairlines
/// rendered by each child as a top-edge overlay (matches the design's
/// "every block has a top border" rule rather than DSCard's row-owns-top
/// rule which would force `hideTopBorder` flags everywhere).
private struct DictCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DS.Color.bgSurface,
            in: RoundedRectangle(cornerRadius: DS.Radius.lg - 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg - 2)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg - 2))
    }
}

// MARK: - Section header (mono H2 + hint + scope pill)

private struct DictSectionHeader: View {
    let title: String
    let hint: String
    let scope: DictScopePill.Variant

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.88)
                .textCase(.uppercase)
                .foregroundStyle(DS.Color.textTertiary)
            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Color.textQuaternary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Space.s3)
            DictScopePill(variant: scope)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}

// MARK: - Scope pill (mono uppercase chip with hairline border)

private struct DictScopePill: View {
    enum Variant {
        case localOnly       // hairline border, quaternary fg
        case sentToGemini    // accent soft fill + accent border, accent fg
        case paused          // same neutral as localOnly with sparkle
    }

    let variant: Variant

    var body: some View {
        HStack(spacing: 5) {
            DSIcon(name: icon, size: 10, color: foreground)
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.xs))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xs)
                .strokeBorder(border, lineWidth: DS.Border.hairline)
        )
        .help(help)
    }

    private var icon: DSIconName {
        switch variant {
        case .localOnly:     return .lock
        case .sentToGemini:  return .sparkle
        case .paused:        return .sparkle
        }
    }

    private var label: String {
        switch variant {
        case .localOnly:     return "Local only"
        case .sentToGemini:  return "Sent to Gemini"
        case .paused:        return "Paused"
        }
    }

    private var foreground: Color {
        switch variant {
        case .localOnly, .paused: return DS.Color.textQuaternary
        case .sentToGemini:       return DS.Color.accentFg
        }
    }

    private var background: Color {
        switch variant {
        case .localOnly, .paused: return .clear
        case .sentToGemini:       return DS.Color.accentSoft
        }
    }

    private var border: Color {
        switch variant {
        case .localOnly, .paused: return DS.Color.borderSubtle
        case .sentToGemini:       return DS.Color.accentBorder
        }
    }

    private var help: String {
        switch variant {
        case .localOnly:    return "Replacements never leave your Mac."
        case .sentToGemini: return "Attached to every Gemini request, in the cache prefix."
        case .paused:       return "Dictionary is off — words kept, not sent to Gemini."
        }
    }
}

// MARK: - Header breadcrumb pill

private struct DictScopeCrumb: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .tracking(0.4)
            .foregroundStyle(DS.Color.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.xs)
                    .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
            )
            .lineLimit(1)
    }
}

// MARK: - Replacement row

private enum DictEntryStyle { case user, auto }

private struct ReplacementRow: View {
    let replacement: DictionaryReplacement
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: DS.Space.s4) {
            // `from` column: left-aligned monospace pill
            Text(replacement.from)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(DS.Color.bgInset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
                )
                .frame(maxWidth: .infinity, alignment: .leading)

            DSIcon(name: .arrowRight, size: 13, color: DS.Color.textQuaternary)
                .frame(width: 18, alignment: .center)

            // `to` column
            Text(replacement.to)
                .font(.system(size: 13))
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // delete (visible on row hover) — right-aligned within the
            // shared trailing gutter so its column matches the Add
            // button below and the two arrows align horizontally.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button(action: onRemove) {
                    DSIcon(name: .x, size: 11, color: hovered ? DS.Color.dangerFg : DS.Color.textQuaternary)
                        .frame(width: 24, height: 24)
                        .background(
                            hovered ? DS.Color.dangerSoft : .clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                }
                .buttonStyle(.plain)
                .opacity(hovered ? 1 : 0)
                .accessibilityLabel("Remove \(replacement.from)")
            }
            .frame(width: DictionaryView.trailingGutter)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, DS.Space.s3 + 2)
        .background(hovered ? DS.Color.bgHover : .clear)
        .overlay(DS.Color.borderSubtle.frame(height: 1), alignment: .top)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
    }
}

// MARK: - Add-pair inline text field

/// 28pt-tall input matching the design's repl-add field: `bg-base` fill,
/// hairline border, optional monospace face for the `find` side. Focus
/// state echoes the accent border + 3pt accent-soft outer halo from the
/// spec.
private struct DictAddTextField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool = false
    var onCommit: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(DS.Color.bgBase, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(focused ? DS.Color.accent : DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(focused ? DS.Color.accentSoft : .clear, lineWidth: 3)
                    .padding(-2)
            )
            .focused($focused)
            .onSubmit(onCommit)
            .animation(DS.Motion.fast, value: focused)
    }
}

// MARK: - Dictionary add-entry field (with embedded counter)

private struct DictAddEntryField: View {
    let placeholder: String
    @Binding var text: String
    var onCommit: () -> Void = {}
    let maxLength: Int

    @FocusState private var focused: Bool

    private var counter: Int { text.count }
    private var isNear: Bool { counter >= maxLength - 5 && counter < maxLength }
    private var isOver: Bool { counter >= maxLength }

    var body: some View {
        HStack(spacing: 0) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DS.Color.textPrimary)
                .focused($focused)
                .onSubmit(onCommit)
                .onChange(of: text) { _, newValue in
                    if newValue.count > maxLength {
                        text = String(newValue.prefix(maxLength))
                    }
                }
            Text("\(counter)/\(maxLength)")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .tracking(0.4)
                .foregroundStyle(counterColor)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(DS.Color.bgBase, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused ? DS.Color.accent : DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused ? DS.Color.accentSoft : .clear, lineWidth: 3)
                .padding(-2)
        )
        .animation(DS.Motion.fast, value: focused)
    }

    private var counterColor: Color {
        if isOver { return DS.Color.dangerFg }
        if isNear { return DS.Color.warningFg }
        return DS.Color.textQuaternary
    }
}

// MARK: - Dictionary chip
//
// Mirrors design `.dchip` — two variants share the same shape; only the
// fill / border / text-color differ:
//   - `.user`: filled accent-soft + accent-border, accent-fg text.
//   - `.auto`: transparent fill, dashed neutral border, text-secondary.
//
// The legend above the chip cloud carries the legend; the dashed
// border + softer text on `.auto` chips is enough on its own to
// distinguish them at a glance.

private struct DictChip: View {
    let text: String
    let style: DictEntryStyle
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .padding(.leading, 10)
                .padding(.trailing, 4)

            Button(action: onRemove) {
                DSIcon(name: .x, size: 8, color: removeColor)
                    .frame(width: 18, height: 18)
                    .background(
                        hovered ? removeBg : .clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel("Remove \(text)")
        }
        .frame(height: 26)
        .background(background, in: RoundedRectangle(cornerRadius: 999))
        .overlay(borderOverlay)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
    }

    private var textColor: Color {
        switch style {
        case .user: return DS.Color.accentFg
        case .auto: return DS.Color.textSecondary
        }
    }

    private var background: Color {
        switch style {
        case .user: return DS.Color.accentSoft
        case .auto: return .clear
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        switch style {
        case .user:
            RoundedRectangle(cornerRadius: 999)
                .strokeBorder(DS.Color.accentBorder, lineWidth: DS.Border.hairline)
        case .auto:
            RoundedRectangle(cornerRadius: 999)
                .strokeBorder(
                    DS.Color.borderDefault,
                    style: StrokeStyle(lineWidth: DS.Border.hairline + 0.2, dash: [2, 2])
                )
        }
    }

    private var removeColor: Color {
        switch style {
        case .user: return DS.Color.accentFg.opacity(hovered ? 1.0 : 0.55)
        case .auto: return DS.Color.textSecondary.opacity(hovered ? 1.0 : 0.55)
        }
    }

    private var removeBg: Color {
        switch style {
        case .user: return DS.Color.accentFg.opacity(0.14)
        case .auto: return DS.Color.textSecondary.opacity(0.14)
        }
    }
}

// MARK: - Two-stage clear-all button

private struct ClearStagedButton: View {
    let label: String
    let destructive: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                DSIcon(name: .refresh, size: 11, color: foreground)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(foreground)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(fill, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(border, lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
        .animation(DS.Motion.fast, value: destructive)
        .help(destructive
              ? "Clear all your typed terms too."
              : "Clear auto-extracted terms. Your typed ones stay.")
        .accessibilityLabel(label)
    }

    private var foreground: Color {
        if destructive { return DS.Color.dangerFg }
        return hovered ? DS.Color.textPrimary : DS.Color.textSecondary
    }

    private var fill: Color {
        if destructive {
            // Hover shifts toward the more saturated danger-base, matching
            // the design's `color-mix(in oklab, --danger-soft 60%,
            // --danger-base)` recipe. Resting state stays at the soft tint.
            return hovered ? DS.Color.dangerBase.opacity(0.25) : DS.Color.dangerSoft
        }
        return hovered ? DS.Color.bgHover : DS.Color.bgInset.opacity(0.6)
    }

    private var border: Color {
        if destructive { return DS.Color.dangerBorder }
        return DS.Color.borderSubtle
    }
}

// MARK: - Flow layout

/// Minimal CSS-flexbox-style wrap layout. Lays subviews left-to-right
/// in rows, wrapping to a new row when the next subview would overflow
/// the parent's width. Used for the dictionary tag cloud.
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
