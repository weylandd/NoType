import XCTest
@testable import NoType

/// Walker integration tests via the extracted seams from U2 + U3:
/// `decideForNode` (per-node pipeline), `budgetForApp` (priority routing),
/// `applyGlobalCap` (active-first sort + global truncation), and
/// `RedactedAXSnapshot.formattedForPrompt` (rendering contract).
///
/// We deliberately do NOT mock `AXUIElementCopyAttributeValue` — the pure
/// seams above cover the new wiring end-to-end against synthetic inputs.
/// Closes the TECHDEBT entry at
/// `solutions/documentation-gaps/accessibility-tree-fixture-tests-2026-05-15.md`.
final class AccessibilityTreeTests: XCTestCase {

    // MARK: - decideForNode — R8 masker-precedence (security boundary)

    func test_decide_secureFieldSkipsBeforeNoiseFilter() {
        // Critical: even if the value would otherwise look "noisy" to
        // AXNoiseFilter, the masker's .skip wins. The noise filter must
        // NEVER be consulted before the masker decides.
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXSecureTextField")
        let decision = AccessibilityTree.decideForNode(
            role: "AXSecureTextField",
            subrole: nil,
            title: nil,
            value: "hunter2",
            metadata: metadata,
            containingBundleID: nil,
            depth: 1
        )
        XCTAssertEqual(decision, .skipSubtree)
    }

    func test_decide_secureSubroleSkipsBeforeNoiseFilter() {
        let metadata = SecureFieldMasker.NodeMetadata(
            role: "AXTextField",
            subrole: "AXSecureTextField"
        )
        let decision = AccessibilityTree.decideForNode(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            title: nil,
            value: "secret",
            metadata: metadata,
            containingBundleID: nil,
            depth: 1
        )
        XCTAssertEqual(decision, .skipSubtree)
    }

    func test_decide_sensitiveSheetParentSkips() {
        // Masker's parent-context-aware skip (sensitive sheet title) also
        // takes precedence over the noise filter.
        let metadata = SecureFieldMasker.NodeMetadata(
            role: "AXTextField",
            parentRole: "AXSheet",
            parentTitle: "Sign in to Acme"
        )
        let decision = AccessibilityTree.decideForNode(
            role: "AXTextField",
            subrole: nil,
            title: nil,
            value: "password123",
            metadata: metadata,
            containingBundleID: nil,
            depth: 1
        )
        XCTAssertEqual(decision, .skipSubtree)
    }

    // MARK: - decideForNode — title scrubbing (R8 security boundary)

    func test_decide_nodeTitleWithURLCreds_scrubbedInRenderedLine() {
        // A node whose TITLE (not value) carries embedded URL credentials
        // must render with the creds redacted. Before R8 the title reached
        // the prompt with only quote-swapping.
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXButton")
        let decision = AccessibilityTree.decideForNode(
            role: "AXButton",
            subrole: nil,
            title: "https://alice:p4ssw0rd@github.com/acme",
            value: nil,
            metadata: metadata,
            containingBundleID: "com.apple.Safari",
            depth: 1
        )
        guard case let .render(line) = decision else {
            XCTFail("expected render, got \(decision)"); return
        }
        XCTAssertTrue(line.contains("[REDACTED — url creds]"), line)
        XCTAssertFalse(line.contains("alice"), line)
        XCTAssertFalse(line.contains("p4ssw0rd"), line)
    }

    func test_decide_nodeTitleWithTokenShapedLabel_scrubbed() {
        // A token-shaped string in a node title (e.g. an AX label that leaked
        // an AWS access key) must be redacted in the rendered line.
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXStaticText")
        let decision = AccessibilityTree.decideForNode(
            role: "AXStaticText",
            subrole: nil,
            title: "AKIAIOSFODNN7EXAMPLE",
            value: nil,
            metadata: metadata,
            containingBundleID: "com.apple.Notes",
            depth: 1
        )
        guard case let .render(line) = decision else {
            XCTFail("expected render, got \(decision)"); return
        }
        XCTAssertTrue(line.contains("[REDACTED — AWS key]"), line)
        XCTAssertFalse(line.contains("AKIAIOSFODNN7EXAMPLE"), line)
    }

    func test_decide_secureNodeWithTokenTitle_stillSkipsEntirely() {
        // Regression: a secure-field node still drops its whole subtree
        // BEFORE formatLine runs, so its title (token-shaped or not) never
        // reaches the prompt. The masker's .skip wins over the new title
        // scrubbing path.
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXSecureTextField")
        let decision = AccessibilityTree.decideForNode(
            role: "AXSecureTextField",
            subrole: nil,
            title: "AKIAIOSFODNN7EXAMPLE",
            value: "hunter2",
            metadata: metadata,
            containingBundleID: "com.apple.Safari",
            depth: 1
        )
        XCTAssertEqual(decision, .skipSubtree)
    }

    // MARK: - decideForNode — drops via AXNoiseFilter

    func test_decide_structuralChromeDrops() {
        let metadata = SecureFieldMasker.NodeMetadata(
            role: "AXButton",
            subrole: "AXCloseButton"
        )
        let decision = AccessibilityTree.decideForNode(
            role: "AXButton",
            subrole: "AXCloseButton",
            title: nil,
            value: nil,
            metadata: metadata,
            containingBundleID: "com.example.app",
            depth: 1
        )
        XCTAssertEqual(decision, .dropRender)
    }

    func test_decide_terminalScrollbackDrops() {
        // R5: long scrollback-shaped value in a Terminal-bundle parent.
        let longValue = String(repeating: "kopachev@host ~ % ls\n", count: 60)
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXTextArea")
        let decision = AccessibilityTree.decideForNode(
            role: "AXTextArea",
            subrole: nil,
            title: nil,
            value: longValue,
            metadata: metadata,
            containingBundleID: "com.apple.Terminal",
            depth: 1
        )
        XCTAssertEqual(decision, .dropRender)
    }

    func test_decide_sameScrollbackShapeInNotesRenders() {
        // Regression net: same shape (6+ newlines, >1000 chars) in a
        // non-terminal parent (Notes) MUST NOT drop — that's the
        // cross-window-signal case the noise filter must preserve.
        let longValue = String(repeating: "A paragraph of notes content.\n", count: 60)
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXTextArea")
        let decision = AccessibilityTree.decideForNode(
            role: "AXTextArea",
            subrole: nil,
            title: nil,
            value: longValue,
            metadata: metadata,
            containingBundleID: "com.apple.Notes",
            depth: 1
        )
        // Should render — long Notes content is real signal.
        if case .render = decision {
            // OK
        } else {
            XCTFail("expected .render for Notes paragraph content, got \(decision)")
        }
    }

    func test_decide_gibberishOnlyShortValueDrops() {
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXTextArea")
        let decision = AccessibilityTree.decideForNode(
            role: "AXTextArea",
            subrole: nil,
            title: nil,
            value: "口》巳@",
            metadata: metadata,
            containingBundleID: "com.apple.QuickTimePlayerX",
            depth: 1
        )
        XCTAssertEqual(decision, .dropRender)
    }

    // MARK: - decideForNode — render happy paths

    func test_decide_textFieldWithValueRenders() {
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXTextField")
        let decision = AccessibilityTree.decideForNode(
            role: "AXTextField",
            subrole: nil,
            title: nil,
            value: "search query",
            metadata: metadata,
            containingBundleID: "com.apple.Safari",
            depth: 1
        )
        XCTAssertEqual(decision, .render("- TextField = search query"))
    }

    func test_decide_buttonWithTitleRenders() {
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXButton")
        let decision = AccessibilityTree.decideForNode(
            role: "AXButton",
            subrole: nil,
            title: "Continue",
            value: nil,
            metadata: metadata,
            containingBundleID: "com.example.app",
            depth: 1
        )
        XCTAssertEqual(decision, .render("- Button \"Continue\""))
    }

    func test_decide_indentReflectsDepth() {
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXButton")
        let decision = AccessibilityTree.decideForNode(
            role: "AXButton",
            subrole: nil,
            title: "Send",
            value: nil,
            metadata: metadata,
            containingBundleID: "com.example.app",
            depth: 3
        )
        // depth=3 → indent = "  " * 2 = "    "
        XCTAssertEqual(decision, .render("    - Button \"Send\""))
    }

    func test_decide_emptyGroupFallsThroughToDropRender() {
        // The pre-existing formatLine safety net (Group/Generic with no
        // title and no value) still returns nil → decideForNode returns
        // .dropRender via the formatLine fallthrough branch.
        let metadata = SecureFieldMasker.NodeMetadata(role: "AXGroup")
        let decision = AccessibilityTree.decideForNode(
            role: "AXGroup",
            subrole: nil,
            title: nil,
            value: nil,
            metadata: metadata,
            containingBundleID: nil,
            depth: 1
        )
        XCTAssertEqual(decision, .dropRender)
    }

    // MARK: - budgetForApp (U3 routing)

    func test_budget_activeAppGetsBumpedCap() {
        XCTAssertEqual(
            AccessibilityTree.budgetForApp(
                bundleID: "ru.keepcoder.Telegram",
                active: "ru.keepcoder.Telegram"
            ),
            AccessibilityTree.perAppNodeBudgetActive
        )
    }

    func test_budget_nonActiveAppGetsBaseCap() {
        XCTAssertEqual(
            AccessibilityTree.budgetForApp(
                bundleID: "com.apple.Safari",
                active: "ru.keepcoder.Telegram"
            ),
            AccessibilityTree.perAppNodeBudgetNonActive
        )
    }

    func test_budget_nilActiveFlattensEveryone() {
        XCTAssertEqual(
            AccessibilityTree.budgetForApp(
                bundleID: "ru.keepcoder.Telegram",
                active: nil
            ),
            AccessibilityTree.perAppNodeBudgetNonActive
        )
    }

    func test_budget_activeBumpIsModestNotAggressive() {
        // Pins the 1.4× ratio against future drift — keeps cross-window
        // signal alive per ADR-009. A ratio above ~1.7× would over-rotate.
        let ratio = Double(AccessibilityTree.perAppNodeBudgetActive)
                  / Double(AccessibilityTree.perAppNodeBudgetNonActive)
        XCTAssertLessThan(ratio, 1.7, "active priority should be modest, not aggressive")
        XCTAssertGreaterThan(ratio, 1.0, "active app should get some priority")
    }

    // MARK: - applyGlobalCap (U3 sort + truncation)

    func test_globalCap_activeMovesToFront() {
        let dumps = [
            makeDump(bundle: "com.apple.Safari", lineCount: 100),
            makeDump(bundle: "ru.keepcoder.Telegram", lineCount: 100),
            makeDump(bundle: "com.apple.Mail", lineCount: 100),
        ]
        let result = AccessibilityTree.applyGlobalCap(
            dumps: dumps,
            activeBundleID: "ru.keepcoder.Telegram"
        )
        XCTAssertEqual(result.apps.first?.bundleID, "ru.keepcoder.Telegram")
        XCTAssertEqual(result.apps.count, 3)
        XCTAssertFalse(result.truncated)
    }

    func test_globalCap_activeAlreadyFirstIsNoOp() {
        let dumps = [
            makeDump(bundle: "ru.keepcoder.Telegram", lineCount: 100),
            makeDump(bundle: "com.apple.Safari", lineCount: 100),
            makeDump(bundle: "com.apple.Mail", lineCount: 100),
        ]
        let result = AccessibilityTree.applyGlobalCap(
            dumps: dumps,
            activeBundleID: "ru.keepcoder.Telegram"
        )
        XCTAssertEqual(
            result.apps.map(\.bundleID),
            ["ru.keepcoder.Telegram", "com.apple.Safari", "com.apple.Mail"]
        )
    }

    func test_globalCap_nilActiveLeavesOrderUntouched() {
        let dumps = [
            makeDump(bundle: "com.apple.Safari", lineCount: 100),
            makeDump(bundle: "ru.keepcoder.Telegram", lineCount: 100),
            makeDump(bundle: "com.apple.Mail", lineCount: 100),
        ]
        let result = AccessibilityTree.applyGlobalCap(
            dumps: dumps,
            activeBundleID: nil
        )
        XCTAssertEqual(
            result.apps.map(\.bundleID),
            ["com.apple.Safari", "ru.keepcoder.Telegram", "com.apple.Mail"]
        )
    }

    func test_globalCap_activeSurvivesTruncationOnBusyMachine() {
        // 8 apps × 700 lines = 5600 — exceeds 5000 global cap.
        // Active app is in the middle (idx 4). After sort + cap, the
        // active app must survive (be in the result) — the truncation
        // sacrifices a non-active app instead.
        var dumps: [RedactedAppDump] = []
        for i in 0..<8 {
            let bundle = "com.example.app\(i)"
            dumps.append(makeDump(bundle: bundle, lineCount: 700))
        }
        let result = AccessibilityTree.applyGlobalCap(
            dumps: dumps,
            activeBundleID: "com.example.app4"
        )
        XCTAssertTrue(result.truncated, "global cap should fire on 8×700")
        XCTAssertEqual(result.apps.first?.bundleID, "com.example.app4")
        XCTAssertNotNil(
            result.apps.first(where: { $0.bundleID == "com.example.app4" }),
            "active app must survive global cap"
        )
    }

    func test_globalCap_truncatedFalseWhenWithinBudget() {
        let dumps = [
            makeDump(bundle: "a", lineCount: 1000),
            makeDump(bundle: "b", lineCount: 700),
            makeDump(bundle: "c", lineCount: 700),
        ]
        let result = AccessibilityTree.applyGlobalCap(
            dumps: dumps,
            activeBundleID: "a"
        )
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.totalNodes, 2400)
        XCTAssertEqual(result.apps.count, 3)
    }

    // MARK: - RedactedAXSnapshot.formattedForPrompt — rendering contract

    func test_format_emptyApps() {
        let snapshot = RedactedAXSnapshot(apps: [])
        XCTAssertEqual(
            snapshot.formattedForPrompt(),
            "(no on-screen context available)"
        )
    }

    func test_format_truncatedMarker() {
        let snapshot = RedactedAXSnapshot(
            apps: [makeDump(bundle: "com.example.app", lineCount: 1)],
            truncated: true
        )
        XCTAssertTrue(
            snapshot.formattedForPrompt().contains("(context truncated — node budget exceeded)"),
            "truncated snapshot should surface the marker"
        )
    }

    func test_format_headerWindowLineShape() {
        // Lines come from formatLine without a renderer-side prefix —
        // formattedForPrompt() adds `"  "` to each line itself. So
        // formatLine output `- StaticText = Hello` (no indent) renders
        // as `  - StaticText = Hello` (2-space prefix from renderer).
        let dump = RedactedAppDump(
            appName: "Telegram",
            bundleID: "ru.keepcoder.Telegram",
            windows: [
                RedactedWindowDump(
                    title: "Telegram @ victoria",
                    lines: ["- StaticText = Hello"]
                )
            ]
        )
        let snapshot = RedactedAXSnapshot(apps: [dump])
        // Renderer emits a trailing blank line after each app's windows
        // (`out += "\n"`), so the expected has TWO trailing newlines —
        // one from the last line's "\n", one from the app separator.
        let expected = """
            === Telegram (ru.keepcoder.Telegram) ===
            Window: "Telegram @ victoria"
              - StaticText = Hello


            """
        XCTAssertEqual(snapshot.formattedForPrompt(), expected)
    }

    func test_format_untitledWindow() {
        let dump = RedactedAppDump(
            appName: "Finder",
            bundleID: "com.apple.finder",
            windows: [RedactedWindowDump(title: nil, lines: ["  - Image \"Documents\""])]
        )
        let snapshot = RedactedAXSnapshot(apps: [dump])
        XCTAssertTrue(snapshot.formattedForPrompt().contains("Window:\n"),
                      "nil title should render bare 'Window:' header")
    }

    func test_format_activeFirstReflectsInOrdering() {
        // U3's applyGlobalCap puts active first; the renderer respects
        // input order. Verify the end-to-end ordering is preserved.
        let dumps = [
            makeDump(bundle: "com.apple.Safari", lineCount: 1),
            makeDump(bundle: "ru.keepcoder.Telegram", lineCount: 1),
        ]
        let result = AccessibilityTree.applyGlobalCap(
            dumps: dumps,
            activeBundleID: "ru.keepcoder.Telegram"
        )
        let snapshot = RedactedAXSnapshot(apps: result.apps)
        let formatted = snapshot.formattedForPrompt()
        guard let telegramIdx = formatted.range(of: "(ru.keepcoder.Telegram)")?.lowerBound,
              let safariIdx = formatted.range(of: "(com.apple.Safari)")?.lowerBound else {
            XCTFail("expected both app headers in formatted output")
            return
        }
        XCTAssertLessThan(telegramIdx, safariIdx,
                          "active app section should appear before non-active")
    }

    // MARK: - Helpers

    private func makeDump(bundle: String, lineCount: Int) -> RedactedAppDump {
        let lines = (0..<lineCount).map { "  - StaticText = line\($0)" }
        return RedactedAppDump(
            appName: bundle,
            bundleID: bundle,
            windows: [RedactedWindowDump(title: nil, lines: lines)]
        )
    }
}
