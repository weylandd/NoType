import XCTest
@testable import NoType

/// Pins `DictionaryHarvester` — the pure-function replacement for the
/// old LLM extractor. Covers tokenization, shape filtering, multi-word
/// longest-match priority, case preservation, and existing-dedup.
final class DictionaryHarvesterTests: XCTestCase {

    // MARK: - Shape filter

    func test_shape_acceptsCapitalized() {
        XCTAssertTrue(DictionaryHarvester.passesShape("Anthropic"))
        XCTAssertTrue(DictionaryHarvester.passesShape("Вася"))
    }

    func test_shape_acceptsMixedCase() {
        XCTAssertTrue(DictionaryHarvester.passesShape("iOS"))
        XCTAssertTrue(DictionaryHarvester.passesShape("gRPC"))
        XCTAssertTrue(DictionaryHarvester.passesShape("NoType"))
    }

    func test_shape_acceptsAllCaps() {
        XCTAssertTrue(DictionaryHarvester.passesShape("NASA"))
        XCTAssertTrue(DictionaryHarvester.passesShape("JSON"))
    }

    func test_shape_acceptsAtypicalSymbols() {
        XCTAssertTrue(DictionaryHarvester.passesShape("claude.md"))
        XCTAssertTrue(DictionaryHarvester.passesShape("generate_keys"))
        XCTAssertTrue(DictionaryHarvester.passesShape("bin/python"))
        XCTAssertTrue(DictionaryHarvester.passesShape("bin/"))
        XCTAssertTrue(DictionaryHarvester.passesShape("state-of-the-art"))
    }

    func test_shape_rejectsLowercasePlainWord() {
        XCTAssertFalse(DictionaryHarvester.passesShape("hello"))
        XCTAssertFalse(DictionaryHarvester.passesShape("привет"))
        XCTAssertFalse(DictionaryHarvester.passesShape("send"))
    }

    func test_shape_rejectsPureDigitsOrSymbols() {
        XCTAssertFalse(DictionaryHarvester.passesShape("12345"))
        XCTAssertFalse(DictionaryHarvester.passesShape("___"))
        XCTAssertFalse(DictionaryHarvester.passesShape("-_/"))
    }

    // MARK: - Tokenization

    func test_tokenize_dropsTrailingSentencePeriod() {
        let toks = DictionaryHarvester.tokenize("I love Anthropic.")
        XCTAssertEqual(toks, ["I", "love", "Anthropic"])
    }

    func test_tokenize_keepsInternalPeriod() {
        let toks = DictionaryHarvester.tokenize("See claude.md for details.")
        XCTAssertEqual(toks, ["See", "claude.md", "for", "details"])
    }

    func test_tokenize_keepsTrailingBinders() {
        // Slash/dash/underscore at the end are structural ("bin/", "_priv"),
        // not punctuation. Keep them.
        let toks = DictionaryHarvester.tokenize("Open bin/ first")
        XCTAssertEqual(toks, ["Open", "bin/", "first"])
    }

    func test_tokenize_underscoreInside() {
        let toks = DictionaryHarvester.tokenize("Use generate_keys today")
        XCTAssertEqual(toks, ["Use", "generate_keys", "today"])
    }

    func test_tokenize_splitsOnPunctuation() {
        let toks = DictionaryHarvester.tokenize("Hello, World! And Вася?")
        XCTAssertEqual(toks, ["Hello", "World", "And", "Вася"])
    }

    func test_tokenize_dropsPureDigits() {
        // "2024" alone has no letters → discarded by the
        // contains-letter post-filter.
        let toks = DictionaryHarvester.tokenize("Year 2024 release")
        XCTAssertEqual(toks, ["Year", "release"])
    }

    // MARK: - Single-word harvest

    func test_harvest_singleProperNoun_caseFromContext() {
        let transcript = "shipping to anthropic tomorrow"
        let context    = "Slack: Anthropic Inc - your invite"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["Anthropic"])
    }

    func test_harvest_skipsWordNotInContext() {
        let transcript = "I love OpenAI today"
        let context    = "Anthropic dashboard - nothing else here"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        // "OpenAI" passes shape filter but is NOT in context → dropped.
        XCTAssertEqual(words, [])
    }

    func test_harvest_skipsLowercaseEvenIfInContext() {
        let transcript = "send the message"
        // "send" is on screen as a button label, but doesn't pass shape
        // (lowercase, no symbol). Confirms shape filter blocks UI chrome.
        let context    = "Button: send"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, [])
    }

    // MARK: - Multi-word harvest

    func test_harvest_multiWord_longestMatchWins() {
        // Both "GitHub" and "GitHub releases" pass shape (GitHub is the
        // trigger). Context has the full 2-span. Longest match wins,
        // "releases" is consumed.
        let transcript = "check GitHub releases page"
        let context    = "Tab: GitHub releases for the project"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["GitHub releases"])
    }

    func test_harvest_multiWord_falsBack_to_singleWord() {
        // Trigger "GitHub" passes shape. The 2-span "GitHub features"
        // is NOT in context, so the harvester falls back to the 1-span
        // "GitHub" alone.
        let transcript = "browsing GitHub features today"
        let context    = "Window: GitHub home for user"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["GitHub"])
    }

    func test_harvest_personName_threeWords() {
        let transcript = "пиши вася пупкин завтра позвонит"
        let context    = "Recipient: Вася Пупкин — manager"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["Вася Пупкин"])
    }

    // MARK: - Dedup

    func test_harvest_excludesExistingEntries_caseInsensitive() {
        let transcript = "shipping to Anthropic tomorrow"
        let context    = "Slack: Anthropic Inc - your invite"
        let words = DictionaryHarvester.harvest(
            transcript: transcript,
            context: context,
            existing: ["anthropic"] // lowercase existing — still dedups
        )
        XCTAssertEqual(words, [])
    }

    func test_harvest_dedupsWithinSameSession() {
        // "NoType" appears twice in the transcript. We should save it
        // once, not twice.
        let transcript = "Open NoType then close NoType and reopen NoType"
        let context    = "App: NoType — push to talk"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["NoType"])
    }

    // MARK: - Caps

    func test_harvest_capsAtMaxCandidates() {
        // 7 distinct proper nouns, all in context.
        let nouns = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf"]
        let transcript = nouns.joined(separator: " then ")
        let context    = nouns.joined(separator: ", ")
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words.count, DictionaryHarvester.maxCandidates,
            "must cap at maxCandidates per session")
        // Order preserved — first N words from the transcript.
        XCTAssertEqual(words, Array(nouns.prefix(DictionaryHarvester.maxCandidates)))
    }

    func test_harvest_rejectsBeyondSanityLength() {
        // Single token in context that exceeds the sanity cap.
        let long = String(repeating: "X", count: DictionaryHarvester.sanityMaxLength + 1)
        let transcript = "send \(long.lowercased()) please"
        let context    = "Window: \(long)"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, [],
            "single tokens past sanityMaxLength must be dropped")
    }

    func test_harvest_singleLetterTokensRejected() {
        // "I" passes shape (uppercase first letter) but is too short
        // for minSingleTokenLength.
        let transcript = "I went home"
        let context    = "I I I I I — placeholder line"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, [])
    }

    // MARK: - Atypical-symbol matching

    func test_harvest_filepathWithSlash() {
        let transcript = "run bin/python now"
        let context    = "Terminal: ./bin/python script.py"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["bin/python"])
    }

    func test_harvest_filenameWithDot() {
        let transcript = "open claude.md and read it"
        let context    = "Editor: claude.md (modified)"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["claude.md"])
    }

    // MARK: - Empty inputs

    func test_harvest_emptyTranscript() {
        XCTAssertEqual(
            DictionaryHarvester.harvest(transcript: "", context: "Anthropic here", existing: []),
            []
        )
    }

    func test_harvest_emptyContext() {
        XCTAssertEqual(
            DictionaryHarvester.harvest(transcript: "Hello Anthropic", context: "", existing: []),
            []
        )
    }
}
