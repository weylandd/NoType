import AppKit
import SwiftUI

/// Keeps the process alive when the last NSPanel/NSWindow closes —
/// otherwise AppKit's default `applicationShouldTerminateAfterLastWindowClosed`
/// policy fires the moment a HUD panel dismisses, killing the menu-bar
/// utility. NSWorkspace also pings us with `applicationShouldHandleReopen`
/// when the user double-clicks the dock-less app icon; we use that to
/// pop the main window if it's been closed.
///
/// `applicationWillTerminate(_:)` is the canonical hook for the
/// orderly-quit path triggered by the popover's Quit button
/// (`NSApp.terminate(nil)` in `HistoryPopover`). It does NOT fire on
/// crash / kill — for that, the assertion classes' `deinit` is the
/// safety net (e.g. `MusicInterruption.deinit` restores mute). Used to
/// run the `MusicInterruption` mute-restore *synchronously* before the
/// process exits so the user's system isn't left stranded on mute when
/// the deinit chain may not run reliably under `NSApp.terminate`. Any
/// AppState-side handler is registered via `terminationHandler` after
/// the `@NSApplicationDelegateAdaptor` instantiates this class.
final class NoTypeAppDelegate: NSObject, NSApplicationDelegate {
    /// Runs from `applicationWillTerminate(_:)` on the main thread,
    /// synchronously before the process exits. Used by `AppState` to
    /// release the `MusicInterruption` assertion if one is held — see
    /// the class doc-comment for why.
    var terminationHandler: (@MainActor () -> Void)?

    /// Runs from `applicationDidFinishLaunching(_:)` — the first moment
    /// `NSApplicationMain` has actually started the application. Every
    /// piece of launch work that *schedules* `MainActor` work hangs off
    /// this, because doing any of it from `NoTypeApp.init()` is a latent
    /// ordering bug and the leading suspect for the macOS 26.2
    /// executor-identity crash. (The one thing that rides the earlier
    /// `willFinishLaunchingHandler` instead is the appearance write,
    /// which schedules nothing — see that property.) Assigned in
    /// `NoTypeApp.init()` (assigning a closure schedules nothing) so the
    /// handler is guaranteed to be in place before AppKit calls back.
    ///
    /// Deliberately NOT a SwiftUI `.task` on the main `Window`: NoType is
    /// `LSUIElement` and, once onboarding is complete, that window is not
    /// presented at launch — a returning user would never fire it.
    ///
    /// This is a single point of failure for the whole app: if it is
    /// never assigned or never fires, NoType runs with no hotkey tap, no
    /// permission reads and every mirror empty, which looks exactly like
    /// a genuinely ungranted install. `AppState.prime()` logs on entry so
    /// that state is diagnosable, and
    /// `LaunchOrderingTests.test_launchWork_isActuallyWiredUp_fromNoTypeAppInit`
    /// pins the assignment.
    var launchHandler: (@MainActor () -> Void)?

    /// Runs from `applicationWillFinishLaunching(_:)` — the earliest hook
    /// that is still after `NSApplicationMain` has started the app, and
    /// crucially *before* SwiftUI evaluates the first `View.body`. Only
    /// the appearance write hangs off this: `AppearanceController.init`
    /// used to apply the theme precisely so "the very first frame already
    /// has the correct appearance", and `applicationDidFinishLaunching`
    /// is one hook too late to preserve that. Priming stays on the later
    /// hook — it is the work that must not run early.
    ///
    /// `AppearanceController.apply()` is idempotent, so `launchHandler`
    /// re-applies it as a belt-and-braces: if a future SwiftUI release
    /// stops forwarding `willFinishLaunching` through
    /// `@NSApplicationDelegateAdaptor`, the theme still lands, one frame
    /// later, instead of never.
    var willFinishLaunchingHandler: (@MainActor () -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        willFinishLaunchingHandler?()
    }

    /// Note the absence of `MainActor.assumeIsolated` in both launch hooks
    /// and in `applicationWillTerminate(_:)`. `assumeIsolated` calls into
    /// the `swift_task_isCurrentExecutor` family — precisely the check
    /// that faults in this crash family, and the reason the project
    /// rejects it as a bridge (`NoType/UI/CLAUDE.md` hard rules). It is
    /// also pure ceremony here: `NSApplicationDelegate` conformance makes
    /// this class `@MainActor`, so calling a `@MainActor` closure needs no
    /// runtime check — the direct calls below typecheck under
    /// `SWIFT_STRICT_CONCURRENCY: complete`, which is the proof.
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchHandler?()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // AppKit guarantees this fires on the main thread before the
        // process dies, so the synchronous `releaseMusicInterruption()`
        // call gets to roll back the CoreAudio mute write before exit.
        terminationHandler?()
    }
}

@main
struct NoTypeApp: App {
    @NSApplicationDelegateAdaptor(NoTypeAppDelegate.self) private var appDelegate

    @State private var permissions: PermissionsViewModel
    @State private var appState:    AppState
    /// Owns the user's theme preference. Reads it from `UserDefaults` on
    /// init; the `NSApp.appearance` write happens in `apply()` from the
    /// launch hook, because no launch-path initializer may touch `NSApp`.
    @State private var appearance:  AppearanceController
    /// Drives the first-run wizard. Created before AppState so AppState
    /// can hold a reference and suppress permission HUDs while the
    /// wizard is showing.
    @State private var onboarding:  OnboardingState
    /// Sparkle 2 auto-update wrapper. The sidebar banner in `MainWindow`
    /// observes its `phase` and surfaces pending updates to the user.
    @State private var updates:     UpdateController

    init() {
        let perms        = PermissionsViewModel()
        let hud          = HUDController(permissions: perms)
        let gemini       = GeminiClient()
        let history      = HistoryStore()
        let stats        = StatsStore()
        let instructions = InstructionsStore()
        let categorizer  = AppCategorizer(client: gemini, store: instructions)
        let dictionary   = DictionaryStore()
        let onboarding   = OnboardingState()

        let appearance = AppearanceController()
        let state = AppState(
            permissions: perms,
            hud: hud,
            gemini: gemini,
            historyStore: history,
            statsStore: stats,
            instructionsStore: instructions,
            appCategorizer: categorizer,
            dictionaryStore: dictionary,
            onboarding: onboarding
        )

        _permissions = State(wrappedValue: perms)
        _appState    = State(wrappedValue: state)
        _appearance  = State(wrappedValue: appearance)
        _onboarding  = State(wrappedValue: onboarding)
        _updates     = State(wrappedValue: UpdateController())

        // Assigning a closure schedules nothing and touches no `NSApp`, so
        // this is legal here — and doing it in `init` (rather than from a
        // scene's `.task`) guarantees the handler is installed before
        // AppKit fires `applicationDidFinishLaunching(_:)`.
        //
        // Appearance is applied BEFORE priming so the theme is on `NSApp`
        // ahead of any UI the priming work can surface (the launch
        // permission HUD) — and on the earlier `willFinishLaunching` hook
        // so it also lands ahead of the first `View.body`. Re-applied from
        // `launchHandler` as an idempotent fallback; see
        // `willFinishLaunchingHandler`'s doc-comment.
        appDelegate.willFinishLaunchingHandler = {
            appearance.apply()
        }
        appDelegate.launchHandler = {
            appearance.apply()
            state.prime()
        }
    }

    /// Bind the termination handler once at scene-graph build time so
    /// the user's mute state always gets restored on `NSApp.terminate(nil)`
    /// (popover's Quit button). The delegate retains the closure; the
    /// closure retains the State-wrapped `appState`, which is the same
    /// instance the rest of the app uses. Idempotent — re-binding the
    /// same closure on every body invalidation is harmless.
    private func wireTerminationHandler() {
        appDelegate.terminationHandler = { [appState] in
            appState.releaseMusicInterruption()
        }
    }

    var body: some Scene {
        // Tray icon is suppressed entirely while the wizard is pending.
        // No menu-bar surface should exist before the user has agreed
        // to permissions / supplied an API key — they go straight to
        // the onboarding window. `isInserted` re-evaluates on every
        // body invalidation, so the icon appears the instant the user
        // clicks Continue on the last onboarding step.
        MenuBarExtra(isInserted: .constant(!onboarding.isOnboarding)) {
            HistoryPopover()
                .environment(appState)
                .environment(permissions)
                .environment(appearance)
                .environment(onboarding)
        } label: {
            MenuBarIcon()
                .environment(appState)
                .environment(permissions)
                .environment(onboarding)
        }
        .menuBarExtraStyle(.window)

        // Main window. Single-instance (`Window`, not `WindowGroup`).
        // `MainWindowView` toggles `NSApp.setActivationPolicy` between
        // `.regular` (open) and `.accessory` (closed) so NoType only
        // appears in the Dock while the window is up.
        //
        // `defaultLaunchBehavior` is decided once at scene-graph build
        // time from a synchronous UserDefaults read. When the wizard is
        // still pending we force-present the window so the user lands
        // directly in onboarding, with no need for a tray-icon detour
        // (the `MenuBarExtra` above is suppressed during onboarding by
        // design). After completion, subsequent launches fall back to
        // `.automatic` and don't auto-open the window — matches the
        // "menu-bar utility" behaviour.
        Window("NoType", id: "main") {
            MainWindowView()
                .environment(appState)
                .environment(permissions)
                .environment(appearance)
                .environment(onboarding)
                .environment(updates)
                // Sparkle wants a live NSApplication to attach its scheduler
                // to — `start()` from MainWindowView's lifecycle fits that.
                // Idempotent: the controller no-ops if started already.
                .task { updates.start() }
                // Register the orderly-quit handler that releases the
                // MusicInterruption assertion before exit so the user's
                // mute state survives `NSApp.terminate(nil)` from the
                // popover's Quit button.
                .task { wireTerminationHandler() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(
            width:  MainWindowMetrics.canvasSize.width,
            height: MainWindowMetrics.canvasSize.height
        )
        .defaultLaunchBehavior(
            OnboardingState.hasCompletedOnboarding ? .automatic : .presented
        )
        .commandsRemoved()
    }
}
