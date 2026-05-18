import AppKit
import SwiftUI

/// Recording pane of the redesigned Settings screen. Three cards:
///   1. Shortcuts — recording + cancel shortcut rows (with rebind buttons).
///   2. How recording works — the press/release/lock/cancel callout.
///   3. Input device — mic source pill + Change button, music interruption picker.
///
/// Shortcut rebinding fires through the parent shell so the rebind
/// sheet has one owner per Settings tab.
struct RecordingPane: View {
    @Environment(AppState.self) private var appState

    let onChangeRecordingShortcut: () -> Void
    let onChangeCancelShortcut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            shortcutsCard
            howItWorksCard
            inputDeviceCard
        }
    }

    // MARK: - Shortcuts

    private var shortcutsCard: some View {
        let disabled = appState.recordingState != .idle
        return DSCard(
            title: "Shortcuts",
            meta: disabled ? "Disabled while recording" : nil
        ) {
            DSCardRow(
                title: "Recording shortcut",
                subtitle: "Press & hold to dictate. Release to paste at the cursor."
            ) {
                HStack(spacing: DS.Space.s3) {
                    DSKeycapPill(label: appState.hotkeyBinding.displayWord, style: .compact)
                    DSSecondaryButton(label: "Change", action: onChangeRecordingShortcut)
                        .disabled(disabled)
                }
            }
            DSCardRow(
                title: "Cancel shortcut",
                subtitle: "Aborts the current session — nothing gets pasted."
            ) {
                HStack(spacing: DS.Space.s3) {
                    DSKeycapPill(label: appState.cancelHotkeyBinding.displayWord, style: .compact)
                    DSSecondaryButton(label: "Change", action: onChangeCancelShortcut)
                        .disabled(disabled)
                }
            }
        }
    }

    // MARK: - How it works

    private var howItWorksCard: some View {
        DSCard(title: "How recording works") {
            // Top hairline still wanted between head and callout, so
            // we render an explicit divider — the callout has its own
            // padded chrome and isn't a DSCardRow.
            DS.Color.borderSubtle.frame(height: DS.Border.hairline)
            HowRecordingWorksCallout()
        }
    }

    // MARK: - Input device

    private var inputDeviceCard: some View {
        @Bindable var appState = appState
        return DSCard(title: "Input device") {
            DSCardRow(
                title: "Microphone",
                subtitle: micSubtitle,
                layout: .col
            ) {
                HStack(spacing: DS.Space.s3) {
                    MicSourcePill(
                        isAutoDetect: AudioDeviceManager.shared.selectedUID == nil,
                        deviceName: AudioDeviceManager.shared.effectiveLabel
                    )
                    Spacer(minLength: 0)
                    DSSecondaryButton(label: "Change", action: showMicMenu)
                }
            }

            DSCardRow(
                title: "Music interruption",
                subtitle: AttributedString(MusicInterruption.Mode.subtitle(for: appState.musicInterruptionMode))
            ) {
                DSSegmented(
                    options: MusicInterruption.Mode.allCases,
                    selection: $appState.musicInterruptionMode,
                    label: { $0.label }
                )
            }
        }
    }

    private var micSubtitle: String {
        AudioDeviceManager.shared.selectedUID == nil
            ? "Falls back to the built-in mic when a Bluetooth headset is active — so AirPods don't drop into HFP."
            : "NoType records from the device you picked. Switch back to Auto-detect anytime."
    }

    /// Pop the input-device NSMenu. `MicInputPicker` (popover footer
    /// + onboarding mic-check) is the other caller of this shape;
    /// each owns its own NSMenu construction. Extract into a shared
    /// helper when a third caller appears — until then duplication
    /// is cheaper than abstracting prematurely.
    private func showMicMenu() {
        let devices = AudioDeviceManager.shared
        let menu = NSMenu()

        let defaultItem = NSMenuItem(
            title: systemDefaultLabel,
            action: #selector(RecordingPaneMenuTarget.selectSystemDefault),
            keyEquivalent: ""
        )
        defaultItem.state = devices.selectedUID == nil ? .on : .off
        let defaultTarget = RecordingPaneMenuTarget(devices: devices, uid: nil)
        defaultItem.target = defaultTarget
        defaultItem.representedObject = defaultTarget
        menu.addItem(defaultItem)

        if !devices.inputs.isEmpty {
            menu.addItem(.separator())
        }

        for device in devices.inputs {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(RecordingPaneMenuTarget.selectDevice(_:)),
                keyEquivalent: ""
            )
            item.state = devices.selectedUID == device.uid ? .on : .off
            let target = RecordingPaneMenuTarget(devices: devices, uid: device.uid)
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }

    private var systemDefaultLabel: String {
        let devices = AudioDeviceManager.shared
        if let def = devices.systemDefault {
            return "System default — \(def.name)"
        }
        return "System default"
    }
}

private final class RecordingPaneMenuTarget: NSObject {
    let devices: AudioDeviceManager
    let uid: String?
    init(devices: AudioDeviceManager, uid: String?) {
        self.devices = devices
        self.uid = uid
    }
    @MainActor @objc func selectSystemDefault() {
        devices.selectedUID = nil
    }
    @MainActor @objc func selectDevice(_ sender: NSMenuItem) {
        devices.selectedUID = uid
    }
}
