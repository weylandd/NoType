import SwiftUI

/// First row of the About card. Shows the synthetic brand mark, the
/// app name + version number, a "checks every 24 h" hint, and the
/// Check-for-updates primary button.
struct VersionBlock: View {
    @Environment(UpdateController.self) private var updates

    private static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s4) {
            AppIconBadge(size: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("NoType")
                        .font(DS.Font.body(.semibold))
                        .foregroundStyle(DS.Color.textPrimary)
                    Text(Self.versionString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DS.Color.textTertiary)
                }
                Text("Checks automatically every 24 hours.")
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.textQuaternary)
            }

            Spacer(minLength: 0)

            DSPrimaryButton(
                label: updates.phase == .checking ? "Checking…" : "Check for updates",
                size: .small,
                isLoading: updates.phase == .checking,
                isEnabled: updates.phase != .checking,
                accessibilityLabelOverride: "Check for updates"
            ) {
                updates.checkForUpdates()
            }
        }
        .padding(.horizontal, DS.Space.s5 - 2)
        .padding(.vertical, DS.Space.s5 - 2)
    }
}
