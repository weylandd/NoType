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
/// raising in the wild, and this path is *mostly* dead for a user parked
/// mid-onboarding — two of the three `presentMissing` callers are gated
/// on `onboarding.isComplete`, but `AppState.handleHotkeyPress` is not,
/// so a stray hotkey press with the microphone ungranted still builds a
/// panel mid-wizard. Do not read that as an exclusion. What names the
/// actual thrower is `NoType/Diagnostics/ExceptionBreadcrumb.swift`, not
/// this file.
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
    /// keep away from AppKit. ``column(_:topInset:gap:)`` accumulates each
    /// row's `topInset` from the measured heights above it, so a corrupt
    /// frame on one panel would otherwise travel into every origin below
    /// it. That accumulator now substitutes an unusable height itself (and
    /// reports it), so this limb is the second line rather than the first —
    /// it still stands, because `topRightOrigin` is a chokepoint for any
    /// caller, not a guard on one.
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

    // MARK: - The top-right column

    /// Every surface that can occupy the top-right HUD column, in the
    /// order it stacks downward from the column's `topInset`.
    ///
    /// **This enum is the layering, and the order is the contract.**
    /// Before it existed, all four HUD kinds were positioned by handing
    /// `HUDController.topInset` verbatim to
    /// ``topRightOrigin(visibleFrame:panelSize:topInset:rightInset:)``, so
    /// any two co-visible panels were *superimposed* at the same point at
    /// the same `NSWindow.Level.statusBar`. Two `.borderless` panels
    /// stacked in Z with their close buttons in the same 22 × 22 box is
    /// indistinguishable, to the user, from a close button that does not
    /// work: the click lands on the front panel, and the identical panel
    /// behind it is revealed in the same place.
    ///
    /// The error HUD owns the top slot because it is the only surface that
    /// is *about* something having gone wrong and the only one that
    /// auto-dismisses — a notice pushed below a permission card the user
    /// has been ignoring for a week is a notice they will not read. Note
    /// what this deliberately is **not**: the error HUD does not *hide* the
    /// other surfaces. "Shows alone" was the old documented claim and it
    /// cannot be honestly implemented — a permission card names something
    /// the app cannot function without, and suppressing it to make room for
    /// a transient toast trades one lost message for another.
    ///
    /// `recording` and `transcribing` are mutually exclusive by
    /// construction (`HUDController.showTranscribingHUD` closes the
    /// recording panel), so their relative order never resolves anything in
    /// practice. They are still ranked, because a column with a
    /// deterministic total order is testable and one with a partial order
    /// is not.
    enum Slot: Int, CaseIterable, Comparable, Sendable, CustomStringConvertible {
        case error
        case recording
        case transcribing
        case accessibilityCard
        case microphoneCard

        static func < (lhs: Slot, rhs: Slot) -> Bool { lhs.rawValue < rhs.rawValue }

        var description: String {
            switch self {
            case .error:             "error"
            case .recording:         "recording"
            case .transcribing:      "transcribing"
            case .accessibilityCard: "accessibility-card"
            case .microphoneCard:    "microphone-card"
            }
        }
    }

    /// A live panel offered to ``column(_:topInset:gap:)`` for placement.
    struct Occupant: Equatable, Sendable {
        let slot: Slot
        /// The panel's measured frame height. Sized by `HUDPanel.sizeToFit()`
        /// before this is read — a column's second row cannot be placed until
        /// the first row's height is known, which is the whole reason that
        /// measure pass is separable from the place pass.
        let height: CGFloat

        init(slot: Slot, height: CGFloat) {
            self.slot = slot
            self.height = height
        }
    }

    /// Where one occupant's panel goes: its own top inset within the column.
    struct Row: Equatable, Sendable {
        let slot: Slot
        let topInset: CGFloat
    }

    /// The resolved column, plus whichever occupants' measured heights were
    /// unusable and had to be assumed.
    ///
    /// `sanitised` exists for the same reason ``Placement/sanitised`` does:
    /// a substituted height still yields arithmetically valid insets, so
    /// nothing downstream would ever mention it, and a column silently laid
    /// out against a made-up height is the silent-degradation shape this
    /// whole file exists to stop.
    struct Column: Equatable, Sendable {
        let rows: [Row]
        let sanitised: [Slot]
    }

    /// Lay `occupants` out as a single top-anchored column: slot order from
    /// the top, `gap` between neighbours, each row's inset accumulated from
    /// the heights above it.
    ///
    /// Input order is irrelevant — the column sorts by ``Slot``, so the
    /// caller cannot change the layering by changing the order it happens
    /// to collect its live panels in.
    ///
    /// **An unusable height is assumed to be ``seedContentSize``'s, not
    /// skipped.** Skipping would advance the accumulator by nothing and
    /// place the next panel at the *same* inset — re-creating the exact
    /// superposition this function exists to prevent, and doing it on the
    /// one path where something has already gone wrong. `seedContentSize`
    /// is the honest assumption rather than an arbitrary one: it is what
    /// `HUDPanel.applyValidated(contentSize:)` leaves a panel at when it
    /// rejects a measurement, so on the path that produces a non-finite
    /// height it is also the panel's real on-screen height.
    ///
    /// `topInset` and `gap` are not sanitised here. Both are compile-time
    /// constants at the only call site, and a non-finite `topInset` is
    /// already substituted (and reported) one layer down by
    /// ``topRightOrigin(visibleFrame:panelSize:topInset:rightInset:)``, so
    /// nothing non-finite reaches AppKit either way.
    static func column(
        _ occupants: [Occupant],
        topInset: CGFloat,
        gap: CGFloat
    ) -> Column {
        var rows: [Row] = []
        var sanitised: [Slot] = []
        var next = topInset

        for occupant in occupants.sorted(by: { $0.slot < $1.slot }) {
            rows.append(Row(slot: occupant.slot, topInset: next))

            let height: CGFloat
            if occupant.height.isFinite, occupant.height > 0 {
                height = occupant.height
            } else {
                sanitised.append(occupant.slot)
                height = seedContentSize.height
            }
            next += height + gap
        }

        return Column(rows: rows, sanitised: sanitised)
    }
}
