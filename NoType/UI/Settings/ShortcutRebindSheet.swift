import AppKit
import SwiftUI

/// Compact rebind sheet for both Recording shortcut and Cancel
/// shortcut. Listens for the next key press via `NSEvent` local
/// monitor and saves immediately on a valid capture. The user can
/// dismiss via the Cancel button or by pressing Escape **outside**
/// the cancel-shortcut variant (the cancel variant treats Escape
/// as a valid binding, so we instead expose a visible Cancel
/// button as the only dismiss path).
///
/// This deliberately does NOT host the full `MacKeyboardView` from
/// onboarding — the Settings flow is a quick one-off rebind, not a
/// guided wizard. A pulsing "press any key" target chip carries the
/// same affordance in a much smaller footprint.
struct ShortcutRebindSheet: View {
    enum Kind {
        case recording
        case cancel
    }

    let kind: Kind
    let currentBinding: HotkeyBinding
    let onCancel: () -> Void
    /// Returns `nil` on success; otherwise the inline error string
    /// the sheet should display (e.g. collision with recording key).
    let onCapture: (HotkeyBinding) -> String?

    @State private var capturedBinding: HotkeyBinding?
    @State private var localMonitor: Any?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s5) {
            header
            captureZone
            if let err = errorMessage {
                Text(err)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.dangerFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(DS.Space.s6)
        .frame(minWidth: 460, idealWidth: 460)
        .onAppear { installMonitor() }
        .onDisappear { uninstallMonitor() }
    }

    // MARK: - Layout

    private var title: String {
        switch kind {
        case .recording: return "Change recording shortcut"
        case .cancel:    return "Change cancel shortcut"
        }
    }

    private var subtitle: String {
        switch kind {
        case .recording:
            return "Press a key or modifier to set the new push-to-talk shortcut. Hold-to-record and double-tap-to-lock will keep working with the new key."
        case .cancel:
            return "Press a key to set the shortcut that cancels an in-flight recording. Default is Escape. Modifier keys aren't accepted — pick a regular key."
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Text(subtitle)
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var captureZone: some View {
        let display = capturedBinding ?? currentBinding
        let label = capturedBinding == nil ? "Current" : "New"
        return HStack(spacing: DS.Space.s3) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Color.textTertiary)
            keyChip(for: display, highlighted: capturedBinding != nil)
            Spacer(minLength: 0)
            Text(capturedBinding == nil ? "Press any key…" : "Saved on Apply")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Color.textTertiary)
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s4)
        .background(
            DS.Color.bgInset,
            in: RoundedRectangle(cornerRadius: DS.Radius.md)
        )
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s3) {
            Spacer(minLength: 0)
            DSSecondaryButton(label: "Cancel", action: onCancel)
            DSPrimaryButton(
                label: "Apply",
                isEnabled: capturedBinding != nil
            ) {
                guard let binding = capturedBinding else { return }
                if let err = onCapture(binding) {
                    errorMessage = err
                } else {
                    errorMessage = nil
                    onCancel()
                }
            }
        }
    }

    private func keyChip(for binding: HotkeyBinding, highlighted: Bool) -> some View {
        Text(binding.displayWord)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(highlighted ? DS.Color.accentFg : DS.Color.textPrimary)
            .padding(.horizontal, DS.Space.s3)
            .padding(.vertical, 6)
            .background(
                highlighted ? DS.Color.accent.opacity(0.18) : DS.Color.bgSurface,
                in: RoundedRectangle(cornerRadius: DS.Radius.sm)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(
                        highlighted ? DS.Color.accent : DS.Color.borderSubtle,
                        lineWidth: DS.Border.hairline
                    )
            )
    }

    // MARK: - Event monitor

    private func installMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleEvent(event)
            // Consume the captured event so it doesn't ripple to the
            // main window (e.g. focused Continue button).
            return nil
        }
    }

    private func uninstallMonitor() {
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }

    private func handleEvent(_ event: NSEvent) {
        guard let code = OnboardingKeyboard.codeForVirtual(UInt16(event.keyCode)) else {
            return
        }
        let candidate = HotkeyBinding(code: code)

        // Variant-specific allowlist runs first. We surface the error
        // inline so the user understands why a press didn't stick.
        switch kind {
        case .recording:
            if !candidate.isAllowedAsHotkey {
                errorMessage = "This key isn't allowed as a recording shortcut. Reserved keys: Escape, Power, Caps Lock."
                return
            }
        case .cancel:
            if !candidate.isAllowedAsCancelBinding {
                errorMessage = "This key isn't allowed as a cancel shortcut. Pick a regular key — modifiers and Caps Lock aren't supported."
                return
            }
        }
        errorMessage = nil
        capturedBinding = candidate
    }
}
