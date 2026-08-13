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
        // `HUDPanelGeometry.column` accumulates each row's `topInset` from
        // the measured heights above it, so one corrupt panel's frame would
        // otherwise travel into every origin below it. The column sanitises
        // that itself now; this stays because `topRightOrigin` is a
        // chokepoint for any caller, not a guard on one.
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

    // MARK: - The column: the collision this whole seam exists to stop

    // THE regression. Before `column(_:topInset:gap:)` existed, every HUD kind
    // was placed by handing `HUDController.topInset` straight to
    // `topRightOrigin`, so any two co-visible panels resolved to the *same*
    // point at the same `NSWindow.Level.statusBar`. Two borderless panels
    // superimposed, each with a 22 × 22 close button in the same corner, is
    // indistinguishable from a close button that does nothing: the click
    // reaches the front panel only, and the one behind it is revealed in
    // exactly the place the user just clicked.
    //
    // These assert distinctness first and arithmetic second, in that order of
    // importance — a column that stacks in the wrong order is a cosmetic bug,
    // a column that stacks two panels at one inset is the reported one.

    func test_column_noTwoOccupantsEverShareAnInset() {
        let column = HUDPanelGeometry.column(
            HUDPanelGeometry.Slot.allCases.map { .init(slot: $0, height: 120) },
            topInset: 38,
            gap: 10
        )
        let insets = column.rows.map(\.topInset)
        XCTAssertEqual(insets.count, HUDPanelGeometry.Slot.allCases.count)
        XCTAssertEqual(
            Set(insets).count, insets.count,
            "two HUD panels resolved to the same top inset — that is the superposition that reads as a dead close button"
        )
    }

    func test_column_singleOccupant_sitsAtTheColumnTopInset() {
        let column = HUDPanelGeometry.column(
            [.init(slot: .error, height: 148)], topInset: 38, gap: 10
        )
        XCTAssertEqual(column.rows, [.init(slot: .error, topInset: 38)])
        XCTAssertEqual(column.sanitised, [])
    }

    func test_column_accumulatesHeightPlusGapPerRow() {
        let column = HUDPanelGeometry.column(
            [
                .init(slot: .error, height: 100),
                .init(slot: .recording, height: 60),
                .init(slot: .microphoneCard, height: 90)
            ],
            topInset: 38,
            gap: 10
        )
        XCTAssertEqual(
            column.rows,
            [
                .init(slot: .error, topInset: 38),
                .init(slot: .recording, topInset: 148),          // 38 + 100 + 10
                .init(slot: .microphoneCard, topInset: 218)      // 148 + 60 + 10
            ]
        )
    }

    func test_column_sortsBySlot_soCollectionOrderCannotChangeTheLayering() {
        // The controller collects live panels in whatever order its stored
        // properties happen to be read. If that order reached the layout, the
        // layering would be an accident of the collecting code.
        let reversed = HUDPanelGeometry.column(
            [
                .init(slot: .microphoneCard, height: 50),
                .init(slot: .accessibilityCard, height: 50),
                .init(slot: .error, height: 50)
            ],
            topInset: 0,
            gap: 0
        )
        XCTAssertEqual(reversed.rows.map(\.slot), [.error, .accessibilityCard, .microphoneCard])
    }

    func test_slotOrder_errorOwnsTheTopSlot() {
        // Pins the ruling in `Slot`'s doc-comment: the error HUD is the only
        // surface that auto-dismisses, so burying it under a permission card
        // the user has been ignoring means they never read it.
        XCTAssertEqual(HUDPanelGeometry.Slot.allCases.first, .error)
        XCTAssertTrue(HUDPanelGeometry.Slot.error < .recording)
        XCTAssertTrue(HUDPanelGeometry.Slot.error < .accessibilityCard)
    }

    func test_column_empty_producesNoRows() {
        let column = HUDPanelGeometry.column([], topInset: 38, gap: 10)
        XCTAssertEqual(column.rows, [])
        XCTAssertEqual(column.sanitised, [])
    }

    // MARK: - The column: unusable heights

    // A skipped row would advance the accumulator by nothing and put the next
    // panel back on top of this one — re-creating the superposition on the one
    // path where something has already gone wrong. `seedContentSize.height` is
    // the substitute because it is what `HUDPanel.applyValidated(contentSize:)`
    // leaves a rejected panel at, so on the path that produces a non-finite
    // measurement it is also the panel's real on-screen height.

    func test_column_nonFiniteHeight_isSubstitutedWithTheSeedHeight_andReported() {
        let column = HUDPanelGeometry.column(
            [
                .init(slot: .error, height: .nan),
                .init(slot: .recording, height: 60)
            ],
            topInset: 38,
            gap: 10
        )
        XCTAssertEqual(column.sanitised, [.error])
        XCTAssertEqual(
            column.rows,
            [
                .init(slot: .error, topInset: 38),
                .init(
                    slot: .recording,
                    topInset: 38 + HUDPanelGeometry.seedContentSize.height + 10
                )
            ],
            "a row whose height did not measure must still push the row below it clear of itself"
        )
    }

    func test_column_infiniteHeight_isSubstituted_notPropagated() {
        // `infinity > 0` is true, so a positivity-only check waves it through
        // and every inset below becomes infinity — the same mutation
        // `sizeRejection` is written against.
        let column = HUDPanelGeometry.column(
            [
                .init(slot: .error, height: .infinity),
                .init(slot: .recording, height: 60)
            ],
            topInset: 38,
            gap: 10
        )
        XCTAssertEqual(column.sanitised, [.error])
        XCTAssertTrue(
            column.rows.allSatisfy { $0.topInset.isFinite },
            "an infinite height propagated into the insets below it"
        )
    }

    func test_column_nonPositiveHeight_isSubstituted_andReported() {
        let column = HUDPanelGeometry.column(
            [
                .init(slot: .error, height: 0),
                .init(slot: .recording, height: -5),
                .init(slot: .transcribing, height: 40)
            ],
            topInset: 0,
            gap: 0
        )
        XCTAssertEqual(column.sanitised, [.error, .recording])
        XCTAssertEqual(
            column.rows.map(\.topInset),
            [0, HUDPanelGeometry.seedContentSize.height, HUDPanelGeometry.seedContentSize.height * 2]
        )
    }

    func test_column_cleanHeights_reportNothingSanitised() {
        // The complement: `sanitised` must be empty on the ordinary path, or
        // the controller logs a substitution warning on every layout and the
        // signal is worthless.
        let column = HUDPanelGeometry.column(
            HUDPanelGeometry.Slot.allCases.map { .init(slot: $0, height: 0.5) },
            topInset: 38,
            gap: 10
        )
        XCTAssertEqual(column.sanitised, [])
    }

    // MARK: - Raise-site guard: the tree

    // The rule these pin is in `NoType/UI/CLAUDE.md` — a raise-prone AppKit /
    // AVFoundation call inside a main-actor Swift-concurrency job is made only
    // after its preconditions are validated at the call. See
    // `RaiseSiteScanner` below for why the scan covers two files and not the
    // codebase, and `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`
    // for why the rule exists.

    func test_raiseSiteGuard_hudPanel_everyGeometryMutationSitsInsideItsChokepoint() throws {
        let source = try Self.appSource(RaiseSiteScanner.hudPanelPath)
        // Before asserting anything about violations, prove the scan still has
        // its subject: a read that silently resolved to the wrong or an empty
        // file would report zero violations and pass perfectly.
        XCTAssertTrue(
            source.contains("final class HUDPanel"),
            "\(RaiseSiteScanner.hudPanelPath) no longer declares HUDPanel — the scan lost its subject."
        )

        let unguarded = RaiseSiteScanner.unguardedCalls(inSource: source, rules: RaiseSiteScanner.hudPanelRules)
        XCTAssertEqual(
            unguarded.map(\.description), [],
            """
            \(RaiseSiteScanner.hudPanelPath): an AppKit geometry mutation is written outside \
            `applyValidated(…)`.

            Every setContentSize / setFrameOrigin / setFrame call in this file must go through \
            the validating wrapper — a NaN `NSHostingView.fittingSize` handed to AppKit raises \
            NSInvalidArgumentException, and these panels are presented from inside a \
            `Task { @MainActor }` where that raise corrupts the process's main-executor identity. \
            See NoType/UI/CLAUDE.md and \
            docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md.
            """
        )
    }

    func test_raiseSiteGuard_micProbe_everyTapMutationSitsInsideItsChokepoint() throws {
        let source = try Self.appSource(RaiseSiteScanner.micProbePath)
        XCTAssertTrue(
            source.contains("final class MicProbe"),
            "\(RaiseSiteScanner.micProbePath) no longer declares MicProbe — the scan lost its subject."
        )

        let unguarded = RaiseSiteScanner.unguardedCalls(inSource: source, rules: RaiseSiteScanner.micProbeRules)
        XCTAssertEqual(
            unguarded.map(\.description), [],
            """
            \(RaiseSiteScanner.micProbePath): an AVAudioEngine tap mutation is written outside \
            its chokepoint.

            `installTap` belongs in `installTapAndStart()` (behind MicProbeFormatGate) and \
            `removeTap` in `removeTapIfInstalled()` (behind the lock-guarded `tapInstalled` \
            gate). Both raise `com.apple.coreaudio.avfaudio` on a bad argument, and both are \
            reachable from `Task { @MainActor }` bodies. The historical shape of this bug is a \
            bare `removeTap` in the `engine.start()` catch arm, safe only by local reasoning \
            about the two lines above it.
            """
        )
    }

    func test_placementGuard_hudController_everyPlacementGoesThroughTheColumn() throws {
        let source = try Self.appSource(RaiseSiteScanner.hudControllerPath)
        XCTAssertTrue(
            source.contains("final class HUDController"),
            "\(RaiseSiteScanner.hudControllerPath) no longer declares HUDController — the scan lost its subject."
        )

        let unguarded = RaiseSiteScanner.unguardedCalls(
            inSource: source, rules: RaiseSiteScanner.hudControllerRules
        )
        XCTAssertEqual(
            unguarded.map(\.description), [],
            """
            \(RaiseSiteScanner.hudControllerPath): a HUD panel is positioned outside `relayout()`.

            Every `positionTopRight` call in this file must take its inset from \
            `HUDPanelGeometry.column(_:topInset:gap:)`. A placement written anywhere else \
            hands a panel the raw `topInset` again, which is how all four HUD kinds ended up \
            superimposed at one point at one window level — and superimposed panels read to \
            the user as a close button that does not work. See NoType/UI/CLAUDE.md \
            "HUD slots & widths".
            """
        )
    }

    func test_placementGuard_hudController_columnIsPresentInvokedAndStillConsulted() throws {
        // The presence complement required by
        // `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`.
        // The absence test above is trivially green on a file where `relayout`
        // was deleted, was never called, or had decayed into placing panels
        // without asking the column — which is the whole regression, restored.
        let source = try Self.appSource(RaiseSiteScanner.hudControllerPath)
        XCTAssertEqual(
            RaiseSiteScanner.presenceFailures(
                inSource: source, rules: RaiseSiteScanner.hudControllerRules
            ).map(\.description),
            [],
            "\(RaiseSiteScanner.hudControllerPath): the column chokepoint is dead, unreachable, or no longer consults HUDPanelGeometry."
        )
    }

    func test_placementGuard_hudController_everyShowAndHideRelayouts() throws {
        // The scan above cannot see this: a `hideErrorHUD` that drops its
        // panel without calling `relayout()` writes no `positionTopRight` at
        // all, so it escapes an absence-only guard entirely — and leaves every
        // row below the closed one parked in its old place, with a hole where
        // the dismissed panel was. The column is only correct if *every*
        // mutation of the panel set re-derives it.
        let source = try Self.appSource(RaiseSiteScanner.hudControllerPath)
        let code = LaunchPathScanner.strippingCommentsAndStrings(source)
        let mutators = [
            "func presentMissing", "func reconcileGranted", "func hidePermissionsHUD",
            "func dismissPermissionPanel", "func showRecordingHUD", "func hideRecordingHUD",
            "func showTranscribingHUD", "func hideTranscribingHUD",
            "func showErrorHUD", "func hideErrorHUD"
        ]
        let functions = LaunchPathScanner.functionBodies(in: code)
        var missing: [String] = []
        for mutator in mutators {
            let name = String(mutator.dropFirst("func ".count))
            guard let body = functions.first(where: { $0.name == name })?.body else {
                missing.append("\(name) is no longer declared")
                continue
            }
            if !LaunchPathScanner.line(body, contains: "relayout (") {
                missing.append("\(name) mutates the panel set without calling relayout()")
            }
        }
        XCTAssertEqual(
            missing, [],
            "\(RaiseSiteScanner.hudControllerPath): a show/hide leaves the column stale."
        )
    }

    // MARK: - Raise-site guard: the presence complement

    // Non-optional, per `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`:
    // the two tests above assert only that no call escapes its chokepoint, and
    // that is trivially satisfied by the chokepoint — or the whole feature —
    // being deleted. These assert the destination is alive: the mutator still
    // happens, the chokepoint is defined, something calls it, and it still
    // validates rather than having decayed into a passthrough.

    func test_raiseSiteGuard_hudPanel_chokepointIsPresentInvokedAndStillValidating() throws {
        let source = try Self.appSource(RaiseSiteScanner.hudPanelPath)
        XCTAssertEqual(
            RaiseSiteScanner.presenceFailures(
                inSource: source, rules: RaiseSiteScanner.hudPanelRules
            ).map(\.description),
            [],
            "\(RaiseSiteScanner.hudPanelPath): the geometry chokepoint is dead, unreachable, or no longer validates."
        )
    }

    func test_raiseSiteGuard_micProbe_chokepointsArePresentInvokedAndStillValidating() throws {
        let source = try Self.appSource(RaiseSiteScanner.micProbePath)
        XCTAssertEqual(
            RaiseSiteScanner.presenceFailures(
                inSource: source, rules: RaiseSiteScanner.micProbeRules
            ).map(\.description),
            [],
            "\(RaiseSiteScanner.micProbePath): a tap chokepoint is dead, unreachable, or no longer validates."
        )
    }

    // MARK: - Raise-site guard: fixtures pinning the scanner itself

    func test_scanner_acceptsAMutationInsideAValidatingChokepoint() {
        XCTAssertEqual(RaiseSiteScanner.unguardedCalls(inSource: Self.guardedFixture, rules: Self.fixtureRules), [])
        XCTAssertEqual(RaiseSiteScanner.presenceFailures(inSource: Self.guardedFixture, rules: Self.fixtureRules), [])
    }

    func test_scanner_flagsAMutationOutsideTheChokepoint() {
        let source = """
        final class Fixture {
            func position() {
                setFrameOrigin(NSPoint(x: 1, y: 2))
            }
            private func applyValidated(frameOrigin origin: NSPoint) {
                if Geometry.originRejection(origin) != nil { return }
                setFrameOrigin(origin)
            }
        }
        """
        let hits = RaiseSiteScanner.unguardedCalls(inSource: source, rules: Self.fixtureRules)
        XCTAssertEqual(hits.count, 1, "Expected the bare call in `position()` to be flagged. Got: \(hits)")
        XCTAssertEqual(hits.first?.kind, .unguarded)
        XCTAssertEqual(hits.first?.scope, "position")
    }

    /// A raise-prone call written directly in `deinit` sits inside no `func`
    /// body at all. It must be flagged, not skipped — `MicProbe.deinit` is a
    /// real tap-mutation site and the reason `removeTapIfInstalled()` exists.
    func test_scanner_flagsAMutationAtNoEnclosingFunctionScope() {
        let source = """
        final class Fixture {
            deinit {
                setFrameOrigin(.zero)
            }
            private func applyValidated(frameOrigin origin: NSPoint) {
                if Geometry.originRejection(origin) != nil { return }
                setFrameOrigin(origin)
            }
        }
        """
        let hits = RaiseSiteScanner.unguardedCalls(inSource: source, rules: Self.fixtureRules)
        XCTAssertEqual(hits.count, 1, "Got: \(hits)")
        XCTAssertEqual(hits.first?.scope, RaiseSiteScanner.noEnclosingScope)
    }

    /// THE mutation the absence half cannot see. The call still sits inside
    /// `applyValidated`, so no call has escaped — but the wrapper no longer
    /// validates anything, and the raise is back with every source-scan
    /// assertion green. This is the hook-guard trap from
    /// `source-scan-guard-fidelity-2026-07-25.md` in its source-scan form.
    func test_scanner_flagsAChokepointStrippedOfItsValidation() {
        let source = """
        final class Fixture {
            func position() {
                applyValidated(frameOrigin: .zero)
            }
            private func applyValidated(frameOrigin origin: NSPoint) {
                setFrameOrigin(origin)
            }
        }
        """
        XCTAssertEqual(
            RaiseSiteScanner.unguardedCalls(inSource: source, rules: Self.fixtureRules), [],
            "the absence half is structurally blind to this — that is why the presence half exists"
        )
        let failures = RaiseSiteScanner.presenceFailures(inSource: source, rules: Self.fixtureRules)
        XCTAssertEqual(failures.map(\.kind), [.chokepointNotValidating], "Got: \(failures)")
    }

    func test_scanner_presenceFlagsADeletedChokepoint() {
        let source = """
        final class Fixture {
            func position() {
                setFrameOrigin(.zero)
            }
        }
        """
        let kinds = RaiseSiteScanner.presenceFailures(inSource: source, rules: Self.fixtureRules).map(\.kind)
        XCTAssertTrue(kinds.contains(.chokepointMissing), "Got: \(kinds)")
    }

    /// The absence-only trap in its purest form: delete the feature and
    /// "no unguarded call site exists" is vacuously true.
    func test_scanner_presenceFlagsAVanishedMutator() {
        let source = """
        final class Fixture {
            private func applyValidated(frameOrigin origin: NSPoint) {
                _ = Geometry.originRejection(origin)
            }
        }
        """
        XCTAssertEqual(RaiseSiteScanner.unguardedCalls(inSource: source, rules: Self.fixtureRules), [])
        let kinds = RaiseSiteScanner.presenceFailures(inSource: source, rules: Self.fixtureRules).map(\.kind)
        XCTAssertTrue(kinds.contains(.mutatorVanished), "Got: \(kinds)")
    }

    /// A chokepoint that is defined and validates, and that nothing calls —
    /// `scene-task-is-not-a-launch-hook`'s failure one level in. The panel
    /// would simply never be sized.
    func test_scanner_presenceFlagsAChokepointNothingInvokes() {
        let source = """
        final class Fixture {
            private func applyValidated(frameOrigin origin: NSPoint) {
                if Geometry.originRejection(origin) != nil { return }
                setFrameOrigin(origin)
            }
        }
        """
        let kinds = RaiseSiteScanner.presenceFailures(inSource: source, rules: Self.fixtureRules).map(\.kind)
        XCTAssertTrue(kinds.contains(.chokepointNeverCalled), "Got: \(kinds)")
    }

    /// The overload-collapse hole. `applyValidated` is *already* overloaded in
    /// `HUDPanel` (contentSize / frameOrigin), so "some body named the
    /// chokepoint contains the check" is satisfied for a second, un-validating
    /// overload by its sibling — and the absence half sees the correct scope
    /// name and is happy. `source-scan-guard-fidelity-2026-07-25.md` names this
    /// exact shape ("overloads must not collapse on name"); the fix is to
    /// require the check in each body that performs the mutation.
    func test_scanner_presenceFlagsAnUnvalidatingSecondOverloadOfTheChokepoint() {
        let source = """
        final class Fixture {
            func position() {
                applyValidated(frameOrigin: .zero)
                applyValidated(uncheckedOrigin: .zero)
            }
            private func applyValidated(frameOrigin origin: NSPoint) {
                if Geometry.originRejection(origin) != nil { return }
                setFrameOrigin(origin)
            }
            private func applyValidated(uncheckedOrigin origin: NSPoint) {
                setFrameOrigin(origin)
            }
        }
        """
        XCTAssertEqual(
            RaiseSiteScanner.unguardedCalls(inSource: source, rules: Self.fixtureRules), [],
            "the absence half cannot see this — both calls sit in a function named `applyValidated`"
        )
        XCTAssertEqual(
            RaiseSiteScanner.presenceFailures(inSource: source, rules: Self.fixtureRules).map(\.kind),
            [.chokepointNotValidating],
            "the un-validating overload must not be excused by its validating sibling"
        )
    }

    /// Needle-list rot, checklist item 1. `setFrameTopLeftPoint` is the direct
    /// substitute for `setFrameOrigin` in a method named `positionTopRight`,
    /// and raises on the same non-finite input. An un-needled mutator passes
    /// silently, so the list has to carry every geometry API that reaches the
    /// rule, not only the two the file happens to use today.
    func test_scanner_flagsAnAlternativeGeometryMutatorOutsideTheChokepoint() {
        let source = """
        final class Fixture {
            func positionTopRight() {
                applyValidated(frameOrigin: .zero)
                setFrameTopLeftPoint(NSPoint(x: 1, y: 2))
            }
            private func applyValidated(frameOrigin origin: NSPoint) {
                if HUDPanelGeometry.originRejection(origin) != nil { return }
                setFrameOrigin(origin)
            }
        }
        """
        let hits = RaiseSiteScanner.unguardedCalls(inSource: source, rules: RaiseSiteScanner.hudPanelRules)
        XCTAssertEqual(hits.map(\.mutator), ["setFrameTopLeftPoint ("], "Got: \(hits)")
        XCTAssertEqual(hits.first?.scope, "positionTopRight")
    }

    /// `setFrame` is a prefix of `setFrameOrigin`, and `removeTap` of
    /// `removeTapIfInstalled`. Either collapse breaks the scan in a different
    /// direction: the first makes a guarded `setFrameOrigin` look like an
    /// unguarded `setFrame`, the second makes every *call to the gate* look
    /// like an ungated `removeTap`.
    func test_scanner_mutatorNeedlesRespectIdentifierBoundaries() {
        let rules = [
            RaiseSiteScanner.Rule(
                mutator: "setFrame (", chokepoint: "applyValidated",
                mustValidate: [], mustOccur: false
            ),
            RaiseSiteScanner.Rule(
                mutator: "removeTap (", chokepoint: "removeTapIfInstalled",
                mustValidate: [], mustOccur: false
            )
        ]
        let source = """
        final class Fixture {
            func teardown() {
                setFrameOrigin(.zero)
                removeTapIfInstalled()
            }
        }
        """
        XCTAssertEqual(
            RaiseSiteScanner.unguardedCalls(inSource: source, rules: rules), [],
            "`setFrameOrigin(` is not `setFrame(`, and `removeTapIfInstalled(` is not `removeTap(`"
        )
    }

    /// Every one of these files documents the very calls being scanned for, so
    /// a scan that did not strip comments would report the doc-comments as
    /// violations and get itself relaxed.
    func test_scanner_ignoresMutatorsInCommentsAndStringLiterals() {
        let source = """
        final class Fixture {
            /// The only call to setFrameOrigin( in the project.
            func position() {
                log("setFrameOrigin( is not called here")
                // setFrameOrigin(.zero)
                applyValidated(frameOrigin: .zero)
            }
            private func applyValidated(frameOrigin origin: NSPoint) {
                if Geometry.originRejection(origin) != nil { return }
                setFrameOrigin(origin)
            }
            func log(_ s: String) {}
        }
        """
        XCTAssertEqual(RaiseSiteScanner.unguardedCalls(inSource: source, rules: Self.fixtureRules), [])
        XCTAssertEqual(RaiseSiteScanner.presenceFailures(inSource: source, rules: Self.fixtureRules), [])
    }

    // MARK: - The error HUD's repeat: coalesce rather than rebuild

    // Failures arrive in bursts — `settleRetry` surfaces one notice per chunk
    // — and every `showErrorHUD` used to `close()` the live NSPanel and stand
    // a fresh one up in the same place. A click landing in that window dies
    // with the panel it started on (SwiftUI needs mouse-down and mouse-up on
    // one live button), so the user sees an identical card still sitting
    // there and reports that the X does nothing. Measured on the reporter's
    // machine 2026-08-13: five rebuilds in 244 ms, no intervening hide, four
    // sharing one payload.

    private static func payload(
        title: String = "Gemini rejected the request",
        description: String = "Unexpected response (HTTP 0).",
        code: String? = "ERR_GEMINI · 0",
        retryLabel: String? = nil,
        secondaryLabel: String? = nil
    ) -> ErrorPayload {
        ErrorPayload(
            title: title,
            description: description,
            code: code,
            retryLabel: retryLabel,
            secondaryLabel: secondaryLabel
        )
    }

    func test_coalesce_repeatOfTheVisibleActionlessNotice_isTreatedAsARepeat() {
        // The reporter's exact card: a session-failure notice carrying
        // `GeminiError.http(status: 0, …)` and no action button.
        XCTAssertTrue(
            HUDController.shouldCoalesceError(showing: Self.payload(), incoming: Self.payload()),
            "The burst case. Rebuilding here is what swallows the click."
        )
    }

    func test_coalesce_refusesWhenNoErrorHUDIsUp() {
        XCTAssertFalse(
            HUDController.shouldCoalesceError(showing: nil, incoming: Self.payload()),
            "With nothing on screen there is nothing to coalesce into — the first show must build a panel."
        )
    }

    func test_coalesce_refusesADifferentNotice() {
        // The 503 that arrived beside the HTTP-0s in the same burst. Dropping
        // it would leave the user reading a stale cause, which is the failure
        // mode `NoType/UI/CLAUDE.md` protects when it insists the five
        // recoverable causes stay five distinct sentences.
        let differsInDescription = Self.payload(description: "Gemini is having trouble (HTTP 503).")
        XCTAssertFalse(
            HUDController.shouldCoalesceError(showing: Self.payload(), incoming: differsInDescription)
        )
        XCTAssertFalse(
            HUDController.shouldCoalesceError(
                showing: Self.payload(), incoming: Self.payload(title: "No internet connection")
            )
        )
        XCTAssertFalse(
            HUDController.shouldCoalesceError(
                showing: Self.payload(), incoming: Self.payload(code: "ERR_GEMINI · 503")
            )
        )
    }

    /// The term that is *not* about equality. Handlers are closures and are
    /// not comparable, so an equal payload does not imply an equal panel —
    /// coalescing an actionable notice would leave a button running the
    /// **first** call's handler while the caller believes it installed the
    /// second's. Swept on both label limbs and on both together.
    func test_coalesce_refusesAnActionableNotice_evenWhenThePayloadIsEqual() {
        for (retry, secondary) in [
            ("Retry", String?.none), (nil, "Open Settings"), ("Retry", "Open Settings")
        ] as [(String?, String?)] {
            let actionable = Self.payload(retryLabel: retry, secondaryLabel: secondary)
            XCTAssertFalse(
                HUDController.shouldCoalesceError(showing: actionable, incoming: actionable),
                "retryLabel=\(retry ?? "nil") secondaryLabel=\(secondary ?? "nil"): an equal payload is not an equal panel once a button renders."
            )
        }
    }

    func test_coalesce_isReachedOnlyThroughEqualityOfTheWholePayload() {
        // Guards against the predicate decaying into a title/code comparison:
        // two notices agreeing on everything the user reads but differing in
        // severity or glyph are still different panels.
        var tinted = Self.payload()
        tinted.severity = .warning
        XCTAssertFalse(HUDController.shouldCoalesceError(showing: Self.payload(), incoming: tinted))

        var reglyphed = Self.payload()
        reglyphed.iconSymbol = "wifi.slash"
        XCTAssertFalse(HUDController.shouldCoalesceError(showing: Self.payload(), incoming: reglyphed))
    }

    // MARK: - Which process is painting

    // `HUDPanelGeometry.column` deconflicts panels within one process and can
    // have no wider scope. Two *processes* each holding a correct column still
    // superimpose their slot-0 panels exactly, because every HUDPanel is
    // `.statusBar` level and anchored to the same corner of the same screen —
    // the identical failure mode `Slot` removed, one level up. A test host is
    // a full NoType.app that builds `HUDController` directly, so a run of
    // `AppStateRetryTests` paints real panels over the developer's desktop.

    func test_testHost_isRecognisedByEitherSignalAlone() {
        XCTAssertTrue(
            HUDHostEnvironment.isTestHost(environment: [:], xctestLinked: true),
            "XCTest linked into the process is sufficient — the env key is absent when a bundle is injected."
        )
        XCTAssertTrue(
            HUDHostEnvironment.isTestHost(
                environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
                xctestLinked: false
            ),
            "The configured host is sufficient — the class is absent before the framework loads."
        )
    }

    func test_shippingApp_isNotMistakenForATestHost() {
        // The direction that must never be wrong: a false positive silences
        // every HUD in the notarized build. Neither signal exists there.
        XCTAssertFalse(HUDHostEnvironment.isTestHost(environment: [:], xctestLinked: false))
        XCTAssertFalse(
            HUDHostEnvironment.isTestHost(
                environment: ["HOME": "/Users/x", "XCTestConfigurationFilePathXX": "decoy"],
                xctestLinked: false
            ),
            "The key is matched exactly, not by prefix."
        )
    }

    func test_thisSuiteIsItselfRunningInARecognisedTestHost() {
        // The live complement to the pure table above. If this fails, the
        // predicate is looking for a signal that does not exist in practice
        // and the suppression is dead code — the silent-pass shape that
        // `source-scan-guard-fidelity-2026-07-25.md` warns about.
        XCTAssertTrue(HUDHostEnvironment.isTestHostProcess)
    }

    // MARK: - Presence guards for the two fixes above

    // Both fixes are one-line consultations inside a body no unit test can
    // drive (`showErrorHUD` builds an NSPanel; `show()` calls AppKit). Per
    // `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`
    // these assert *presence* at the site, not merely absence elsewhere, and
    // each pins the destination too — a gate whose guarded action was deleted
    // is as broken as a missing gate, and an absence-only scan is green on
    // both.

    func test_presenceGuard_showErrorHUD_stillAsksWhetherThisIsARepeat() throws {
        let source = try Self.appSource(RaiseSiteScanner.hudControllerPath)
        let code = LaunchPathScanner.strippingCommentsAndStrings(source)
        let body = try XCTUnwrap(
            LaunchPathScanner.functionBodies(in: code).first(where: { $0.name == "showErrorHUD" })?.body,
            "HUDController.showErrorHUD is no longer declared — the scan lost its subject."
        )
        XCTAssertTrue(
            LaunchPathScanner.line(body, contains: "shouldCoalesceError ("),
            """
            HUDController.showErrorHUD no longer consults `shouldCoalesceError`. Every call \
            then closes the live NSPanel and stands up a replacement, and a click landing in \
            that window is destroyed with the button it started on — which the user reports, \
            correctly, as an X that does nothing.
            """
        )
        // The destination: the predicate is only worth consulting if the
        // rebuild it skips is still what the other branch does.
        XCTAssertTrue(
            LaunchPathScanner.line(body, contains: "errorPanel?.close ("),
            "showErrorHUD no longer rebuilds on the non-repeat path — the coalesce guards nothing."
        )
    }

    func test_presenceGuard_hudPanelShow_stillWithholdsPaintingFromATestHost() throws {
        let source = try Self.appSource(RaiseSiteScanner.hudPanelPath)
        let code = LaunchPathScanner.strippingCommentsAndStrings(source)
        let body = try XCTUnwrap(
            LaunchPathScanner.functionBodies(in: code).first(where: { $0.name == "show" })?.body,
            "HUDPanel.show is no longer declared — the scan lost its subject."
        )
        XCTAssertTrue(
            LaunchPathScanner.line(body, contains: "HUDHostEnvironment.isTestHostProcess"),
            """
            HUDPanel.show no longer gates on HUDHostEnvironment. A test host is a full \
            NoType.app process, so every NoTypeTests run that builds a HUDController paints \
            real .statusBar panels over the user's desktop, at the same top-right coordinates \
            as the installed app's — a cross-process superposition HUDPanelGeometry.column \
            cannot reach.
            """
        )
        XCTAssertTrue(
            LaunchPathScanner.line(body, contains: "orderFrontRegardless ("),
            "HUDPanel.show no longer orders the panel front — the shipping app shows no HUDs at all."
        )
    }

    // MARK: - Fixture helpers

    private static let fixtureRules = [
        RaiseSiteScanner.Rule(
            mutator: "setFrameOrigin (",
            chokepoint: "applyValidated",
            mustValidate: ["Geometry.originRejection ("]
        )
    ]

    private static let guardedFixture = """
    final class Fixture {
        func position() {
            applyValidated(frameOrigin: .zero)
        }
        private func applyValidated(frameOrigin origin: NSPoint) {
            if Geometry.originRejection(origin) != nil { return }
            setFrameOrigin(origin)
        }
    }
    """

    private static func appSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NoTypeTests/
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Raise-site scanner

/// Pure source-text scanner behind the raise-site guard above.
///
/// **What it pins.** `NoType/UI/CLAUDE.md`'s rule that a raise-prone AppKit /
/// AVFoundation / CoreAudio call inside a main-actor Swift-concurrency job is
/// made only after its preconditions have been validated at the call site.
///
/// **What it deliberately does NOT pin, and why that is not a gap to close.**
/// The rule as a whole is not mechanically checkable: there is no closed set of
/// AppKit APIs that can raise, so a general needle list would be a guess — and
/// per `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`
/// every way a source scan fails produces a **passing** test. A broad scan
/// would not cry wolf; it would sit green over an unbounded set of raise sites
/// it never learned to look for, while reviewers stopped checking by hand
/// because "a test pins this" — strictly worse than no scan. So the scan covers
/// only the sites where a *named chokepoint* makes the set genuinely closed:
///
/// | File | Mutator | Chokepoint |
/// |---|---|---|
/// | `NoType/UI/HUDPanel.swift` | `setContentSize` / `setFrameOrigin` / `setFrame` / `setFrameTopLeftPoint` / `setFrameSize` | `applyValidated` |
/// | `NoType/Onboarding/MicProbe.swift` | `installTap` | `installTapAndStart` |
/// | `NoType/Onboarding/MicProbe.swift` | `removeTap` | `removeTapIfInstalled` |
///
/// `FixedSizeWindowConfigurator.lock` is **not** here on purpose: its
/// precondition ("AppKit is not currently reconfiguring this window") has no
/// API, so there is nothing for a chokepoint to validate — see that method's
/// doc-comment and the audit table in `NoType/UI/CLAUDE.md`.
///
/// **Known limits, measured by trying to defeat this scanner rather than
/// guessed.** Recorded because a source scan's failure mode is a *passing*
/// test, so an unrecorded limit is indistinguishable from coverage:
///
/// - **The mutator list is an enumeration, not a closed set.** Every geometry
///   API on the list is caught anywhere in the file; one that is *not* on it
///   passes silently. The `frame` property setter (`self.frame = …`) is the
///   known un-needled case: `frame =` would also match every `let frame = …`,
///   and the noise is not worth it for a spelling nothing in the file uses.
/// - **A new mutator kind inside an existing wrapper passes** — see the
///   comment on ``hudPanelRules``.
/// - **`mustValidate` is a substring test, not a dataflow one.** A body that
///   calls the predicate and discards the result (`_ = sizeRejection(size)`)
///   satisfies it. It pins that the check is still *there*, which is the
///   deletion this guard exists to catch; it cannot pin that it still gates.
/// - **Not a limit, checked:** a call whose callee and argument list sit on
///   different lines is not matched — but Swift does not parse that as a call
///   at all (`error: function is unused`), so it is unreachable.
///
/// **A plain absence needle cannot express this rule**, which is the whole
/// reason this is positional rather than a `contains` check: a *guarded* call
/// still contains the literal `setContentSize(`. The predicate is "every
/// occurrence's innermost enclosing function is the chokepoint".
///
/// Mirrors `LaunchPathScanner` rather than `DSComponentsHoverTests` — a pure
/// function over injected source text (so the fixtures drive it without
/// touching disk) that reuses that scanner's needle matcher, comment stripper
/// and brace matcher instead of carrying second copies of all three.
enum RaiseSiteScanner {

    static let hudPanelPath = "NoType/UI/HUDPanel.swift"
    static let micProbePath = "NoType/Onboarding/MicProbe.swift"
    static let hudControllerPath = "NoType/UI/HUDController.swift"

    /// Reported as the scope of a hit that sits inside no `func` / `init` body
    /// — a `deinit`, or type scope.
    static let noEnclosingScope = "<no enclosing function>"

    /// "This mutator may be written only inside this function, and that
    /// function must still validate."
    struct Rule {
        /// Needle for the raise-prone call. **Spell it with the trailing
        /// paren.** `setFrame` without one is satisfied by `setFrameOrigin`,
        /// and `removeTap` without one is satisfied by every call to
        /// `removeTapIfInstalled()` — the gate itself. A single space matches
        /// any run of whitespace (`LaunchPathScanner.matchIndex`).
        let mutator: String
        /// The one function the mutator may appear inside.
        let chokepoint: String
        /// Substrings some body named `chokepoint` must contain — the
        /// validation that makes it a gate rather than a passthrough. Without
        /// this, deleting the check from inside the wrapper leaves every
        /// assertion green while the raise is fully back.
        let mustValidate: [String]
        /// `false` for a mutator that is legitimately absent today and is
        /// listed only so that *adding* one outside the chokepoint fails.
        let mustOccur: Bool

        init(mutator: String, chokepoint: String, mustValidate: [String], mustOccur: Bool = true) {
            self.mutator = mutator
            self.chokepoint = chokepoint
            self.mustValidate = mustValidate
            self.mustOccur = mustOccur
        }
    }

    struct Finding: Equatable, CustomStringConvertible {
        enum Kind: String, Equatable {
            /// The mutator is written outside its chokepoint.
            case unguarded
            /// The mutator no longer appears at all — the guard is vacuous.
            case mutatorVanished
            /// No function by the chokepoint's name is declared.
            case chokepointMissing
            /// The chokepoint is declared but nothing calls it.
            case chokepointNeverCalled
            /// The chokepoint is declared and called, but has lost its check.
            case chokepointNotValidating
        }

        let kind: Kind
        let mutator: String
        /// The enclosing function of the offending call, or the chokepoint
        /// name for a presence failure.
        let scope: String
        let detail: String

        var description: String { "\(kind.rawValue) [\(mutator) / \(scope)]: \(detail)" }
    }

    // MARK: Rule sets

    static let hudPanelRules: [Rule] = [
        Rule(
            mutator: "setContentSize (",
            chokepoint: "applyValidated",
            mustValidate: ["HUDPanelGeometry.sizeRejection ("]
        ),
        Rule(
            mutator: "setFrameOrigin (",
            chokepoint: "applyValidated",
            mustValidate: ["HUDPanelGeometry.originRejection ("]
        ),
        // None of the three below is present today. They are listed because
        // fidelity checklist item 1 — "the needle list rots toward the
        // original example" — is the failure mode here: each is an AppKit
        // geometry mutator a maintainer could reach for *instead of* the two
        // above, and an un-needled one passes silently. `setFrameTopLeftPoint`
        // in particular is the direct substitute for `setFrameOrigin` in a
        // method literally named `positionTopRight`.
        //
        // Note the residual limit: adding one *inside* an existing wrapper
        // still passes, because `applyValidated(frameOrigin:)` validates a
        // point, not a rect or a size. A new mutator kind needs a new
        // `HUDPanelGeometry` predicate as well as a rule beside these.
        Rule(mutator: "setFrame (", chokepoint: "applyValidated", mustValidate: [], mustOccur: false),
        Rule(mutator: "setFrameTopLeftPoint (", chokepoint: "applyValidated", mustValidate: [], mustOccur: false),
        Rule(mutator: "setFrameSize (", chokepoint: "applyValidated", mustValidate: [], mustOccur: false)
    ]

    /// Not a *raise* rule — the same chokepoint shape applied to a placement
    /// defect. `positionTopRight` raises nothing; what it does when written
    /// outside `relayout()` is hand a panel the raw `topInset` again, which is
    /// how four HUD kinds came to share one point at one window level. The
    /// scanner does not care which kind of invariant a chokepoint enforces,
    /// only that one function owns the call and still consults its helper.
    static let hudControllerRules: [Rule] = [
        Rule(
            mutator: "positionTopRight (",
            chokepoint: "relayout",
            mustValidate: ["HUDPanelGeometry.column ("]
        )
    ]

    static let micProbeRules: [Rule] = [
        Rule(
            mutator: "installTap (",
            chokepoint: "installTapAndStart",
            mustValidate: [
                "MicProbeFormatGate.positivityRejection (",
                "MicProbeFormatGate.rejection ("
            ]
        ),
        Rule(
            mutator: "removeTap (",
            chokepoint: "removeTapIfInstalled",
            // R10: the gate is read *and* cleared under `lock`, because
            // `deinit` runs nonisolated on whatever thread drops the last
            // reference. A `removeTapIfInstalled` that stopped taking the
            // lock would still be a chokepoint and still be called.
            mustValidate: ["tapInstalled", "lock.lock ("]
        )
    ]

    // MARK: The absence half

    /// Every mutator occurrence whose innermost enclosing function is not the
    /// rule's chokepoint.
    static func unguardedCalls(inSource source: String, rules: [Rule]) -> [Finding] {
        let code = LaunchPathScanner.strippingCommentsAndStrings(source)
        let functions = LaunchPathScanner.functionBodies(in: code)

        return rules.flatMap { rule -> [Finding] in
            hits(of: rule.mutator, in: code).compactMap { hit in
                let scope = innermostFunction(containing: hit.index, in: functions)?.name ?? noEnclosingScope
                guard scope != rule.chokepoint else { return nil }
                return Finding(
                    kind: .unguarded,
                    mutator: rule.mutator.trimmingCharacters(in: .whitespaces),
                    scope: scope,
                    detail: "`\(hit.line)` must be written inside `\(rule.chokepoint)`, not in \(scope)"
                )
            }
        }
    }

    // MARK: The presence half

    /// The complement required by
    /// `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`:
    /// ``unguardedCalls(inSource:rules:)`` asserts only that nothing escaped,
    /// which is trivially true of a file where the mutator, the chokepoint, or
    /// the check inside it has been deleted.
    static func presenceFailures(inSource source: String, rules: [Rule]) -> [Finding] {
        let code = LaunchPathScanner.strippingCommentsAndStrings(source)
        let functions = LaunchPathScanner.functionBodies(in: code)
        var findings: [Finding] = []

        for rule in rules {
            let label = rule.mutator.trimmingCharacters(in: .whitespaces)

            if rule.mustOccur, hits(of: rule.mutator, in: code).isEmpty {
                findings.append(Finding(
                    kind: .mutatorVanished,
                    mutator: label,
                    scope: rule.chokepoint,
                    detail: "no `\(label)` call remains — the guard is vacuous, not satisfied"
                ))
            }

            let bodies = functions.filter { $0.name == rule.chokepoint }
            guard !bodies.isEmpty else {
                findings.append(Finding(
                    kind: .chokepointMissing,
                    mutator: label,
                    scope: rule.chokepoint,
                    detail: "no `\(rule.chokepoint)` is declared, so nothing validates `\(label)`"
                ))
                continue
            }

            let calledFromElsewhere = hits(of: "\(rule.chokepoint) (", in: code).contains { hit in
                guard let enclosing = innermostFunction(containing: hit.index, in: functions) else {
                    // The declaration itself sits at type scope, not inside a
                    // body — never count it as a call.
                    return false
                }
                return enclosing.name != rule.chokepoint
            }
            if !calledFromElsewhere {
                findings.append(Finding(
                    kind: .chokepointNeverCalled,
                    mutator: label,
                    scope: rule.chokepoint,
                    detail: "`\(rule.chokepoint)` is declared but nothing calls it"
                ))
            }

            // Checked per *body*, not "some body named the chokepoint has it".
            // `applyValidated` is already overloaded (contentSize / frameOrigin),
            // so an any-body test is satisfied for a second, un-validating
            // overload by its sibling — the overload-collapse failure named in
            // `source-scan-guard-fidelity-2026-07-25.md` ("overloads must not
            // collapse on name"). Only the bodies that actually perform the
            // mutation are required to validate, which is also what keeps the
            // frameOrigin wrapper from being asked for a size check.
            let guardingBodies = bodies.filter { LaunchPathScanner.line($0.body, contains: rule.mutator) }
            for guarding in guardingBodies {
                for needle in rule.mustValidate
                where !LaunchPathScanner.line(guarding.body, contains: needle) {
                    findings.append(Finding(
                        kind: .chokepointNotValidating,
                        mutator: label,
                        scope: rule.chokepoint,
                        detail: "a `\(rule.chokepoint)` body performs `\(label)` without `\(needle.trimmingCharacters(in: .whitespaces))` — that wrapper is a passthrough"
                    ))
                }
            }
        }
        return findings
    }

    // MARK: Primitives

    private struct Hit {
        let index: Int
        let line: String
    }

    /// Every match of `needle` in `code`, with its character offset into
    /// `code` — the offset is what lets the enclosing function be resolved,
    /// and it is why `LaunchPathScanner.matchIndex` exists rather than only
    /// the `Bool` form.
    private static func hits(of needle: String, in code: String) -> [Hit] {
        var result: [Hit] = []
        var offset = 0
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let chars = Array(line)
            var from = 0
            while from <= chars.count,
                  let column = LaunchPathScanner.matchIndex(String(chars[from...]), of: needle) {
                result.append(
                    Hit(
                        index: offset + from + column,
                        line: line.trimmingCharacters(in: .whitespaces)
                    )
                )
                from += column + 1
            }
            offset += chars.count + 1
        }
        return result
    }

    /// The narrowest function body containing `index`. Narrowest rather than
    /// first, so a nested declaration wins over the function around it.
    private static func innermostFunction(
        containing index: Int,
        in functions: [LaunchPathScanner.Function]
    ) -> LaunchPathScanner.Function? {
        functions
            .filter { $0.range.contains(index) }
            .min { $0.range.count < $1.range.count }
    }
}
