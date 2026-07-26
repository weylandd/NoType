import AppKit

/// Pure geometry validation for `HUDPanel`'s AppKit frame mutations.
///
/// **Why this exists.** `HUDPanel` sizes itself from
/// `NSHostingView.fittingSize` — a full SwiftUI layout measurement. Taken
/// before the hosting view has a stable window / screen context (which is
/// exactly when `HUDPanel.init` takes it), that measurement can come back
/// NaN or infinite. Handing such a value to `-[NSWindow setFrameOrigin:]`
/// makes AppKit raise `NSInvalidArgumentException` — *"Invalid parameter
/// not satisfying: !((__x) != (__x))"*, i.e. AppKit's own NaN assertion.
///
/// A raise there is worse than a mispositioned HUD. `AppState` presents
/// permission HUDs from inside a `Task { @MainActor }`, and an
/// Objective-C exception unwinding out of a main-actor Swift-concurrency
/// job orphans the thread's `ExecutorTrackingInfo`, so the *next* "am I on
/// the main executor?" check SIGSEGVs somewhere unrelated. See
/// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
///
/// **Scope — do not overclaim this helper.** It closes a latent
/// NaN-geometry bug. It is a *ranked suspect* for the crash family above,
/// not a confirmed culprit: no call in this file has been observed
/// raising in the wild, and `HUDController.presentMissing` is gated on
/// `onboarding.isComplete`, so this path is dead for a user parked
/// mid-onboarding. What names the actual thrower is
/// `NoType/Diagnostics/ExceptionBreadcrumb.swift`, not this file.
///
/// **Rejection policy — deliberate, and asymmetric between the two.**
///
/// - A rejected **size** means *skip the mutation*. The panel keeps its
///   last-good size, and on the very first pass that is
///   ``seedContentSize`` — a sane floor. There is nothing meaningful to
///   clamp a NaN `fittingSize` to.
/// - A rejected **origin** must **not** silently skip. `HUDPanel.init`
///   seeds its `contentRect` at the origin, so a skipped first
///   positioning pass parks the HUD in the bottom-left corner of the
///   screen for the rest of the session. Instead ``topRightOrigin(visibleFrame:panelSize:topInset:rightInset:)``
///   sanitises each contributing term and still returns a screen-derived
///   top-right point — a stale-but-placed HUD beats both a crash and a
///   HUD in the wrong corner. It returns `nil` only when the *screen's*
///   visible frame is itself unusable, because that is the one input no
///   fallback can be derived from.
///
/// Every rejection is logged at a persisted level by the caller
/// (`HUDPanel`); a silently mispositioned HUD with no log line is the
/// failure shape this whole work stream exists to stop.
///
/// Pure function namespace: deterministic, no AppKit calls, no `NSWindow`.
/// Pinned by `NoTypeTests/HUDPanelGeometryTests.swift`.
enum HUDPanelGeometry {

    /// The `contentRect` size a `HUDPanel` is constructed with, before the
    /// first `fittingSize` measurement replaces it.
    ///
    /// Named rather than inlined because it is load-bearing twice: it is
    /// the seed, and it is the **floor** the panel falls back to when that
    /// first measurement is rejected. Not a design token — no HUD is ever
    /// shown at this size; it is the placeholder SwiftUI's intrinsic
    /// content size overwrites. The per-HUD widths in
    /// `NoType/UI/CLAUDE.md` ("HUD slots & widths") come from the SwiftUI
    /// views, not from here.
    static let seedContentSize = NSSize(width: 300, height: 100)

    /// Why a geometry value must not reach AppKit.
    ///
    /// `CaseIterable` exists for the exhaustiveness test — it asserts
    /// every case is produced by at least one input, so adding a case
    /// without an input that reaches it goes red instead of shipping dead
    /// classification.
    enum Rejection: Hashable, Sendable, CaseIterable, CustomStringConvertible {
        /// Width is NaN or infinite — the `fittingSize`-before-stable-context case.
        case nonFiniteWidth
        /// Height is NaN or infinite — same source.
        case nonFiniteHeight
        /// Width is finite but zero or negative.
        case nonPositiveWidth
        /// Height is finite but zero or negative.
        case nonPositiveHeight
        /// Origin x is NaN or infinite.
        case nonFiniteX
        /// Origin y is NaN or infinite.
        case nonFiniteY

        var description: String {
            switch self {
            case .nonFiniteWidth:     "width is not finite"
            case .nonFiniteHeight:    "height is not finite"
            case .nonPositiveWidth:   "width is not positive"
            case .nonPositiveHeight:  "height is not positive"
            case .nonFiniteX:         "origin x is not finite"
            case .nonFiniteY:         "origin y is not finite"
            }
        }
    }

    /// Returns `nil` when `size` is safe to hand to `setContentSize`,
    /// otherwise the first reason it is not.
    ///
    /// **Finiteness is tested before positivity, and that order is
    /// load-bearing.** `Double.nan > 0` is `false` and
    /// `Double.infinity > 0` is `true`, so a positivity-only check would
    /// misclassify NaN as "not positive" *and wave infinity straight
    /// through*. Neither `> 0` nor a bare `x != x` NaN idiom expresses
    /// this rule — only `isFinite` does.
    static func sizeRejection(_ size: NSSize) -> Rejection? {
        guard size.width.isFinite  else { return .nonFiniteWidth }
        guard size.height.isFinite else { return .nonFiniteHeight }
        guard size.width  > 0 else { return .nonPositiveWidth }
        guard size.height > 0 else { return .nonPositiveHeight }
        return nil
    }

    /// Returns `nil` when `origin` is safe to hand to `setFrameOrigin`,
    /// otherwise the first reason it is not.
    ///
    /// Finiteness only — a HUD legitimately sits at a negative origin on a
    /// display arranged to the left of, or below, the primary one.
    static func originRejection(_ origin: NSPoint) -> Rejection? {
        guard origin.x.isFinite else { return .nonFiniteX }
        guard origin.y.isFinite else { return .nonFiniteY }
        return nil
    }

    /// Top-right anchored origin for a panel of `panelSize` inside
    /// `visibleFrame`, with CSS-style `top` / `right` insets.
    ///
    /// Extracted from `HUDPanel.positionTopRight` for the same reason
    /// `FixedSizeWindowConfigurator.adjustedFrame(for:target:)` was
    /// extracted from its window lock: the arithmetic is the part worth
    /// testing and the `NSWindow` around it is not testable at all.
    ///
    /// - Returns: a finite point, or `nil` when `visibleFrame` is itself
    ///   not finite — the one input for which no screen-derived fallback
    ///   exists. The caller logs and skips in that case.
    ///
    /// **Non-finite terms are sanitised to zero rather than propagated.**
    /// A NaN in `panelSize` or in an inset would otherwise poison the
    /// subtraction and produce exactly the NaN origin this helper exists
    /// to keep away from AppKit. `HUDController.repositionPermissionPanels`
    /// accumulates `topInset` from `panel.frame.height`, so a corrupt
    /// frame on one card would otherwise travel into the next card's
    /// origin. Zeroing parks the panel flush in the corner — visibly
    /// wrong, logged, and not a crash.
    static func topRightOrigin(
        visibleFrame: NSRect,
        panelSize: NSSize,
        topInset: CGFloat,
        rightInset: CGFloat
    ) -> NSPoint? {
        guard visibleFrame.origin.x.isFinite,
              visibleFrame.origin.y.isFinite,
              visibleFrame.size.width.isFinite,
              visibleFrame.size.height.isFinite
        else { return nil }

        let width  = panelSize.width.isFinite  ? panelSize.width  : 0
        let height = panelSize.height.isFinite ? panelSize.height : 0
        let right  = rightInset.isFinite ? rightInset : 0
        let top    = topInset.isFinite   ? topInset   : 0

        return NSPoint(
            x: visibleFrame.maxX - width - right,
            y: visibleFrame.maxY - height - top
        )
    }
}
