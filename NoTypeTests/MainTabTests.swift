import XCTest
@testable import NoType

/// Pins the `MainTab` enum surface used by the main window's
/// sidebar nav + the cross-window `pendingTabSelection` flag
/// consumed by `MainWindowView`. Sidebar layout itself is a
/// SwiftUI view and not unit-testable without snapshot
/// infrastructure; this file covers what is testable:
///
///   1. Enum membership + ordering (4th sidebar item is Settings).
///   2. Display labels + icon names per case.
///   3. The pure consume-pending-selection function for cross-window
///      navigation, including the load-bearing clear-first-apply-second
///      order from plan §270 (prevents stale-flag hijack).
final class MainTabTests: XCTestCase {

    // MARK: - Enum membership + ordering

    func test_allCases_includesSettings_asFourthAndLast() {
        let cases = MainTab.allCases
        XCTAssertEqual(cases.count, 4, "Sidebar nav expects exactly 4 tabs in v1.")
        XCTAssertEqual(cases[3], .settings, "Settings must be the 4th and last sidebar entry.")
        // Document the full sidebar order so refactors that reorder are
        // caught explicitly (UI muscle-memory + popover gear flow expect
        // Settings at the bottom of the nav, not interleaved).
        XCTAssertEqual(cases, [.home, .instructions, .dictionary, .settings])
    }

    // MARK: - Labels + icons

    func test_label_settings_isSentenceCaseString() {
        XCTAssertEqual(MainTab.settings.label, "Settings")
    }

    func test_icon_settings_usesGearGlyph() {
        XCTAssertEqual(MainTab.settings.icon, .settings)
    }

    func test_label_otherTabs_unchanged() {
        XCTAssertEqual(MainTab.home.label,         "Home")
        XCTAssertEqual(MainTab.instructions.label, "Instructions")
        XCTAssertEqual(MainTab.dictionary.label,   "Dictionary")
    }

    func test_icon_otherTabs_unchanged() {
        XCTAssertEqual(MainTab.home.icon,         .home)
        XCTAssertEqual(MainTab.instructions.icon, .edit)
        XCTAssertEqual(MainTab.dictionary.icon,   .bookmark)
    }

    // MARK: - consumePendingSelection (cross-window flag)

    func test_consumePending_nilFlag_returnsCurrent_andStaysNil() {
        var pending: MainTab? = nil
        let next = MainTab.consumePendingSelection(pending: &pending, current: .home)
        XCTAssertEqual(next, .home, "Nil pending should leave selectedTab unchanged.")
        XCTAssertNil(pending, "Nil pending is a no-op — must remain nil.")
    }

    func test_consumePending_nonNilFlag_returnsPending_andClears() {
        var pending: MainTab? = .settings
        let next = MainTab.consumePendingSelection(pending: &pending, current: .home)
        XCTAssertEqual(next, .settings, "Non-nil pending must override current.")
        XCTAssertNil(pending, "Pending must be cleared atomically on consumption.")
    }

    func test_consumePending_staleFlag_clearedRegardlessOfCurrent() {
        // Anti-stale guarantee (plan §270 / §285): even when the consumer
        // is invoked for an unrelated reason (Sparkle banner click,
        // scenePhase re-activation, etc.), the pending flag is cleared
        // first — apply second. The stored value still surfaces this
        // time, but won't linger to fire later.
        var pending: MainTab? = .settings
        _ = MainTab.consumePendingSelection(pending: &pending, current: .instructions)
        XCTAssertNil(pending, "Stale flag must be cleared atomically — must not linger.")
    }

    func test_consumePending_idempotent_secondCallNoOp() {
        var pending: MainTab? = .settings
        _ = MainTab.consumePendingSelection(pending: &pending, current: .home)
        let second = MainTab.consumePendingSelection(pending: &pending, current: .dictionary)
        XCTAssertEqual(second, .dictionary, "Second consumption should fall back to caller's current.")
        XCTAssertNil(pending)
    }

    func test_consumePending_pendingEqualsCurrent_stillClears() {
        // Edge case: gear button sets pending = .settings, but the
        // window's selectedTab was *already* .settings (user re-opens
        // the popover and clicks gear again). Function still clears
        // and returns the value — caller assigns to selectedTab
        // (a no-op) and the flag is gone. No special-case branch
        // needed; pinning this so future "optimisation" doesn't
        // introduce one.
        var pending: MainTab? = .settings
        let next = MainTab.consumePendingSelection(pending: &pending, current: .settings)
        XCTAssertEqual(next, .settings)
        XCTAssertNil(pending)
    }
}
