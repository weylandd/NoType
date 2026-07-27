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
///   substitutes each non-finite contributing term and still returns a
///   screen-derived top-right point — a placed HUD beats both a crash and
///   a HUD in the wrong corner — **and reports which terms it had to
///   substitute** so the caller can log it. It returns `nil` only when the
///   *screen's* visible frame is itself unusable, because that is the one
///   input no fallback can be derived from.
///
/// Every rejection **and every substitution** is logged at a persisted
/// level by the caller (`HUDPanel`); a silently mispositioned HUD with no
/// log line is the failure shape this whole work stream exists to stop.
/// That is why ``topRightOrigin(visibleFrame:panelSize:topInset:rightInset:)``
/// returns a ``Placement`` rather than a bare point: a substituted origin
/// is arithmetically valid, so ``originRejection(_:)`` waves it through and
/// the caller would otherwise have no way to tell it from a clean one.
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

    /// A term ``topRightOrigin(visibleFrame:panelSize:topInset:rightInset:)``
    /// had to substitute because the caller's value was not finite.
    ///
    /// This type exists so the substitution is **reportable**. A substituted
    /// origin is arithmetically valid, so ``originRejection(_:)`` accepts it
    /// and no rejection is ever logged — without naming the term, a HUD that
    /// moved because one card's frame was corrupt is indistinguishable from
    /// a correctly placed one. Silent degradation is precisely the shape
    /// this work stream exists to stop.
    enum SanitisedTerm: Hashable, Sendable, CaseIterable, CustomStringConvertible {
        /// `panelSize.width` was NaN or infinite.
        case panelWidth
        /// `panelSize.height` was NaN or infinite.
        case panelHeight
        /// `topInset` was NaN or infinite — the `HUDController` accumulator case.
        case topInset
        /// `rightInset` was NaN or infinite.
        case rightInset

        var description: String {
            switch self {
            case .panelWidth:  "panel width"
            case .panelHeight: "panel height"
            case .topInset:    "top inset"
            case .rightInset:  "right inset"
            }
        }
    }

    /// Where to put the panel, plus whatever had to be substituted to get
    /// there.
    ///
    /// `sanitised` is empty on the clean path and is listed in
    /// ``SanitisedTerm`` declaration order otherwise, so the caller's log
    /// line is stable.
    struct Placement: Equatable, Sendable {
        let origin: NSPoint
        let sanitised: [SanitisedTerm]
    }

    /// Top-right anchored placement for a panel of `panelSize` inside
    /// `visibleFrame`, with CSS-style `top` / `right` insets.
    ///
    /// Extracted from `HUDPanel.positionTopRight` for the same reason
    /// `FixedSizeWindowConfigurator.adjustedFrame(for:target:)` was
    /// extracted from its window lock: the arithmetic is the part worth
    /// testing and the `NSWindow` around it is not testable at all.
    ///
    /// - Returns: a ``Placement`` whose origin is finite, or `nil` when
    ///   `visibleFrame` is itself not finite — the one input for which no
    ///   screen-derived fallback exists. The caller logs and skips in that
    ///   case.
    ///
    /// **Non-finite terms are substituted with zero rather than propagated.**
    /// A NaN in `panelSize` or in an inset would otherwise poison the
    /// subtraction and produce exactly the NaN origin this helper exists to
    /// keep away from AppKit. `HUDController.repositionPermissionPanels`
    /// accumulates `topInset` from `panel.frame.height`, so a corrupt frame
    /// on one card would otherwise travel into the next card's origin.
    ///
    /// Substituting zero anchors the arithmetic back to the screen, but the
    /// resulting point is **not a good placement**: the panel's real frame is
    /// unchanged, so zeroing its width leaves it overhanging the visible area
    /// by that width rather than sitting flush in the corner. It is placed,
    /// logged, and not a crash — not correct. That is exactly why the
    /// substitution is returned in `Placement.sanitised` instead of being
    /// swallowed here.
    static func topRightOrigin(
        visibleFrame: NSRect,
        panelSize: NSSize,
        topInset: CGFloat,
        rightInset: CGFloat
    ) -> Placement? {
        guard visibleFrame.origin.x.isFinite,
              visibleFrame.origin.y.isFinite,
              visibleFrame.size.width.isFinite,
              visibleFrame.size.height.isFinite
        else { return nil }

        var sanitised: [SanitisedTerm] = []
        func substitutingNonFinite(_ value: CGFloat, _ term: SanitisedTerm) -> CGFloat {
            guard value.isFinite else {
                sanitised.append(term)
                return 0
            }
            return value
        }

        let width  = substitutingNonFinite(panelSize.width,  .panelWidth)
        let height = substitutingNonFinite(panelSize.height, .panelHeight)
        let top    = substitutingNonFinite(topInset,         .topInset)
        let right  = substitutingNonFinite(rightInset,       .rightInset)

        return Placement(
            origin: NSPoint(
                x: visibleFrame.maxX - width - right,
                y: visibleFrame.maxY - height - top
            ),
            sanitised: sanitised
        )
    }
}
