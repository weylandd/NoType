import XCTest
@testable import NoType

/// Pins `DictionaryHarvester` — the pure-function replacement for the
/// old LLM extractor. Covers tokenization, shape filtering, multi-word
/// longest-match priority, case preservation, and existing-dedup.
final class DictionaryHarvesterTests: XCTestCase {

    // MARK: - Shape filter

    func test_shape_rejectsFirstCapOnlySingleToken() {
        // Single tokens whose only capital is at index 0 are
        // indistinguishable from sentence-start chrome words (`Вот`,
        // `Так`, `Для`) — past dictionaries got polluted with them.
        // Real proper nouns like `Anthropic`, `Slack`, `Apple` are also
        // rejected as standalones; users add them via the textfield.
        // They still ride through as part of multi-word phrases (see
        // `test_shape_acceptsInternalCapital_inMultiWord`).
        XCTAssertFalse(DictionaryHarvester.passesShape("Anthropic"))
        XCTAssertFalse(DictionaryHarvester.passesShape("Slack"))
        XCTAssertFalse(DictionaryHarvester.passesShape("Apple"))
        XCTAssertFalse(DictionaryHarvester.passesShape("Вася"))
        XCTAssertFalse(DictionaryHarvester.passesShape("Вот"))
        XCTAssertFalse(DictionaryHarvester.passesShape("Так"))
        XCTAssertFalse(DictionaryHarvester.passesShape("Для"))
    }

    func test_shape_rejectsFirstCapPlusLowercaseFiller_multiWord() {
        // Same pattern surfacing as multi-word: `Для этого`, `Вот это`.
        // Only the leading capital exists; rest of the joined string is
        // lowercase → rejects. Symmetric loss of `Anthropic news` /
        // `Slack команде` is accepted (no internal upper after position
        // 0); user adds those manually.
        XCTAssertFalse(DictionaryHarvester.passesShape("Для этого"))
        XCTAssertFalse(DictionaryHarvester.passesShape("Вот это"))
        XCTAssertFalse(DictionaryHarvester.passesShape("Anthropic news"))
    }

    func test_shape_acceptsInternalCapital_inMultiWord() {
        // Brand-bearing multi-word collocations: the second/later
        // word's first cap is at an "internal" position of the joined
        // string. Catches person names and product names.
        XCTAssertTrue(DictionaryHarvester.passesShape("Вася Пупкин"))
        XCTAssertTrue(DictionaryHarvester.passesShape("Apple iPhone"))
        XCTAssertTrue(DictionaryHarvester.passesShape("Anthropic Inc"))
        XCTAssertTrue(DictionaryHarvester.passesShape("Slack Microsoft"))
    }

    func test_shape_acceptsMixedCase() {
        XCTAssertTrue(DictionaryHarvester.passesShape("iOS"))
        XCTAssertTrue(DictionaryHarvester.passesShape("gRPC"))
        XCTAssertTrue(DictionaryHarvester.passesShape("NoType"))
        XCTAssertTrue(DictionaryHarvester.passesShape("iPhone"))
    }

    func test_shape_acceptsAllCaps() {
        // All-caps tokens have uppercase at positions ≥ 1, so internal
        // cap rule fires. `UI` (2 chars) also passes shape but is
        // filtered by minSingleTokenLength = 3 at the harvest level.
        XCTAssertTrue(DictionaryHarvester.passesShape("NASA"))
        XCTAssertTrue(DictionaryHarvester.passesShape("JSON"))
    }

    func test_shape_acceptsSpecialBinders() {
        // Slash, underscore, asterisk, hash, dollar — non-prose
        // signals that survive any case.
        XCTAssertTrue(DictionaryHarvester.passesShape("bin/python"))
        XCTAssertTrue(DictionaryHarvester.passesShape("bin/"))
        XCTAssertTrue(DictionaryHarvester.passesShape("generate_keys"))
        XCTAssertTrue(DictionaryHarvester.passesShape("*.swift"))
        XCTAssertTrue(DictionaryHarvester.passesShape("#engineering"))
        XCTAssertTrue(DictionaryHarvester.passesShape("$variable"))
    }

    func test_shape_rejectsHyphenOnlyTokens() {
        // Hyphen is too common in prose (`что-то`, `state-of-the-art`,
        // `well-known`) to be a standalone trigger. These reject unless
        // they ALSO carry another signal.
        XCTAssertFalse(DictionaryHarvester.passesShape("что-то"))
        XCTAssertFalse(DictionaryHarvester.passesShape("какой-то"))
        XCTAssertFalse(DictionaryHarvester.passesShape("какие-то"))
        XCTAssertFalse(DictionaryHarvester.passesShape("state-of-the-art"))
        XCTAssertFalse(DictionaryHarvester.passesShape("well-known"))
    }

    func test_shape_acceptsDotInLongTokens() {
        // Dot is accepted only for filename / domain-like tokens
        // (length ≥ 6). Short abbreviations (`T.e`, `e.g.`) reject.
        XCTAssertTrue(DictionaryHarvester.passesShape("claude.md"))
        XCTAssertTrue(DictionaryHarvester.passesShape("react.dev"))
        XCTAssertTrue(DictionaryHarvester.passesShape("app.notype"))
    }

    func test_shape_rejectsShortDotAbbreviations() {
        // `T.e`, `e.g.`, `и.т.д` — too short, would surface as noise.
        XCTAssertFalse(DictionaryHarvester.passesShape("T.e"))
        XCTAssertFalse(DictionaryHarvester.passesShape("e.g."))
        XCTAssertFalse(DictionaryHarvester.passesShape("т.е."))
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

    func test_shape_acceptsLowercaseLettersWithDigits() {
        // Code / version / model names like `h264`, `mp4`, `version1`
        // have no uppercase or special binder but the digit signals
        // they're not pure prose. Accepted via rule (b).
        XCTAssertTrue(DictionaryHarvester.passesShape("h264"))
        XCTAssertTrue(DictionaryHarvester.passesShape("mp4"))
        XCTAssertTrue(DictionaryHarvester.passesShape("version1"))
    }

    // MARK: - Tokenization

    func test_tokenize_dropsTrailingSentencePeriod() {
        let toks = DictionaryHarvester.tokenizeText("I love Anthropic.")
        XCTAssertEqual(toks, ["I", "love", "Anthropic"])
    }

    func test_tokenize_keepsInternalPeriod() {
        let toks = DictionaryHarvester.tokenizeText("See claude.md for details.")
        XCTAssertEqual(toks, ["See", "claude.md", "for", "details"])
    }

    func test_tokenize_keepsTrailingBinders() {
        // Slash/dash/underscore at the end are structural ("bin/", "_priv"),
        // not punctuation. Keep them.
        let toks = DictionaryHarvester.tokenizeText("Open bin/ first")
        XCTAssertEqual(toks, ["Open", "bin/", "first"])
    }

    func test_tokenize_underscoreInside() {
        let toks = DictionaryHarvester.tokenizeText("Use generate_keys today")
        XCTAssertEqual(toks, ["Use", "generate_keys", "today"])
    }

    func test_tokenize_splitsOnPunctuation() {
        let toks = DictionaryHarvester.tokenizeText("Hello, World! And Вася?")
        XCTAssertEqual(toks, ["Hello", "World", "And", "Вася"])
    }

    func test_tokenize_keepsPureDigitTokens_forMultiWordSpans() {
        // Pure-digit runs ARE kept as tokens so multi-word phrases like
        // `iPhone 10` can match as a 2-span. The shape filter rejects
        // them as standalone candidates (`passesShape("2024")` returns
        // false — no letter), so they never become single-token entries
        // on their own.
        let toks = DictionaryHarvester.tokenizeText("Year 2024 release")
        XCTAssertEqual(toks, ["Year", "2024", "release"])
    }

    func test_tokenize_dropsPureBinderRuns() {
        // A run that's only binders ("___", "----") has neither letter
        // nor digit — gets discarded.
        let toks = DictionaryHarvester.tokenizeText("hello ___ world ---- end")
        XCTAssertEqual(toks, ["hello", "world", "end"])
    }

    // MARK: - Sentence-start tracking

    func test_tokenize_marksFirstTokenAsSentenceStart() {
        // Implicit beginning-of-string is a sentence boundary; first
        // token is sentence-start, the rest mid-sentence.
        let toks = DictionaryHarvester.tokenize("Anthropic выпустила Claude")
        XCTAssertEqual(toks.map { $0.isSentenceStart }, [true, false, false])
    }

    func test_tokenize_marksAfterPeriodAsSentenceStart() {
        // After `. ` the next token resets to sentence-start; after a
        // comma it does not.
        let toks = DictionaryHarvester.tokenize("Hello world. Anthropic, Slack")
        let pairs = toks.map { ($0.text, $0.isSentenceStart) }
        XCTAssertEqual(pairs.map { $0.0 }, ["Hello", "world", "Anthropic", "Slack"])
        XCTAssertEqual(pairs.map { $0.1 }, [true, false, true, false])
    }

    func test_tokenize_marksAfterQuestionAndExclamation() {
        let toks = DictionaryHarvester.tokenize("Привет! Вася? Иван")
        XCTAssertEqual(toks.map { $0.isSentenceStart }, [true, true, true])
    }

    func test_tokenize_marksAfterColonAsSentenceStart() {
        // UI labels — `Label: Value` — must mark Value as sentence-
        // start, otherwise the harvester treats UI chrome as
        // mid-sentence proper nouns.
        let toks = DictionaryHarvester.tokenize("Header: Anthropic news")
        let pairs = toks.map { ($0.text, $0.isSentenceStart) }
        XCTAssertEqual(pairs.map { $0.0 }, ["Header", "Anthropic", "news"])
        XCTAssertEqual(pairs.map { $0.1 }, [true, true, false])
    }

    func test_tokenize_marksAfterNewlineAsSentenceStart() {
        let toks = DictionaryHarvester.tokenize("Hello world\nAnthropic news")
        let pairs = toks.map { ($0.text, $0.isSentenceStart) }
        XCTAssertEqual(pairs.map { $0.0 }, ["Hello", "world", "Anthropic", "news"])
        XCTAssertEqual(pairs.map { $0.1 }, [true, false, true, false])
    }

    func test_tokenize_internalAbbreviationDoesNotResetFlag() {
        // `т.е.` tokenizes as `т.е` (trailing dot dropped). The next
        // token comes after the trailing dot, which DOES reset the
        // flag — Russian sentences often continue past `т.е.` but
        // we accept the false-positive (lowercase next-words won't
        // be triggers anyway).
        let toks = DictionaryHarvester.tokenize("Прости т.е. это означает X")
        let pairs = toks.map { ($0.text, $0.isSentenceStart) }
        XCTAssertEqual(pairs.map { $0.0 }, ["Прости", "т.е", "это", "означает", "X"])
        XCTAssertEqual(pairs.map { $0.1 }, [true, false, true, false, false])
    }

    // MARK: - Language detection

    func test_isNounCapitalizingLanguage_detectsGerman() {
        // A realistic German sentence — articles + nouns + verbs.
        // NLLanguageRecognizer should classify as German.
        XCTAssertTrue(DictionaryHarvester.isNounCapitalizingLanguage(
            "Das ist ein wunderschönes Haus in Berlin und ich liebe es sehr"
        ))
    }

    func test_isNounCapitalizingLanguage_rejectsEnglish() {
        XCTAssertFalse(DictionaryHarvester.isNounCapitalizingLanguage(
            "This is a beautiful house in New York and I love it very much"
        ))
    }

    func test_isNounCapitalizingLanguage_rejectsRussian() {
        XCTAssertFalse(DictionaryHarvester.isNounCapitalizingLanguage(
            "Это очень красивый дом в Москве и я его очень люблю"
        ))
    }

    func test_isNounCapitalizingLanguage_rejectsEmptyText() {
        XCTAssertFalse(DictionaryHarvester.isNounCapitalizingLanguage(""))
    }

    // MARK: - shouldSave logic

    private func midHead(_ text: String) -> DictionaryHarvester.Token {
        DictionaryHarvester.Token(text: text, isSentenceStart: false)
    }

    private func startHead(_ text: String) -> DictionaryHarvester.Token {
        DictionaryHarvester.Token(text: text, isSentenceStart: true)
    }

    func test_shouldSave_skipsFirstCapTier_whenNounCapitalizingLanguage() {
        // German common noun `Haus` (4 chars, would fail length anyway,
        // but the language flag suppresses the tier entirely).
        XCTAssertFalse(DictionaryHarvester.shouldSave(
            transcriptHead: midHead("Haus"),
            canonical: "Haus",
            nounCapitalizingLanguage: true
        ))
    }

    func test_shouldSave_stillFiresStrictTier_underNounCapitalizingLanguage() {
        // Strict tier survives even in German.
        XCTAssertTrue(DictionaryHarvester.shouldSave(
            transcriptHead: startHead("iPhone"),
            canonical: "iPhone 10",
            nounCapitalizingLanguage: true
        ))
    }

    func test_shouldSave_firstCapTier_savesLongBrand_atMidSentence() {
        // Anthropic (9 chars) mid-sentence in transcript → save.
        XCTAssertTrue(DictionaryHarvester.shouldSave(
            transcriptHead: midHead("Anthropic"),
            canonical: "Anthropic",
            nounCapitalizingLanguage: false
        ))
    }

    func test_shouldSave_firstCapTier_rejectsShortWord_evenIfMid() {
        // `Auto` (4 chars) is below the first-cap min length — reject
        // regardless of position.
        XCTAssertFalse(DictionaryHarvester.shouldSave(
            transcriptHead: midHead("Auto"),
            canonical: "Auto",
            nounCapitalizingLanguage: false
        ))
    }

    func test_shouldSave_firstCapTier_rejectsAtSentenceStart_evenIfLongEnough() {
        // `Anthropic` (9 chars, would pass length) but trigger at
        // sentence-start → reject. The OR-with-context-mid escape was
        // removed: transcript position is the only signal we trust now.
        XCTAssertFalse(DictionaryHarvester.shouldSave(
            transcriptHead: startHead("Anthropic"),
            canonical: "Anthropic",
            nounCapitalizingLanguage: false
        ))
    }

    func test_shouldSave_firstCapTier_rejectsShortCommonRussianWords() {
        // The user-reported noise list (sentence-start chrome). Even
        // mid-sentence (e.g. `Anthropic выпустила. Так что...`), Так
        // is only 3 chars and fails length.
        XCTAssertFalse(DictionaryHarvester.shouldSave(
            transcriptHead: midHead("Так"),
            canonical: "Так",
            nounCapitalizingLanguage: false
        ))
        XCTAssertFalse(DictionaryHarvester.shouldSave(
            transcriptHead: midHead("Вот"),
            canonical: "Вот",
            nounCapitalizingLanguage: false
        ))
    }

    // MARK: - Multi-word tail signal

    func test_multiWordTailSignal_passesFirstCap() {
        XCTAssertTrue(DictionaryHarvester.hasMultiWordTailSignal("Inc"))
        XCTAssertTrue(DictionaryHarvester.hasMultiWordTailSignal("Pro"))
        XCTAssertTrue(DictionaryHarvester.hasMultiWordTailSignal("Пупкин"))
    }

    func test_multiWordTailSignal_passesDigit() {
        XCTAssertTrue(DictionaryHarvester.hasMultiWordTailSignal("10"))
        XCTAssertTrue(DictionaryHarvester.hasMultiWordTailSignal("2024"))
        XCTAssertTrue(DictionaryHarvester.hasMultiWordTailSignal("h264"))
    }

    func test_multiWordTailSignal_passesSpecialBinder() {
        XCTAssertTrue(DictionaryHarvester.hasMultiWordTailSignal("bin/python"))
        XCTAssertTrue(DictionaryHarvester.hasMultiWordTailSignal("generate_keys"))
        XCTAssertTrue(DictionaryHarvester.hasMultiWordTailSignal("claude.md"))
    }

    func test_multiWordTailSignal_rejectsLowercaseProse() {
        // Verb conjugations and common lowercase word endings that
        // would otherwise produce sentence-fragment phrases like
        // `iPhone 10 сохраняется` → these endings reject so the harvest
        // falls back to a shorter, more reusable canonical.
        XCTAssertFalse(DictionaryHarvester.hasMultiWordTailSignal("сохраняется"))
        XCTAssertFalse(DictionaryHarvester.hasMultiWordTailSignal("working"))
        XCTAssertFalse(DictionaryHarvester.hasMultiWordTailSignal("tomorrow"))
        XCTAssertFalse(DictionaryHarvester.hasMultiWordTailSignal("news"))
    }

    // MARK: - End-to-end harvest under German

    func test_harvest_german_skipsCommonNoun() {
        // Mid-sentence `Haus` in a recognizably German transcript →
        // first-cap tier off, strict fails, not saved. The auto-detect
        // path is exercised (we pass no `nounCapitalizingLanguage`).
        let transcript = "Ich habe heute ein neues Haus in München gekauft und bin sehr glücklich"
        let context    = "Notizen: ein schönes Haus in München"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertFalse(words.contains("Haus"),
            "first-cap tier must be disabled for German; got \(words)")
        XCTAssertFalse(words.contains("München"),
            "common-noun-shaped capital should not save in German; got \(words)")
    }

    func test_harvest_german_stillCatchesStrictTier() {
        // Even in German, the strict tier still catches mixed-case +
        // digit tokens. `iPhone 10` is a real product mention — save.
        let transcript = "Ich habe gestern ein iPhone 10 in München gekauft und es funktioniert großartig"
        let context    = "Store: iPhone 10 Pro Max sofort verfügbar"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertTrue(words.contains("iPhone 10"),
            "strict tier must still fire for German; got \(words)")
    }

    func test_harvest_explicitNonNounCapFlag_savesFirstCapMidSentence() {
        // Forcing the flag false (e.g. for an English transcript that
        // happened to look German to NLLanguageRecognizer) preserves
        // the first-cap-mid-sentence path. Pinned for the test surface
        // so we can exercise both branches deterministically.
        let transcript = "shipping to Anthropic tomorrow"
        let context    = "Slack: Anthropic Inc - your invite"
        let words = DictionaryHarvester.harvest(
            transcript: transcript,
            context: context,
            existing: [],
            nounCapitalizingLanguage: false
        )
        XCTAssertEqual(words, ["Anthropic"])
    }

    func test_harvest_explicitNounCapFlag_skipsFirstCapTier() {
        // Forcing the flag true on a non-German transcript suppresses
        // the first-cap path. Inverse of the test above.
        let transcript = "shipping to Anthropic tomorrow"
        let context    = "Slack: Anthropic Inc - your invite"
        let words = DictionaryHarvester.harvest(
            transcript: transcript,
            context: context,
            existing: [],
            nounCapitalizingLanguage: true
        )
        XCTAssertEqual(words, [])
    }

    // MARK: - Sentence-start in context

    func test_contextSentenceStart_atStringStart() {
        let context = "Anthropic news"
        let idx = context.startIndex
        XCTAssertTrue(DictionaryHarvester.isAtSentenceStart(in: context, before: idx))
    }

    func test_contextSentenceStart_afterColon() {
        // `Header: Anthropic` — Anthropic is at sentence-start because
        // colon is treated as a boundary marker.
        let context = "Header: Anthropic"
        let idx = context.range(of: "Anthropic")!.lowerBound
        XCTAssertTrue(DictionaryHarvester.isAtSentenceStart(in: context, before: idx))
    }

    func test_contextSentenceStart_afterLetterMidSentence() {
        // `shipping to Anthropic` — Anthropic is mid-sentence (preceded
        // by a real word).
        let context = "shipping to Anthropic tomorrow"
        let idx = context.range(of: "Anthropic")!.lowerBound
        XCTAssertFalse(DictionaryHarvester.isAtSentenceStart(in: context, before: idx))
    }

    func test_contextSentenceStart_afterCommaMidSentence() {
        // After a comma, the next word is NOT sentence-start (commas
        // don't end sentences). Walk back past comma, hit letter → mid.
        let context = "Apple, Anthropic, Google"
        let idx = context.range(of: "Anthropic")!.lowerBound
        XCTAssertFalse(DictionaryHarvester.isAtSentenceStart(in: context, before: idx))
    }

    func test_contextSentenceStart_afterNewline() {
        let context = "Hello world\nAnthropic news"
        let idx = context.range(of: "Anthropic")!.lowerBound
        XCTAssertTrue(DictionaryHarvester.isAtSentenceStart(in: context, before: idx))
    }

    func test_contextSentenceStart_afterPeriodAndSpace() {
        let context = "Hello world. Anthropic news"
        let idx = context.range(of: "Anthropic")!.lowerBound
        XCTAssertTrue(DictionaryHarvester.isAtSentenceStart(in: context, before: idx))
    }

    // MARK: - Single-word harvest

    func test_harvest_savesBrand_whenMidSentenceInTranscript() {
        // `Anthropic` mid-sentence in transcript (after "shipping to ").
        // Length 9 ≥ 5, trigger position mid → first-cap tier passes
        // regardless of context position.
        let transcript = "shipping to Anthropic tomorrow"
        let context    = "Slack: Anthropic Inc - your invite"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["Anthropic"])
    }

    func test_harvest_savesSlack_whenMidSentenceInTranscript() {
        // `Slack` is a real brand the user dictates mid-sentence.
        // Length 5 ≥ firstCapTierMinLength, mid → save.
        let transcript = "написал в Slack команде вчера"
        let context    = "Tab: Slack — channels list"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["Slack"])
    }

    func test_harvest_rejectsAtSentenceStart_evenIfContextMid() {
        // The user-reported regression: `Apple` at the start of a
        // transcript sentence would previously save when the
        // context happened to show `Apple` mid-sentence somewhere
        // (e.g. inside a Notes window). The OR-rule was the leak
        // channel for sentence-start chrome (`Вот`, `Так`, `Для`)
        // because the full-screen AX dump always finds the chrome
        // word mid-sentence in some unrelated app. Now the
        // transcript-position signal alone gates the tier: trigger
        // at sentence-start → reject regardless of context.
        let transcript = "Apple just released a new model"
        let context    = "Notes: вчера я смотрел Apple новости"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, [])
    }

    func test_harvest_rejectsTak_whenAtSentenceStartInTranscript() {
        // The user-reported leak from real testing. `Так` at the
        // start of every transcript sentence + `Так` mid-sentence in
        // some random app's AX text used to save via the OR rule.
        // Now: trigger SS in transcript + length 3 < 5 → reject.
        let transcript = "Так, мне нужно проверить Anthropic"
        let context    = "Status bar: посмотри Так на это"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertFalse(words.contains("Так"),
            "sentence-start chrome must never save; got \(words)")
    }

    func test_harvest_rejectsShortFirstCap_evenMidSentence() {
        // `Auto` (4 chars) mid-sentence in transcript still rejects
        // via the length filter. Reproduces the test-2 noise case
        // where `Auto` slipped past the OR rule.
        let transcript = "Дальше, Auto detect, работает или нет"
        let context    = "Header: Auto detect mode enabled"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertFalse(words.contains("Auto"),
            "4-char first-cap word must be below firstCapTierMinLength; got \(words)")
    }

    func test_harvest_rejectsDlya_inMultiWord_whenSentenceStartInTranscript() {
        // `Для этого` — multi-word with first-cap plain shape. Trigger
        // `Для` at sentence-start → reject. Even if context happens to
        // show `Для этого` mid-sentence, transcript SS gates this.
        let transcript = "Для этого нужно купить новый телефон"
        let context    = "Notes: использую Для этого специальный софт"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertFalse(words.contains("Для этого"))
        XCTAssertFalse(words.contains("Для"))
    }

    func test_harvest_multiWordVerbTail_fallsBackToShorterCanonical() {
        // The exact noise case from the user's test 3: transcript
        // contains `iPhone 10 сохраняется`, context contains it
        // verbatim. The 3-span fails the boundary filter (last token
        // `сохраняется` is lowercase prose), so the algorithm falls
        // back to the 2-span `iPhone 10` whose boundaries (`iPhone`
        // internal cap + `10` digit) both pass.
        let transcript = "В тесте iPhone 10 сохраняется всё"
        let context    = "Snippet: iPhone 10 сохраняется в словаре всё"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertTrue(words.contains("iPhone 10"),
            "expected fallback to 2-span; got \(words)")
        XCTAssertFalse(words.contains("iPhone 10 сохраняется"),
            "verb tail must not survive; got \(words)")
    }

    // MARK: - User real-world scenario

    func test_harvest_userScenario_GitHubActionsMacOS() {
        // Reproduces the user's actual test session:
        // - Transcript dictates "GitHub Actions", "macOS", references
        //   "packages"/"минуты" in lowercase.
        // - Context is GitHub usage info containing capitalized
        //   "Packages", "Минуты", "Actions", "GitHub", "macOS".
        // The OLD algorithm saved noise: ["Минуты", "Packages",
        // "на Actions", "Actions"] — case promotion from context +
        // multi-word phrases bleeding into prose particles. NEW
        // algorithm must:
        //   - Reject `минуты`/`packages` (lowercase in transcript →
        //     never become triggers, no case promotion via context).
        //   - Reject `на Actions artifacts` (`на` lowercase boundary
        //     fails the interesting-signal check).
        //   - Save useful triggers: GitHub, Actions, macOS.
        //   - Substring-dedup the second `Actions` so it isn't repeated.
        let transcript = """
        Так, я хочу протестировать GitHub Actions, чтобы проверить на \
        Actions artifacts. И я хочу, чтобы в моих packages были минуты. \
        Вот, потому что мне важен множитель минут на macOS. А ещё у \
        меня репозиторий фришный, на free модели.
        """
        let context = """
        Приватные репозитории на Free:
        • 2 000 минут Actions в месяц GitHub
        • 500 МБ storage (общий пул на Actions artifacts, кэши и Packages)
        • Минуты сбрасываются в начале биллингового цикла
        Множители минут:
        • Linux — ×1
        • Windows — ×2
        • macOS — ×10
        """
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])

        // Verify what the user explicitly flagged as NOISE is gone.
        XCTAssertFalse(words.contains("Минуты"),  "case-promoted noise: got \(words)")
        XCTAssertFalse(words.contains("Packages"), "case-promoted noise: got \(words)")
        XCTAssertFalse(words.contains("packages"), "lowercase prose: got \(words)")
        XCTAssertFalse(words.contains("минуты"),   "lowercase prose: got \(words)")
        XCTAssertFalse(words.contains("на Actions"),
            "phrase boundary starts with prose particle 'на': got \(words)")
        XCTAssertFalse(words.contains("на Actions artifacts"),
            "phrase boundaries both prose: got \(words)")

        // Verify useful saves are present.
        XCTAssertTrue(words.contains("GitHub"),  "GitHub should save: got \(words)")
        XCTAssertTrue(words.contains("Actions"), "Actions should save: got \(words)")
        XCTAssertTrue(words.contains("macOS"),   "macOS should save: got \(words)")

        // The second `Actions` trigger must be substring-deduped, not
        // saved twice.
        let actionsHits = words.filter { $0.lowercased() == "actions" }.count
        XCTAssertEqual(actionsHits, 1, "Actions should appear once: got \(words)")
    }

    func test_harvest_substringDedup_skipsWordContainedInExisting() {
        // If user already has `GitHub Actions` saved, a new harvest
        // session finding `Actions` alone should be skipped (existing
        // multi-word is more informative).
        let transcript = "вчера запустил Actions"
        let context    = "Tab: Actions deploy"
        let words = DictionaryHarvester.harvest(
            transcript: transcript,
            context: context,
            existing: ["GitHub Actions"]
        )
        XCTAssertFalse(words.contains("Actions"),
            "Actions is strict subset of existing GitHub Actions: got \(words)")
    }

    func test_harvest_exactMatchInExisting_isReturnedForRefresh() {
        // Exact match against an existing entry is INCLUDED in the
        // return list so the caller can refresh `addedAt`. (The
        // substring check has a `!= existingSeq` clause that
        // distinguishes strict-subset from exact match.)
        let transcript = "вчера обсуждал Anthropic с командой"
        let context    = "Slack: Anthropic news daily"
        let words = DictionaryHarvester.harvest(
            transcript: transcript,
            context: context,
            existing: ["Anthropic"]
        )
        XCTAssertEqual(words, ["Anthropic"])
    }

    func test_harvest_mixedCaseSingleToken_savedFromTranscriptCasing() {
        // `iOS` has internal upper in the TRANSCRIPT (i lowercase + O
        // uppercase + S uppercase). Trigger fires on the transcript
        // token, saved with transcript's casing. Context only verifies
        // it appears on screen — never promotes lowercase transcript
        // to capital canonical (the user-reported `минуты → Минуты`
        // regression).
        let transcript = "running iOS apps daily"
        let context    = "AppStore: iOS market share grew"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["iOS"])
    }

    func test_harvest_doesNotPromoteLowercaseTranscriptToCanonicalCapital() {
        // Reproduces the user-reported `минуты → Минуты` noise:
        // transcript has the word in lowercase but context has the
        // capital. Old algorithm promoted via context casing; new
        // algorithm rejects because lowercase transcript token never
        // becomes a trigger.
        let transcript = "хочу, чтобы в моих packages были минуты"
        let context    = "GitHub Free: Packages • Минуты сбрасываются"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertFalse(words.contains("Минуты"), "no case promotion: got \(words)")
        XCTAssertFalse(words.contains("Packages"), "no case promotion: got \(words)")
        XCTAssertFalse(words.contains("packages"), "lowercase transcript token is not a trigger: got \(words)")
    }

    func test_harvest_skipsWordNotInContext() {
        let transcript = "I love iPhone today"
        let context    = "Anthropic dashboard - nothing else here"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        // "iPhone" passes shape filter but is NOT in context → dropped.
        XCTAssertEqual(words, [])
    }

    func test_harvest_skipsHyphenatedRussianPronoun() {
        // `что-то` starts lowercase → never passes first-cap-plain
        // shape. Strict fails (hyphen not in special binder set).
        // Rejected regardless of sentence position.
        let transcript = "написал что-то в чате"
        let context    = "Sidebar: что-то непонятное"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, [])
    }

    func test_harvest_skipsShortDotAbbreviation() {
        // `т.е` (trailing dot dropped by tokenizer) → starts lowercase,
        // dot but length < 6. Both tiers reject.
        let transcript = "написал т.е. это означает"
        let context    = "Reply: т.е. вот так получилось"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
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

    func test_harvest_multiWord_longestMatchWins_whenTailHasShape() {
        // Multi-word longest-match requires the tail token to carry
        // its own shape signal (first-cap, digit, special binder,
        // dot). Here `Pro` has a first cap → 2-span `Apple Pro`
        // survives the tail filter and wins over the 1-span `Apple`.
        let transcript = "купил Apple Pro вчера"
        let context    = "Store: Apple Pro Max"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["Apple Pro"])
    }

    func test_harvest_multiWord_fallsToShorter_whenTailIsLowercaseProse() {
        // `GitHub releases` is the kind of phrase that USED to be saved
        // as a multi-word but is too prose-like to be a useful entry —
        // `releases` is lowercase plural prose. Same shape filter that
        // rejects `iPhone 10 сохраняется` falls back to 1-span `GitHub`
        // here, which is the genuinely useful save.
        let transcript = "check GitHub releases page"
        let context    = "Tab: GitHub releases for the project"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["GitHub"])
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

    func test_harvest_personName_savesMultiWord_whenTranscriptCapitalizes() {
        // User says "Вася Пупкин" with proper casing. Trigger fires on
        // "Пупкин" (first-cap, length 6 ≥ 5, mid-sentence). 2-span
        // "Вася Пупкин" matches context. Both tokens pass boundary
        // filter (uppercase letters). Save with transcript casing.
        let transcript = "пиши Вася Пупкин завтра"
        let context    = "Recipient: Вася Пупкин — manager"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["Вася Пупкин"])
    }

    // MARK: - Dedup

    func test_harvest_excludesExistingEntries_caseInsensitive() {
        // Uses mixed-case `iOS` which still passes the strict shape
        // filter. Lowercase `ios` in `existing` should still dedup.
        let transcript = "shipping to ios users tomorrow"
        let context    = "AppStore: iOS market share"
        let words = DictionaryHarvester.harvest(
            transcript: transcript,
            context: context,
            existing: ["ios"] // lowercase existing — still dedups
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
        // 7 distinct mixed-case nouns (each passes strict shape via
        // internal cap), all in context. Verifies the per-session cap
        // truncates after `maxCandidates`.
        let nouns = ["iPhone", "NoType", "MacBook", "iPadPro", "iCloud", "iMessage", "AirPods"]
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
        // "I" is too short for `minSingleTokenLength` (3) and would
        // also fail the strict shape filter (cap only at index 0).
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

    // MARK: - Digit-bearing tokens

    func test_harvest_phraseWithDigit_iPhone10() {
        // Both "iPhone" (mixed case) and "10" (pure digit) are tokens.
        // 2-span `iPhone 10` matches context as a whole — saved as one
        // canonical phrase. `iPhone` alone would also match but the
        // longest-match rule consumes the 2-span first.
        let transcript = "купил iPhone 10 вчера"
        let context    = "Store: iPhone 10 Pro Max"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["iPhone 10"])
    }

    func test_harvest_codecName_h264() {
        // Lowercase letters + digits — passes shape via the digit rule
        // even without any uppercase or atypical binder.
        let transcript = "compressed it with h264 yesterday"
        let context    = "Codec: h264 (high profile)"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, ["h264"])
    }

    func test_harvest_pureDigitToken_notSavedAlone() {
        // Standalone `2024` cannot be a trigger (no letter → fails the
        // transcript shape filter). `Year` (4 chars) is also below the
        // first-cap-tier minimum length. Net: nothing saved — the user
        // explicitly excluded pure-digit triggers ("просто цифры не
        // нужно запоминать").
        let transcript = "Year 2024 was great"
        let context    = "Header: Year 2024 review"
        let words = DictionaryHarvester.harvest(transcript: transcript, context: context, existing: [])
        XCTAssertEqual(words, [])
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
