import AppKit
import XCTest
@testable import NoType

/// Pins `HUDPanelGeometry` — the pure validation that stands between an
/// `NSHostingView.fittingSize` measurement and AppKit's NaN assertion in
/// `-[NSWindow setFrameOrigin:]`.
///
/// Scope note: the predicate is the unit under test on purpose.
/// `HUDPanel.applyValidated(contentSize:)` / `(frameOrigin:)` are `private`
/// and driving them would mean constructing a real `NSPanel` with a live
/// `NSHostingView` — which is exactly the unstable-context measurement the
/// helper exists to survive, and not reproducible on demand. "Every call
/// site is gated" is carried by source inspection (U7's scan) and the
/// manual HUD smoke, not by widening access to make a test reach.
final class HUDPanelGeometryTests: XCTestCase {

    // MARK: - Size: accepted

    func test_size_finitePositive_isAccepted() {
        XCTAssertNil(HUDPanelGeometry.sizeRejection(NSSize(width: 300, height: 148)))
    }

    func test_size_seedContentSize_isAccepted() {
        // The floor a rejected first measurement leaves the panel at must
        // itself be a legal size — otherwise the fallback is not one.
        XCTAssertNil(HUDPanelGeometry.sizeRejection(HUDPanelGeometry.seedContentSize))
    }

    func test_size_subPointButPositive_isAccepted() {
        // The rule is "positive", not "at least one point". A hairline
        // panel is a layout bug, not a raise.
        XCTAssertNil(HUDPanelGeometry.sizeRejection(NSSize(width: 0.5, height: 0.5)))
    }

    // MARK: - Size: NaN

    // THE mutation these guard against: replacing `isFinite` with an
    // ordinary comparison. `Double.nan > 0` is `false`, so a positivity-only
    // check still *rejects* NaN — but for the wrong reason, and the log
    // line then names the wrong defect. Asserting the reason, not just the
    // rejection, is what makes that mutation visible.

    func test_size_nanWidth_isRejectedAsNonFinite_notAsNonPositive() {
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(NSSize(width: CGFloat.nan, height: 148)),
            .nonFiniteWidth,
            "a NaN width classified as .nonPositiveWidth means the finiteness limb was replaced by a comparison"
        )
    }

    func test_size_nanHeight_isRejectedAsNonFinite_notAsNonPositive() {
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(NSSize(width: 300, height: CGFloat.nan)),
            .nonFiniteHeight,
            "a NaN height classified as .nonPositiveHeight means the finiteness limb was replaced by a comparison"
        )
    }

    func test_size_bothNaN_reportsWidthFirst() {
        // Deterministic ordering so the log line is stable.
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(NSSize(width: CGFloat.nan, height: CGFloat.nan)),
            .nonFiniteWidth
        )
    }

    // MARK: - Size: infinity

    // The killer mutation. `Double.infinity > 0` is `true`, so a
    // positivity-only check waves infinity straight through to AppKit —
    // and a bare `x != x` NaN idiom does too. Only `isFinite` catches it.

    func test_size_infiniteWidth_isRejected() {
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(NSSize(width: CGFloat.infinity, height: 148)),
            .nonFiniteWidth,
            "infinity passes both `> 0` and `x == x`; only isFinite rejects it"
        )
    }

    func test_size_infiniteHeight_isRejected() {
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(NSSize(width: 300, height: CGFloat.infinity)),
            .nonFiniteHeight,
            "infinity passes both `> 0` and `x == x`; only isFinite rejects it"
        )
    }

    func test_size_negativeInfiniteHeight_isRejectedAsNonFinite() {
        // -inf *does* fail `> 0`, so this one alone cannot distinguish the
        // two implementations — but it pins the classification, which can.
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(NSSize(width: 300, height: -CGFloat.infinity)),
            .nonFiniteHeight
        )
    }

    func test_size_negativeInfiniteWidth_isRejectedAsNonFinite() {
        // Symmetry with the height case above: without it, a width-only
        // guard reordered to positivity-first still classifies -inf as
        // `.nonPositiveWidth` with nothing to catch it.
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(NSSize(width: -CGFloat.infinity, height: 148)),
            .nonFiniteWidth
        )
    }

    // MARK: - Size: zero and negative

    func test_size_zero_isRejected() {
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(.zero),
            .nonPositiveWidth,
            "zero is finite, so the positivity limb — not the finiteness limb — must catch it"
        )
    }

    func test_size_zeroHeightOnly_isRejected() {
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(NSSize(width: 300, height: 0)),
            .nonPositiveHeight
        )
    }

    func test_size_negativeWidth_isRejected() {
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(NSSize(width: -300, height: 148)),
            .nonPositiveWidth
        )
    }

    func test_size_negativeHeight_isRejected() {
        XCTAssertEqual(
            HUDPanelGeometry.sizeRejection(NSSize(width: 300, height: -148)),
            .nonPositiveHeight
        )
    }

    // MARK: - Origin

    func test_origin_finite_isAccepted() {
        XCTAssertNil(HUDPanelGeometry.originRejection(NSPoint(x: 1124, y: 762)))
    }

    func test_origin_negative_isAccepted() {
        // A display arranged left of / below the primary one gives a
        // legitimately negative origin. Finiteness only — never positivity.
        XCTAssertNil(HUDPanelGeometry.originRejection(NSPoint(x: -1140, y: -200)))
    }

    func test_origin_zero_isAccepted() {
        XCTAssertNil(HUDPanelGeometry.originRejection(.zero))
    }

    func test_origin_nanX_isRejected() {
        XCTAssertEqual(
            HUDPanelGeometry.originRejection(NSPoint(x: CGFloat.nan, y: 762)),
            .nonFiniteX
        )
    }

    func test_origin_nanY_isRejected() {
        XCTAssertEqual(
            HUDPanelGeometry.originRejection(NSPoint(x: 1124, y: CGFloat.nan)),
            .nonFiniteY
        )
    }

    func test_origin_infiniteX_isRejected() {
        // The `x != x` mutation: a NaN-only idiom accepts this point and
        // hands infinity to setFrameOrigin.
        XCTAssertEqual(
            HUDPanelGeometry.originRejection(NSPoint(x: CGFloat.infinity, y: 762)),
            .nonFiniteX,
            "an `x != x` NaN idiom would accept infinity here"
        )
    }

    func test_origin_infiniteY_isRejected() {
        XCTAssertEqual(
            HUDPanelGeometry.originRejection(NSPoint(x: 1124, y: -CGFloat.infinity)),
            .nonFiniteY,
            "an `x != x` NaN idiom would accept infinity here"
        )
    }

    // MARK: - topRightOrigin: the normal case

    private static let laptopVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 875)

    func test_topRightOrigin_plausibleVisibleFrame() {
        let placement = HUDPanelGeometry.topRightOrigin(
            visibleFrame: Self.laptopVisibleFrame,
            panelSize: NSSize(width: 300, height: 148),
            topInset: 38,
            rightInset: 16
        )
        XCTAssertEqual(placement?.origin.x, 1440 - 300 - 16)
        XCTAssertEqual(placement?.origin.y, 875 - 148 - 38)
        XCTAssertEqual(
            placement?.sanitised, [],
            "the clean path must report no substitutions — otherwise the caller logs an error on every normal placement"
        )
    }

    func test_topRightOrigin_offsetVisibleFrame_secondaryDisplay() {
        // A display arranged to the left of the primary: the visible
        // frame's own origin is negative and must be honoured, which is
        // what `maxX` / `maxY` (not `width` / `height`) buy.
        let placement = HUDPanelGeometry.topRightOrigin(
            visibleFrame: NSRect(x: -1920, y: 100, width: 1920, height: 1000),
            panelSize: NSSize(width: 300, height: 148),
            topInset: 38,
            rightInset: 16
        )
        XCTAssertEqual(placement?.origin.x, 0 - 300 - 16)
        XCTAssertEqual(placement?.origin.y, 1100 - 148 - 38)
        XCTAssertEqual(placement?.sanitised, [])
    }

    // MARK: - topRightOrigin: the no-prior-position case

    func test_topRightOrigin_afterRejectedFirstMeasurement_isScreenDerived_notZero() throws {
        // The scenario the whole rejection policy turns on: `fittingSize`
        // came back NaN on the first pass, `applyValidated(contentSize:)`
        // skipped, so the panel is still at `seedContentSize`. The origin
        // must still be computed — a skip here parks the HUD at the
        // seeded (0, 0) contentRect, i.e. the bottom-left corner of the
        // screen, silently, for the rest of the session.
        let placement = try XCTUnwrap(HUDPanelGeometry.topRightOrigin(
            visibleFrame: Self.laptopVisibleFrame,
            panelSize: HUDPanelGeometry.seedContentSize,
            topInset: 38,
            rightInset: 16
        ))
        XCTAssertEqual(placement.origin.x, 1440 - 300 - 16)
        XCTAssertEqual(placement.origin.y, 875 - 100 - 38)
        XCTAssertNotEqual(placement.origin, .zero, "the fallback must be screen-derived, not the seeded origin")
        XCTAssertNil(
            HUDPanelGeometry.originRejection(placement.origin),
            "the fallback origin must itself pass the origin gate"
        )
        XCTAssertEqual(
            placement.sanitised, [],
            "seedContentSize is finite, so falling back to it is not a substitution and must not log as one"
        )
    }

    // MARK: - topRightOrigin: substituting non-finite terms

    func test_topRightOrigin_nonFinitePanelSize_isSanitisedToZero_notPropagated() throws {
        // A NaN in the panel size must not travel into the subtraction —
        // that is precisely how a NaN origin reaches setFrameOrigin.
        let placement = try XCTUnwrap(HUDPanelGeometry.topRightOrigin(
            visibleFrame: Self.laptopVisibleFrame,
            panelSize: NSSize(width: CGFloat.nan, height: CGFloat.infinity),
            topInset: 38,
            rightInset: 16
        ))
        XCTAssertEqual(placement.origin.x, 1440 - 0 - 16)
        XCTAssertEqual(placement.origin.y, 875 - 0 - 38)
        XCTAssertNil(
            HUDPanelGeometry.originRejection(placement.origin),
            "a substituted origin must pass the origin gate"
        )
        XCTAssertEqual(
            placement.sanitised, [.panelWidth, .panelHeight],
            "the substitution must be reported — an origin the origin gate accepts is one nothing downstream can log"
        )
    }

    func test_topRightOrigin_nonFiniteInsets_areSanitisedToZero() throws {
        // `HUDController.repositionPermissionPanels` accumulates
        // `topInset` from `panel.frame.height`, so one corrupt card's
        // frame would otherwise travel into the next card's origin.
        let placement = try XCTUnwrap(HUDPanelGeometry.topRightOrigin(
            visibleFrame: Self.laptopVisibleFrame,
            panelSize: NSSize(width: 300, height: 148),
            topInset: CGFloat.nan,
            rightInset: CGFloat.infinity
        ))
        XCTAssertEqual(placement.origin.x, 1440 - 300)
        XCTAssertEqual(placement.origin.y, 875 - 148)
        XCTAssertEqual(placement.sanitised, [.topInset, .rightInset])
    }

    /// Each of the four substitutable terms, driven independently and in
    /// **both** polarities.
    ///
    /// Two mutations this kills that the combined cases above do not: a
    /// per-term guard that handles NaN but not infinity (or vice versa),
    /// and a mis-wired `SanitisedTerm` that reports the wrong term because
    /// every combined case substitutes two terms at once.
    func test_topRightOrigin_eachTermIsSubstitutedIndependently_inBothPolarities() throws {
        let base = NSSize(width: 300, height: 148)
        for bad in [CGFloat.nan, .infinity, -.infinity] {
            let cases: [(HUDPanelGeometry.Placement?, HUDPanelGeometry.SanitisedTerm, CGFloat, CGFloat)] = [
                (HUDPanelGeometry.topRightOrigin(
                    visibleFrame: Self.laptopVisibleFrame,
                    panelSize: NSSize(width: bad, height: base.height),
                    topInset: 38, rightInset: 16
                ), .panelWidth, 1440 - 0 - 16, 875 - 148 - 38),

                (HUDPanelGeometry.topRightOrigin(
                    visibleFrame: Self.laptopVisibleFrame,
                    panelSize: NSSize(width: base.width, height: bad),
                    topInset: 38, rightInset: 16
                ), .panelHeight, 1440 - 300 - 16, 875 - 0 - 38),

                (HUDPanelGeometry.topRightOrigin(
                    visibleFrame: Self.laptopVisibleFrame,
                    panelSize: base,
                    topInset: bad, rightInset: 16
                ), .topInset, 1440 - 300 - 16, 875 - 148 - 0),

                (HUDPanelGeometry.topRightOrigin(
                    visibleFrame: Self.laptopVisibleFrame,
                    panelSize: base,
                    topInset: 38, rightInset: bad
                ), .rightInset, 1440 - 300 - 0, 875 - 148 - 38)
            ]

            for (result, term, expectedX, expectedY) in cases {
                let placement = try XCTUnwrap(result, "\(term) with \(bad) must still yield a placement")
                XCTAssertEqual(placement.sanitised, [term], "\(bad) in \(term) reported the wrong term")
                XCTAssertEqual(placement.origin.x, expectedX, "\(term) / \(bad)")
                XCTAssertEqual(placement.origin.y, expectedY, "\(term) / \(bad)")
                XCTAssertNil(HUDPanelGeometry.originRejection(placement.origin))
            }
        }
    }

    // MARK: - topRightOrigin: the one unrecoverable input

    /// All four `visibleFrame` components, each driven to non-finite on its
    /// own. The guard ANDs them, so a case only ever exercised alongside
    /// another leaves its own limb free to be deleted.
    func test_topRightOrigin_eachNonFiniteVisibleFrameComponent_returnsNil() {
        let frames: [(String, NSRect)] = [
            ("origin.x",    NSRect(x: CGFloat.nan, y: 0, width: 1440, height: 875)),
            ("origin.y",    NSRect(x: 0, y: CGFloat.infinity, width: 1440, height: 875)),
            ("size.width",  NSRect(x: 0, y: 0, width: CGFloat.nan, height: 875)),
            ("size.height", NSRect(x: 0, y: 0, width: 1440, height: -CGFloat.infinity))
        ]
        for (label, frame) in frames {
            XCTAssertNil(
                HUDPanelGeometry.topRightOrigin(
                    visibleFrame: frame,
                    panelSize: NSSize(width: 300, height: 148),
                    topInset: 38,
                    rightInset: 16
                ),
                "non-finite visibleFrame \(label): with no usable screen geometry there is no screen-derived fallback to return"
            )
        }
    }

    // MARK: - Exhaustiveness

    func test_everyRejectionCase_isProducedBySomeInput() {
        // Guards the classification against rot: a case added with no
        // input that produces it fails here instead of shipping dead
        // classification. Same discipline as
        // `MicProbeFormatGateTests.test_everyRejectionCase_isProducedBySomeShapePair`.
        let producers: [HUDPanelGeometry.Rejection: () -> HUDPanelGeometry.Rejection?] = [
            .nonFiniteWidth:    { HUDPanelGeometry.sizeRejection(NSSize(width: CGFloat.nan, height: 148)) },
            .nonFiniteHeight:   { HUDPanelGeometry.sizeRejection(NSSize(width: 300, height: CGFloat.nan)) },
            .nonPositiveWidth:  { HUDPanelGeometry.sizeRejection(NSSize(width: 0, height: 148)) },
            .nonPositiveHeight: { HUDPanelGeometry.sizeRejection(NSSize(width: 300, height: 0)) },
            .nonFiniteX:        { HUDPanelGeometry.originRejection(NSPoint(x: CGFloat.nan, y: 0)) },
            .nonFiniteY:        { HUDPanelGeometry.originRejection(NSPoint(x: 0, y: CGFloat.nan)) }
        ]

        for expected in HUDPanelGeometry.Rejection.allCases {
            guard let produce = producers[expected] else {
                XCTFail("no input produces \(expected) — add one or drop the case")
                continue
            }
            XCTAssertEqual(produce(), expected, "\(expected) is not produced by its documented input")
        }
    }

    func test_everySanitisedTermCase_isProducedBySomeInput() {
        // Same discipline as the Rejection exhaustiveness test above: a
        // term the caller can never be told about is a term whose
        // substitution is silent, which is the defect this type exists to
        // prevent.
        let base = NSSize(width: 300, height: 148)
        let producers: [HUDPanelGeometry.SanitisedTerm: () -> [HUDPanelGeometry.SanitisedTerm]?] = [
            .panelWidth: {
                HUDPanelGeometry.topRightOrigin(
                    visibleFrame: Self.laptopVisibleFrame,
                    panelSize: NSSize(width: CGFloat.nan, height: base.height),
                    topInset: 38, rightInset: 16
                )?.sanitised
            },
            .panelHeight: {
                HUDPanelGeometry.topRightOrigin(
                    visibleFrame: Self.laptopVisibleFrame,
                    panelSize: NSSize(width: base.width, height: CGFloat.nan),
                    topInset: 38, rightInset: 16
                )?.sanitised
            },
            .topInset: {
                HUDPanelGeometry.topRightOrigin(
                    visibleFrame: Self.laptopVisibleFrame,
                    panelSize: base, topInset: CGFloat.nan, rightInset: 16
                )?.sanitised
            },
            .rightInset: {
                HUDPanelGeometry.topRightOrigin(
                    visibleFrame: Self.laptopVisibleFrame,
                    panelSize: base, topInset: 38, rightInset: CGFloat.nan
                )?.sanitised
            }
        ]

        for expected in HUDPanelGeometry.SanitisedTerm.allCases {
            guard let produce = producers[expected] else {
                XCTFail("no input produces \(expected) — add one or drop the case")
                continue
            }
            XCTAssertEqual(produce(), [expected], "\(expected) is not produced by its documented input")
        }
    }
}
