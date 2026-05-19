import SwiftUI

/// Step 2 — manual API-key setup.
///
/// Centered layout: eyebrow, title, lede, then either the resume card
/// (key already saved on this Mac) or the editor card (paste-and-
/// validate). Continue lives inline in the body, not the chrome footer
/// — the design treats the CTA as part of the key cluster.
struct OnboardingAPIKeyStep: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(AppState.self)        private var appState

    @State private var draft: String = ""
    @State private var isEditing: Bool = false
    @State private var savedKey: String? = nil
    @State private var validating: Bool = false
    @State private var errorMessage: String? = nil
    @State private var revealKey: Bool = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        OnboardingChrome(stepIndex: 1, stepLabel: "02 — API KEY") {
            VStack(spacing: DS.Space.s7) {
                headBlock

                if !isEditing, let saved = savedKey, !saved.isEmpty {
                    resumeCard(for: saved)
                } else {
                    editorCard
                }

                privacyFootnote

                continueButton
            }
            .frame(maxWidth: .infinity)
        } footer: {
            // Continue button is inline in the body for this step.
            Color.clear.frame(height: 8)
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

    // MARK: - Head

    private var headBlock: some View {
        VStack(spacing: 10) {
            Text("Link your Gemini API key")
                .font(.system(size: 34, weight: .medium))
                .tracking(-0.02 * 34)
                .foregroundStyle(DS.Color.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            ledeText
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(DS.Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ledeText: Text {
        let intro = Text("NoType uses ")
        let model = Text("Gemini 3.1 Flash-Lite")
            .foregroundColor(DS.Color.textPrimary)
            .fontWeight(.semibold)
        let rest = Text(" for transcription. Paste your API key once — it's stored in your macOS Keychain and never leaves your machine.")
        return intro + model + rest
    }

    // MARK: - Editor card

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            keyField

            HStack(alignment: .top, spacing: 12) {
                aiStudioLink
                Spacer(minLength: 8)
                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Color.dangerFg)
                        .lineSpacing(2)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
            }
            .frame(minHeight: 18)
        }
        .frame(maxWidth: 580, alignment: .leading)
    }

    private var keyField: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(DS.Color.textTertiary)
                .frame(width: 14, height: 14)

            keyInput

            Button(action: { revealKey.toggle() }) {
                Image(systemName: revealKey ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Color.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealKey ? "Hide key" : "Show key")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(fieldBorder, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(fieldGlow, lineWidth: 3)
                .blur(radius: 0)
                .padding(-1.5)
                .opacity(fieldGlowOpacity)
        )
        .animation(DS.Motion.fast, value: fieldFocused)
        .animation(DS.Motion.fast, value: errorMessage)
    }

    @ViewBuilder
    private var keyInput: some View {
        Group {
            if revealKey {
                TextField("", text: $draft, prompt: keyPrompt)
            } else {
                SecureField("", text: $draft, prompt: keyPrompt)
            }
        }
        .textFieldStyle(.plain)
        .focused($fieldFocused)
        .font(.system(size: 13, design: .monospaced))
        .tracking(0.02 * 13)
        .foregroundStyle(DS.Color.textPrimary)
        .tint(DS.Color.accent)
        .onChange(of: draft) { _, _ in
            errorMessage = nil
        }
        .onSubmit { continueTapped() }
    }

    private var keyPrompt: Text {
        Text("AIzaSy…  paste your Gemini API key")
            .foregroundColor(DS.Color.textQuaternary)
    }

    private var fieldBorder: Color {
        if errorMessage != nil { return DS.Color.dangerBorder }
        if fieldFocused        { return DS.Color.accent }
        return DS.Color.borderDefault
    }

    private var fieldGlow: Color {
        errorMessage != nil ? DS.Color.dangerSoft : DS.Color.accentSoft
    }

    private var fieldGlowOpacity: Double {
        (errorMessage != nil || fieldFocused) ? 1.0 : 0.0
    }

    private var aiStudioLink: some View {
        Link(destination: URL(string: "https://aistudio.google.com/app/apikey")!) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                Text("Get a key in Google AI Studio")
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(DS.Color.accentFg)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Resume card (key already saved)

    private func resumeCard(for saved: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(DS.Color.successSoft)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(DS.Color.successBorder, lineWidth: DS.Border.hairline)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Color.successFg)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(maskedRepresentation(of: saved))
                        .font(.system(size: 13, design: .monospaced))
                        .tracking(0.06 * 13)
                        .foregroundStyle(DS.Color.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
                        )
                    VerifiedTag()
                }

                Text("STORED LOCALLY · KEYCHAIN")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .tracking(0.04 * 10.5)
                    .foregroundStyle(DS.Color.textQuaternary)
            }

            Spacer(minLength: 0)

            Button(action: {
                draft = ""
                isEditing = true
                fieldFocused = true
            }) {
                Text("Edit")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.Color.accentFg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(DS.Color.bgSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(DS.Color.successBorder, lineWidth: 1)
        )
        .frame(maxWidth: 580)
    }

    private func maskedRepresentation(of key: String) -> String {
        let head = String(key.prefix(6))
        let dotCount = min(20, max(8, key.count - 6))
        return head + String(repeating: "•", count: dotCount)
    }

    // MARK: - Privacy footnote

    private var privacyFootnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("STORED LOCALLY · KEYCHAIN · NEVER LEAVES YOUR MAC")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .tracking(0.04 * 10.5)
        }
        .foregroundStyle(DS.Color.textQuaternary)
    }

    // MARK: - Continue button

    private var continueButton: some View {
        DSPrimaryButton(
            label: validating ? "Validating" : "Continue",
            size: .large,
            trailingSystemSymbol: "arrow.right",
            isLoading: validating,
            isEnabled: continueEnabled,
            minWidth: 180,
            // Keep VoiceOver pinned to "Continue" so the announced
            // identity doesn't churn when the visible label flips to
            // "Validating" during the API-key check.
            accessibilityLabelOverride: "Continue",
            action: continueTapped
        )
    }

    private var continueEnabled: Bool {
        if validating { return false }
        if !isEditing, let saved = savedKey, !saved.isEmpty { return true }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
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
                case .http(let s, let body):
                    errorMessage = GeminiClient.GeminiError.descriptionForGenericHTTP(
                        status: s, body: body, trailing: "Try again."
                    )
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

// MARK: - Verified tag

private struct VerifiedTag: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(DS.Color.successFg)
                .frame(width: 5, height: 5)
            Text("Verified")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .tracking(0.04 * 10.5)
                .textCase(.uppercase)
        }
        .foregroundStyle(DS.Color.successFg)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(DS.Color.successSoft, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(DS.Color.successBorder, lineWidth: DS.Border.hairline)
        )
    }
}
