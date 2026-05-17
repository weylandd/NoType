import AppKit
import SwiftUI

/// Step 5 — verify (and optionally change) the global hotkey.
///
/// Shows a full Mac keyboard layout. Any key the user presses anywhere
/// on their actual keyboard lights up on screen — this is the "press
/// feedback" loop so if someone hits the wrong key they can see it.
/// The currently-configured hotkey is rendered with a pulsing target
/// halo; pressing it (real key or on-screen click) flips the row to a
/// verified state and unlocks Continue.
///
/// Pressing the "Change shortcut" link enters remap mode: the next key
/// the user presses (or clicks on screen) becomes the new binding via
/// `AppState.applyHotkeyBinding(_:)`. Modifier keys route through the
/// existing flagsChanged path inside `HotkeyMonitor`; non-modifier keys
/// route through keyDown/keyUp on the bound `virtualKeyCode`.
///
/// While the screen is showing, `AppState.onboardingHotkeyPressObserver`
/// is set so a press of the bound key drives this screen's verification
/// without starting a recording session. Real-time highlight of *any*
/// pressed key is driven by a local `NSEvent` monitor — it fires only
/// when the app is focused, which is the case while the onboarding
/// window is up.
struct OnboardingHotkeyStep: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(AppState.self)        private var appState

    @State private var binding:  HotkeyBinding = .load()
    @State private var verified: Bool = false
    @State private var remap:    Bool = false
    /// Snapshot of `verified` taken when entering remap mode so a
    /// Cancel restores the prior state instead of forcing the user to
    /// re-verify a binding they had already confirmed.
    @State private var verifiedBeforeRemap: Bool = false
    @State private var heldCodes: Set<String> = []
    @State private var localMonitor: Any?

    var body: some View {
        OnboardingChrome(
            stepIndex: 4,
            stepLabel: "05 — SHORTCUT",
            contentMaxWidth: 1000
        ) {
            VStack(spacing: 22) {
                Text("Set your trigger key")
                    .font(.system(size: 34, weight: .medium))
                    .tracking(-0.02 * 34)
                    .foregroundStyle(DS.Color.textPrimary)

                shortcutRow

                MacKeyboardView(
                    pressedCodes:   heldCodes,
                    targetCode:     binding.code,
                    verifiedTarget: verified && !remap,
                    isRemap:        remap,
                    onKeyTap:       handleKeyTap
                )

                caption

                continueButton
            }
            .frame(maxWidth: .infinity)
        } footer: {
            Color.clear.frame(height: 8)
        }
        .onAppear {
            binding = appState.hotkeyBinding
            verified = false
            installObservers()
        }
        .onDisappear {
            uninstallObservers()
        }
    }

    // MARK: - Header pill (current shortcut + change link)

    private var shortcutRow: some View {
        HStack(spacing: 14) {
            Text(remap ? "New shortcut" : (verified ? "Verified shortcut" : "Your shortcut"))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(DS.Color.textTertiary)

            ShortcutKeyPill(binding: binding, highlighted: remap)

            Button(action: toggleRemap) {
                Text(remap ? "Cancel" : "Change shortcut")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(remap ? DS.Color.accentFg : DS.Color.textSecondary)
                    .underline(true, color: (remap ? DS.Color.accentFg : DS.Color.textSecondary).opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Caption beneath the keyboard

    @ViewBuilder
    private var caption: some View {
        let (text, color) = captionContents
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .tracking(0.04 * 11.5)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .animation(DS.Motion.base, value: verified)
            .animation(DS.Motion.base, value: remap)
    }

    private var captionContents: (String, Color) {
        if remap {
            return (
                "PRESS ANY KEY ON YOUR KEYBOARD — OR CLICK ONE BELOW",
                DS.Color.accentFg
            )
        }
        if verified {
            return (
                "DETECTED — YOU'RE SET WITH \(binding.displayWord.uppercased())",
                DS.Color.successFg
            )
        }
        return (
            "PRESS THE \(binding.displayWord.uppercased()) KEY TO VERIFY",
            DS.Color.textQuaternary
        )
    }

    // MARK: - Continue button

    private var continueButton: some View {
        let enabled = verified && !remap
        return Button(action: {
            if enabled { onboarding.goNext() }
        }) {
            HStack(spacing: 6) {
                Text("Complete setup")
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(DS.Color.textOnAccent)
            .padding(.horizontal, 14)
            .frame(minWidth: 200, minHeight: 36)
            .background(
                enabled ? DS.Color.accent : DS.Color.accent.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.18), lineWidth: DS.Border.hairline)
                    .blendMode(.plusLighter)
                    .opacity(enabled ? 1 : 0)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Complete setup")
    }

    // MARK: - Event wiring

    private func installObservers() {
        // Real CGEventTap path — fires for the currently-bound key
        // (modifier or non-modifier) even when the onboarding window
        // isn't first-responder. AppState routes the press here instead
        // of starting a recording session.
        appState.onboardingHotkeyPressObserver = {
            self.heldCodes.insert(self.binding.code)
            self.handleConfiguredHotkeyPress()
        }
        appState.onboardingHotkeyReleaseObserver = {
            self.heldCodes.remove(self.binding.code)
        }

        // Local NSEvent monitor — fires for ANY key while the app is
        // focused. Drives the "you pressed the wrong key" feedback by
        // lighting up whichever key the user actually hit.
        // Guard against double-install: SwiftUI can fire `.onAppear`
        // twice across view-identity churn, and leaking the old token
        // means a stale closure keeps running for the process lifetime.
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .keyUp, .flagsChanged]
            ) { event in
                handleNSEvent(event)
                // In remap mode we eat plain keyDown/keyUp so a tap on
                // `Return` doesn't also activate the focused Continue
                // button. BUT we still pass through shortcuts the user
                // might need to leave the window (⌘W, ⌘Q, ⌘., ⌃-…) —
                // eating them would trap the user in remap.
                if remap, event.type != .flagsChanged {
                    let passthroughMods: NSEvent.ModifierFlags = [.command, .control]
                    if event.modifierFlags.intersection(passthroughMods).isEmpty {
                        return nil
                    }
                }
                return event
            }
        }
    }

    private func uninstallObservers() {
        appState.onboardingHotkeyPressObserver = nil
        appState.onboardingHotkeyReleaseObserver = nil
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        heldCodes.removeAll()
    }

    private func handleNSEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            guard !event.isARepeat else { return }
            guard let code = OnboardingKeyboard.codeForVirtual(UInt16(event.keyCode)) else {
                return
            }
            if remap {
                attemptRemap(to: code)
            } else {
                heldCodes.insert(code)
                if code == binding.code { handleConfiguredHotkeyPress() }
            }
        case .keyUp:
            guard let code = OnboardingKeyboard.codeForVirtual(UInt16(event.keyCode)) else {
                return
            }
            heldCodes.remove(code)
        case .flagsChanged:
            reconcileModifierFlags(event.modifierFlags, vk: UInt16(event.keyCode))
        default:
            break
        }
    }

    /// `flagsChanged` only tells us the new flag state, not which side
    /// changed. We compare the new flags + the event's `keyCode` (Apple
    /// includes the virtual code of the changing modifier) to figure
    /// out which side-specific code is now held or released.
    private func reconcileModifierFlags(_ flags: NSEvent.ModifierFlags, vk: UInt16) {
        guard let code = OnboardingKeyboard.codeForVirtual(vk) else { return }
        // Decide press vs release: if the relevant device-side flag is
        // set in `flags`, this is a press; otherwise release.
        let isPressed: Bool = {
            switch code {
            case "AltLeft", "AltRight":        return flags.contains(.option)
            case "ControlLeft", "ControlRight":return flags.contains(.control)
            case "ShiftLeft", "ShiftRight":    return flags.contains(.shift)
            case "MetaLeft", "MetaRight":      return flags.contains(.command)
            case "CapsLock":                   return flags.contains(.capsLock)
            case "Fn":                         return flags.contains(.function)
            default: return false
            }
        }()
        if isPressed {
            if !heldCodes.contains(code) {
                heldCodes.insert(code)
                if remap { attemptRemap(to: code) }
                else if code == binding.code { handleConfiguredHotkeyPress() }
            }
        } else {
            heldCodes.remove(code)
        }
    }

    private func handleConfiguredHotkeyPress() {
        guard !remap else { return }
        verified = true
    }

    // MARK: - Remap flow

    private func toggleRemap() {
        if remap {
            // Cancel — restore the verified state we had before entering
            // remap mode so the user doesn't have to re-press a binding
            // they had already confirmed.
            remap = false
            verified = verifiedBeforeRemap
        } else {
            verifiedBeforeRemap = verified
            remap = true
            verified = false
        }
    }

    private func attemptRemap(to code: String) {
        let candidate = HotkeyBinding(code: code)
        guard candidate.isAllowedAsHotkey else {
            // Visual no-op — Escape / Power / CapsLock are filtered out.
            return
        }
        // Rebinding to the SAME code is a no-op at the AppState level
        // (applyHotkeyBinding short-circuits on equality). Preserve the
        // user's prior `verified` state in that case so they aren't
        // forced to re-press a binding they had already confirmed.
        let sameAsCurrent = candidate.code == binding.code
        binding = candidate
        appState.applyHotkeyBinding(candidate)
        if !sameAsCurrent {
            verified = false
        } else {
            verified = verifiedBeforeRemap
        }
        remap = false
    }

    // MARK: - On-screen key click

    private func handleKeyTap(_ code: String) {
        if remap {
            attemptRemap(to: code)
            return
        }
        if code == binding.code {
            // Briefly flash press + verify
            heldCodes.insert(code)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                heldCodes.remove(code)
                verified = true
            }
        } else {
            // Visual click feedback even on a wrong key — same
            // highlight a real press would produce, briefly.
            heldCodes.insert(code)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 140_000_000)
                heldCodes.remove(code)
            }
        }
    }
}

// MARK: - Shortcut key pill (top row preview)

private struct ShortcutKeyPill: View {
    let binding: HotkeyBinding
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 2) {
            Text(binding.displayGlyph)
                .font(.system(size: 15))
            if let side = binding.sideIndicator {
                Text(side)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(DS.Color.textTertiary)
                    .padding(.top, 1)
            }
        }
        .foregroundStyle(DS.Color.textPrimary)
        .padding(.horizontal, 10)
        .frame(minWidth: 44, minHeight: 36)
        .background(
            highlighted
                ? AnyShapeStyle(DS.Color.accentSoft)
                : AnyShapeStyle(DS.Color.bgInset),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    highlighted ? DS.Color.accentBorder : DS.Color.borderDefault,
                    lineWidth: DS.Border.hairline
                )
        )
        .animation(DS.Motion.fast, value: highlighted)
    }
}
