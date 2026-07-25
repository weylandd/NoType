import AppKit
import Foundation
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class PermissionsViewModel {
    @ObservationIgnored private static let log = Logger(subsystem: "app.notype", category: "permissions")

    private(set) var microphone:     PermissionStatus = .unknown
    private(set) var accessibility:  PermissionStatus = .unknown
    /// Optional. Gates the screenshot + OCR fallback (`NoType/Context/ScreenCapture/`).
    /// Deliberately NOT part of `allGranted` / `recordingReady` — the app
    /// works fine without it; granting just turns on richer context for
    /// AX-poor apps (Slack, Discord, web-views, Notion).
    private(set) var screenRecording: PermissionStatus = .unknown

    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    /// Guards `prime()` against a second run. Mirrors `UpdateController`'s
    /// `didStart` latch — re-priming would register a second pair of
    /// notification observers (which are never de-registered).
    ///
    /// `private(set)` rather than `private` so `LaunchPrimingTests` can pin
    /// the latch: the statuses alone cannot detect its removal, because
    /// `refresh()` is value-idempotent and a second run returns the same
    /// three values whether or not the guard fired.
    @ObservationIgnored private(set) var didPrime = false

    var allGranted: Bool {
        microphone.isGranted && accessibility.isGranted
    }

    /// Critical-path subset for actually starting a recording session.
    var recordingReady: Bool { allGranted }

    /// Deliberately empty. Every launch-path type must schedule no
    /// `MainActor` work and touch no `NSApp` during construction — this
    /// is the first object `NoTypeApp.init()` builds, and the old
    /// `refresh()` call reached `startPollingIfNeeded()`, which spawns a
    /// `Task` whenever any permission is ungranted (i.e. on every first
    /// run). See `prime()`.
    init() {}

    deinit {
        pollingTask?.cancel()
    }

    /// Reads the live TCC state and starts observing. Called from
    /// `applicationDidFinishLaunching(_:)`, never from `init` — see the
    /// initializer's doc-comment and
    /// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
    /// Idempotent.
    func prime() {
        guard !didPrime else { return }
        didPrime = true
        Self.log.info("launch: priming permissions")
        refresh()
        observeAppActivation()
    }

    func refresh() {
        microphone      = MicrophonePermission.current()
        accessibility   = AccessibilityPermission.current()
        screenRecording = ScreenRecordingPermission.current()
        startPollingIfNeeded()
    }

    func requestMicrophone() async {
        microphone = await MicrophonePermission.request()
    }

    func requestAccessibility() {
        AccessibilityPermission.request()
        startPollingIfNeeded()
    }

    func requestScreenRecording() async {
        screenRecording = await ScreenRecordingPermission.request()
        // System Settings round-trip for users who previously denied —
        // start polling so we pick up the change without restart.
        startPollingIfNeeded()
        // Auto-open the Settings pane on the first denied result so the
        // user lands on the (now-populated) Screen Recording list right
        // away. The first `request()` call is what makes the app show up
        // there, so opening Settings before it would land them on an
        // empty list — which is exactly the bug we just fixed.
        if !screenRecording.isGranted {
            ScreenRecordingPermission.openSystemSettings()
        }
    }

    func openMicrophoneSettings()      { MicrophonePermission.openSystemSettings() }
    func openAccessibilitySettings()   { AccessibilityPermission.openSystemSettings() }
    func openScreenRecordingSettings() { ScreenRecordingPermission.openSystemSettings() }

    // MARK: - Internals

    private func observeAppActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        // LSUIElement apps don't reliably get NSApplication.didBecomeActive
        // when returning from System Settings, so also listen to the workspace.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Poll while any *watched* permission is unresolved. Screen recording
    /// is watched but optional, so polling stops only once all three are
    /// granted OR everything required is granted AND the user has had a
    /// chance to settle screen recording (the user can re-trigger polling
    /// from the onboarding screen / settings later).
    private var needsPolling: Bool {
        !microphone.isGranted || !accessibility.isGranted || !screenRecording.isGranted
    }

    private func startPollingIfNeeded() {
        if !needsPolling {
            if pollingTask != nil {
                pollingTask?.cancel()
                pollingTask = nil
                Self.log.info("permissions resolved; polling stopped")
            }
            return
        }
        guard pollingTask == nil else { return }
        Self.log.info("starting permission polling")
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await MainActor.run { self.tick() }
            }
        }
    }

    private func tick() {
        let prev = (microphone, accessibility, screenRecording)
        microphone      = MicrophonePermission.current()
        accessibility   = AccessibilityPermission.current()
        screenRecording = ScreenRecordingPermission.current()
        let now = (microphone, accessibility, screenRecording)
        Self.log.debug("tick: mic=\(String(describing: self.microphone)) ax=\(String(describing: self.accessibility)) scr=\(String(describing: self.screenRecording))")
        if prev != now {
            Self.log.info("permissions changed: mic=\(String(describing: self.microphone)) ax=\(String(describing: self.accessibility)) scr=\(String(describing: self.screenRecording))")
        }
        if !needsPolling {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }
}
