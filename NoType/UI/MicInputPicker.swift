import AppKit
import SwiftUI

/// Native dropdown for the user-pinned input device.
///
/// Visually identical to the original `.mic-select` pill in the popover
/// footer — fixed 30 × 180 pt, accent mic glyph, secondary label, chevron.
/// Clicking opens an `NSMenu` listing every audio input the HAL knows
/// about plus an explicit "System default" entry. Selection is persisted
/// in `UserDefaults` via `AudioDeviceManager.shared.selectedUID`.
///
/// Lives in its own file because it appears in two surfaces — the
/// popover footer (`HistoryPopover`) and the onboarding mic-check screen
/// (`OnboardingMicCheckStep`). Per `NoType/UI/CLAUDE.md`'s "appears in ≥2
/// surfaces → live in a shared file" rule.
struct MicInputPicker: View {
    // Singleton @Observable — SwiftUI tracks reads inside `body` and
    // re-renders when observed properties change. No wrapper needed.
    private var devices: AudioDeviceManager { AudioDeviceManager.shared }

    var body: some View {
        Button {
            showMenu()
        } label: {
            HStack(spacing: DS.Space.s2 + 1) {
                DSIcon(name: .mic, size: 13, color: DS.Color.accentFg)
                Text(devices.effectiveLabel)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                DSIcon(name: .chevronDown, size: 11, color: DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Space.s3 + 2)  // 10 pt
            .frame(height: DS.Size.hSM + 2)         // 30 pt
            .frame(maxWidth: 180)
            .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.sm + 1))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm + 1)
                    .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .help("Choose microphone")
    }

    /// Pop a native NSMenu from the click. Using NSMenu directly (rather
    /// than SwiftUI's `Menu`) keeps the pill chrome intact — `Menu`'s
    /// menu styles all bring chrome of their own that doesn't match the
    /// existing footer button.
    private func showMenu() {
        let menu = NSMenu()

        let defaultItem = NSMenuItem(
            title: systemDefaultLabel,
            action: #selector(MicInputPickerMenuTarget.selectSystemDefault),
            keyEquivalent: ""
        )
        defaultItem.state = devices.selectedUID == nil ? .on : .off
        let target = MicInputPickerMenuTarget(devices: devices, uid: nil)
        defaultItem.target = target
        defaultItem.representedObject = target
        menu.addItem(defaultItem)

        if !devices.inputs.isEmpty {
            menu.addItem(.separator())
        }

        for device in devices.inputs {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(MicInputPickerMenuTarget.selectDevice(_:)),
                keyEquivalent: ""
            )
            item.state = devices.selectedUID == device.uid ? .on : .off
            let t = MicInputPickerMenuTarget(devices: devices, uid: device.uid)
            item.target = t
            item.representedObject = t
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

/// Target for the NSMenu items — each item owns its target so the
/// closure carries the device UID. `representedObject` keeps a strong
/// reference so the target outlives the click.
private final class MicInputPickerMenuTarget: NSObject {
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
