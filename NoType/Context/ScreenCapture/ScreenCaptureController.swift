import AppKit
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

/// `ScreenCaptureKit` wrapper for grabbing a single `CGImage` of the
/// **active window** of a specific app. Used by the screenshot + OCR
/// fallback orchestrator (`ScreenCaptureContext`).
///
/// Requires macOS 14+ — ScreenCaptureKit (SCShareableContent /
/// SCScreenshotManager) landed in macOS 14.0, which matches the
/// project's deployment target (see ADR-001).
/// Capture is ~10–30 ms on Apple Silicon.
enum ScreenCaptureController {
    private static let log = Logger(subsystem: "app.notype", category: "screen-capture")

    enum CaptureError: Error, LocalizedError {
        case permissionDenied
        case noOnScreenWindow

        var errorDescription: String? {
            switch self {
            case .permissionDenied:   "Screen Recording permission is not granted."
            case .noOnScreenWindow:   "No on-screen window found for the active app."
            }
        }
    }

    /// Capture the largest visible on-screen window owned by the given
    /// pid. Picks the largest-area `SCWindow` as the "active" one — this
    /// matches what the user is looking at when they hold the hotkey;
    /// minimised or off-screen windows are filtered out by `SCShareableContent`'s
    /// `onScreenWindowsOnly: true` flag.
    ///
    /// Throws `CaptureError.permissionDenied` if TCC has not been granted,
    /// `CaptureError.noOnScreenWindow` if the app has no usable window
    /// (common when capturing menu-bar-only apps).
    static func captureActiveWindow(pid: pid_t) async throws -> CGImage {
        // `SCShareableContent.current` itself throws if the user has not
        // granted Screen Recording — translate to a clear error so
        // `ScreenCaptureContext` can log a specific reason.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            log.info("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            throw CaptureError.permissionDenied
        }

        // Filter to windows owned by the target app, drop window-layer
        // chrome (menus, popups have non-zero layers). Then pick the
        // largest by frame area.
        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == pid && window.windowLayer == 0
        }
        guard let target = candidates.max(by: { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }) else {
            throw CaptureError.noOnScreenWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        // Native resolution — Vision OCR happily handles whatever scale we
        // hand it; bigger frames give better recognition on dense UI.
        config.width  = max(Int(target.frame.width  * 2), 1)
        config.height = max(Int(target.frame.height * 2), 1)
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let t0 = Date()
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        log.debug("capture took \(Int(Date().timeIntervalSince(t0) * 1000))ms pid=\(pid) size=\(image.width)x\(image.height)")
        return image
    }
}
