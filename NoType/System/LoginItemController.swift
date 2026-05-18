import AppKit
import Foundation
import Observation
import OSLog
import ServiceManagement

/// Display-side status of the macOS "Open at login" registration for
/// NoType. Mirrors the subset of `SMAppService.Status` we care about
/// — collapsing `.notFound` into `.notRegistered` because both render
/// as "Off" in the UI and only differ in how SMAppService classifies
/// the registration internally.
enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval

    init(rawStatus: SMAppService.Status) {
        switch rawStatus {
        case .enabled:          self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered, .notFound:
            self = .notRegistered
        @unknown default:
            self = .notRegistered
        }
    }

    var isEnabled: Bool { self == .enabled }
    var requiresApproval: Bool { self == .requiresApproval }
}

/// `@MainActor @Observable` wrapper around `SMAppService.mainApp` for
/// the "Open NoType at login" toggle. `SMAppService` does not expose a
/// KVO or publisher surface — status is read on demand via the actor
/// API, and we refresh manually after every register/unregister call
/// plus whenever a relevant SwiftUI surface appears.
///
/// User-visible flow:
///   - Toggle ON → `register()` → status becomes `.enabled`
///     (or `.requiresApproval` if the user hasn't yet approved NoType
///     in System Settings → Login Items).
///   - Toggle OFF → `unregister()` → status becomes `.notRegistered`.
///   - `.requiresApproval` → inline note + "Open Login Items" button
///     that fires `openLoginItemsSettings()`.
@MainActor
@Observable
final class LoginItemController {
    private static let log = Logger(subsystem: "app.notype", category: "loginitems")

    /// Apple-documented deep-link to the Login Items pane in System
    /// Settings (macOS 13+). Pinned by `LoginItemControllerTests`.
    nonisolated static let loginItemsSettingsURLString = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    private(set) var status: LoginItemStatus = .notRegistered

    /// Most recent error from a register/unregister attempt — surfaced
    /// inline in the Settings row when non-nil. Cleared by `refresh()`.
    private(set) var lastError: String?

    init() {
        refresh()
    }

    /// Re-read the live `SMAppService` status and update `status`.
    /// Cheap; safe to call from `onAppear`.
    func refresh() {
        let raw = SMAppService.mainApp.status
        let next = LoginItemStatus(rawStatus: raw)
        if next != status {
            Self.log.info("login-item status changed: \(String(describing: self.status), privacy: .public) -> \(String(describing: next), privacy: .public)")
        }
        status = next
    }

    func setEnabled(_ enabled: Bool) async {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            Self.log.error("SMAppService \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Opens System Settings → General → Login Items so the user can
    /// approve NoType when status is `.requiresApproval`.
    func openLoginItemsSettings() {
        guard let url = URL(string: Self.loginItemsSettingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }
}
