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
}
