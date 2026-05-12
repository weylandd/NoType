import AppKit
import SwiftUI

/// Borderless, non-activating floating window for our HUDs.
///
/// The blur is provided by an `NSVisualEffectView` that *is* the panel's
/// `contentView` — embedding the effect inside a SwiftUI `.background(...)`
/// silently fails to pick up the window's `behindWindow` blur context, which
/// is why the HUD looked like a flat darkened square. The SwiftUI hosting
/// view is layered on top with a clear background.
@MainActor
final class HUDPanel: NSPanel {
    private static let cornerRadius: CGFloat = 14

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
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
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
        host.invalidateIntrinsicContentSize()
        layoutIfNeeded()
        setContentSize(host.fittingSize)
    }

    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }

    /// Place the panel anchored to the top-right of the active screen, with
    /// CSS-style `top` and `right` insets relative to the visible frame.
    func positionTopRight(topInset: CGFloat, rightInset: CGFloat) {
        guard let screen = NSScreen.main else { return }
        // Make sure the panel has been sized to its current content first.
        layoutIfNeeded()
        setContentSize(hostingView.fittingSize)

        let visible = screen.visibleFrame
        let size = frame.size
        let originX = visible.maxX - size.width - rightInset
        let originY = visible.maxY - size.height - topInset
        setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    func show() {
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}
