import AppKit
import XCTest
@testable import NoType

/// Behavioural half of the launch-ordering fix (the structural half is
/// `LaunchOrderingTests`, a source scan).
///
/// The rule: no type constructed by `NoTypeApp.init()` may schedule
/// `MainActor` work or touch `NSApp` during construction, because that
/// window is before `NSApplicationMain` has started the application. The
/// work moved into `prime()` / `apply()`, called from
/// `applicationDidFinishLaunching(_:)`. See
/// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
///
/// Scope note: these tests deliberately never call `AppState.prime()`.
/// Priming installs a real `CGEventTap` via `HotkeyMonitor.start()` when
/// Accessibility is granted, which must not happen inside a test process.
/// What `prime()` *contains* is pinned structurally by `LaunchOrderingTests`
/// instead.
@MainActor
final class LaunchPrimingTests: XCTestCase {

    // MARK: - PermissionsViewModel (U1)

    /// The regression guard for the change: `PermissionsViewModel` is the
    /// first object `NoTypeApp.init()` constructs, and its old initializer
    /// reached `startPollingIfNeeded()`, which spawns a `Task` whenever any
    /// permission is ungranted — i.e. on every first run.
    func test_permissionsViewModel_init_readsNothing_andStartsNoPolling() {
        let vm = PermissionsViewModel()

        XCTAssertEqual(vm.microphone, .unknown, "init must not read live TCC state")
        XCTAssertEqual(vm.accessibility, .unknown, "init must not read live TCC state")
        XCTAssertEqual(vm.screenRecording, .unknown, "init must not read live TCC state")
        XCTAssertFalse(vm.allGranted)
        XCTAssertFalse(vm.recordingReady)
    }

    /// After priming, the statuses are real. `.unknown` is only ever the
    /// pre-prime placeholder — every TCC API returns one of the other three.
    func test_permissionsViewModel_prime_resolvesEveryStatus() {
        let vm = PermissionsViewModel()
        vm.prime()

        XCTAssertNotEqual(vm.microphone, .unknown, "prime() must perform the live TCC read")
        XCTAssertNotEqual(vm.accessibility, .unknown, "prime() must perform the live TCC read")
        XCTAssertNotEqual(vm.screenRecording, .unknown, "prime() must perform the live TCC read")
    }

    /// Idempotence: a second `prime()` must not register a second pair of
    /// notification observers or a redundant polling task. Observed through
    /// the latch's visible effect — the statuses stay coherent and the call
    /// is a no-op rather than a re-entry.
    func test_permissionsViewModel_prime_isIdempotent() {
        let vm = PermissionsViewModel()
        vm.prime()
        let afterFirst = (vm.microphone, vm.accessibility, vm.screenRecording)

        vm.prime()
        vm.prime()

        XCTAssertEqual(vm.microphone, afterFirst.0)
        XCTAssertEqual(vm.accessibility, afterFirst.1)
        XCTAssertEqual(vm.screenRecording, afterFirst.2)
    }

    // MARK: - AppState (U1)

    /// `AppState.init()` must leave every store-backed mirror at its empty
    /// default. Populating them is `prime()`'s job; doing it from `init`
    /// means eight `Task { @MainActor … }` bodies scheduled before the app
    /// exists.
    func test_appState_init_leavesMirrorsAtEmptyDefaults() {
        let state = Self.makeAppState()

        XCTAssertTrue(state.history.isEmpty, "history must not be loaded from init")
        XCTAssertEqual(state.statsSummary, .empty, "stats must not be loaded from init")
        XCTAssertTrue(state.dictionaryEntries.isEmpty, "dictionary must not be loaded from init")
    }

    /// `AppState.init()` must not prime its `PermissionsViewModel` either —
    /// the whole launch path stays inert until the delegate callback.
    func test_appState_init_doesNotPrimePermissions() {
        let perms = PermissionsViewModel()
        _ = Self.makeAppState(permissions: perms)

        XCTAssertEqual(perms.microphone, .unknown)
        XCTAssertEqual(perms.accessibility, .unknown)
        XCTAssertEqual(perms.screenRecording, .unknown)
    }

    // MARK: - AppearanceController (U2)

    func test_appearance_init_readsPersistedMode_withoutTouchingNSApp() {
        let restore = Self.stashAppearanceDefault()
        defer { restore() }
        UserDefaults.standard.set(AppearanceMode.dark.rawValue, forKey: AppearanceController.userDefaultsKey)

        let appearanceBefore = NSApp?.appearance
        let controller = AppearanceController()

        XCTAssertEqual(controller.mode, .dark, "init must read the persisted mode")
        XCTAssertEqual(
            NSApp?.appearance, appearanceBefore,
            "init must not write NSApp.appearance — that is apply()'s job, from the launch hook"
        )
    }

    func test_appearance_init_fallsBackToSystem_whenNothingPersisted() {
        let restore = Self.stashAppearanceDefault()
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: AppearanceController.userDefaultsKey)

        XCTAssertEqual(AppearanceController().mode, .system)
    }

    func test_appearance_apply_setsAppearanceForPersistedMode() throws {
        let app = try XCTUnwrap(NSApp, "needs a live NSApplication host")
        let restore = Self.stashAppearanceDefault()
        let originalAppearance = app.appearance
        defer {
            restore()
            app.appearance = originalAppearance
        }

        UserDefaults.standard.set(AppearanceMode.dark.rawValue, forKey: AppearanceController.userDefaultsKey)
        let controller = AppearanceController()
        controller.apply()

        XCTAssertEqual(app.appearance?.name, NSAppearance.Name.darkAqua)
    }

    /// The `didSet` path must keep working after the init-time `apply()`
    /// was removed: a later user change still persists and re-applies.
    func test_appearance_settingModePostLaunch_persistsAndReapplies() throws {
        let app = try XCTUnwrap(NSApp, "needs a live NSApplication host")
        let restore = Self.stashAppearanceDefault()
        let originalAppearance = app.appearance
        defer {
            restore()
            app.appearance = originalAppearance
        }

        UserDefaults.standard.set(AppearanceMode.system.rawValue, forKey: AppearanceController.userDefaultsKey)
        let controller = AppearanceController()

        controller.mode = .light

        XCTAssertEqual(app.appearance?.name, NSAppearance.Name.aqua, "didSet must re-apply")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: AppearanceController.userDefaultsKey),
            AppearanceMode.light.rawValue,
            "didSet must persist"
        )
    }

    // MARK: - Helpers

    private static func makeAppState(permissions: PermissionsViewModel? = nil) -> AppState {
        let perms = permissions ?? PermissionsViewModel()
        let gemini = GeminiClient()
        let instructions = InstructionsStore()
        return AppState(
            permissions: perms,
            hud: HUDController(permissions: perms),
            gemini: gemini,
            historyStore: HistoryStore(),
            statsStore: StatsStore(),
            instructionsStore: instructions,
            appCategorizer: AppCategorizer(client: gemini, store: instructions),
            dictionaryStore: DictionaryStore(),
            onboarding: OnboardingState()
        )
    }

    /// `AppearanceController` reads `UserDefaults.standard` directly, so
    /// tests must put the real key back afterwards.
    private static func stashAppearanceDefault() -> () -> Void {
        let key = AppearanceController.userDefaultsKey
        let saved = UserDefaults.standard.string(forKey: key)
        return {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
