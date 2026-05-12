import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self)             private var appState
    @Environment(AppearanceController.self) private var appearance
    @Environment(\.dismiss)                 private var dismiss

    @State private var apiKey: String = ""
    @State private var dirty: Bool = false
    @State private var saveError: String?

    /// Mirror of `PasteSettings.restoreDelayMs` for the slider control.
    /// Initialised in `.onAppear`, written back via `onChange`.
    @State private var pasteDelayMs: Double = Double(PasteSettings.defaultRestoreDelayMs)

    var body: some View {
        // Shadow the @Environment value with @Bindable so we can pass
        // `$appearance.mode` into the Picker as a SwiftUI Binding.
        @Bindable var appearance = appearance
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    DSIcon(name: .x, size: 11, color: DS.Color.textTertiary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            DSSeparator()

            VStack(alignment: .leading, spacing: 6) {
                Text("Gemini API key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Color.textSecondary)
                SecureField("Paste your key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { _, _ in dirty = true }
                    .onSubmit { commitAndClose() }
                HStack(spacing: 6) {
                    Link(destination: URL(string: "https://aistudio.google.com/app/apikey")!) {
                        Text("Get a key →")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Color.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if let err = saveError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Color.dangerBase)
                    }
                }
            }

            DSSeparator()

            // Appearance — Adaptive (system) / Light / Dark.
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Color.textSecondary)
                Picker("", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            DSSeparator()

            // Paste restore delay — how long we hold our text on the
            // clipboard before restoring the user's prior contents.
            // Bump if the target app sometimes pastes the old clipboard
            // (heavy Electron apps especially).
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Paste restore delay")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Color.textSecondary)
                    Spacer()
                    Text("\(Int(pasteDelayMs)) ms")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(DS.Color.textTertiary)
                }
                Slider(
                    value: $pasteDelayMs,
                    in: Double(PasteSettings.restoreDelayRange.lowerBound)
                        ... Double(PasteSettings.restoreDelayRange.upperBound),
                    step: 10
                )
                .onChange(of: pasteDelayMs) { _, new in
                    PasteSettings.restoreDelayMs = Int(new)
                }
                Text("Higher if the target app sometimes pastes your old clipboard. Default: \(PasteSettings.defaultRestoreDelayMs) ms.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Color.textTertiary)
            }

            HStack {
                Spacer()
                Button("Save") {
                    commitAndClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!dirty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            apiKey = appState.currentAPIKey ?? ""
            dirty = false
            saveError = nil
            pasteDelayMs = Double(PasteSettings.restoreDelayMs)
        }
    }

    private func commitAndClose() {
        do {
            try appState.updateAPIKey(apiKey)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
