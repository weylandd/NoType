import SwiftUI

/// Step 1.1 — manual API key setup.
///
/// Asks for a Gemini API key, validates it with a free `models` listing
/// call, and persists it via `appState.updateAPIKey(_)` before advancing.
///
/// Resume behaviour: when a key is already saved (the user came back to
/// this step after navigating away or relaunching), the field renders as
/// `AIzaSy••••••••` and Continue is enabled without re-validation. Tap
/// "Edit" to clear and enter a new key.
struct OnboardingAPIKeyStep: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(AppState.self)        private var appState

    @State private var draft: String = ""
    @State private var isEditing: Bool = false
    @State private var savedKey: String? = nil
    @State private var validating: Bool = false
    @State private var errorMessage: String? = nil
    @FocusState private var fieldFocused: Bool

    var body: some View {
        OnboardingChrome(stepIndex: 1) {
            VStack(alignment: .leading, spacing: DS.Space.s6) {
                heading

                VStack(alignment: .leading, spacing: DS.Space.s3 + 2) {
                    Text("Gemini API key")
                        .font(DS.Font.bodySM(.medium))
                        .foregroundStyle(DS.Color.textSecondary)

                    if !isEditing, let saved = savedKey {
                        maskedPreview(for: saved)
                    } else {
                        editableField
                    }

                    HStack(spacing: 6) {
                        Link(destination: URL(string: "https://aistudio.google.com/app/apikey")!) {
                            Text("Get a key in Google AI Studio →")
                                .font(.system(size: 11.5))
                                .foregroundStyle(DS.Color.accent)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        if let err = errorMessage {
                            Text(err)
                                .font(.system(size: 11.5))
                                .foregroundStyle(DS.Color.dangerBase)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        } footer: {
            DSPrimaryButton(
                label: validating ? "Validating…" : "Continue",
                trailingSystemSymbol: validating ? nil : "arrow.right"
            ) {
                continueTapped()
            }
            .opacity(continueEnabled ? 1.0 : 0.45)
            .disabled(!continueEnabled)
        }
        .onAppear {
            savedKey = appState.currentAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let saved = savedKey, !saved.isEmpty {
                isEditing = false
                draft = ""
            } else {
                savedKey = nil
                isEditing = true
                draft = ""
            }
            errorMessage = nil
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Text("Connect your Gemini key")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Text("NoType uses Google's Gemini 3.1 Flash-Lite to turn your voice into text. Paste an API key from Google AI Studio — it's stored locally on your Mac and used only to send Gemini your audio.")
                .font(DS.Font.bodyMD())
                .foregroundStyle(DS.Color.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var editableField: some View {
        SecureField("Paste your key", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onChange(of: draft) { _, _ in
                errorMessage = nil
            }
            .onSubmit { continueTapped() }
    }

    private func maskedPreview(for saved: String) -> some View {
        HStack(spacing: DS.Space.s3) {
            Text(maskedRepresentation(of: saved))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(DS.Color.textPrimary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DS.Color.borderDefault, lineWidth: DS.Border.hairline)
                )
            Spacer()
            DSLinkButton(label: "Edit") {
                isEditing = true
                draft = ""
                fieldFocused = true
            }
        }
    }

    private func maskedRepresentation(of key: String) -> String {
        let prefix = key.prefix(6)
        return "\(prefix)••••••••"
    }

    private var continueEnabled: Bool {
        if validating { return false }
        if !isEditing, let saved = savedKey, !saved.isEmpty { return true }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func continueTapped() {
        guard continueEnabled else { return }

        // Resume path: saved key exists and the user didn't edit. Skip
        // validation entirely — they already proved this key works.
        if !isEditing, let saved = savedKey, !saved.isEmpty {
            _ = saved   // saved is already in SecretStore
            onboarding.goNext()
            return
        }

        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        validating = true
        errorMessage = nil

        Task { @MainActor in
            do {
                try await appState.validateGeminiKey(candidate)
                try appState.updateAPIKey(candidate)
                validating = false
                onboarding.goNext()
            } catch let g as GeminiClient.GeminiError {
                validating = false
                switch g {
                case .http(let s, _) where s == 401 || s == 403:
                    errorMessage = "Gemini didn't accept this key. Double-check it in Google AI Studio."
                case .http(let s, _):
                    errorMessage = "Gemini error \(s). Try again."
                case .missingKey:
                    errorMessage = "Paste a key first."
                case .decoding, .empty, .blocked:
                    errorMessage = g.errorDescription ?? "Couldn't validate key."
                }
            } catch let urlError as URLError {
                validating = false
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost:
                    errorMessage = "No internet — NoType needs to reach Gemini to validate."
                case .timedOut:
                    errorMessage = "Validation timed out. Try again."
                default:
                    errorMessage = urlError.localizedDescription
                }
            } catch {
                validating = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
