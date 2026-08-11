import AppKit
import os
import SwiftUI

/// Manages the floating HUD panels.
///
/// **Every panel this class owns shares one screen region** — a single
/// top-right column, laid out by `relayout()`. Nothing is positioned
/// anywhere else, and no panel is positioned on its own: a show or a hide
/// of *any* kind re-lays out *all* of them. That is the whole point.
/// Previously each kind handed `topInset` verbatim to
/// `HUDPanel.positionTopRight`, so two co-visible panels landed at the same
/// point at the same window level — and superimposed panels read as a
/// broken close button, because the click reaches only the front one and
/// the one behind it is revealed in the same place. See
/// `HUDPanelGeometry.Slot` for the ordering, and for why the error HUD
/// owning the top slot is not the same thing as it "showing alone".
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
    private static let log = Logger(subsystem: "app.notype", category: "ui.hud")

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

    // The card ordering that used to live here as `Self.order` is now
    // `HUDPanelGeometry.Slot`'s declaration order, alongside the other three
    // HUD kinds — the two orderings were never independent, and keeping them
    // in separate places is how the cards ended up stacked correctly among
    // themselves while colliding with everything else.

    init(permissions: PermissionsViewModel) {
        self.permissions = permissions
    }

    var permissionsHUDVisible: Bool { !permissionPanels.isEmpty }

    /// Whether an error HUD is currently up. Read-only mirror of the
    /// private panel slot, in the same shape as `permissionsHUDVisible`.
    ///
    /// Exists so "this failure was surfaced to the user" can be asserted
    /// rather than assumed — R19 makes it a requirement that a retry which
    /// recovered nothing produces a visible outcome instead of silently
    /// restoring the row's pre-tap appearance, and invariant 1 of
    /// `NoType/UI/CLAUDE.md` makes `showErrorHUD` the only way that can
    /// happen. Read by `AppStateRetryTests`; U7 renders the row half of the
    /// same requirement.
    var errorHUDVisible: Bool { errorPanel != nil }

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
        relayout()
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
        relayout()
    }

    /// Sweep all permission panels (used when everything is granted).
    func hidePermissionsHUD() {
        for panel in permissionPanels.values {
            panel.hide()
            panel.close()
        }
        permissionPanels.removeAll()
        dismissedKinds.removeAll()
        relayout()
    }

    private func dismissPermissionPanel(for kind: PermissionKind) {
        permissionPanels[kind]?.hide()
        permissionPanels[kind]?.close()
        permissionPanels.removeValue(forKey: kind)
        dismissedKinds.insert(kind)
        relayout()
    }

    // MARK: - Column layout

    /// The single placement path. **Every live panel is re-placed on every
    /// call**, because a column is not a per-panel property: hiding the row
    /// above changes where every row below it belongs, and showing a new
    /// top-slot panel moves everything down. A show or hide that skipped
    /// this would leave a hole where the dismissed panel was, or park a new
    /// one on top of a live one.
    ///
    /// The slot ordering and the arithmetic both live in the pure
    /// `HUDPanelGeometry` — an `NSPanel` cannot be stood up in a unit test,
    /// and the part worth testing here is "no two panels resolve to the same
    /// inset", which is arithmetic. Same extraction rationale as
    /// `topRightOrigin`. `HUDPanelGeometryTests`' source guard pins that
    /// `positionTopRight` is reached only from here, that this method still
    /// consults the column, and that every show/hide still calls it.
    private func relayout() {
        let occupants: [(slot: HUDPanelGeometry.Slot, panel: HUDPanel)] = [
            errorPanel.map        { (HUDPanelGeometry.Slot.error, $0) },
            recordingPanel.map    { (HUDPanelGeometry.Slot.recording, $0) },
            transcribingPanel.map { (HUDPanelGeometry.Slot.transcribing, $0) },
            permissionPanels[.accessibility].map { (HUDPanelGeometry.Slot.accessibilityCard, $0) },
            permissionPanels[.microphone].map    { (HUDPanelGeometry.Slot.microphoneCard, $0) }
        ].compactMap { $0 }

        // One persisted breadcrumb per layout change, naming which slots are
        // occupied. This is the record whose *absence* made a "the close
        // button does nothing" report undiagnosable from logs alone: the
        // question that had to be answered was "were two panels up at the
        // same time", and nothing in this file used to say. Slot names only
        // — never a payload, which carries user-visible failure text.
        guard !occupants.isEmpty else {
            Self.log.notice("HUD column: empty")
            return
        }

        // Measure everything before placing anything: row N's inset is the
        // accumulation of the heights of rows 0..<N.
        for occupant in occupants { occupant.panel.sizeToFit() }

        let column = HUDPanelGeometry.column(
            occupants.map { .init(slot: $0.slot, height: $0.panel.frame.height) },
            topInset: topInset,
            gap: cardGap
        )
        if !column.sanitised.isEmpty {
            let terms = column.sanitised.map(\.description).joined(separator: ", ")
            Self.log.error(
                "HUD column laid out against assumed heights: \(terms, privacy: .public) did not measure"
            )
        }
        Self.log.notice(
            "HUD column: \(column.rows.map(\.slot.description).joined(separator: ", "), privacy: .public)"
        )

        // Looked up by slot rather than zipped against `occupants`: the
        // column re-sorts, so positional correspondence would be a silent
        // coupling to an ordering this method deliberately does not own.
        for row in column.rows {
            guard let panel = occupants.first(where: { $0.slot == row.slot })?.panel else { continue }
            panel.positionTopRight(topInset: row.topInset, rightInset: rightInset)
            panel.show()
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
        recordingPanel = HUDPanel(rootView: view)
        relayout()
    }

    func hideRecordingHUD() {
        recordingPanel?.hide()
        recordingPanel?.close()
        recordingPanel = nil
        relayout()
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
        transcribingPanel = nil

        let view = TranscribingHUD(
            targetAppName: targetAppName,
            onDismiss: { [weak self] in
                self?.hideTranscribingHUD()
            }
        )
        transcribingPanel = HUDPanel(rootView: view)
        relayout()
    }

    func hideTranscribingHUD() {
        transcribingPanel?.hide()
        transcribingPanel?.close()
        transcribingPanel = nil
        relayout()
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
        errorPanel = nil
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
        errorPanel = HUDPanel(rootView: view)
        relayout()

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
        relayout()
    }
}
