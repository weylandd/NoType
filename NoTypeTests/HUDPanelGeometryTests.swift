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
/// | `NoType/UI/HUDPanel.swift` | `setContentSize` / `setFrameOrigin` / `setFrame` | `applyValidated` |
/// | `NoType/Onboarding/MicProbe.swift` | `installTap` | `installTapAndStart` |
/// | `NoType/Onboarding/MicProbe.swift` | `removeTap` | `removeTapIfInstalled` |
///
/// `FixedSizeWindowConfigurator.lock` is **not** here on purpose: its
/// precondition ("AppKit is not currently reconfiguring this window") has no
/// API, so there is nothing for a chokepoint to validate — see that method's
/// doc-comment and the audit table in `NoType/UI/CLAUDE.md`.
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
        // Not present today. Listed so that adding a whole-frame mutation
        // outside the wrapper fails rather than shipping unvalidated — and
        // note the limit: adding one *inside* `applyValidated(frameOrigin:)`
        // would pass, because that wrapper validates a point, not a rect. A
        // new mutator kind needs a new `HUDPanelGeometry` predicate and a
        // rule beside this one.
        Rule(mutator: "setFrame (", chokepoint: "applyValidated", mustValidate: [], mustOccur: false)
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

            for needle in rule.mustValidate
            where !bodies.contains(where: { LaunchPathScanner.line($0.body, contains: needle) }) {
                findings.append(Finding(
                    kind: .chokepointNotValidating,
                    mutator: label,
                    scope: rule.chokepoint,
                    detail: "no `\(rule.chokepoint)` body contains `\(needle.trimmingCharacters(in: .whitespaces))` — the wrapper is now a passthrough"
                ))
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
