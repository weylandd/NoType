import XCTest
@testable import NoType

/// Pins `InsertionTarget.slice(value:cursor:)` — the pure UTF-16 trimming
/// + value-content scrubbing that runs after the AX value is read in
/// `captureSync`. The AX-bound parts (focused element lookup, secure-role
/// skip) are not unit-testable; those are covered manually in the staging
/// build. Here we cover the pure logic.
final class InsertionTargetTests: XCTestCase {

    // MARK: - Cursor placement

    func test_cursorAtEnd_beforeFilled_afterEmpty() {
        let value = "Hi Sarah, thanks for the update"
        let t = InsertionTarget.slice(value: value, cursor: value.utf16.count)
        XCTAssertEqual(t.textBefore, "Hi Sarah, thanks for the update")
        XCTAssertEqual(t.textAfter, "")
    }

    func test_cursorAtStart_beforeEmpty_afterFilled() {
        let value = "Hi Sarah"
        let t = InsertionTarget.slice(value: value, cursor: 0)
        XCTAssertEqual(t.textBefore, "")
        XCTAssertEqual(t.textAfter, "Hi Sarah")
    }

    func test_cursorInMiddle_bothSidesFilled() {
        // "Hello, |world" — cursor between comma+space and "w".
        let value = "Hello, world"
        let t = InsertionTarget.slice(value: value, cursor: 7)
        XCTAssertEqual(t.textBefore, "Hello, ")
        XCTAssertEqual(t.textAfter, "world")
    }

    func test_negativeCursor_clampedToZero() {
        let value = "Hello"
        let t = InsertionTarget.slice(value: value, cursor: -100)
        XCTAssertEqual(t.textBefore, "")
        XCTAssertEqual(t.textAfter, "Hello")
    }

    func test_cursorBeyondEnd_clampedToTotal() {
        let value = "Hello"
        let t = InsertionTarget.slice(value: value, cursor: 9999)
        XCTAssertEqual(t.textBefore, "Hello")
        XCTAssertEqual(t.textAfter, "")
    }

    func test_emptyValue_bothSidesEmpty() {
        let t = InsertionTarget.slice(value: "", cursor: 0)
        XCTAssertEqual(t.textBefore, "")
        XCTAssertEqual(t.textAfter, "")
    }

    // MARK: - maxSide trimming (cache budget)

    func test_longTextBefore_trimmedToMaxSide() {
        // 1000 'a' chars before a known marker; cursor right after.
        let prefix = String(repeating: "a", count: 1000)
        let value = prefix + "MARK"
        let cursor = value.utf16.count
        let t = InsertionTarget.slice(value: value, cursor: cursor, maxSide: 500)
        XCTAssertEqual(t.textBefore.count, 500)
        XCTAssertTrue(t.textBefore.hasSuffix("aMARK") || t.textBefore.hasSuffix("MARK"))
        XCTAssertEqual(t.textAfter, "")
    }

    func test_longTextAfter_trimmedToMaxSide() {
        let value = "MARK" + String(repeating: "a", count: 1000)
        let t = InsertionTarget.slice(value: value, cursor: 0, maxSide: 500)
        XCTAssertEqual(t.textBefore, "")
        XCTAssertEqual(t.textAfter.count, 500)
        XCTAssertTrue(t.textAfter.hasPrefix("MARK"))
    }

    func test_bothSidesLong_eachClampedIndependently() {
        let left = String(repeating: "L", count: 1000)
        let right = String(repeating: "R", count: 1000)
        let value = left + right
        let t = InsertionTarget.slice(value: value, cursor: left.utf16.count, maxSide: 200)
        XCTAssertEqual(t.textBefore.count, 200)
        XCTAssertEqual(t.textAfter.count, 200)
        XCTAssertEqual(t.textBefore, String(repeating: "L", count: 200))
        XCTAssertEqual(t.textAfter, String(repeating: "R", count: 200))
    }

    // MARK: - Unicode / surrogate boundaries

    func test_emojiInValue_doesNotCrash() {
        // 👋 is a surrogate pair in UTF-16. Slice cursor right after the
        // emoji (UTF-16 offset = 2) — should not crash and should give
        // sensible output.
        let value = "👋 hello"
        let t = InsertionTarget.slice(value: value, cursor: 2)
        XCTAssertEqual(t.textBefore, "👋")
        XCTAssertEqual(t.textAfter, " hello")
    }

    func test_emojiCutMidSurrogate_lossyButNoCrash() {
        // Cursor in the middle of a surrogate pair (UTF-16 offset 1, after
        // the high surrogate of 👋). The slice falls back to a lossy
        // decode that replaces the unpaired surrogate with U+FFFD; we
        // assert that the call succeeds and produces something non-empty.
        let value = "👋 hi"
        let t = InsertionTarget.slice(value: value, cursor: 1)
        XCTAssertFalse(t.textBefore.isEmpty || t.textAfter.isEmpty)
    }

    func test_combiningCharacters_arePreserved() {
        let value = "café"  // "cafe" + combining acute? Most likely precomposed é
        let t = InsertionTarget.slice(value: value, cursor: value.utf16.count)
        XCTAssertEqual(t.textBefore, "café")
    }

    // MARK: - SecureFieldMasker integration

    func test_creditCardInTextBefore_isMasked() {
        // 4111 1111 1111 1111 is a valid Luhn test card.
        let value = "Card: 4111 1111 1111 1111 — please charge"
        let t = InsertionTarget.slice(value: value, cursor: value.utf16.count)
        XCTAssertFalse(t.textBefore.contains("4111 1111 1111 1111"))
        XCTAssertTrue(t.textBefore.contains("[REDACTED"))
    }

    func test_stripeKeyInTextAfter_isMasked() {
        let stripe = "sk_live_abcdefghijklmnop"
        let value = "Use " + stripe + " to charge."
        let t = InsertionTarget.slice(value: value, cursor: 4)
        XCTAssertFalse(t.textAfter.contains(stripe))
        XCTAssertTrue(t.textAfter.contains("[REDACTED"))
    }

    func test_normalText_isNotMasked() {
        let value = "Just a normal sentence with no secrets."
        let t = InsertionTarget.slice(value: value, cursor: value.utf16.count)
        XCTAssertEqual(t.textBefore, value)
        XCTAssertFalse(t.textBefore.contains("[REDACTED"))
    }

    // MARK: - Empty struct / sentinel

    func test_emptyStaticIsEmpty() {
        XCTAssertEqual(InsertionTarget.empty.textBefore, "")
        XCTAssertEqual(InsertionTarget.empty.textAfter, "")
    }

    // MARK: - Scrollback-shape detection (terminals not in known-bundles list)

    func test_looksLikeScrollback_terminalShape_isTrue() {
        // 6 lines of code-shaped content, well over 1000 chars, role
        // AXTextArea — the typical terminal scrollback signature.
        let line = String(repeating: "abc 123 ", count: 30)
        let value = (0..<6).map { _ in line }.joined(separator: "\n")
        XCTAssertTrue(value.utf16.count > 1000, "fixture must exceed length threshold")
        XCTAssertTrue(InsertionTarget.looksLikeScrollback(value: value, role: "AXTextArea"))
    }

    func test_looksLikeScrollback_shortMultiLine_isFalse() {
        // Multi-line note-style content but under length threshold — a
        // legitimate compose box, NOT scrollback.
        let value = """
        Hello team,

        I'd like to discuss a few items.
        Let me know what works best.

        Thanks.
        """
        XCTAssertFalse(InsertionTarget.looksLikeScrollback(value: value, role: "AXTextArea"))
    }

    func test_looksLikeScrollback_singleLineLong_isFalse() {
        // 5000-char single-line URL or token — long but no newlines, so
        // not scrollback (and a real text field could legit hold this).
        let value = String(repeating: "x", count: 5000)
        XCTAssertFalse(InsertionTarget.looksLikeScrollback(value: value, role: "AXTextArea"))
    }

    func test_looksLikeScrollback_textFieldRole_isFalse() {
        // Even if the content shape matches, a single-line `AXTextField`
        // is by definition not a scrollback viewport.
        let line = String(repeating: "abc 123 ", count: 30)
        let value = (0..<6).map { _ in line }.joined(separator: "\n")
        XCTAssertFalse(InsertionTarget.looksLikeScrollback(value: value, role: "AXTextField"))
    }

    func test_looksLikeScrollback_emptyValue_isFalse() {
        XCTAssertFalse(InsertionTarget.looksLikeScrollback(value: "", role: "AXTextArea"))
    }
}
