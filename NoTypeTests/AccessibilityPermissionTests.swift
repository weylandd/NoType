import XCTest
@testable import NoType

/// Pins the pure state-machine + UserDefaults side effects of
/// `AccessibilityPermission`. The `AXIsProcessTrustedWithOptions`
/// syscall is not mocked — see `NoType/Permissions/CLAUDE.md`
/// "Testing" section — so this file covers:
///
///   - `mapStatus(isAxGranted:hasAsked:)`  — pure 4-case truth table.
///   - `migrateHasAskedIfNeeded(defaults:)` — backfill rule for users
///     whose onboarding already completed under an older build.
///
/// `request()` is *not* tested directly: it calls the syscall with
/// `prompt: true`, which on a fresh TCC database opens the macOS
/// system Accessibility prompt — disruptive on dev machines and CI.
/// The flag-write contract for `request()` is documented as a hard
/// rule in `NoType/Permissions/CLAUDE.md` and verified manually per
/// the U3 smoke checklist in the originating plan.
///
/// Each test runs against an isolated `UserDefaults` suite so we
/// never disturb the real `UserDefaults.standard` (the user's actual
/// onboarding-complete + hasAsked state).
final class AccessibilityPermissionTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "notype.tests.accessibilityPermission.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        // Belt and braces — start clean even if a previous test crashed.
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - mapStatus

    func test_mapStatus_grantedAlwaysWins_evenWithoutHasAsked() {
        XCTAssertEqual(
            AccessibilityPermission.mapStatus(isAxGranted: true, hasAsked: false),
            .granted
        )
    }

    func test_mapStatus_grantedAlwaysWins_evenWithHasAsked() {
        XCTAssertEqual(
            AccessibilityPermission.mapStatus(isAxGranted: true, hasAsked: true),
            .granted
        )
    }

    /// Fresh install: TCC empty, user has never seen our Grant UI →
    /// `.notDetermined` so the onboarding row renders yellow "REQUIRED"
    /// rather than red "DENIED".
    func test_mapStatus_freshInstall_returnsNotDetermined() {
        XCTAssertEqual(
            AccessibilityPermission.mapStatus(isAxGranted: false, hasAsked: false),
            .notDetermined
        )
    }

    /// User saw the prompt (or its UI counterpart) and refused →
    /// `.denied` so the row renders red with an "Open Settings" CTA.
    func test_mapStatus_explicitRefusal_returnsDenied() {
        XCTAssertEqual(
            AccessibilityPermission.mapStatus(isAxGranted: false, hasAsked: true),
            .denied
        )
    }

    // MARK: - migrateHasAskedIfNeeded

    /// Fresh install path: neither key is set → migration leaves the
    /// flag unset so `mapStatus` returns `.notDetermined`.
    func test_migration_freshInstall_doesNotSetFlag() {
        AccessibilityPermission.migrateHasAskedIfNeeded(defaults: suite)
        XCTAssertFalse(suite.bool(forKey: AccessibilityPermission.hasAskedKey))
    }

    /// Existing user whose onboarding finished under an older build
    /// (when AX always returned `.denied`). Without this backfill they
    /// would see yellow "REQUIRED" + a Grant button that silently no-ops
    /// because macOS only prompts once per launch lifetime.
    func test_migration_completedOnboarding_backfillsFlag() {
        suite.set(true, forKey: OnboardingState.completeKey)

        AccessibilityPermission.migrateHasAskedIfNeeded(defaults: suite)

        XCTAssertTrue(suite.bool(forKey: AccessibilityPermission.hasAskedKey))
    }

    /// User is still inside the onboarding wizard (or never completed
    /// it). They should see `.notDetermined` on the Permissions step;
    /// the migration must not pre-flip the flag.
    func test_migration_incompleteOnboarding_leavesFlagUnset() {
        suite.set(false, forKey: OnboardingState.completeKey)

        AccessibilityPermission.migrateHasAskedIfNeeded(defaults: suite)

        XCTAssertFalse(suite.bool(forKey: AccessibilityPermission.hasAskedKey))
    }

    /// Flag already set (by a prior `request()` call). Migration must
    /// not run again — it would still set the same value, but the
    /// `guard` short-circuit makes the intent explicit and keeps the
    /// behaviour deterministic if we ever change the truthy value.
    func test_migration_isIdempotent_whenFlagAlreadySet() {
        suite.set(true, forKey: AccessibilityPermission.hasAskedKey)

        AccessibilityPermission.migrateHasAskedIfNeeded(defaults: suite)

        XCTAssertTrue(suite.bool(forKey: AccessibilityPermission.hasAskedKey))
    }

    /// The migration writes the flag iff *both* conditions hold —
    /// flag unset AND onboarding complete. Existing flag wins over
    /// the absent-onboarding-key path (we never reset `hasAsked`).
    func test_migration_existingFlag_isNotOverwrittenBy_incompleteOnboarding() {
        suite.set(true, forKey: AccessibilityPermission.hasAskedKey)
        suite.set(false, forKey: OnboardingState.completeKey)

        AccessibilityPermission.migrateHasAskedIfNeeded(defaults: suite)

        XCTAssertTrue(suite.bool(forKey: AccessibilityPermission.hasAskedKey))
    }
}
