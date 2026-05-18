import AppKit
import SwiftUI

/// Settings → Microphone row: shows the current effective input device
/// as a status label ("Auto-detect" when on system default, otherwise
/// the device name) and a "Change" button that pops an `NSMenu`
/// listing every input device + an explicit "System default" entry.
///
/// Distinct from `MicInputPicker` (popover footer + onboarding mic-
/// check) by visual treatment: the picker is a single pill that opens
/// the menu on click; this is a `DSSettingsRow` with trailing label +
/// secondary button. Both share the underlying `AudioDeviceManager`
/// `selectedUID` source of truth so a pick in one surface is reflected
/// in the other immediately.
struct MicChangeRow: View {
    private var devices: AudioDeviceManager { AudioDeviceManager.shared }

    var body: some View {
        DSSettingsRow(
            title: "Change microphone",
            subtitle: subtitleForCurrent()
        ) {
            HStack(spacing: DS.Space.s2) {
                Text(statusLabel)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200, alignment: .trailing)

                DSSecondaryButton(label: "Change") {
                    showMenu()
                }
            }
        }
    }

    /// Status text mirrors the active state.
    ///
    /// - `Auto-detect` — no user pin (`selectedUID == nil`); the
    ///   effective device is whatever `AudioDeviceManager` resolves
    ///   right now (system default, or the BT-avoidance fallback).
    /// - Specific device name — the user has pinned a device. Pin
    ///   wins over the avoidance fallback per the
    ///   `AudioDeviceManager` policy.
    private var statusLabel: String {
        if devices.selectedUID == nil {
            return "Auto-detect"
        }
        return devices.effectiveLabel
    }

    private func subtitleForCurrent() -> String {
        if devices.selectedUID == nil {
            return "Auto-detect uses your system default mic, switching to the built-in mic when the default is a Bluetooth headset (keeps headphones in high-fidelity playback)."
        }
        return "NoType records from \(devices.effectiveLabel)."
    }

    /// Pop the same NSMenu shape `MicInputPicker` uses, but rooted at
    /// the Change button's window. We can't share the menu construction
    /// today without dragging a bit of UI plumbing into `MicInputPicker`
    /// — `MicChangeRow` is small enough that duplicating is cheaper
    /// than abstracting prematurely.
    private func showMenu() {
        let menu = NSMenu()

        let defaultItem = NSMenuItem(
            title: systemDefaultLabel,
            action: #selector(MicChangeRowMenuTarget.selectSystemDefault),
            keyEquivalent: ""
        )
        defaultItem.state = devices.selectedUID == nil ? .on : .off
        let defaultTarget = MicChangeRowMenuTarget(devices: devices, uid: nil)
        defaultItem.target = defaultTarget
        defaultItem.representedObject = defaultTarget
        menu.addItem(defaultItem)

        if !devices.inputs.isEmpty {
            menu.addItem(.separator())
        }

        for device in devices.inputs {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(MicChangeRowMenuTarget.selectDevice(_:)),
                keyEquivalent: ""
            )
            item.state = devices.selectedUID == device.uid ? .on : .off
            let target = MicChangeRowMenuTarget(devices: devices, uid: device.uid)
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }

    private var systemDefaultLabel: String {
        if let def = devices.systemDefault {
            return "System default — \(def.name)"
        }
        return "System default"
    }
}

/// `representedObject` keeps the target alive for the duration of the
/// menu click — same pattern as `MicInputPickerMenuTarget`.
private final class MicChangeRowMenuTarget: NSObject {
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
