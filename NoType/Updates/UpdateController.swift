import Foundation
import Observation
import os
@preconcurrency import Sparkle

/// SwiftUI-facing state of Sparkle 2 auto-update flow.
///
/// Wraps `SPUUpdater` with a custom `SPUUserDriver` (`UpdateUserDriver`) so we
/// can render our own in-app banner instead of Sparkle's modal alert window —
/// see `NoType/Updates/CLAUDE.md` and the "UI обновлений — банер в сайдбаре"
/// section of the auto-update plan.
///
/// Lifecycle: instantiated once in `NoTypeApp.init()` and injected into the
/// SwiftUI environment. `start()` runs from `applicationDidFinishLaunching(_:)`
/// via `NoTypeAppDelegate.launchHandler`, so Sparkle's scheduler observes a
/// live `NSApplication` and does so on every launch — including the
/// menu-bar-only launch of a returning `LSUIElement` user.
@MainActor
@Observable
final class UpdateController {
    /// What the banner should currently show.
    enum Phase: Equatable {
        /// Nothing to do — banner hidden.
        case idle
        /// Background check is in progress (transient; not user-facing).
        case checking
        /// Update found; banner says "Update to X.Y.Z · Restart to apply".
        case available(AvailableUpdate)
        /// User accepted; Sparkle is downloading. `progress` ∈ [0, 1].
        case downloading(progress: Double)
        /// Download finished; Sparkle is unpacking the .zip. `progress` ∈ [0, 1].
        case extracting(progress: Double)
        /// Installer is running. App will terminate and relaunch shortly.
        case installing
        /// Surfaced for logging; banner falls back to idle so the user isn't
        /// stuck on a permanently visible error chrome.
        case failed(String)
    }

    /// The minimal subset of `SUAppcastItem` we need for the banner.
    struct AvailableUpdate: Equatable {
        /// `displayVersionString` from the appcast item — usually
        /// `CFBundleShortVersionString` like `"0.1.2"`.
        let versionString: String
    }

    private(set) var phase: Phase = .idle

    private let log = Logger(subsystem: "app.notype", category: "updates")
    private let updater: SPUUpdater
    private let driver: UpdateUserDriver
    private var didStart = false

    // The four `pending*` slots and `setPhase(_:)` below would naturally be
    // `fileprivate`, but `UpdateUserDriver` lives in a sibling file inside
    // this module — they must be at least `internal`. Treat them as the
    // controller↔driver bridge surface; nothing outside `NoType/Updates/`
    // should ever touch them. If we grow more callsites we'll wrap this in
    // an explicit internal protocol.

    /// Captured from `SPUUserDriver.showUpdateFound(...)`. Calling it with
    /// `.install` tells Sparkle to start downloading; `.dismiss` postpones
    /// without skipping; `.skip` marks the version as skipped permanently.
    var pendingUpdateReply: ((SPUUserUpdateChoice) -> Void)?
    /// Captured from `SPUUserDriver.showReady(toInstallAndRelaunch:)`. We
    /// auto-fire `.install` from the driver so the user only clicks once
    /// (the banner), but keep the slot so a future Settings flow could
    /// pause between download and relaunch.
    var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?
    /// Captured from any of the `showXXXWithCancellation:` driver methods.
    /// `dismiss()` calls this to cancel an in-flight download/check.
    var pendingCancellation: (() -> Void)?

    init() {
        let driver = UpdateUserDriver()
        self.driver = driver
        self.updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
        driver.controller = self
    }

    /// Start the scheduler. Must be called from a launch callback (not
    /// `init`) because Sparkle wants a live `NSApplication` to attach to.
    /// Idempotent — `SPUUpdater.start()` throws if called twice, and the
    /// latch also covers a retry after a failed start.
    func start() {
        guard !didStart else { return }
        didStart = true
        do {
            try updater.start()
            log.info("sparkle updater started; auto-checks=\(self.updater.automaticallyChecksForUpdates, privacy: .public)")
        } catch {
            log.error("sparkle start failed: \(error.localizedDescription, privacy: .public)")
            // Reopen the latch. The launch hook fires exactly once, so the
            // only remaining retry is the user's explicit Settings →
            // "Check for updates", which calls `start()` first for this
            // reason. (Before the launch-hook move, a window
            // re-presentation re-fired the scene `.task` and retried here.)
            didStart = false
        }
    }

    /// User clicked the banner. If an update is available → tell Sparkle to
    /// download. If a download is already finished and waiting → tell it to
    /// install. Otherwise no-op (the banner shouldn't be visible then).
    func installNow() {
        if let reply = pendingInstallReply {
            pendingInstallReply = nil
            phase = .installing
            reply(.install)
            return
        }
        if let reply = pendingUpdateReply {
            pendingUpdateReply = nil
            reply(.install)
            return
        }
        log.debug("installNow called with no pending reply — ignoring")
    }

    /// User dismissed the banner (close button or programmatic). Postpones
    /// the update; Sparkle will offer it again on next scheduled check.
    func dismiss() {
        pendingCancellation?()
        pendingCancellation = nil
        pendingUpdateReply?(.dismiss)
        pendingUpdateReply = nil
        pendingInstallReply?(.dismiss)
        pendingInstallReply = nil
        phase = .idle
    }

    /// User asked for a manual check from Settings → Updates. Thin wrapper
    /// around `SPUUpdater.checkForUpdates()` — Sparkle drives the existing
    /// driver callbacks, so phase transitions through `.checking` → `.idle`
    /// (no update) or `.checking` → `.available(...)` exactly like the
    /// scheduled 24 h check.
    ///
    /// Calls `start()` first — a no-op in the normal case (the launch hook
    /// already started the scheduler) and the recovery path when that
    /// start threw: a manual check would otherwise run against an
    /// unstarted `SPUUpdater` for the rest of the process lifetime.
    func checkForUpdates() {
        start()
        updater.checkForUpdates()
    }

    /// User clicked the X chip on the `.available` banner. Tells Sparkle
    /// to mark this specific appcast version as skipped — Sparkle persists
    /// the choice and won't surface the same version again on subsequent
    /// scheduled checks. A newer version will still trigger the banner.
    ///
    /// Mirrors `dismiss()` but dispatches `.skip` instead of `.dismiss`
    /// so the choice is durable across launches. No-op when the slot is
    /// empty (banner not in `.available` state).
    func skipThisVersion() {
        guard let reply = pendingUpdateReply else {
            log.debug("skipThisVersion called with no pending reply — ignoring")
            return
        }
        pendingUpdateReply = nil
        pendingInstallReply = nil
        pendingCancellation = nil
        reply(.skip)
        phase = .idle
    }

    // MARK: - Driver callbacks (called from UpdateUserDriver; see access note above)

    func setPhase(_ newPhase: Phase) {
        guard phase != newPhase else { return }
        phase = newPhase
    }
}
