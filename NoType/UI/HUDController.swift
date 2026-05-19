import AppKit
import SwiftUI

/// Manages the floating HUD panels.
///
/// **Permissions HUD**: each missing permission has its own NSPanel so cards
/// look like distinct glass surfaces. Cards are *only* surfaced explicitly —
/// at launch, on menu-bar click, or on hotkey press (microphone-only). State
/// changes are handled by `reconcileGranted()`, which only removes cards that
/// became granted; it never re-shows.
///
/// **Recording HUD**: created on each session start with constants captured
/// from press-time (`startedAt`, target app name).
@MainActor
final class HUDController {
    private let permissions: PermissionsViewModel

    private var permissionPanels: [PermissionKind: HUDPanel] = [:]
    /// Kinds the user actively closed (X / "Not now" / primary CTA). Re-permitted
    /// on the next explicit trigger via `presentMissing(_:)`.
    private var dismissedKinds: Set<PermissionKind> = []
    private var recordingPanel:    HUDPanel?
    private var transcribingPanel: HUDPanel?
    private var errorPanel:        HUDPanel?
    /// Auto-hides the error HUD after a short delay so the user isn't
    /// staring at a stale "Couldn't reach Gemini" card forever. Cancelled
    /// when a new error replaces the current one or the panel is hidden
    /// manually.
    private var errorAutoDismiss: Task<Void, Never>?

    private let topInset:    CGFloat = 38
    private let rightInset:  CGFloat = 16
    private let cardGap:     CGFloat = 10

    private static let order: [PermissionKind] = [.accessibility, .microphone]

    init(permissions: PermissionsViewModel) {
        self.permissions = permissions
    }

    var permissionsHUDVisible: Bool { !permissionPanels.isEmpty }

    // MARK: - Permissions HUD

    /// User-triggered explicit show. Resets dismissal flags for the requested
    /// kinds and creates panels for those still missing.
    func presentMissing(_ kinds: Set<PermissionKind>) {
        dismissedKinds.subtract(kinds)
        for kind in kinds where !isGranted(kind) && permissionPanels[kind] == nil {
            let card = PermissionCard(
                permissions: permissions,
                kind: kind,
                onDismiss: { [weak self] in
                    self?.dismissPermissionPanel(for: kind)
                }
            )
            permissionPanels[kind] = HUDPanel(rootView: card)
        }
        repositionPermissionPanels()
    }

    /// Auto-hide-only update. Removes panels for kinds whose permission was
    /// granted; never creates new panels. Call on every permission state change.
    func reconcileGranted() {
        for kind in Array(permissionPanels.keys) where isGranted(kind) {
            permissionPanels[kind]?.hide()
            permissionPanels[kind]?.close()
            permissionPanels.removeValue(forKey: kind)
            dismissedKinds.remove(kind)
        }
        repositionPermissionPanels()
    }

    /// Sweep all permission panels (used when everything is granted).
    func hidePermissionsHUD() {
        for panel in permissionPanels.values {
            panel.hide()
            panel.close()
        }
        permissionPanels.removeAll()
        dismissedKinds.removeAll()
    }

    private func dismissPermissionPanel(for kind: PermissionKind) {
        permissionPanels[kind]?.hide()
        permissionPanels[kind]?.close()
        permissionPanels.removeValue(forKey: kind)
        dismissedKinds.insert(kind)
        repositionPermissionPanels()
    }

    private func repositionPermissionPanels() {
        var top = topInset
        for kind in Self.order {
            guard let panel = permissionPanels[kind] else { continue }
            panel.layoutIfNeeded()
            panel.positionTopRight(topInset: top, rightInset: rightInset)
            panel.show()
            top += panel.frame.height + cardGap
        }
    }

    private func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: permissions.accessibility.isGranted
        case .microphone:    permissions.microphone.isGranted
        }
    }

    // MARK: - Recording HUD

    func showRecordingHUD(
        startedAt: Date,
        targetAppName: String,
        samplesProvider: @escaping @MainActor () -> [Float],
        onCancel: @escaping @MainActor () -> Void
    ) {
        recordingPanel?.hide()
        recordingPanel?.close()
        recordingPanel = nil

        // The X button cancels the in-flight session — same as pressing
        // Esc globally. `onCancel` is wired by AppState to drop audio,
        // hide HUD, and return to idle. Hiding the panel happens inside
        // `cancelRecording`; we don't pre-hide here.
        let view = RecordingHUD(
            startedAt: startedAt,
            targetAppName: targetAppName,
            samplesProvider: samplesProvider,
            onDismiss: onCancel
        )
        let panel = HUDPanel(rootView: view)
        panel.layoutIfNeeded()
        panel.positionTopRight(topInset: topInset, rightInset: rightInset)
        panel.show()
        recordingPanel = panel
    }

    func hideRecordingHUD() {
        recordingPanel?.hide()
        recordingPanel?.close()
        recordingPanel = nil
    }

    // MARK: - Transcribing HUD

    /// Replace the recording HUD with the compact transcribing surface
    /// the moment the hotkey is released. Stays visible until the
    /// resulting text is pasted (or fails) — or until the user dismisses
    /// it manually via the X button.
    ///
    /// The X button is **dismiss-only**: it hides the HUD but the
    /// in-flight Gemini call keeps running and the result still pastes
    /// when ready. We don't expose a real "cancel" because the request
    /// is short-lived and the user-recoverable mistake is "the HUD is in
    /// my way", not "stop the transcription".
    func showTranscribingHUD(targetAppName: String) {
        recordingPanel?.hide()
        recordingPanel?.close()
        recordingPanel = nil

        transcribingPanel?.hide()
        transcribingPanel?.close()

        let view = TranscribingHUD(
            targetAppName: targetAppName,
            onDismiss: { [weak self] in
                self?.hideTranscribingHUD()
            }
        )
        let panel = HUDPanel(rootView: view)
        panel.layoutIfNeeded()
        panel.positionTopRight(topInset: topInset, rightInset: rightInset)
        panel.show()
        transcribingPanel = panel
    }

    func hideTranscribingHUD() {
        transcribingPanel?.hide()
        transcribingPanel?.close()
        transcribingPanel = nil
    }

    // MARK: - Error HUD

    /// Show a single error surface in the top-right. Replaces any
    /// previously-visible error HUD — we only ever show the most recent.
    /// Auto-dismisses after `autoDismissAfter` seconds; pass `nil` to
    /// keep the panel up until the user closes it.
    func showErrorHUD(
        payload: ErrorPayload,
        autoDismissAfter: TimeInterval? = 8,
        onRetry:     (@MainActor () -> Void)? = nil,
        onSecondary: (@MainActor () -> Void)? = nil
    ) {
        errorPanel?.hide()
        errorPanel?.close()
        errorAutoDismiss?.cancel()

        let view = ErrorHUD(
            payload: payload,
            onDismiss: { [weak self] in self?.hideErrorHUD() },
            onRetry: onRetry.map { handler in
                { @MainActor [weak self] in
                    handler()
                    self?.hideErrorHUD()
                }
            },
            onSecondary: onSecondary.map { handler in
                { @MainActor [weak self] in
                    handler()
                    self?.hideErrorHUD()
                }
            }
        )
        let panel = HUDPanel(rootView: view)
        panel.layoutIfNeeded()
        panel.positionTopRight(topInset: topInset, rightInset: rightInset)
        panel.show()
        errorPanel = panel

        if let delay = autoDismissAfter {
            errorAutoDismiss = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.hideErrorHUD()
            }
        }
    }

    func hideErrorHUD() {
        errorAutoDismiss?.cancel()
        errorAutoDismiss = nil
        errorPanel?.hide()
        errorPanel?.close()
        errorPanel = nil
    }
}
