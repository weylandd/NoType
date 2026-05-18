import SwiftUI

/// Single permission status chip used in the About card's
/// permissions grid. Three layouts off the same shape: granted
/// (green soft fill + check), denied (red soft fill + warning),
/// optional (tertiary neutral). Click opens the relevant System
/// Settings pane via the per-permission `openSystemSettings()`
/// helpers.
struct PermissionChip: View {
    enum Kind {
        case microphone
        case accessibility
        case screenRecording

        var name: String {
            switch self {
            case .microphone:      return "Microphone"
            case .accessibility:   return "Accessibility"
            case .screenRecording: return "Screen Recording"
            }
        }

        var icon: DSIconName {
            switch self {
            case .microphone:      return .bell
            case .accessibility:   return .lock
            case .screenRecording: return .eye
            }
        }
    }

    let kind: Kind
    let status: PermissionStatus
    /// `true` when this permission gates app behaviour. Screen
    /// Recording is the only one that's `false` — denied still reads
    /// as neutral "Optional" rather than red.
    let isRequired: Bool
    let onOpenSettings: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: DS.Space.s3 + 2) {
                iconWell
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.name)
                        .font(DS.Font.bodySM(.medium))
                        .foregroundStyle(DS.Color.textPrimary)
                    statusLabel
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.s4)
            .padding(.vertical, DS.Space.s3 + 2)
            .background(
                hovering ? DS.Color.bgHover : DS.Color.bgBase,
                in: RoundedRectangle(cornerRadius: DS.Radius.md)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .strokeBorder(
                        hovering ? DS.Color.borderDefault : DS.Color.borderSubtle,
                        lineWidth: DS.Border.hairline
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(kind.name), \(stateLabelText)")
    }

    // MARK: - Icon well

    private var iconWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(iconWellBackground)
                .frame(width: 28, height: 28)
            DSIcon(name: kind.icon, size: 14, color: iconColor)
        }
    }

    // MARK: - Status label

    private var statusLabel: some View {
        HStack(spacing: 4) {
            DSIcon(name: stateIcon, size: 10, color: stateColor)
            Text(stateLabelText)
                .font(DS.Font.labelMono())
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(stateColor)
        }
    }

    // MARK: - State derivation

    private var stateLabelText: String {
        switch (status, isRequired) {
        case (.granted, _):      return "Granted"
        case (.denied, true):    return "Denied"
        case (.denied, false):   return "Optional"
        case (.notDetermined, true):  return "Required"
        case (.notDetermined, false): return "Optional"
        case (.unknown, true):   return "Checking"
        case (.unknown, false):  return "Optional"
        }
    }

    private var stateIcon: DSIconName {
        switch (status, isRequired) {
        case (.granted, _):      return .check
        case (.denied, true):    return .warning
        default:                 return .dot
        }
    }

    private var stateColor: Color {
        switch (status, isRequired) {
        case (.granted, _):      return DS.Color.successFg
        case (.denied, true):    return DS.Color.dangerFg
        default:                 return DS.Color.textTertiary
        }
    }

    private var iconColor: Color {
        switch (status, isRequired) {
        case (.granted, _):      return DS.Color.successFg
        case (.denied, true):    return DS.Color.dangerFg
        default:                 return DS.Color.textSecondary
        }
    }

    private var iconWellBackground: Color {
        switch (status, isRequired) {
        case (.granted, _):      return DS.Color.successSoft
        case (.denied, true):    return DS.Color.dangerSoft
        default:                 return DS.Color.bgInset
        }
    }
}
