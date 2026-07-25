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

    // MARK: - The delegate hook (U1/U2 delivery mechanism)

    /// Every piece of launch work now hangs off this one callback. Nothing
    /// else in the suite exercises it, so a rename, a stray `guard`, or a
    /// dropped assignment would silently disable the whole app while the
    /// tests stayed green.
    func test_applicationDidFinishLaunching_invokesLaunchHandler() {
        let delegate = NoTypeAppDelegate()
        var fired = 0
        delegate.launchHandler = { fired += 1 }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        XCTAssertEqual(fired, 1, "applicationDidFinishLaunching must invoke launchHandler")
    }

    /// The appearance write rides the earlier hook so it lands before the
    /// first `View.body` — `didFinishLaunching` is one hook too late for the
    /// "very first frame already has the correct appearance" guarantee.
    func test_applicationWillFinishLaunching_invokesWillFinishHandler() {
        let delegate = NoTypeAppDelegate()
        var fired = 0
        delegate.willFinishLaunchingHandler = { fired += 1 }

        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        XCTAssertEqual(fired, 1, "applicationWillFinishLaunching must invoke willFinishLaunchingHandler")
    }

    /// The orderly-quit hook. It restores the user's system audio after a
    /// `MusicInterruption` mute, so a handler that is never invoked leaves
    /// the whole machine silent after quitting NoType.
    func test_applicationWillTerminate_invokesTerminationHandler() {
        let delegate = NoTypeAppDelegate()
        var fired = 0
        delegate.terminationHandler = { fired += 1 }

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertEqual(fired, 1, "applicationWillTerminate must invoke terminationHandler")
    }

    /// Both hooks are optional-chained; an unassigned handler must be a
    /// no-op rather than a crash (the xctest host reaches them with no
    /// handler installed).
    func test_launchHooks_areNoOpsWithoutHandlers() {
        let delegate = NoTypeAppDelegate()

        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
    }

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
        let restore = Self.stashPermissionFlags()
        defer { restore() }

        let vm = PermissionsViewModel()
        vm.prime()

        XCTAssertNotEqual(vm.microphone, .unknown, "prime() must perform the live TCC read")
        XCTAssertNotEqual(vm.accessibility, .unknown, "prime() must perform the live TCC read")
        XCTAssertNotEqual(vm.screenRecording, .unknown, "prime() must perform the live TCC read")
    }

    /// Idempotence: a second `prime()` must not register a second pair of
    /// notification observers (they are never de-registered).
    ///
    /// Asserting only on the statuses would be vacuous — `refresh()` is
    /// value-idempotent, so three identical reads pass whether or not the
    /// latch fired. The latch itself is therefore the assertion: reading
    /// `didPrime` also means deleting the guard breaks compilation here
    /// rather than silently reopening double-registration.
    func test_permissionsViewModel_prime_isIdempotent() {
        let restore = Self.stashPermissionFlags()
        defer { restore() }

        let vm = PermissionsViewModel()
        XCTAssertFalse(vm.didPrime, "the latch must start open")

        vm.prime()
        XCTAssertTrue(vm.didPrime, "prime() must latch")
        let afterFirst = (vm.microphone, vm.accessibility, vm.screenRecording)

        vm.prime()
        vm.prime()

        XCTAssertTrue(vm.didPrime)
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
        stash([AppearanceController.userDefaultsKey])
    }

    /// `prime()` -> `refresh()` -> `AccessibilityPermission.current()` runs
    /// `migrateHasAskedIfNeeded`, which WRITES `hasAsked = true` into the
    /// real `UserDefaults.standard` whenever onboarding is already complete
    /// and Accessibility is not granted — the exact state that flips the
    /// developer's onboarding card from neutral "REQUIRED" to red "DENIED".
    /// `AccessibilityPermissionTests` uses a UUID suite for the same reason;
    /// `PermissionsViewModel` has no defaults seam, so stash and restore.
    private static func stashPermissionFlags() -> () -> Void {
        stash([AccessibilityPermission.hasAskedKey, ScreenRecordingPermission.hasAskedKey])
    }

    private static func stash(_ keys: [String]) -> () -> Void {
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        return {
            for (key, value) in saved {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }
}
