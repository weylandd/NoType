import AppKit
import Foundation
import OSLog

/// Orchestrator for the optional screenshot + OCR fallback.
///
/// Pipeline: permission gate → `ScreenCaptureController.captureActiveWindow`
/// → `TextRecognizer.recognize` → per-line `SecureFieldMasker.scrubContent`
/// → packed into a module-private `RedactedScreenText`.
///
/// Returns `nil` on any failure (permission denied, no on-screen window,
/// OCR error, cancellation by deadline). The caller treats `nil` as
/// "no OCR data" — the prompt simply doesn't get an OCR sub-block.
///
/// Type-level guarantee: the only path from raw pixel-recognised text to
/// the network goes through `SecureFieldMasker.scrubContent` here. There
/// is no public accessor on `RedactedScreenText` for the unscrubbed lines
/// — mirrors `RedactedAXSnapshot`. See `NoType/Context/CLAUDE.md`.
enum ScreenCaptureContext {
    private static let log = Logger(subsystem: "app.notype", category: "screen-capture")

    /// Soft cap on recognised lines included in the prompt. The screen of
    /// a busy IDE / browser easily produces 300+ lines; we don't want to
    /// drown the model in low-signal text. Set `truncated=true` when hit.
    static let maxLines = 200

    /// Soft cap on total character count after scrubbing — bounds prompt
    /// tokens regardless of line count. ~8K chars ≈ 2K tokens, comfortable
    /// next to the AX dump's 5–15K-token budget.
    static let maxTotalChars = 8_000

    /// Run the full pipeline. The deadline is enforced cooperatively via
    /// `Task.isCancelled` checks at each stage; callers wrap this in a
    /// `withTaskGroup`-style race against a timeout sleep.
    static func capture(activeApp: AppInfo, pid: pid_t) async -> RedactedScreenText? {
        // Permission check first — cheapest gate, also the most common
        // "no result" case in production.
        guard ScreenRecordingPermission.current() == .granted else {
            log.info("ocr skipped: no screen recording permission")
            return nil
        }
        if Task.isCancelled { return nil }

        // Capture.
        let image: CGImage
        do {
            image = try await ScreenCaptureController.captureActiveWindow(pid: pid)
        } catch {
            log.info("ocr skipped: capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        if Task.isCancelled { return nil }

        // OCR.
        let rawLines: [String]
        do {
            rawLines = try await TextRecognizer.recognize(image)
        } catch {
            log.info("ocr skipped: recognize failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        if Task.isCancelled { return nil }

        // Per-line scrub + budget enforcement.
        var kept: [String] = []
        kept.reserveCapacity(min(rawLines.count, maxLines))
        var charCount = 0
        var truncated = false
        for line in rawLines {
            if kept.count >= maxLines {
                truncated = true
                break
            }
            let scrubbed = SecureFieldMasker.scrubContent(line)
            // `scrubContent` only replaces matches with `[REDACTED — …]`
            // labels of comparable length, so the scrubbed line is rarely
            // empty unless the input itself was whitespace.
            let trimmed = scrubbed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if charCount + trimmed.count > maxTotalChars {
                truncated = true
                break
            }
            kept.append(trimmed)
            charCount += trimmed.count
        }

        let windowTitle = findActiveWindowTitle(pid: pid)
        log.info("ocr ok: lines=\(kept.count) chars=\(charCount) truncated=\(truncated)")
        return RedactedScreenText(
            appName: activeApp.name,
            bundleID: activeApp.bundleID,
            windowTitle: windowTitle,
            scrubbedLines: kept,
            truncated: truncated
        )
    }

    /// Best-effort window title via `NSWorkspace` / NSRunningApplication.
    /// Doesn't go through AX — we already have AX data; we just want a
    /// short label so the model knows what window the OCR text came from.
    private static func findActiveWindowTitle(pid: pid_t) -> String? {
        // `NSRunningApplication.localizedName` is the app's name, not the
        // window title; macOS doesn't expose window titles through
        // NSWorkspace without AX or screen recording. Returning nil here
        // and letting `RedactedScreenText.formattedForPrompt` emit
        // `Window:` (no quoted title) is fine — the model has the app
        // name from the surrounding header.
        _ = pid
        return nil
    }
}
