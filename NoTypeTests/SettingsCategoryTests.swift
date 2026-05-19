import XCTest
@testable import NoType

/// Pins the `SettingsCategory` enum surface used by the redesigned
/// Settings tab's secondary sidebar + the cross-surface
/// `pendingSettingsCategory` flag consumed by `SettingsTabView` (deep-
/// links from outside the main window — e.g. the missing-API-key HUD's
/// "Open Settings" button landing on API & Usage). Mirrors the shape
/// of `MainTabTests` since the consume-pending-selection helper here
/// is a clone of `MainTab`'s.
final class SettingsCategoryTests: XCTestCase {

    // MARK: - Enum membership + ordering

    func test_allCases_orderIsStable() {
        // Sidebar order is muscle-memory for users; pin it explicitly
        // so a refactor that reorders is caught before the user has to
        // hunt for the API key field.
        XCTAssertEqual(
            SettingsCategory.allCases,
            [.general, .recording, .languagePaste, .apiUsage, .about]
        )
    }

    // MARK: - Labels + crumbs + icons

    func test_apiUsage_label_andCrumb() {
        XCTAssertEqual(SettingsCategory.apiUsage.label, "API & Usage")
        XCTAssertEqual(SettingsCategory.apiUsage.crumb, "Settings / API & Usage")
    }

    func test_icon_apiUsage_usesLockGlyph() {
        XCTAssertEqual(SettingsCategory.apiUsage.icon, .lock)
    }

    // MARK: - consumePendingSelection (cross-surface flag)

    func test_consumePending_nilFlag_returnsCurrent_andStaysNil() {
        var pending: SettingsCategory? = nil
        let next = SettingsCategory.consumePendingSelection(
            pending: &pending,
            current: .general
        )
        XCTAssertEqual(next, .general, "Nil pending must leave selectedCategory unchanged.")
        XCTAssertNil(pending, "Nil pending is a no-op — must remain nil.")
    }

    func test_consumePending_nonNilFlag_returnsPending_andClears() {
        var pending: SettingsCategory? = .apiUsage
        let next = SettingsCategory.consumePendingSelection(
            pending: &pending,
            current: .general
        )
        XCTAssertEqual(next, .apiUsage, "Non-nil pending must override current.")
        XCTAssertNil(pending, "Pending must be cleared atomically on consumption.")
    }

    func test_consumePending_staleFlag_clearedRegardlessOfCurrent() {
        // Same anti-stale guarantee as MainTab (plan §270 / §285): even
        // when the consumer fires for an unrelated reason (Sparkle
        // banner → main-window open + Settings tab cascade), the flag
        // is cleared first. Pinning so future "optimisation" can't
        // re-introduce a branch.
        var pending: SettingsCategory? = .apiUsage
        _ = SettingsCategory.consumePendingSelection(
            pending: &pending,
            current: .recording
        )
        XCTAssertNil(pending, "Stale flag must be cleared atomically — must not linger.")
    }

    func test_consumePending_idempotent_secondCallNoOp() {
        var pending: SettingsCategory? = .apiUsage
        _ = SettingsCategory.consumePendingSelection(pending: &pending, current: .general)
        let second = SettingsCategory.consumePendingSelection(
            pending: &pending,
            current: .about
        )
        XCTAssertEqual(second, .about, "Second consumption must fall back to caller's current.")
        XCTAssertNil(pending)
    }

    func test_consumePending_pendingEqualsCurrent_stillClears() {
        // Edge: user is already on API & Usage when the HUD button
        // fires. Function still clears and returns the value; caller
        // assigns to selectedCategory (no-op) and the flag is gone.
        // Pinning so no special-case branch creeps in.
        var pending: SettingsCategory? = .apiUsage
        let next = SettingsCategory.consumePendingSelection(
            pending: &pending,
            current: .apiUsage
        )
        XCTAssertEqual(next, .apiUsage)
        XCTAssertNil(pending)
    }
}
