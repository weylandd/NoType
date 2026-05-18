import SwiftUI

/// Settings → API → Gemini key row. Shows a masked summary of the
/// currently stored key with an Edit button that opens a sheet:
/// SecureField + AI-Studio link + Save / Cancel. Save validates
/// against `validateGeminiKey` first, then writes through
/// `updateAPIKey` (existing AppState paths — no new logic).
///
/// **Security:** the error label inside the sheet must NEVER
/// surface a `GeminiError.http(status:body:)` body verbatim — the
/// body can carry partial key echo, project metadata, or quota
/// identifiers. Body redaction is enforced through the static
/// `errorMessage(for:)` helper which routes everything through
/// case-mapped messages or the body-redacted `errorDescription`
/// already implemented in `GeminiError`. Pinned by
/// `GeminiKeyRowTests.test_errorBody_doesNotLeakIntoUILabel`.
///
/// Pattern parity with `OnboardingAPIKeyStep.continueTapped` —
/// reuse the existing async validate-then-save flow rather than
/// inventing a parallel path.
struct GeminiKeyRow: View {
    @Environment(AppState.self) private var appState

    @State private var showingEditSheet = false

    var body: some View {
        let key = appState.currentAPIKey ?? ""
        DSCardRow(
            title: "API key",
            subtitle: Self.subtitle,
            hideTopBorder: true
        ) {
            HStack(spacing: DS.Space.s3) {
                MaskedKeyPill(value: Self.maskedDisplay(for: key))
                DSSecondaryButton(
                    label: "Edit",
                    leadingSystemSymbol: "pencil"
                ) {
                    showingEditSheet = true
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            EditAPIKeySheet(isPresented: $showingEditSheet)
                .environment(appState)
        }
    }

    /// Subtitle copy that includes an inline link to Google AI Studio
    /// — matches the design's "Need one? Get a key in Google AI Studio ↗".
    private static var subtitle: AttributedString {
        var s = AttributedString("Need one? ")
        s.foregroundColor = DS.Color.textTertiary
        var link = AttributedString("Get a key in Google AI Studio ↗")
        link.foregroundColor = DS.Color.accentFg
        link.link = URL(string: "https://aistudio.google.com/app/apikey")
        s.append(link)
        return s
    }

    // MARK: - Pure helpers (testable)

    /// Render `AIzaSyXXXX…` style preview for an existing key.
    /// Reveals the first 6 characters so the user can visually
    /// confirm which key is loaded, then pads with 8 middle-dot
    /// glyphs. Defensive for short / empty inputs — keeps a
    /// fixed-width display so the row layout doesn't reflow.
    static func maskedDisplay(for key: String) -> String {
        let prefix = key.prefix(6)
        return prefix + String(repeating: "•", count: 8)
    }
}

/// Masked key display pill — lock glyph + first 6 chars + 8 middle
/// dots, monospaced and slightly tracked so the dots read evenly.
private struct MaskedKeyPill: View {
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            DSIcon(name: .lock, size: 11, color: DS.Color.textQuaternary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DS.Color.textPrimary)
                .tracking(0.5)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
    }
}

extension GeminiKeyRow {
    /// Translate a thrown error from the validate / save path into
    /// the inline label shown inside the Edit sheet. Case-mapped
    /// for the two common authentication outcomes (missingKey,
    /// 401/403); falls back to `errorDescription` for every other
    /// `GeminiError` case — that property already discards the
    /// `body` field, so this is body-safe by construction.
    /// `URLError` is translated to friendly offline / timeout
    /// copy. Everything else uses Apple's localizedDescription
    /// (the catch-all path that never sees a `GeminiError`).
    static func errorMessage(for error: Error) -> String {
        if let g = error as? GeminiClient.GeminiError {
            switch g {
            case .missingKey:
                return "Invalid key — check format"
            case .http(let status, _) where status == 401 || status == 403:
                return "Authentication failed (\(status))"
            case .http, .decoding, .empty, .blocked:
                return g.errorDescription ?? "Couldn't validate key."
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet — NoType needs to reach Gemini to validate."
            case .timedOut:
                return "Validation timed out. Try again."
            default:
                return urlError.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }
}

// MARK: - Edit sheet

private struct EditAPIKeySheet: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool

    @State private var draft: String = ""
    @State private var errorMessage: String? = nil
    @State private var validating: Bool = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Update Gemini API key")
                .font(DS.Font.bodyMD(.semibold))
                .foregroundStyle(DS.Color.textPrimary)

            Text("Paste a new key. NoType validates it with Gemini before saving.")
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("AIza…", text: $draft)
                .textFieldStyle(.plain)
                .padding(.horizontal, DS.Space.s3)
                .padding(.vertical, DS.Space.s2 + 2)
                .background(DS.Color.bgInset,
                            in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .strokeBorder(
                            errorMessage != nil ? DS.Color.dangerBorder : DS.Color.borderDefault,
                            lineWidth: DS.Border.hairline
                        )
                )
                .focused($fieldFocused)
                .onChange(of: draft) { _, _ in errorMessage = nil }

            if let err = errorMessage {
                Text(err)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.dangerFg)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Link(destination: URL(string: "https://aistudio.google.com/app/apikey")!) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Get a key in Google AI Studio")
                }
                .font(.system(size: 12))
                .foregroundStyle(DS.Color.accentFg)
            }
            .buttonStyle(.plain)

            HStack(spacing: DS.Space.s3) {
                Spacer()
                DSSecondaryButton(label: "Cancel") {
                    isPresented = false
                }
                DSPrimaryButton(
                    label: validating ? "Validating" : "Save",
                    isLoading: validating,
                    isEnabled: saveEnabled,
                    accessibilityLabelOverride: "Save"
                ) {
                    save()
                }
            }
        }
        .padding(DS.Space.s5)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
    }

    private var saveEnabled: Bool {
        if validating { return false }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
    }

    private func save() {
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        validating = true
        errorMessage = nil

        Task { @MainActor in
            do {
                try await appState.validateGeminiKey(candidate)
                // Honor the Cancel-during-validation contract: if the user
                // hit Cancel while the network round-trip was in flight,
                // the binding has flipped to `false` and we must NOT write
                // the candidate to the Keychain even though validation
                // succeeded. Otherwise "Cancel" silently saves the key.
                guard isPresented else {
                    validating = false
                    return
                }
                try appState.updateAPIKey(candidate)
                validating = false
                isPresented = false
            } catch {
                validating = false
                errorMessage = GeminiKeyRow.errorMessage(for: error)
            }
        }
    }
}
