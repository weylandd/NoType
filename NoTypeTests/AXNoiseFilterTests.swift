import XCTest
@testable import NoType

/// **Hard rule** (mirrors `SecureFieldMaskerTests`): any change to
/// `AXNoiseFilter.swift` must add at least one new test case here.
/// No exceptions.
///
/// Three predicate layers are tested:
/// - **`shouldDropNode`** — structural chrome (R4) + gibberish density (R7)
/// - **`isViewportScrollback`** — terminal-parent-gated scrollback drop (R5)
/// - **`collapseRepetitivePacks`** — sequence-level summary-line pass (R6)
final class AXNoiseFilterTests: XCTestCase {

    // MARK: - R4 structural chrome — drop

    func test_drop_closeButtonChrome() {
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXButton", subrole: "AXCloseButton",
            title: nil, value: ""
        ))
    }

    func test_drop_minimizeButtonChrome() {
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXButton", subrole: "AXMinimizeButton",
            title: nil, value: ""
        ))
    }

    func test_drop_fullScreenButtonChrome() {
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXButton", subrole: "AXFullScreenButton",
            title: nil, value: ""
        ))
    }

    func test_drop_zoomButtonChrome() {
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXButton", subrole: "AXZoomButton",
            title: nil, value: ""
        ))
    }

    func test_drop_allChromeSubrolesWhenLabelless() {
        // Locks the **full inventory** of chrome subroles from
        // `AXNoiseFilter.chromeSubroleSet`. Adding or removing any subrole
        // from that set requires updating this list. Each one drops to
        // `.dropRender` when the carrying node has no title and no value.
        let subroles = [
            "AXCloseButton",
            "AXMinimizeButton",
            "AXFullScreenButton",
            "AXZoomButton",
            "AXIncrementArrow",
            "AXDecrementArrow",
            "AXIncrementPage",
            "AXDecrementPage",
            "AXToolbarButton",
        ]
        for subrole in subroles {
            XCTAssertTrue(
                AXNoiseFilter.shouldDropNode(
                    role: "AXButton", subrole: subrole,
                    title: nil, value: ""
                ),
                "subrole '\(subrole)' should drop as labelless chrome"
            )
        }
    }

    func test_drop_scrollBarRole() {
        // AXScrollBar carries a numeric position value — drop regardless,
        // scroll position is pure mechanic.
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXScrollBar", subrole: nil,
            title: nil, value: "0.5"
        ))
    }

    func test_drop_valueIndicatorRole() {
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXValueIndicator", subrole: nil,
            title: nil, value: "1414"
        ))
    }

    func test_drop_labellessSplitGroup() {
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXSplitGroup", subrole: nil,
            title: nil, value: ""
        ))
    }

    func test_drop_labellessToolbar() {
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXToolbar", subrole: nil,
            title: nil, value: ""
        ))
    }

    func test_drop_labellessScrollArea() {
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXScrollArea", subrole: nil,
            title: nil, value: ""
        ))
    }

    // MARK: - R4 — must NOT drop (real content survives)

    func test_keep_buttonWithTitle() {
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXButton", subrole: nil,
            title: "Continue", value: ""
        ))
    }

    func test_keep_buttonWithValue() {
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXButton", subrole: nil,
            title: nil, value: "Send"
        ))
    }

    func test_keep_titledTabGroup() {
        // A titled container is a hint that descendants follow ("tab bar").
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXTabGroup", subrole: nil,
            title: "tab bar", value: ""
        ))
    }

    func test_keep_chromeSubroleWithContent() {
        // Defends against over-aggressive role-based drops.
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXButton", subrole: "AXCloseButton",
            title: "Close Document", value: ""
        ))
    }

    // MARK: - R7 gibberish density — drop

    func test_drop_shortMojibakeWithSymbols() {
        // QuickTime OCR-as-AX: 4 chars, 2 of 4 are symbols.
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXTextArea", subrole: nil,
            title: nil, value: "口》巳@"
        ))
    }

    func test_drop_bulletDigitFragment() {
        // QuickTime artifact "• 0" — 3 chars, mostly symbol/whitespace.
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXTextArea", subrole: nil,
            title: nil, value: "• 0"
        ))
    }

    func test_drop_shortAllSymbols() {
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXTextArea", subrole: nil,
            title: nil, value: "@@"
        ))
    }

    func test_drop_singleSymbol() {
        XCTAssertTrue(AXNoiseFilter.shouldDropNode(
            role: "AXTextArea", subrole: nil,
            title: nil, value: "•"
        ))
    }

    // MARK: - R7 — must NOT drop (real text survives)

    func test_keep_shortCJK() {
        // 公第〇 — 3 ideographs, all `isAlphabetic` per Unicode. Ratio = 0.
        // Critical: would have been wrongly dropped under the original
        // "ratio > 0.5, no length floor" predicate; this test pins the fix.
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXTextArea", subrole: nil,
            title: nil, value: "公第〇"
        ))
    }

    func test_keep_fullCyrillic() {
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXStaticText", subrole: nil,
            title: nil, value: "Привет"
        ))
    }

    func test_keep_fullCJKDocument() {
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXStaticText", subrole: nil,
            title: nil, value: "中文文档"
        ))
    }

    func test_keep_digitsOnly() {
        // Decimals count toward alpha-or-decimal ratio.
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXStaticText", subrole: nil,
            title: nil, value: "123"
        ))
    }

    func test_keep_longStringWithSymbolMix() {
        // Length escape valve: > 8 non-whitespace chars always passes.
        // Catches OCR artifacts that read like garbled menus.
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXStaticText", subrole: nil,
            title: nil, value: "• A G% Mon Mar 23 19:42"
        ))
    }

    func test_keep_longAllSymbols() {
        // Length escape valve fires even when every char is a symbol.
        // Long structured-symbol content (a checksum line, an ASCII
        // separator) is probably real screen content the user might
        // reference.
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXStaticText", subrole: nil,
            title: nil, value: "@@@@@@@@@@"
        ))
    }

    func test_keep_titleRealValueGibberish() {
        // Even if value is gibberish, a real title means the node carries
        // signal — keep.
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXImage", subrole: nil,
            title: "Movies", value: "口》巳@"
        ))
    }

    func test_keep_emptyTitleAndValue() {
        // No content at all — not gibberish; R4 / formatLine fallback
        // handles "nothing to render" separately.
        XCTAssertFalse(AXNoiseFilter.shouldDropNode(
            role: "AXImage", subrole: nil,
            title: nil, value: ""
        ))
    }

    // MARK: - isGibberishDominant — direct unit checks

    func test_gibberish_cjk3CharsKeeps() {
        XCTAssertFalse(AXNoiseFilter.isGibberishDominant("公第〇"))
    }

    func test_gibberish_lengthEscapeValveAt9() {
        // 9 non-whitespace chars → above the floor → never drops.
        XCTAssertFalse(AXNoiseFilter.isGibberishDominant("@@@@@@@@@"))
    }

    func test_gibberish_lengthFloorBoundary() {
        // Exactly at floor (8 chars) and 100% symbols → drops.
        XCTAssertTrue(AXNoiseFilter.isGibberishDominant("@@@@@@@@"))
    }

    func test_gibberish_emptyIsNotDropped() {
        // Empty string is "no signal", not "gibberish-dominant".
        XCTAssertFalse(AXNoiseFilter.isGibberishDominant(""))
    }

    func test_gibberish_whitespaceOnlyIsNotDropped() {
        XCTAssertFalse(AXNoiseFilter.isGibberishDominant("   \t  "))
    }

    // MARK: - R5 viewport scrollback — drop (terminal parent)

    func test_scrollback_dropInTerminalBundle() {
        let longValue = String(repeating: "brew install line one\n", count: 60)
        XCTAssertTrue(AXNoiseFilter.isViewportScrollback(
            role: "AXTextArea",
            value: longValue,
            containingBundleID: "com.apple.Terminal"
        ))
    }

    func test_scrollback_dropInGhostty() {
        let longValue = String(repeating: "kopachev@host ~ % ls\n", count: 60)
        XCTAssertTrue(AXNoiseFilter.isViewportScrollback(
            role: "AXTextArea",
            value: longValue,
            containingBundleID: "com.mitchellh.ghostty"
        ))
    }

    func test_scrollback_dropInITerm() {
        let longValue = String(repeating: "$ git status\nclean\n", count: 60)
        XCTAssertTrue(AXNoiseFilter.isViewportScrollback(
            role: "AXTextArea",
            value: longValue,
            containingBundleID: "com.googlecode.iterm2"
        ))
    }

    // MARK: - R5 — must NOT drop (non-terminal parent or below threshold)

    func test_scrollback_keepInNotes() {
        // Critical regression test: a 6-paragraph 1500-char Notes document
        // hits the same newline/length thresholds as terminal scrollback
        // BUT the parent isn't a terminal — must NOT drop.
        let longValue = String(repeating: "A paragraph of notes content.\n", count: 60)
        XCTAssertFalse(AXNoiseFilter.isViewportScrollback(
            role: "AXTextArea",
            value: longValue,
            containingBundleID: "com.apple.Notes"
        ))
    }

    func test_scrollback_keepInTextEdit() {
        let longValue = String(repeating: "An open spec document line.\n", count: 60)
        XCTAssertFalse(AXNoiseFilter.isViewportScrollback(
            role: "AXTextArea",
            value: longValue,
            containingBundleID: "com.apple.TextEdit"
        ))
    }

    func test_scrollback_keepInBear() {
        let longValue = String(repeating: "A note paragraph.\n", count: 60)
        XCTAssertFalse(AXNoiseFilter.isViewportScrollback(
            role: "AXTextArea",
            value: longValue,
            containingBundleID: "net.shinyfrog.bear"
        ))
    }

    func test_scrollback_keepNilParent() {
        XCTAssertFalse(AXNoiseFilter.isViewportScrollback(
            role: "AXTextArea",
            value: String(repeating: "line\n", count: 60),
            containingBundleID: nil
        ))
    }

    func test_scrollback_keepBelowThreshold() {
        // In a terminal but value is too short / too few newlines.
        XCTAssertFalse(AXNoiseFilter.isViewportScrollback(
            role: "AXTextArea",
            value: "short\nthree\nlines",
            containingBundleID: "com.apple.Terminal"
        ))
    }

    // MARK: - R6 pack collapse — collapses

    func test_packCollapse_24SnapshotPattern() {
        var lines = (1...24).map { i in
            "  - Image \"Снимок экрана 2025-06-02 в 14.\(String(format: "%02d", i)).00\""
        }
        AXNoiseFilter.collapseRepetitivePacks(&lines)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(
            lines[0],
            "  - Image (× 24 items, stem \"Снимок экрана\")"
        )
    }

    func test_packCollapse_englishScreenshotPattern() {
        var lines = (1...12).map { i in
            "  - Image \"Screenshot 2026-05-16 at 17.50.\(String(format: "%02d", i))\""
        }
        AXNoiseFilter.collapseRepetitivePacks(&lines)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(
            lines[0],
            "  - Image (× 12 items, stem \"Screenshot\")"
        )
    }

    func test_packCollapse_sameStemNoDate() {
        // 6 "Untitled Document" Pages files (same title, no trailing
        // variation) collapse on the identical stem.
        var lines = Array(repeating: "  - Image \"Untitled Document\"", count: 6)
        AXNoiseFilter.collapseRepetitivePacks(&lines)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(
            lines[0],
            "  - Image (× 6 items, stem \"Untitled Document\")"
        )
    }

    func test_packCollapse_interlopersPreserved() {
        var lines: [String] = []
        // Run of 7 same-stem.
        for i in 1...7 {
            lines.append("  - Image \"Screenshot 2026-05-16 at 17.50.\(String(format: "%02d", i))\"")
        }
        // Interloper.
        lines.append("  - Button \"Open\"")
        // Another run of 6.
        for i in 1...6 {
            lines.append("  - Image \"Снимок экрана 2026-01-26 в 19.40.\(String(format: "%02d", i))\"")
        }
        AXNoiseFilter.collapseRepetitivePacks(&lines)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "  - Image (× 7 items, stem \"Screenshot\")")
        XCTAssertEqual(lines[1], "  - Button \"Open\"")
        XCTAssertEqual(lines[2], "  - Image (× 6 items, stem \"Снимок экрана\")")
    }

    // MARK: - R6 pack collapse — must NOT collapse (negative regression cases)

    func test_packCollapse_distinctStemSafariTabs() {
        // 6 Safari tabs with different titles — distinct stems, must NOT collapse.
        let lines = [
            "  - RadioButton \"Gmail\"",
            "  - RadioButton \"GitHub\"",
            "  - RadioButton \"Stack Overflow\"",
            "  - RadioButton \"Hacker News\"",
            "  - RadioButton \"Apple Developer\"",
            "  - RadioButton \"Notion\"",
        ]
        var mutable = lines
        AXNoiseFilter.collapseRepetitivePacks(&mutable)
        XCTAssertEqual(mutable, lines)
    }

    func test_packCollapse_distinctStemFinderSidebar() {
        let lines = [
            "  - Image \"Documents\"",
            "  - Image \"Downloads\"",
            "  - Image \"Desktop\"",
            "  - Image \"Music\"",
            "  - Image \"Pictures\"",
            "  - Image \"Movies\"",
        ]
        var mutable = lines
        AXNoiseFilter.collapseRepetitivePacks(&mutable)
        XCTAssertEqual(mutable, lines)
    }

    func test_packCollapse_belowThreshold() {
        // 5 same-stem items — below the ≥6 threshold, must NOT collapse.
        let lines = (1...5).map { i in
            "  - Image \"Screenshot 2026-05-16 at 17.50.\(String(format: "%02d", i))\""
        }
        var mutable = lines
        AXNoiseFilter.collapseRepetitivePacks(&mutable)
        XCTAssertEqual(mutable, lines)
    }

    func test_packCollapse_versionedReleasesNotStripped() {
        // "Release 1.0" / "Release 2.0" — inline version numbers are NOT
        // trailing-date pattern, must NOT strip / NOT collapse.
        let lines = (1...6).map { i in
            "  - Button \"Release \(i).0\""
        }
        var mutable = lines
        AXNoiseFilter.collapseRepetitivePacks(&mutable)
        XCTAssertEqual(mutable, lines)
    }

    func test_packCollapse_valueBearingLinesNotPackable() {
        // Lines with `= value` are deliberately not packable.
        var lines = (1...8).map { i in
            "  - Button \"Country \(i)\" = enabled"
        }
        let original = lines
        AXNoiseFilter.collapseRepetitivePacks(&lines)
        XCTAssertEqual(lines, original)
    }

    func test_packCollapse_emptyArray() {
        var lines: [String] = []
        AXNoiseFilter.collapseRepetitivePacks(&lines)
        XCTAssertEqual(lines, [])
    }

    func test_packCollapse_singleLine() {
        var lines = ["  - Image \"Screenshot 2026-05-16 at 17.50.07\""]
        let original = lines
        AXNoiseFilter.collapseRepetitivePacks(&lines)
        XCTAssertEqual(lines, original)
    }

    // MARK: - stripTrailingTemplateTokens — direct unit checks

    func test_stem_stripsTrailingDate() {
        XCTAssertEqual(
            AXNoiseFilter.stripTrailingTemplateTokens("Screenshot 2026-05-16 at 17.50.07"),
            "Screenshot"
        )
    }

    func test_stem_stripsRussianLocaleDate() {
        XCTAssertEqual(
            AXNoiseFilter.stripTrailingTemplateTokens("Снимок экрана 2026-01-26 в 19.40.53"),
            "Снимок экрана"
        )
    }

    func test_stem_preservesUntitledDocument() {
        XCTAssertEqual(
            AXNoiseFilter.stripTrailingTemplateTokens("Untitled Document"),
            "Untitled Document"
        )
    }

    func test_stem_preservesVersionedNames() {
        // Inline single number is NOT a date — preserve.
        XCTAssertEqual(
            AXNoiseFilter.stripTrailingTemplateTokens("Release 1.0"),
            "Release 1.0"
        )
        XCTAssertEqual(
            AXNoiseFilter.stripTrailingTemplateTokens("Release 2.0"),
            "Release 2.0"
        )
    }

    func test_stem_dotSeparatedDate() {
        XCTAssertEqual(
            AXNoiseFilter.stripTrailingTemplateTokens("Photo 2026.05.16 14.30.00"),
            "Photo"
        )
    }

    func test_stem_slashSeparatedDate() {
        XCTAssertEqual(
            AXNoiseFilter.stripTrailingTemplateTokens("Export 2026/05/16"),
            "Export"
        )
    }

    // MARK: - trailingDateRegex tightening — participant suffix must NOT be stripped

    func test_stem_meetingWithParticipantSuffix_preservesName() {
        // "Meeting 2026-05-18 - Alice" has a date mid-string but the
        // participant name after the date is real signal — must survive
        // in the stem. Regression net for the earlier greedy `.*$` form
        // of the regex.
        XCTAssertEqual(
            AXNoiseFilter.stripTrailingTemplateTokens("Meeting 2026-05-18 - Alice"),
            "Meeting 2026-05-18 - Alice"
        )
    }

    func test_stem_projectWithTopicSuffix_preservesTopic() {
        XCTAssertEqual(
            AXNoiseFilter.stripTrailingTemplateTokens("Project 2026-05-18 - Quarterly Review"),
            "Project 2026-05-18 - Quarterly Review"
        )
    }

    func test_packCollapse_meetingWithParticipantSuffix_doesNotOverStrip() {
        // 6 meeting titles with distinct participants — each retains its
        // ` - Alice` / ` - Bob` suffix in the stem, so the pack does NOT
        // collapse (distinct stems). Regression net: under the earlier
        // greedy `.*$` form of `trailingDateRegex`, all 6 would have
        // collapsed to stem "Meeting".
        let names = ["Alice", "Bob", "Carol", "Dave", "Eve", "Frank"]
        let lines = names.map { name in
            "  - Image \"Meeting 2026-05-18 - \(name)\""
        }
        var mutable = lines
        AXNoiseFilter.collapseRepetitivePacks(&mutable)
        XCTAssertEqual(mutable, lines, "distinct participant suffixes must NOT collapse")
    }
}
