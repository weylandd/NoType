import XCTest
import AppKit
@testable import NoType

/// Pins `FixedSizeWindowConfigurator` — the AppKit belt-and-braces that
/// locks the main app window to a fixed size by stripping `.resizable`
/// from the style mask and pinning `min/maxSize` (see `MainWindow.swift`).
///
/// Two test surfaces:
///
/// 1. **Pure-function math** (`adjustedFrame(for:target:)`). The PR's
///    stated correctness claim is that the resize-to-target call
///    preserves the visual top-left anchor in AppKit's bottom-left
///    coordinate system. Testing the math against a real `NSWindow.setFrame`
///    is fragile because AppKit's `constrainFrameRect(_:to:)` clamps the
///    result to the active screen, which varies across CI runners.
///    Pinning the pure function isolates the invariant from screen state.
///
/// 2. **NSWindow application** (`lock(window:to:)`). The `styleMask`
///    strip and `min/maxSize` pin are screen-independent and can be
///    asserted directly against a synthetic `NSWindow` created in the
///    test.
///
/// 3. **The already-locked predicate** (`lockReason(for:target:)` plus its
///    `WindowState` reader). Pure, so it is pinned directly; then driven
///    through `lock(window:to:)` against a mutation-counting `NSWindow`
///    subclass, because "the repeat call mutates nothing" is otherwise
///    unobservable — re-stripping an absent bit and re-assigning identical
///    sizes leaves no trace, so an assertion on final state would stay
///    green with the guard deleted.
///
///    Framing that must not drift: this predicate is **containment**. It
///    narrows how often a raise-prone `styleMask` mutation runs; it does
///    not remove the raise. `test_lock_firstCallOnFreshWindow_stillMutates`
///    pins that deliberately — the one call most likely to raise is the one
///    the predicate never skips.
@MainActor
final class FixedSizeWindowConfiguratorTests: XCTestCase {

    private let target = NSSize(width: 1080, height: 760)

    // MARK: - Pure-function math

    func test_adjustedFrame_atTargetSize_returnsIdenticalRect() {
        let input = NSRect(x: 500, y: 400, width: 1080, height: 760)
        let output = FixedSizeWindowConfigurator.adjustedFrame(for: input, target: target)
        XCTAssertEqual(output, input)
    }

    func test_adjustedFrame_taller_preservesTopEdge() {
        let input = NSRect(x: 200, y: 100, width: 800, height: 900)
        let inputTopY = input.origin.y + input.size.height   // 1000
        let output = FixedSizeWindowConfigurator.adjustedFrame(for: input, target: target)
        XCTAssertEqual(output.size, target, "Size must match target after adjust.")
        XCTAssertEqual(
            output.origin.y + output.size.height,
            inputTopY,
            "Top-left anchor (origin.y + height) must be preserved across a shrink."
        )
        XCTAssertEqual(output.origin.x, input.origin.x, "Width changes do not shift origin.x.")
    }

    func test_adjustedFrame_shorter_preservesTopEdge() {
        let input = NSRect(x: 200, y: 50, width: 800, height: 400)
        let inputTopY = input.origin.y + input.size.height   // 450
        let output = FixedSizeWindowConfigurator.adjustedFrame(for: input, target: target)
        XCTAssertEqual(output.size, target)
        XCTAssertEqual(
            output.origin.y + output.size.height,
            inputTopY,
            "Top-left anchor must be preserved across a grow."
        )
    }

    func test_adjustedFrame_widthOnlyMismatch_movesNoVertical() {
        let input = NSRect(x: 0, y: 0, width: 800, height: 760)
        let output = FixedSizeWindowConfigurator.adjustedFrame(for: input, target: target)
        XCTAssertEqual(output.size, target)
        XCTAssertEqual(output.origin.y, input.origin.y, "Height matches target — dy is zero, origin.y must not move.")
    }

    // MARK: - NSWindow application (screen-independent state)

    private func makeResizableWindow(frame: NSRect) -> NSWindow {
        NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    func test_lock_stripsResizableStyleBit() {
        let window = makeResizableWindow(frame: NSRect(x: 100, y: 100, width: 1080, height: 760))
        XCTAssertTrue(window.styleMask.contains(.resizable), "Precondition: window starts resizable.")
        FixedSizeWindowConfigurator.lock(window: window, to: target)
        XCTAssertFalse(window.styleMask.contains(.resizable), "lock() must strip .resizable.")
    }

    func test_lock_pinsMinSizeAndMaxSizeToTarget() {
        let window = makeResizableWindow(frame: NSRect(x: 0, y: 0, width: 1080, height: 760))
        FixedSizeWindowConfigurator.lock(window: window, to: target)
        XCTAssertEqual(window.minSize, target)
        XCTAssertEqual(window.maxSize, target)
    }

    func test_lock_isIdempotent() {
        let window = makeResizableWindow(frame: NSRect(x: 0, y: 0, width: 1080, height: 760))
        FixedSizeWindowConfigurator.lock(window: window, to: target)
        let firstMask = window.styleMask
        FixedSizeWindowConfigurator.lock(window: window, to: target)
        XCTAssertEqual(window.styleMask, firstMask, "Second lock() call must not change the style mask.")
        XCTAssertEqual(window.minSize, target)
        XCTAssertEqual(window.maxSize, target)
    }

    // MARK: - Already-locked predicate (pure)

    func test_lockReason_stateMatchingTarget_needsNoLock() {
        let state = FixedSizeWindowConfigurator.WindowState(
            isResizable: false, minSize: target, maxSize: target, frameSize: target
        )
        XCTAssertNil(
            FixedSizeWindowConfigurator.lockReason(for: state, target: target),
            "A window already matching the target on all four facts needs no mutation."
        )
    }

    func test_lockReason_resizableBitStillPresent_needsLock() {
        // The fresh-window and post-reconfiguration case. Everything else
        // already matches, so this isolates the style-mask limb — and it is
        // the case the predicate must NOT skip.
        let state = FixedSizeWindowConfigurator.WindowState(
            isResizable: true, minSize: target, maxSize: target, frameSize: target
        )
        XCTAssertEqual(FixedSizeWindowConfigurator.lockReason(for: state, target: target), .resizable)
    }

    func test_lockReason_minSizeDiffers_needsLock() {
        let state = FixedSizeWindowConfigurator.WindowState(
            isResizable: false,
            minSize: NSSize(width: 400, height: 300),
            maxSize: target,
            frameSize: target
        )
        XCTAssertEqual(FixedSizeWindowConfigurator.lockReason(for: state, target: target), .minSizeMismatch)
    }

    func test_lockReason_maxSizeDiffers_needsLock() {
        // Its own limb rather than folded into minSize: AppKit defaults
        // maxSize to a huge value, so a window can be pinned on one and not
        // the other, and the diagnostic should say which.
        let state = FixedSizeWindowConfigurator.WindowState(
            isResizable: false,
            minSize: target,
            maxSize: NSSize(width: 10_000, height: 10_000),
            frameSize: target
        )
        XCTAssertEqual(FixedSizeWindowConfigurator.lockReason(for: state, target: target), .maxSizeMismatch)
    }

    func test_lockReason_frameSizeDiffers_needsLock() {
        let state = FixedSizeWindowConfigurator.WindowState(
            isResizable: false,
            minSize: target,
            maxSize: target,
            frameSize: NSSize(width: 1080, height: 788)
        )
        XCTAssertEqual(FixedSizeWindowConfigurator.lockReason(for: state, target: target), .frameSizeMismatch)
    }

    func test_lockReason_everythingDiffers_reportsResizableFirst() {
        // Deterministic ordering so a caller that logs the reason gets a
        // stable line rather than whichever limb the compiler evaluated.
        let state = FixedSizeWindowConfigurator.WindowState(
            isResizable: true,
            minSize: NSSize(width: 1, height: 1),
            maxSize: NSSize(width: 2, height: 2),
            frameSize: NSSize(width: 3, height: 3)
        )
        XCTAssertEqual(FixedSizeWindowConfigurator.lockReason(for: state, target: target), .resizable)
    }

    func test_everyLockReasonCase_isProducedBySomeState() {
        // Guards the classification against rot: a case added with no state
        // that produces it fails here instead of shipping dead
        // classification. Same discipline as
        // `HUDPanelGeometryTests.test_everyRejectionCase_isProducedBySomeInput`.
        let producers: [FixedSizeWindowConfigurator.LockReason: FixedSizeWindowConfigurator.WindowState] = [
            .resizable: .init(
                isResizable: true, minSize: target, maxSize: target, frameSize: target
            ),
            .minSizeMismatch: .init(
                isResizable: false, minSize: .zero, maxSize: target, frameSize: target
            ),
            .maxSizeMismatch: .init(
                isResizable: false, minSize: target, maxSize: .zero, frameSize: target
            ),
            .frameSizeMismatch: .init(
                isResizable: false, minSize: target, maxSize: target, frameSize: .zero
            )
        ]

        for expected in FixedSizeWindowConfigurator.LockReason.allCases {
            guard let state = producers[expected] else {
                XCTFail("no state produces \(expected) — add one or drop the case")
                continue
            }
            XCTAssertEqual(
                FixedSizeWindowConfigurator.lockReason(for: state, target: target),
                expected,
                "\(expected) is not produced by its documented state"
            )
        }
    }

    // MARK: - WindowState reads the facts it claims to read

    func test_windowState_readsEachFactFromItsOwnWindowProperty() {
        // The only impure part of the predicate. Three of the four facts are
        // pinned against values this test set independently of the window,
        // so a swapped field (frameSize <- minSize, min <- max) fails here
        // rather than silently shifting which limb fires.
        let window = makeResizableWindow(frame: NSRect(x: 0, y: 0, width: 1080, height: 760))
        window.minSize = NSSize(width: 400, height: 300)
        window.maxSize = NSSize(width: 2000, height: 1500)

        let state = FixedSizeWindowConfigurator.WindowState(window)

        XCTAssertTrue(state.isResizable, "Window was created with .resizable.")
        XCTAssertEqual(state.minSize, NSSize(width: 400, height: 300))
        XCTAssertEqual(state.maxSize, NSSize(width: 2000, height: 1500))
        // Frame width is titlebar-independent, so it can be pinned to a
        // literal; height cannot, so it is compared to the window itself —
        // which still catches a field swap, since neither min nor max
        // matches the frame.
        XCTAssertEqual(state.frameSize.width, 1080)
        XCTAssertEqual(state.frameSize, window.frame.size)
    }

    func test_windowState_nonResizableWindow_readsFalse() {
        // Both polarities of the style-mask read; without this a hardcoded
        // `true` would pass the test above.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        XCTAssertFalse(FixedSizeWindowConfigurator.WindowState(window).isResizable)
    }

    // MARK: - Containment: the guard skips repeats, never the first call

    func test_lock_firstCallOnFreshWindow_stillMutates() {
        // THE framing test. This step narrows exposure to the raise-prone
        // `styleMask` mutation; it does not remove it. The first lock — the
        // one arriving from `viewDidMoveToWindow` while AppKit is attaching
        // the window, i.e. the mid-configure moment a raise would need — is
        // deliberately NOT skipped. If this ever goes green with zero
        // mutations, the predicate has started skipping the dangerous call
        // and the containment claim in `lock`'s doc-comment is false.
        let window = MutationCountingWindow.makeResizable()
        let before = window.mutationCount

        FixedSizeWindowConfigurator.lock(window: window, to: target)

        XCTAssertGreaterThan(
            window.mutationCount, before,
            "A fresh resizable window must still be mutated — the guard is containment, not prevention."
        )
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    func test_lock_repeatedCallsOnLockedWindow_mutateNothing() {
        // The acceptance bar for this step: repeated `updateNSView` calls
        // against an already-locked window mutate nothing. Asserted by
        // counting AppKit writes, not by comparing end state — identical
        // re-assignments leave no observable trace, so a state comparison
        // would stay green with the guard deleted from `lock`.
        let window = MutationCountingWindow.makeResizable()
        FixedSizeWindowConfigurator.lock(window: window, to: target)

        XCTAssertEqual(
            window.frame.size, target,
            "Precondition: the first lock settled the window at the target size."
        )
        let settled = window.mutationCount

        for _ in 0..<3 {
            FixedSizeWindowConfigurator.lock(window: window, to: target)
        }

        XCTAssertEqual(
            window.mutationCount, settled,
            "Repeat lock() calls on an already-locked window must touch no AppKit property."
        )
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.minSize, target)
        XCTAssertEqual(window.maxSize, target)
    }
}

/// `NSWindow` that counts the AppKit mutations `lock(window:to:)` performs.
///
/// Needed because the no-op this step delivers is invisible in end state:
/// removing an absent style bit and re-assigning identical `min/maxSize`
/// change nothing observable, so only a write count can tell "the guard
/// skipped the call" from "the call ran and happened to be idempotent".
///
/// `constrainFrameRect(_:to:)` is overridden to the identity so `setFrame`
/// lands exactly where `lock` asked. The parent test file's doc-comment
/// notes AppKit otherwise clamps to the active screen, which varies per
/// machine — without this override the post-lock frame could stay off
/// target on a small display and the repeat call would legitimately mutate
/// again, making the test machine-dependent.
@MainActor
private final class MutationCountingWindow: NSWindow {
    private var styleMaskWrites = 0
    private var minSizeWrites = 0
    private var maxSizeWrites = 0
    private var setFrameCalls = 0

    /// Total AppKit writes seen so far. Tests diff this across a call
    /// rather than reading it absolutely, so any writes AppKit performs on
    /// its own during window setup are excluded.
    var mutationCount: Int { styleMaskWrites + minSizeWrites + maxSizeWrites + setFrameCalls }

    static func makeResizable() -> MutationCountingWindow {
        MutationCountingWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    override var styleMask: NSWindow.StyleMask {
        get { super.styleMask }
        set { styleMaskWrites += 1; super.styleMask = newValue }
    }

    override var minSize: NSSize {
        get { super.minSize }
        set { minSizeWrites += 1; super.minSize = newValue }
    }

    override var maxSize: NSSize {
        get { super.maxSize }
        set { maxSizeWrites += 1; super.maxSize = newValue }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        setFrameCalls += 1
        super.setFrame(frameRect, display: flag)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
