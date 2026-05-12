import SwiftUI

enum PermissionKind: Equatable, Sendable, Hashable, CaseIterable {
    case accessibility
    case microphone

    var title: String {
        switch self {
        case .accessibility: "Accessibility access required"
        case .microphone:    "Microphone access required"
        }
    }

    fileprivate var iconSymbol: String {
        switch self {
        case .accessibility: "figure.stand"
        case .microphone:    "mic.slash.fill"
        }
    }

    fileprivate func description() -> AttributedString {
        switch self {
        case .accessibility:
            return Self.bold(
                "NoType reads the focused app's accessibility tree for accurate transcription and listens for the ⌥ Right Option hotkey. One permission covers both.",
                terms: ["accessibility tree", "⌥ Right Option"]
            )
        case .microphone:
            return Self.bold(
                "NoType needs permission to record audio for transcription. Grant Microphone access in System Settings to start dictating.",
                terms: ["Microphone"]
            )
        }
    }

    private static func bold(_ text: String, terms: [String]) -> AttributedString {
        var s = AttributedString(text)
        for term in terms {
            if let r = s.range(of: term) {
                s[r].foregroundColor = DS.Color.textPrimary
                s[r].font = .system(size: 11.5, weight: .semibold)
            }
        }
        return s
    }
}

/// Single permission card. Each missing kind gets its own HUDPanel so that
/// stacked cards remain visually distinct (separate glass surfaces with a
/// gap between), per the menu-bar.html design.
struct PermissionCard: View {
    let permissions: PermissionsViewModel
    let kind: PermissionKind
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                DSGlyphChip(severity: .warning, symbol: kind.iconSymbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary)
                    Text(kind.description())
                        .font(.system(size: 11.5))
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DSCloseButton(action: onDismiss)
            }

            HStack(spacing: 8) {
                DSPrimaryButton(
                    label: ctaText,
                    trailingSystemSymbol: "arrow.up.right.square",
                    action: primaryAction
                )
            }
            .padding(.leading, 36) // align with title (icon 26 + 10 gap)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .dsHudChrome()
    }

    private var status: PermissionStatus {
        switch kind {
        case .accessibility: permissions.accessibility
        case .microphone:    permissions.microphone
        }
    }

    private var ctaText: String {
        status == .denied ? "Open System Settings" : "Grant"
    }

    private func primaryAction() {
        switch kind {
        case .accessibility:
            if permissions.accessibility == .denied {
                permissions.openAccessibilitySettings()
            } else {
                permissions.requestAccessibility()
            }
        case .microphone:
            if permissions.microphone == .denied {
                permissions.openMicrophoneSettings()
            } else {
                Task { await permissions.requestMicrophone() }
            }
        }
        // Close the card immediately — the user has been routed to the right
        // place. We re-show on the next user trigger (menu-bar click, hotkey).
        onDismiss()
    }

}
