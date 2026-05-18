import SwiftUI

/// About pane of the redesigned Settings screen. Single card with
/// three internal blocks separated by hairlines:
///   1. Version + Check-for-updates button.
///   2. Three permission chips (Mic / Accessibility / Screen Recording).
///   3. GitHub source-of-truth row.
///
/// The permission chips read TCC state via `PermissionsViewModel` and
/// route clicks straight to System Settings — they never call
/// `request()` themselves. The onboarding wizard remains the only TCC
/// prompt entry point.
struct AboutPane: View {
    @Environment(PermissionsViewModel.self) private var permissions

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            DSCard {
                VStack(spacing: 0) {
                    VersionBlock()
                    permissionsGrid
                    GitHubRow()
                }
            }
        }
    }

    private var permissionsGrid: some View {
        HStack(alignment: .top, spacing: DS.Space.s3) {
            PermissionChip(
                kind: .microphone,
                status: permissions.microphone,
                isRequired: true,
                onOpenSettings: { MicrophonePermission.openSystemSettings() }
            )
            PermissionChip(
                kind: .accessibility,
                status: permissions.accessibility,
                isRequired: true,
                onOpenSettings: { AccessibilityPermission.openSystemSettings() }
            )
            PermissionChip(
                kind: .screenRecording,
                status: permissions.screenRecording,
                isRequired: false,
                onOpenSettings: { ScreenRecordingPermission.openSystemSettings() }
            )
        }
        .padding(.horizontal, DS.Space.s5 - 2)
        .padding(.vertical, DS.Space.s4 + 2)
        .overlay(
            DS.Color.borderSubtle.frame(height: DS.Border.hairline),
            alignment: .top
        )
    }
}
