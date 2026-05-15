import Foundation
import os
@preconcurrency import Sparkle

/// Custom `SPUUserDriver` for Sparkle 2 that routes every UI event into
/// `UpdateController` state instead of showing Sparkle's modal alert window.
/// The banner in `MainWindow`'s sidebar renders that state.
///
/// All protocol methods are `@MainActor` because Sparkle 2 (≥ 2.6) annotates
/// `SPUUserDriver` as `@MainActor`. The protocol's callback closures may not
/// be `Sendable`, hence `@preconcurrency import Sparkle` in this module.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    weak var controller: UpdateController?

    private let log = Logger(subsystem: "app.notype", category: "updates")
    private var expectedDownloadLength: UInt64 = 0
    private var receivedDownloadLength: UInt64 = 0

    // MARK: - Permission

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // SUEnableAutomaticChecks=YES in Info.plist means Sparkle generally
        // doesn't show this — but if it ever does, opt the user in silently.
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            sendSystemProfile: false
        ))
    }

    // MARK: - Check lifecycle

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        controller?.pendingCancellation = cancellation
        controller?.setPhase(.checking)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let update = UpdateController.AvailableUpdate(
            // Sparkle 2 surfaces displayVersionString as a non-optional String —
            // the human-facing "1.2.3" the banner shows.
            versionString: appcastItem.displayVersionString
        )
        controller?.pendingUpdateReply = reply
        controller?.setPhase(.available(update))
        log.info("update found: \(update.versionString, privacy: .public) (build \(appcastItem.versionString, privacy: .public))")
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // We render the inline `<description>` only — external release-notes
        // URLs are ignored to keep the banner self-contained.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        log.error("release notes download failed: \(error.localizedDescription, privacy: .public)")
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller?.setPhase(.idle)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.error("updater error: \(error.localizedDescription, privacy: .public)")
        controller?.setPhase(.failed(error.localizedDescription))
        acknowledgement()
        // Reset to idle shortly so the banner doesn't get stuck on errors.
        Task { @MainActor [weak controller] in
            try? await Task.sleep(for: .seconds(5))
            if case .failed = controller?.phase {
                controller?.setPhase(.idle)
            }
        }
    }

    // MARK: - Download

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedDownloadLength = 0
        receivedDownloadLength = 0
        controller?.pendingCancellation = cancellation
        controller?.setPhase(.downloading(progress: 0))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadLength &+= length
        let progress: Double
        if expectedDownloadLength > 0 {
            progress = min(1.0, Double(receivedDownloadLength) / Double(expectedDownloadLength))
        } else {
            progress = 0
        }
        controller?.setPhase(.downloading(progress: progress))
    }

    // MARK: - Extraction / install

    func showDownloadDidStartExtractingUpdate() {
        controller?.setPhase(.extracting(progress: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        controller?.setPhase(.extracting(progress: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // The user already clicked the banner; auto-install without prompting
        // again. If we ever want a "Restart now / Restart later" choice this
        // is the place to capture the reply and surface a second UI state.
        controller?.setPhase(.installing)
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        controller?.setPhase(.installing)
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        // Process is about to be replaced; nothing more to do.
        acknowledgement()
    }

    func showUpdateInFocus() {
        // No-op — we have no separate update window to focus.
    }

    func dismissUpdateInstallation() {
        controller?.pendingUpdateReply = nil
        controller?.pendingInstallReply = nil
        controller?.pendingCancellation = nil
        controller?.setPhase(.idle)
    }
}
