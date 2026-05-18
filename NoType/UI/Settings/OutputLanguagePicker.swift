import SwiftUI

/// Settings → System → Output language row. Shows a summary of the
/// user's currently-selected BCP-47 codes; clicking Edit opens a sheet
/// with a search field + scrolling multi-select list + a selected-
/// chip strip at the top. Values are written through to
/// `AppState.outputLanguages` which persists them to UserDefaults and
/// flows them into the `User languages:` Gemini cache-prefix section
/// at the next session start. See plan
/// `2026-05-18-001-feat-settings-screen-plan.md` §584-646.
///
/// The picker is sheet-based (not inline) on purpose:
/// `SettingsTabView` wraps the whole form in a `ScrollView`, and
/// nesting a second `ScrollView` for the language list would fight
/// for vertical drag gestures. The sheet gives the list its own
/// scroll surface.
struct OutputLanguagePicker: View {
    @Environment(AppState.self) private var appState

    @State private var showingSheet = false

    var body: some View {
        @Bindable var appState = appState
        let selected = appState.outputLanguages

        VStack(alignment: .leading, spacing: 0) {
            DSSettingsRow(
                title: "Output language",
                subtitle: Self.subtitle(for: selected)
            ) {
                DSSecondaryButton(label: selected.isEmpty ? "Choose" : "Edit") {
                    showingSheet = true
                }
            }

            if !selected.isEmpty {
                let chips = Self.displayChips(for: selected)
                FlowChipStrip(chips: chips) { code in
                    appState.outputLanguages.removeAll { $0 == code }
                }
                .padding(.horizontal, DS.Space.s4)
                .padding(.bottom, DS.Space.s3)
            }
        }
        .sheet(isPresented: $showingSheet) {
            ManageLanguagesSheet(isPresented: $showingSheet)
                .environment(appState)
        }
    }

    // MARK: - Pure helpers (testable)

    /// Subtitle rendered under the row title. "Comma-separated codes
    /// preferred" copy mirrors how the section appears in the Gemini
    /// cache prefix (BCP-47 codes).
    static func subtitle(for selected: [String]) -> String {
        if selected.isEmpty {
            return "Bias Gemini towards the languages you actually dictate in."
        }
        let names = selected.map { SupportedLanguages.lookup($0)?.englishName ?? $0 }
        return "Will be sent to Gemini as: " + names.joined(separator: ", ")
    }

    /// Resolve saved codes to display chips. Codes the bundled list
    /// has dropped fall back to rendering the bare code so the user
    /// can still remove them.
    static func displayChips(for codes: [String]) -> [(code: String, label: String)] {
        codes.map { code in
            let resolved = SupportedLanguages.lookup(code)?.name ?? code
            return (code: code, label: resolved)
        }
    }
}

// MARK: - Selected chip strip

/// Wrappable row of `DSWordChip`s for the selected-language summary.
/// Uses a `LazyVGrid` so long lists wrap to multiple lines without
/// horizontal scrolling.
private struct FlowChipStrip: View {
    let chips: [(code: String, label: String)]
    let onRemove: (String) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 80), spacing: DS.Space.s2, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.s2) {
            ForEach(chips, id: \.code) { entry in
                DSWordChip(text: entry.label, style: .user) {
                    onRemove(entry.code)
                }
            }
        }
    }
}

// MARK: - Manage Languages sheet

private struct ManageLanguagesSheet: View {
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
                DSCloseButton {
                    isPresented = false
                }
                .accessibilityLabel("Close")
            }

            Text("Pick the languages you dictate in. The selection is sent to Gemini on every transcription as a hint — empty is fine (the model will detect language from audio).")
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !appState.outputLanguages.isEmpty {
                FlowChipStrip(chips: OutputLanguagePicker.displayChips(for: appState.outputLanguages)) { code in
                    appState.outputLanguages.removeAll { $0 == code }
                }
            }

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
                        Text("No languages match “\(query)”.")
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
                DSPrimaryButton(label: "Done") {
                    isPresented = false
                }
            }
        }
        .padding(DS.Space.s5)
        .frame(width: 480, height: 560)
        .onAppear { searchFocused = true }
    }

    private func languageRow(language: SupportedLanguage, isSelected: Bool) -> some View {
        @Bindable var appState = appState
        return Button(action: {
            toggle(language.code)
        }) {
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
