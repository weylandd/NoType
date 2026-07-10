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

    // MARK: - Punctuation-bounded `from` (U5 / R5)

    func test_punctuationFrom_dottedAbbreviation_englishReplaces() {
        // `e.g.` starts+ends with a boundary that ICU `\b` mis-anchors.
        // The look-around matches it at real word boundaries.
        let out = TextReplacementEngine.apply(
            "use e.g. this",
            replacements: [pair("e.g.", "for example")]
        )
        XCTAssertEqual(out, "use for example this")
    }

    func test_punctuationFrom_dottedAbbreviation_russianReplaces() {
        let out = TextReplacementEngine.apply(
            "Короче, т.е. дальше.",
            replacements: [pair("т.е.", "то есть")]
        )
        XCTAssertEqual(out, "Короче, то есть дальше.")
    }

    func test_punctuationFrom_leadingDot_replacesAtBoundary() {
        // `.com` leads with punctuation. Matches only at a real boundary
        // (preceded by non-letter), never glued inside `example.com`.
        let out = TextReplacementEngine.apply(
            "buy a .com domain",
            replacements: [pair(".com", "dot com")]
        )
        XCTAssertEqual(out, "buy a dot com domain")
    }

    func test_punctuationFrom_leadingDot_doesNotMatchInsideWord() {
        // `.com` must NOT fire inside `example.com` — the char before
        // the dot is a letter, so the look-behind blocks it.
        let out = TextReplacementEngine.apply(
            "visit example.com today",
            replacements: [pair(".com", "dot com")]
        )
        XCTAssertEqual(out, "visit example.com today")
    }

    func test_punctuationFrom_leadingHash_replaces() {
        // `#tag` leads with `#` (a non-word char). First char is not a
        // lowercase letter, so no auto-cap variant is generated.
        let out = TextReplacementEngine.apply(
            "use #tag here",
            replacements: [pair("#tag", "hashtag")]
        )
        XCTAssertEqual(out, "use hashtag here")
    }

    func test_punctuationFrom_trailingHash_replaces() {
        // `c#` ends with `#`. Matches at boundary; must not fire inside
        // `abc#def`.
        let out = TextReplacementEngine.apply(
            "code in c# today, not abc#def",
            replacements: [pair("c#", "c sharp")]
        )
        XCTAssertEqual(out, "code in c sharp today, not abc#def")
    }

    func test_punctuationFrom_autoCap_dottedAbbreviationReplaces() {
        // Auto-capitalized variant `E.g.` fires from a lowercase `e.g.`
        // pair, capitalizing the first char of both sides.
        let out = TextReplacementEngine.apply(
            "E.g. this works",
            replacements: [pair("e.g.", "for example")]
        )
        XCTAssertEqual(out, "For example this works")
    }

    func test_punctuationFrom_doesNotOverMatch_dottedInsideToken() {
        // Regression: `e.g.` must NOT fire inside `beg.example` — the
        // look-around anchors at real boundaries only.
        let out = TextReplacementEngine.apply(
            "beg.example works",
            replacements: [pair("e.g.", "for example")]
        )
        XCTAssertEqual(out, "beg.example works")
    }

    func test_punctuationFrom_wordCharBoundedPairStillReplaces() {
        // Regression: an ordinary word-char-bounded pair still replaces
        // and still respects boundaries (does not fire inside `кто есть`).
        let replaced = TextReplacementEngine.apply(
            "то есть, продолжаем.",
            replacements: [pair("то есть", "т.е.")]
        )
        XCTAssertEqual(replaced, "т.е., продолжаем.")

        let notMatched = TextReplacementEngine.apply(
            "Кто есть кто.",
            replacements: [pair("то есть", "т.е.")]
        )
        XCTAssertEqual(notMatched, "Кто есть кто.")
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
