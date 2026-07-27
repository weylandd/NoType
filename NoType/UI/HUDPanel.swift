import AppKit
import os
import SwiftUI

/// Borderless, non-activating floating window for our HUDs.
///
/// The blur is provided by an `NSVisualEffectView` that *is* the panel's
/// `contentView` — embedding the effect inside a SwiftUI `.background(...)`
/// silently fails to pick up the window's `behindWindow` blur context, which
/// is why the HUD looked like a flat darkened square. The SwiftUI hosting
/// view is layered on top with a clear background.
///
/// **Every AppKit geometry mutation in this file goes through
/// `applyValidated(contentSize:)` / `applyValidated(frameOrigin:)`.** A NaN
/// or infinite `NSHostingView.fittingSize` handed to AppKit raises
/// `NSInvalidArgumentException`, and these panels are presented from inside
/// `Task { @MainActor }` bodies where an Objective-C raise corrupts the
/// process's main-executor identity. See `HUDPanelGeometry` for the
/// mechanism and the rejection policy.
@MainActor
final class HUDPanel: NSPanel {
    private static let cornerRadius: CGFloat = 14
    private static let log = Logger(subsystem: "app.notype", category: "ui.hud")

    private let blurView: NSVisualEffectView
    private let hostingView: NSView

    init(rootView: some View) {
        // Build the blur surface first so we can reference it after super.init.
        // `.hudWindow` material reads visibly darker than `.menu` in dark mode
        // — closer to the design's `bg-overlay 92% transparent` and the
        // recording HUD's "darker glass" mood. `.menu` was too pale next to
        // the popover (which itself is `.ultraThinMaterial`).
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = HUDPanel.cornerRadius
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        self.blurView = blur

        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        // Hosting view must be transparent so the blur shows through.
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        self.hostingView = host

        super.init(
            contentRect: NSRect(origin: .zero, size: HUDPanelGeometry.seedContentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        // Let macOS draw the soft system shadow around the rounded contentView.
        hasShadow = true
        animationBehavior = .utilityWindow

        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        contentView = blur

        // Resize the panel as SwiftUI's intrinsic content size changes
        // (e.g. permission cards add/remove rows).
        //
        // This is the measurement most likely to come back non-finite: it
        // is a full SwiftUI layout pass run while the panel is still being
        // configured and the hosting view has no stable window / screen
        // context yet. On rejection the panel keeps `seedContentSize`, and
        // the next `positionTopRight` re-measures.
        host.invalidateIntrinsicContentSize()
        layoutIfNeeded()
        applyValidated(contentSize: host.fittingSize)
    }

    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }

    /// Place the panel anchored to the top-right of the active screen, with
    /// CSS-style `top` and `right` insets relative to the visible frame.
    func positionTopRight(topInset: CGFloat, rightInset: CGFloat) {
        guard let screen = NSScreen.main else {
            // Same silent-skip class as the two branches below, so it gets
            // the same log line: without one, a HUD parked at its seeded
            // bottom-left `contentRect` origin is indistinguishable from a
            // HUD that was never asked to move.
            Self.log.error("HUD panel position skipped: no main screen")
            return
        }
        // Make sure the panel has been sized to its current content first.
        layoutIfNeeded()
        applyValidated(contentSize: hostingView.fittingSize)

        // Derived from `frame.size` *after* the size mutation above, so a
        // rejected measurement still yields a real top-right point from
        // whatever size the panel legitimately has. Skipping the origin
        // too would leave the panel at its seeded `contentRect` origin —
        // the bottom-left corner of the screen, silently, for the rest of
        // the session.
        guard let placement = HUDPanelGeometry.topRightOrigin(
            visibleFrame: screen.visibleFrame,
            panelSize: frame.size,
            topInset: topInset,
            rightInset: rightInset
        ) else {
            // The screen's own visible frame is unusable — the one input
            // no fallback can be derived from.
            Self.log.error("HUD panel position skipped: screen visible frame is not finite")
            return
        }
        if !placement.sanitised.isEmpty {
            // The origin is finite, so `applyValidated(frameOrigin:)` will
            // accept it and nothing downstream would ever mention this. The
            // panel is about to be placed off its intended anchor — say so.
            let terms = placement.sanitised.map(\.description).joined(separator: ", ")
            Self.log.error(
                "HUD panel origin computed from substituted geometry: \(terms, privacy: .public) not finite"
            )
        }
        applyValidated(frameOrigin: placement.origin)
    }

    func show() {
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    // MARK: - Validated AppKit geometry mutations

    // The two methods below are the **only** places this file calls an
    // AppKit frame mutator. Keeping the validity check structural rather
    // than repeated inline at each call site is what makes the invariant
    // mechanically checkable — see `HUDPanelGeometry` for the rejection
    // policy and the raise it prevents.

    /// The only call to `setContentSize` in the project.
    ///
    /// Rejection skips the mutation: the panel keeps its last-good size,
    /// which on the first pass is `HUDPanelGeometry.seedContentSize`.
    private func applyValidated(contentSize size: NSSize) {
        if let rejection = HUDPanelGeometry.sizeRejection(size) {
            Self.log.error(
                """
                HUD panel content size skipped: \(rejection.description, privacy: .public) \
                (\(size.width, privacy: .public) × \(size.height, privacy: .public))
                """
            )
            return
        }
        setContentSize(size)
    }

    /// The only call to `setFrameOrigin` in the project.
    ///
    /// `HUDPanelGeometry.topRightOrigin` substitutes every non-finite term
    /// it composes, so `positionTopRight` reaches the rejection branch only
    /// if the arithmetic itself saturates — `visibleFrame` values finite but
    /// large enough that `maxX` / `maxY` overflow to infinity, which no real
    /// `NSScreen` produces. The check stays because it is the chokepoint's
    /// contract, not a guard on one caller — a future call site that computes
    /// an origin some other way inherits it for free.
    private func applyValidated(frameOrigin origin: NSPoint) {
        if let rejection = HUDPanelGeometry.originRejection(origin) {
            Self.log.error(
                """
                HUD panel origin skipped: \(rejection.description, privacy: .public) \
                (\(origin.x, privacy: .public), \(origin.y, privacy: .public))
                """
            )
            return
        }
        setFrameOrigin(origin)
    }
}
