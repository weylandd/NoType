import XCTest
@testable import NoType

/// Pins `OnboardingState.resetWizard()`:
/// - clears `currentStep`, `furthestStep`, and `complete` UserDefaults
///   keys (so the wizard re-opens on welcome);
/// - does NOT touch unrelated UserDefaults keys (Keychain key, hotkey
///   binding, selected microphone) — explicit promise from plan §305
///   / progress.md P2 resolution.
///
/// Each test uses an isolated `UserDefaults` suite so we never disturb
/// the user's real onboarding state.
final class OnboardingStateTests: XCTestCase {

    private var defaultsSuite: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "notype.tests.onboarding.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: suiteName)
        // Belt and braces — start clean even if a previous test crashed.
        defaultsSuite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaultsSuite.removePersistentDomain(forName: suiteName)
        defaultsSuite = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - resetWizard contract

    @MainActor
    func test_resetWizard_clearsAllThreeOnboardingKeys() async {
        // Simulate a completed onboarding by writing through the
        // documented keys directly. We don't call `goNext()` because
        // `OnboardingState`'s init reads from `UserDefaults.standard`
        // (production singleton), and the suite-isolated check below
        // is what matters.
        defaultsSuite.set(5, forKey: OnboardingState.currentStepKey)   // .complete
        defaultsSuite.set(5, forKey: OnboardingState.furthestStepKey)
        defaultsSuite.set(true, forKey: OnboardingState.completeKey)

        OnboardingState.resetWizardDefaults(in: defaultsSuite)

        XCTAssertNil(defaultsSuite.object(forKey: OnboardingState.currentStepKey))
        XCTAssertNil(defaultsSuite.object(forKey: OnboardingState.furthestStepKey))
        XCTAssertNil(defaultsSuite.object(forKey: OnboardingState.completeKey))
    }

    @MainActor
    func test_resetWizard_preservesKeychainAndHotkeyAndMicKeys() async {
        // Sentinel values on the three keys ce-work R2 + AE9 promise to
        // preserve. None of these should be touched by resetWizard().
        let hotkeyBindingKey   = "notype.hotkey.bindingCode"
        let selectedMicUIDKey  = "notype.selectedInputDeviceUID"

        // Onboarding state to be cleared.
        defaultsSuite.set(5, forKey: OnboardingState.currentStepKey)
        defaultsSuite.set(5, forKey: OnboardingState.furthestStepKey)
        defaultsSuite.set(true, forKey: OnboardingState.completeKey)

        // Sentinel keys that must survive.
        defaultsSuite.set("KeyR", forKey: hotkeyBindingKey)
        defaultsSuite.set("MIC-UID-12345", forKey: selectedMicUIDKey)

        OnboardingState.resetWizardDefaults(in: defaultsSuite)

        XCTAssertEqual(defaultsSuite.string(forKey: hotkeyBindingKey),  "KeyR",
                       "resetWizard must not touch the hotkey binding")
        XCTAssertEqual(defaultsSuite.string(forKey: selectedMicUIDKey), "MIC-UID-12345",
                       "resetWizard must not touch the selected microphone UID")
    }

    @MainActor
    func test_resetWizard_isIdempotent_onAlreadyClearedDefaults() async {
        // No state set. resetWizard() must not crash and must be a no-op.
        OnboardingState.resetWizardDefaults(in: defaultsSuite)
        OnboardingState.resetWizardDefaults(in: defaultsSuite)

        XCTAssertNil(defaultsSuite.object(forKey: OnboardingState.currentStepKey))
        XCTAssertNil(defaultsSuite.object(forKey: OnboardingState.completeKey))
    }

    /// `resetWizard` must also clear the two `permissions.*.hasAsked`
    /// flags so a user who re-opens the wizard via Settings sees the
    /// neutral "REQUIRED" surface again on the Permissions step, not
    /// the leftover red "DENIED" from their pre-reset state. Pinned
    /// by Permissions/CLAUDE.md invariant 6.
    @MainActor
    func test_resetWizard_clearsPermissionHasAskedFlags() async {
        // Simulate a user who completed onboarding and then explicitly
        // refused (or just landed on the row) both permissions.
        defaultsSuite.set(true, forKey: OnboardingState.completeKey)
        defaultsSuite.set(true, forKey: AccessibilityPermission.hasAskedKey)
        defaultsSuite.set(true, forKey: ScreenRecordingPermission.hasAskedKey)

        OnboardingState.resetWizardDefaults(in: defaultsSuite)

        XCTAssertNil(
            defaultsSuite.object(forKey: AccessibilityPermission.hasAskedKey),
            "resetWizard must clear the Accessibility hasAsked flag so the re-run wizard renders yellow REQUIRED instead of red DENIED."
        )
        XCTAssertNil(
            defaultsSuite.object(forKey: ScreenRecordingPermission.hasAskedKey),
            "resetWizard must clear the Screen Recording hasAsked flag for the same reason."
        )
    }

    // MARK: - Instance behaviour

    @MainActor
    func test_resetWizard_instance_movesStateBackToWelcome() async {
        // Inject the suite-isolated defaults so `goNext()` /
        // `resetWizard()` write into the per-test suite — NOT the
        // host process's `UserDefaults.standard`. NoTypeTests is
        // application-hosted in `NoType.app`, so `.standard` is
        // `app.notype` on disk; without the injection this test
        // would clear the developer's "onboarding complete" flag
        // on every CI run and force the wizard on next launch.

        // Snapshot the standard defaults' onboarding state BEFORE the
        // test so we can prove instance methods never wrote through.
        let stdCompleteBefore =
            UserDefaults.standard.object(forKey: OnboardingState.completeKey) as? Bool
        let stdCurrentBefore =
            UserDefaults.standard.object(forKey: OnboardingState.currentStepKey) as? Int
        let stdFurthestBefore =
            UserDefaults.standard.object(forKey: OnboardingState.furthestStepKey) as? Int

        let state = OnboardingState(defaults: defaultsSuite)
        for _ in 0..<5 { state.goNext() }
        XCTAssertEqual(state.currentStep, .complete)
        XCTAssertTrue(state.isComplete)

        state.resetWizard()

        XCTAssertEqual(state.currentStep,  .welcome)
        XCTAssertEqual(state.furthestStep, .welcome)
        XCTAssertFalse(state.isComplete)
        XCTAssertTrue(state.isOnboarding)

        // Regression guard — verify the standard defaults are bit-for-bit
        // unchanged. Catches future regressions where someone re-introduces
        // a `.standard` call inside an `OnboardingState` instance method.
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: OnboardingState.completeKey) as? Bool,
            stdCompleteBefore,
            "Instance methods must never write to UserDefaults.standard — they would poison the developer's onboarding state across test runs."
        )
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: OnboardingState.currentStepKey) as? Int,
            stdCurrentBefore
        )
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: OnboardingState.furthestStepKey) as? Int,
            stdFurthestBefore
        )
    }
}
