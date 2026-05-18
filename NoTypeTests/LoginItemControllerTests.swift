import XCTest
@testable import NoType

/// Pins the surface of `LoginItemController` that's testable without a
/// live `SMAppService` round-trip:
/// 1. The enum mapping from `SMAppService.Status` to our internal
///    `LoginItemStatus` (display state + chip rendering depends on it).
/// 2. The deep-link URL string used to open Login Items in System
///    Settings. URL constants drift silently if hand-crafted at the
///    call site — pinning the string here surfaces breakage at test
///    time, not from a stuck "Open Settings" button.
final class LoginItemControllerTests: XCTestCase {

    // MARK: - Status enum mapping

    func test_loginItemStatus_mapsFromSMAppServiceStatus() {
        // All four `SMAppService.Status` cases the SDK exposes today.
        // Names are stable since macOS 13.
        XCTAssertEqual(LoginItemStatus(rawStatus: .notRegistered),    .notRegistered)
        XCTAssertEqual(LoginItemStatus(rawStatus: .enabled),          .enabled)
        XCTAssertEqual(LoginItemStatus(rawStatus: .requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemStatus(rawStatus: .notFound),         .notRegistered)
    }

    func test_loginItemStatus_isEnabled_onlyForEnabledCase() {
        XCTAssertFalse(LoginItemStatus.notRegistered.isEnabled)
        XCTAssertTrue (LoginItemStatus.enabled.isEnabled)
        XCTAssertFalse(LoginItemStatus.requiresApproval.isEnabled)
    }

    func test_loginItemStatus_requiresApproval_isExclusiveCase() {
        XCTAssertFalse(LoginItemStatus.notRegistered.requiresApproval)
        XCTAssertFalse(LoginItemStatus.enabled.requiresApproval)
        XCTAssertTrue (LoginItemStatus.requiresApproval.requiresApproval)
    }

    // MARK: - System Settings deep-link

    func test_loginItemsSettingsURL_matchesAppleDocumentedScheme() {
        // Apple's documented URL for the Login Items pane in System
        // Settings (macOS 13+) — drifting from this means the button
        // either opens the wrong pane or no-ops.
        XCTAssertEqual(
            LoginItemController.loginItemsSettingsURLString,
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        )

        // And it must parse — `NSWorkspace.open` silently rejects
        // malformed URLs, which would surface as a dead button.
        XCTAssertNotNil(URL(string: LoginItemController.loginItemsSettingsURLString))
    }
}
