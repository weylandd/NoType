import AppKit
import SwiftUI

/// Keeps the process alive when the last NSPanel/NSWindow closes —
/// otherwise AppKit's default `applicationShouldTerminateAfterLastWindowClosed`
/// policy fires the moment a HUD panel dismisses, killing the menu-bar
/// utility. NSWorkspace also pings us with `applicationShouldHandleReopen`
/// when the user double-clicks the dock-less app icon; we use that to
/// pop the main window if it's been closed.
final class NoTypeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct NoTypeApp: App {
    @NSApplicationDelegateAdaptor(NoTypeAppDelegate.self) private var appDelegate

    @State private var permissions: PermissionsViewModel
    @State private var appState:    AppState
    /// Owns the user's theme preference and applies it to NSApp on init —
    /// must exist before the first SwiftUI body resolves so the very first
    /// frame already has the correct appearance.
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

        _permissions = State(wrappedValue: perms)
        _appState = State(
            wrappedValue: AppState(
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
        )
        _appearance = State(wrappedValue: AppearanceController())
        _onboarding = State(wrappedValue: onboarding)
        _updates    = State(wrappedValue: UpdateController())
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
