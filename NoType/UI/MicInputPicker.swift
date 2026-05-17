import AppKit
import SwiftUI

/// Native dropdown for the user-pinned input device.
///
/// Two visual sizes:
///   - `.compact` (default) — fixed 30 × 180 pt, used in the popover
///     footer. Matches the original `.mic-select` pill.
///   - `.large` — 38 pt tall, min-width 340 pt, used on the onboarding
///     mic-check screen where the picker is the focal control.
///
/// Clicking opens an `NSMenu` listing every audio input the HAL knows
/// about plus an explicit "System default" entry. Selection is persisted
/// in `UserDefaults` via `AudioDeviceManager.shared.selectedUID`.
///
/// Lives in its own file because it appears in two surfaces — the
/// popover footer (`HistoryPopover`) and the onboarding mic-check screen
/// (`OnboardingMicCheckStep`). Per `NoType/UI/CLAUDE.md`'s "appears in ≥2
/// surfaces → live in a shared file" rule.
struct MicInputPicker: View {
    enum Size { case compact, large }

    var size: Size = .compact

    // Singleton @Observable — SwiftUI tracks reads inside `body` and
    // re-renders when observed properties change. No wrapper needed.
    private var devices: AudioDeviceManager { AudioDeviceManager.shared }

    var body: some View {
        Button {
            showMenu()
        } label: {
            HStack(spacing: spec.gap) {
                DSIcon(name: .mic, size: spec.iconSize, color: DS.Color.accentFg)
                Text(devices.effectiveLabel)
                    .font(spec.font)
                    .foregroundStyle(spec.labelColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                DSIcon(name: .chevronDown, size: spec.chevSize, color: DS.Color.textTertiary)
            }
            .padding(.horizontal, spec.hPad)
            .frame(height: spec.height)
            .frame(minWidth: spec.minWidth, maxWidth: spec.maxWidth)
            .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: spec.radius))
            .overlay(
                RoundedRectangle(cornerRadius: spec.radius)
                    .strokeBorder(spec.border, lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .help("Choose microphone")
    }

    private var spec: Spec {
        switch size {
        case .compact:
            return Spec(
                height: DS.Size.hSM + 2, hPad: DS.Space.s3 + 2, gap: DS.Space.s2 + 1,
                radius: DS.Radius.sm + 1, iconSize: 13, chevSize: 11,
                font: DS.Font.bodySM(), labelColor: DS.Color.textSecondary,
                minWidth: nil, maxWidth: 180,
                border: DS.Color.borderSubtle
            )
        case .large:
            return Spec(
                height: 38, hPad: 12, gap: 10,
                radius: 8, iconSize: 14, chevSize: 12,
                font: .system(size: 13), labelColor: DS.Color.textPrimary,
                minWidth: 340, maxWidth: 420,
                border: DS.Color.borderDefault
            )
        }
    }

    private struct Spec {
        let height: CGFloat
        let hPad: CGFloat
        let gap: CGFloat
        let radius: CGFloat
        let iconSize: CGFloat
        let chevSize: CGFloat
        let font: SwiftUI.Font
        let labelColor: Color
        let minWidth: CGFloat?
        let maxWidth: CGFloat
        let border: Color
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
