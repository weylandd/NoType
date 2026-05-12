import XCTest
@testable import NoType

/// Pins `TextReplacementEngine.apply` — the deterministic, client-side
/// find/replace pass run between `finalizeForInsertion` and `paste`.
///
/// Required cases (per ADR-016):
/// - Whole-word matching: phrase like "то есть" must NOT match inside "кто есть".
/// - Auto-capitalized variant when `from` starts lowercase.
/// - All-caps variant is intentionally NOT matched (only first-letter capitalized).
/// - No cascading between pairs (each pair sees prior-pair output, but
///   the regex is one-shot per pair — no recursive re-scan).
/// - Empty inputs are no-ops.
/// - Idempotent over already-replaced text.
final class TextReplacementEngineTests: XCTestCase {

    private func pair(_ from: String, _ to: String) -> DictionaryReplacement {
        DictionaryReplacement(from: from, to: to, createdAt: Date())
    }

    // MARK: - Word boundary

    func test_wordBoundary_matchesStandalonePhrase() {
        let out = TextReplacementEngine.apply(
            "Короче, то есть, продолжаем.",
            replacements: [pair("то есть", "т.е.")]
        )
        XCTAssertEqual(out, "Короче, т.е., продолжаем.")
    }

    func test_wordBoundary_doesNotMatchInsideAnotherWord() {
        // "кто есть" starts with 'к' so the 'то' inside is NOT at a
        // word boundary — regex must not match.
        let out = TextReplacementEngine.apply(
            "Кто есть кто, не важно.",
            replacements: [pair("то есть", "т.е.")]
        )
        XCTAssertEqual(out, "Кто есть кто, не важно.")
    }

    func test_wordBoundary_punctuationAdjacent_stillMatches() {
        let out = TextReplacementEngine.apply(
            "(то есть)",
            replacements: [pair("то есть", "т.е.")]
        )
        XCTAssertEqual(out, "(т.е.)")
    }

    // MARK: - Auto-capitalization

    func test_autoCap_capitalizedFirstLetterMatches() {
        let out = TextReplacementEngine.apply(
            "То есть, всё ясно.",
            replacements: [pair("то есть", "т.е.")]
        )
        XCTAssertEqual(out, "Т.е., всё ясно.",
            "lowercase-starting pair auto-generates a capitalized variant")
    }

    func test_autoCap_allCapsNotMatched() {
        // Only the first-letter-capitalized variant is auto-generated.
        // Caps-lock case stays untouched.
        let out = TextReplacementEngine.apply(
            "ТО ЕСТЬ всё это шум.",
            replacements: [pair("то есть", "т.е.")]
        )
        XCTAssertEqual(out, "ТО ЕСТЬ всё это шум.")
    }

    func test_autoCap_notGenerated_whenFromAlreadyCapitalized() {
        // From starts uppercase → no auto-generated variant. Lowercase
        // standalone must NOT be replaced.
        let out = TextReplacementEngine.apply(
            "Слово ChatGPT, слово chatgpt.",
            replacements: [pair("ChatGPT", "GPT")]
        )
        XCTAssertEqual(out, "Слово GPT, слово chatgpt.",
            "uppercase-starting from leaves lowercase variant untouched")
    }

    // MARK: - Cascading / overlap

    func test_pairsApplyInOrder() {
        // Two unrelated pairs both fire.
        let out = TextReplacementEngine.apply(
            "ML и AI, то есть нейросети.",
            replacements: [
                pair("ML", "machine learning"),
                pair("AI", "artificial intelligence"),
            ]
        )
        XCTAssertEqual(out, "machine learning и artificial intelligence, то есть нейросети.")
    }

    // MARK: - Empty / idempotent

    func test_emptyReplacements_returnsTextVerbatim() {
        let out = TextReplacementEngine.apply("hello world", replacements: [])
        XCTAssertEqual(out, "hello world")
    }

    func test_emptyText_returnsEmpty() {
        let out = TextReplacementEngine.apply("", replacements: [pair("a", "b")])
        XCTAssertEqual(out, "")
    }

    func test_idempotent_secondPassChangesNothing() {
        let pairs = [pair("то есть", "т.е.")]
        let once = TextReplacementEngine.apply("Что ж, то есть мы готовы.", replacements: pairs)
        let twice = TextReplacementEngine.apply(once, replacements: pairs)
        XCTAssertEqual(once, twice,
            "applying the same pairs twice produces the same output")
    }

    // MARK: - Regex special characters

    func test_regexSpecialCharsInFrom_areEscaped() {
        // Dots in `from` are literal, not "any character".
        let out = TextReplacementEngine.apply(
            "Visit www.example.com today",
            replacements: [pair("www.example.com", "example.com")]
        )
        XCTAssertEqual(out, "Visit example.com today")
    }

    func test_regexSpecialCharsInTo_areLiterallyEmitted() {
        // `to` containing $ shouldn't be interpreted as a regex capture.
        let out = TextReplacementEngine.apply(
            "amount is dollars",
            replacements: [pair("dollars", "$100")]
        )
        XCTAssertEqual(out, "amount is $100")
    }
}
