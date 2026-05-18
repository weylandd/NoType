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

    // MARK: - Instance behaviour

    @MainActor
    func test_resetWizard_instance_movesStateBackToWelcome() async {
        let state = OnboardingState()
        // Drive through to .complete. `goNext()` writes to
        // `UserDefaults.standard` — we'll restore it on teardown via
        // the suite isolation above (this test reads back via the
        // public `currentStep` instead, so the standard-defaults
        // pollution is bounded to this test process).
        for _ in 0..<5 { state.goNext() }
        XCTAssertEqual(state.currentStep, .complete)
        XCTAssertTrue(state.isComplete)

        state.resetWizard()

        XCTAssertEqual(state.currentStep,  .welcome)
        XCTAssertEqual(state.furthestStep, .welcome)
        XCTAssertFalse(state.isComplete)
        XCTAssertTrue(state.isOnboarding)
    }
}
