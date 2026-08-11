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
/// the deinit chain may not run reliably under `NSApp.terminate`. The
/// AppState-side handler is assigned in `NoTypeApp.init()`, alongside
/// the two launch handlers.
final class NoTypeAppDelegate: NSObject, NSApplicationDelegate {
    /// Runs from `applicationWillTerminate(_:)` on the main thread,
    /// synchronously before the process exits. Used by `AppState` to
    /// release the `MusicInterruption` assertion if one is held — see
    /// the class doc-comment for why.
    ///
    /// Assigned in `NoTypeApp.init()`. It used to be assigned from a
    /// `.task` on `MainWindowView`, which for a returning `LSUIElement`
    /// user never fires — the main window isn't presented at launch, so
    /// quitting from the popover left the system muted. See
    /// `launchHandler`'s doc-comment for the same trap.
    var terminationHandler: (@MainActor () -> Void)?

    /// Runs from `applicationDidFinishLaunching(_:)` — the first moment
    /// `NSApplicationMain` has actually started the application. Every
    /// piece of launch work that *schedules* `MainActor` work hangs off
    /// this, because doing any of it from `NoTypeApp.init()` is a latent
    /// ordering bug — which is the whole reason, and reason enough. It is
    /// **not** coverage of the macOS 26 executor-identity crash family:
    /// that theory shipped as v0.1.13-rc1 (`bfcec4a`) and did not fix the
    /// crash. See
    /// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
    /// (The one thing that rides the earlier
    /// `willFinishLaunchingHandler` instead is the appearance write,
    /// which schedules nothing — see that property.) Assigned in
    /// `NoTypeApp.init()` (assigning a closure schedules nothing) so the
    /// handler is guaranteed to be in place before AppKit calls back.
    ///
    /// Deliberately NOT a SwiftUI `.task` on the main `Window`: NoType is
    /// `LSUIElement` and, once onboarding is complete, that window is not
    /// presented at launch — a returning user would never fire it. That
    /// is not hypothetical: Sparkle's `UpdateController.start()` sat on
    /// exactly that `.task`, so menu-bar-only users got no update checks
    /// at all until they happened to open the window.
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
        // FIRST statement, deliberately. An Objective-C exception raised
        // inside a main-actor Swift-concurrency job orphans the main thread's
        // executor identity and then gets swallowed by AppKit, so the process
        // survives and crashes later at an unrelated executor check — and
        // nothing else in the process observes that throw
        // (`NSSetUncaughtExceptionHandler` does not fire; AppKit catches
        // first). Installing here covers every type constructed below and the
        // whole launch window. Pure function-pointer swap: it schedules no
        // `MainActor` work and touches no `NSApp`, so it does not violate the
        // launch-ordering rule the rest of this initializer obeys. See
        // `NoType/Diagnostics/ExceptionBreadcrumb.swift`; pinned by
        // `ExceptionBreadcrumbTests`.
        ExceptionBreadcrumb.install()

        let perms        = PermissionsViewModel()
        let hud          = HUDController(permissions: perms)
        let gemini       = GeminiClient()
        let history      = HistoryStore()
        let stats        = StatsStore()
        let instructions = InstructionsStore()
        let categorizer  = AppCategorizer(client: gemini, store: instructions)
        let dictionary   = DictionaryStore()
        let onboarding   = OnboardingState()
        // Constructed here rather than left to `AppState.init`'s default
        // argument. A default argument is evaluated at this call site but
        // its `RetainedAudioStore(` text lives in `AppState`'s parameter
        // list, and `LaunchPathScanner.constructedTypeNames` only reads
        // initializer *bodies* — so the defaulted form would put the type
        // on the launch path while making it invisible to the scan that
        // enforces the launch-ordering rule for everything on that path.
        // Naming it here keeps the guard honest.
        let retained     = RetainedAudioStore()

        let appearance = AppearanceController()
        let updates    = UpdateController()
        let state = AppState(
            permissions: perms,
            hud: hud,
            gemini: gemini,
            historyStore: history,
            statsStore: stats,
            instructionsStore: instructions,
            appCategorizer: categorizer,
            dictionaryStore: dictionary,
            onboarding: onboarding,
            retainedAudio: retained
        )

        _permissions = State(wrappedValue: perms)
        _appState    = State(wrappedValue: state)
        _appearance  = State(wrappedValue: appearance)
        _onboarding  = State(wrappedValue: onboarding)
        _updates     = State(wrappedValue: updates)

        // Assigning a closure schedules nothing and touches no `NSApp`, so
        // this is legal here — and doing it in `init` (rather than from a
        // scene's `.task`) guarantees the handlers are installed before
        // AppKit fires the callbacks that invoke them.
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
            // Last of the three: Sparkle's scheduler is background work
            // with no user-visible surface at launch, so it goes behind
            // the theme write and the hotkey-tap install. `start()` needs
            // a live `NSApplication` to attach to, which
            // `applicationDidFinishLaunching(_:)` satisfies at least as
            // well as the scene `.task` it replaces.
            updates.start()
        }

        // Restores the user's mute state on the orderly-quit path
        // (`NSApp.terminate(nil)` from the popover's Quit button). A pure
        // closure assignment like the two above — it schedules nothing, so
        // it belongs in `init` rather than in `launchHandler`: the delegate
        // owns the closure, so assigning it from a closure the delegate
        // itself owns would only add a retain cycle and a later wiring
        // point, for a handler that cannot possibly be needed before launch.
        // Captures the local `state`, not `self.appState`: `@State` must not
        // be read outside a view update.
        appDelegate.terminationHandler = {
            state.releaseMusicInterruption()
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
