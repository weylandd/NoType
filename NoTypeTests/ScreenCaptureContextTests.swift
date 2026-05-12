import XCTest
@testable import NoType

/// Tests for the screenshot + OCR fallback path. The live `SCShareableContent` /
/// Vision calls aren't covered here — they require system permission and
/// running apps with windows, so they're manual smoke tests. What we pin
/// here is the pure logic the orchestrator depends on:
///
/// 1. The `RedactedAXSnapshot.hasContent(for:)` predicate — the trigger
///    that decides whether the OCR sub-block enters the prompt.
/// 2. The `RedactedScreenText.formattedForPrompt()` rendering — the
///    block of text that gets appended inside the `On-screen context:`
///    prompt part.
final class ScreenCaptureContextTests: XCTestCase {

    // MARK: - Trigger predicate: RedactedAXSnapshot.hasContent(for:)

    private func makeWindow(title: String?, lines: [String]) -> RedactedWindowDump {
        RedactedWindowDump(title: title, lines: lines)
    }

    private func makeApp(bundleID: String, windows: [RedactedWindowDump]) -> RedactedAppDump {
        RedactedAppDump(appName: "TestApp", bundleID: bundleID, windows: windows)
    }

    func test_hasContent_returnsFalse_whenBundleMissing() {
        let snap = RedactedAXSnapshot(apps: [
            makeApp(bundleID: "com.apple.mail", windows: [makeWindow(title: "Inbox", lines: ["one"])])
        ])
        XCTAssertFalse(snap.hasContent(for: "com.tinyspeck.slackmacgap"),
                       "bundle absent from the dump means we should trigger OCR")
    }

    func test_hasContent_returnsFalse_whenAppHasNoWindows() {
        let snap = RedactedAXSnapshot(apps: [
            makeApp(bundleID: "com.tinyspeck.slackmacgap", windows: [])
        ])
        XCTAssertFalse(snap.hasContent(for: "com.tinyspeck.slackmacgap"),
                       "empty windows array means AX surfaced nothing — trigger OCR")
    }

    func test_hasContent_returnsFalse_whenAllWindowsHaveEmptyLines() {
        let snap = RedactedAXSnapshot(apps: [
            makeApp(bundleID: "com.tinyspeck.slackmacgap", windows: [
                makeWindow(title: "engineering", lines: []),
                makeWindow(title: "design", lines: []),
            ])
        ])
        XCTAssertFalse(snap.hasContent(for: "com.tinyspeck.slackmacgap"),
                       "windows with zero collected lines = AX-poor (Electron) — trigger OCR")
    }

    func test_hasContent_returnsTrue_whenAnyWindowHasLines() {
        let snap = RedactedAXSnapshot(apps: [
            makeApp(bundleID: "com.apple.mail", windows: [
                makeWindow(title: "Inbox", lines: ["StaticText \"Hi team\""]),
                makeWindow(title: "Draft",  lines: []),
            ])
        ])
        XCTAssertTrue(snap.hasContent(for: "com.apple.mail"),
                      "at least one window with content means AX is sufficient — skip OCR")
    }

    func test_hasContent_caseSensitiveBundleID() {
        // Bundle IDs are canonically lowercase but mismatches must not
        // accidentally match — predicate is strict equality.
        let snap = RedactedAXSnapshot(apps: [
            makeApp(bundleID: "com.tinyspeck.slackmacgap",
                    windows: [makeWindow(title: "x", lines: ["y"])])
        ])
        XCTAssertFalse(snap.hasContent(for: "com.tinyspeck.SlackMacGap"))
        XCTAssertTrue (snap.hasContent(for: "com.tinyspeck.slackmacgap"))
    }

    // MARK: - RedactedScreenText.formattedForPrompt rendering

    func test_screenText_format_includesHeader_appAndWindow() {
        let text = RedactedScreenText(
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            windowTitle: "engineering — Acme",
            scrubbedLines: ["#engineering", "John Doe"]
        )
        let rendered = text.formattedForPrompt()
        XCTAssertTrue(rendered.contains("Screen text (OCR — active window)"),
                      "section header must be present so the model can tell AX from OCR")
        XCTAssertTrue(rendered.contains("Slack (com.tinyspeck.slackmacgap)"))
        XCTAssertTrue(rendered.contains("Window: \"engineering — Acme\""))
        XCTAssertTrue(rendered.contains("#engineering"))
        XCTAssertTrue(rendered.contains("John Doe"))
    }

    func test_screenText_format_nilTitle_rendersBareWindowLabel() {
        let text = RedactedScreenText(
            appName: "Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: nil,
            scrubbedLines: ["github.com"]
        )
        let rendered = text.formattedForPrompt()
        XCTAssertTrue(rendered.contains("Window:\n"),
                      "missing window title renders bare 'Window:' to keep shape consistent")
        XCTAssertFalse(rendered.contains("Window: \""),
                       "no spurious empty-quoted title")
    }

    func test_screenText_format_emptyLines_rendersExplicitNoTextLine() {
        let text = RedactedScreenText(
            appName: "Foo",
            bundleID: "com.foo",
            windowTitle: "Untitled",
            scrubbedLines: []
        )
        let rendered = text.formattedForPrompt()
        XCTAssertTrue(rendered.contains("(no text recognised)"),
                      "empty OCR result must surface explicitly, not silently")
    }

    func test_screenText_format_truncatedFlag_surfacedInPrompt() {
        let text = RedactedScreenText(
            appName: "Foo",
            bundleID: "com.foo",
            windowTitle: nil,
            scrubbedLines: ["one", "two"],
            truncated: true
        )
        let rendered = text.formattedForPrompt()
        XCTAssertTrue(rendered.contains("OCR truncated"),
                      "model must know when it has partial OCR coverage")
    }

    func test_screenText_format_startsWithSeparator_soItDoesntCollideWithAXBlock() {
        // Verifies the leading "\n--- " separator so the prompt reads
        // cleanly when appended after the AX tree text.
        let text = RedactedScreenText(
            appName: "Foo",
            bundleID: "com.foo",
            windowTitle: "x",
            scrubbedLines: ["y"]
        )
        let rendered = text.formattedForPrompt()
        XCTAssertTrue(rendered.hasPrefix("\n--- "),
                      "OCR block must start with a separator that breaks it cleanly from preceding AX text — got prefix: \(rendered.prefix(8))")
    }

    // MARK: - Permission gate (system-state observation)

    func test_capture_returnsNil_whenScreenRecordingDenied() async {
        // Only meaningful on a machine where Screen Recording is NOT
        // granted to the test host. If it IS granted, this test is a
        // no-op (we can't simulate denial without revoking TCC).
        guard ScreenRecordingPermission.current() != .granted else {
            // Test host has the permission — skip rather than fail.
            // The behaviour we want to pin (nil on denial) is exercised
            // any time CI runs on a fresh runner.
            return
        }
        let result = await ScreenCaptureContext.capture(
            activeApp: AppInfo(name: "X", bundleID: "com.example"),
            pid: 1
        )
        XCTAssertNil(result, "capture() must return nil when permission isn't granted")
    }
}
