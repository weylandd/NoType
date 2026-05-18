import XCTest
@testable import NoType

/// Pins the pure helpers behind `OutputLanguagePicker`'s row +
/// chip-strip rendering. SwiftUI render is verified via interactive
/// smoke (Settings → System → Output language → Edit) — no snapshot
/// infrastructure in repo yet (mirrors the U1/U6 convention).
///
/// Marked `@MainActor` because `OutputLanguagePicker.subtitle(for:)`
/// and `displayChips(for:)` are static methods on a SwiftUI `View`
/// (implicitly `@MainActor` under Swift 6 strict concurrency).
@MainActor
final class OutputLanguagePickerTests: XCTestCase {

    // MARK: - subtitle(for:)

    func test_subtitle_emptyShowsHintCopy() {
        let s = OutputLanguagePicker.subtitle(for: [])
        XCTAssertTrue(s.contains("Bias Gemini"),
            "empty selection prompts the user; got: \(s)")
    }

    func test_subtitle_nonEmptyShowsEnglishNamesCommaSeparated() {
        let s = OutputLanguagePicker.subtitle(for: ["en", "ru"])
        XCTAssertTrue(s.contains("English"))
        XCTAssertTrue(s.contains("Russian"))
        XCTAssertTrue(s.contains("English, Russian"),
            "expected `English, Russian` ordering in subtitle; got: \(s)")
    }

    func test_subtitle_unknownCodeFallsBackToBareCode() {
        // A user-saved code we don't recognise (e.g. dropped from the
        // bundle in a future trim) should still render — picker
        // shouldn't silently drop a chip the user wanted.
        let s = OutputLanguagePicker.subtitle(for: ["zz-unknown"])
        XCTAssertTrue(s.contains("zz-unknown"))
    }

    // MARK: - displayChips(for:)

    func test_displayChips_resolvesKnownCodesToNativeName() {
        let chips = OutputLanguagePicker.displayChips(for: ["ru", "ja"])
        XCTAssertEqual(chips.count, 2)
        XCTAssertEqual(chips[0].code, "ru")
        XCTAssertEqual(chips[0].label, "Русский")
        XCTAssertEqual(chips[1].code, "ja")
        XCTAssertEqual(chips[1].label, "日本語")
    }

    func test_displayChips_unknownCodeFallsBackToBareCode() {
        let chips = OutputLanguagePicker.displayChips(for: ["zz-unknown"])
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(chips[0].code, "zz-unknown")
        XCTAssertEqual(chips[0].label, "zz-unknown",
            "unknown code must surface verbatim so the user can still remove it")
    }

    func test_displayChips_preservesOrder() {
        let chips = OutputLanguagePicker.displayChips(for: ["ja", "ru", "en"])
        XCTAssertEqual(chips.map { $0.code }, ["ja", "ru", "en"],
            "chip strip must mirror the saved order (newest-first per AppState.outputLanguages append semantics)")
    }
}
