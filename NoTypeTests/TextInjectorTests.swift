import XCTest
@testable import NoType

/// Pins `TextInjector.finalizeForInsertion` — the client-side boundary
/// safety net described in `Aura/Injection/CLAUDE.md`.
///
/// Two corrections are applied:
///   1. Strip a trailing terminal mark (`.`, `!`, `?`) when `textAfter`
///      shows we're inside an existing sentence (lowercase / continuation
///      punctuation / closing bracket / closing quote).
///   2. Insert a leading space when `textBefore` ends with a non-whitespace
///      character and the dictation starts with a word-opener.
final class TextInjectorTests: XCTestCase {

    // MARK: - Strip: textAfter continues mid-text → terminal must go

    func test_lowercaseAfter_stripsPeriod() {
        let out = TextInjector.finalizeForInsertion(
            "I'll be back in an hour.",
            textBeforeCursor: "",
            textAfterCursor: " before the demo"
        )
        XCTAssertEqual(out, "I'll be back in an hour")
    }

    func test_lowercaseAfter_stripsExclamation() {
        let out = TextInjector.finalizeForInsertion(
            "absolutely!",
            textBeforeCursor: "",
            textAfterCursor: " whenever you're ready"
        )
        XCTAssertEqual(out, "absolutely")
    }

    func test_lowercaseAfter_stripsQuestion() {
        let out = TextInjector.finalizeForInsertion(
            "really?",
            textBeforeCursor: "",
            textAfterCursor: " let me think"
        )
        XCTAssertEqual(out, "really")
    }

    func test_commaAfter_stripsTerminal() {
        let out = TextInjector.finalizeForInsertion(
            "we should regroup.",
            textBeforeCursor: "",
            textAfterCursor: ", maybe Friday"
        )
        XCTAssertEqual(out, "we should regroup")
    }

    func test_semicolonAfter_stripsTerminal() {
        let out = TextInjector.finalizeForInsertion(
            "looks good.",
            textBeforeCursor: "",
            textAfterCursor: "; ship it"
        )
        XCTAssertEqual(out, "looks good")
    }

    func test_colonAfter_stripsTerminal() {
        let out = TextInjector.finalizeForInsertion(
            "I have one question.",
            textBeforeCursor: "",
            textAfterCursor: ": about pricing"
        )
        XCTAssertEqual(out, "I have one question")
    }

    func test_emDashAfter_stripsTerminal() {
        let out = TextInjector.finalizeForInsertion(
            "the timeline.",
            textBeforeCursor: "",
            textAfterCursor: "— but it's tight"
        )
        XCTAssertEqual(out, "the timeline")
    }

    func test_hyphenAfter_stripsTerminal() {
        let out = TextInjector.finalizeForInsertion(
            "Friday.",
            textBeforeCursor: "",
            textAfterCursor: "- next standup"
        )
        XCTAssertEqual(out, "Friday")
    }

    func test_lowercaseAfterLeadingWhitespace_stripsTerminal() {
        // .whitespacesAndNewlines trim handles leading space/newline before
        // the lowercase letter, so we still see "continues mid-sentence".
        let out = TextInjector.finalizeForInsertion(
            "today.",
            textBeforeCursor: "",
            textAfterCursor: "\n\nbefore the demo"
        )
        XCTAssertEqual(out, "today")
    }

    func test_trailingWhitespace_isStrippedAlongsideTerminal() {
        // The regex pattern is `[.!?]+\s*$`, so trailing space after the
        // period also disappears.
        let out = TextInjector.finalizeForInsertion(
            "today.   ",
            textBeforeCursor: "",
            textAfterCursor: " before lunch"
        )
        XCTAssertEqual(out, "today")
    }

    func test_closingParenAfter_stripsTerminal() {
        // Closing brackets/quotes mean we're inside something — adding
        // terminal punct before them is almost always wrong.
        let out = TextInjector.finalizeForInsertion(
            "the meeting at noon.",
            textBeforeCursor: "",
            textAfterCursor: ") confirmed"
        )
        XCTAssertEqual(out, "the meeting at noon")
    }

    func test_closingQuoteAfter_stripsTerminal() {
        let out = TextInjector.finalizeForInsertion(
            "I said hello.",
            textBeforeCursor: "",
            textAfterCursor: "\" and waved"
        )
        XCTAssertEqual(out, "I said hello")
    }

    func test_curlyClosingQuoteAfter_stripsTerminal() {
        let out = TextInjector.finalizeForInsertion(
            "the answer is yes.",
            textBeforeCursor: "",
            textAfterCursor: "\u{201D} replied Sam"
        )
        XCTAssertEqual(out, "the answer is yes")
    }

    func test_multipleTrailingTerminals_allStripped() {
        // The pattern is `[.!?]+\s*$` — runs of terminal punct go too.
        let out = TextInjector.finalizeForInsertion(
            "really?!",
            textBeforeCursor: "",
            textAfterCursor: " he asked"
        )
        XCTAssertEqual(out, "really")
    }

    // MARK: - Keep: end-of-document or new sentence → terminal stays

    func test_emptyAfter_keepsPeriod() {
        let out = TextInjector.finalizeForInsertion(
            "Hello world.",
            textBeforeCursor: "",
            textAfterCursor: ""
        )
        XCTAssertEqual(out, "Hello world.")
    }

    func test_whitespaceOnlyAfter_keepsPeriod() {
        let out = TextInjector.finalizeForInsertion(
            "Hello world.",
            textBeforeCursor: "",
            textAfterCursor: "   \n\t  "
        )
        XCTAssertEqual(out, "Hello world.")
    }

    func test_capitalAfter_keepsPeriod() {
        let out = TextInjector.finalizeForInsertion(
            "We met yesterday.",
            textBeforeCursor: "",
            textAfterCursor: " Next paragraph follows."
        )
        XCTAssertEqual(out, "We met yesterday.")
    }

    func test_terminalPunctAfter_keepsPeriod() {
        // Period after cursor belongs to its own sentence — we don't trip.
        let out = TextInjector.finalizeForInsertion(
            "yes.",
            textBeforeCursor: "",
            textAfterCursor: ". And another."
        )
        XCTAssertEqual(out, "yes.")
    }

    // MARK: - Leading space: insert when textBefore ends non-whitespace

    func test_textBeforeEndsLetter_addsLeadingSpace() {
        let out = TextInjector.finalizeForInsertion(
            "thanks for that",
            textBeforeCursor: "Hi John,",
            textAfterCursor: ""
        )
        // "Hi John," + " thanks for that" = "Hi John, thanks for that"
        XCTAssertEqual(out, " thanks for that")
    }

    func test_textBeforeEndsComma_addsLeadingSpace() {
        let out = TextInjector.finalizeForInsertion(
            "I think we should ship it",
            textBeforeCursor: "Hey,",
            textAfterCursor: ""
        )
        XCTAssertEqual(out, " I think we should ship it")
    }

    func test_textBeforeEndsWhitespace_noLeadingSpace() {
        // Already a space at the boundary — don't double up.
        let out = TextInjector.finalizeForInsertion(
            "thanks for that",
            textBeforeCursor: "Hi John, ",
            textAfterCursor: ""
        )
        XCTAssertEqual(out, "thanks for that")
    }

    func test_emptyTextBefore_noLeadingSpace() {
        let out = TextInjector.finalizeForInsertion(
            "Hello world.",
            textBeforeCursor: "",
            textAfterCursor: ""
        )
        XCTAssertEqual(out, "Hello world.")
    }

    func test_stitchedAlreadyHasLeadingSpace_noDoubleSpace() {
        // Model already added the leading space — don't add another.
        let out = TextInjector.finalizeForInsertion(
            " thanks for that",
            textBeforeCursor: "Hi John,",
            textAfterCursor: ""
        )
        XCTAssertEqual(out, " thanks for that")
    }

    func test_stitchedStartsWithGluePunct_noLeadingSpace() {
        // Dictation begins with a comma / period / etc → glue tight to the
        // previous word. No leading space.
        let out = TextInjector.finalizeForInsertion(
            ", and we'll see",
            textBeforeCursor: "I'll grab coffee",
            textAfterCursor: ""
        )
        XCTAssertEqual(out, ", and we'll see")
    }

    func test_stitchedStartsWithQuote_addsLeadingSpace() {
        // Opening quote is a word-opener — needs a space.
        let out = TextInjector.finalizeForInsertion(
            "\"hi\"",
            textBeforeCursor: "she said",
            textAfterCursor: ""
        )
        XCTAssertEqual(out, " \"hi\"")
    }

    func test_combinedLeadingSpaceAndStrip() {
        // Both corrections at once: textBefore ends with letter (needs
        // space), textAfter continues lowercase (strip period).
        let out = TextInjector.finalizeForInsertion(
            "and probably",
            textBeforeCursor: "we should ship",
            textAfterCursor: " on Friday"
        )
        XCTAssertEqual(out, " and probably")
    }

    // MARK: - No-ops

    func test_noTerminalPunct_lowercaseAfter_unchanged() {
        let out = TextInjector.finalizeForInsertion(
            "the meeting is at three",
            textBeforeCursor: "",
            textAfterCursor: " before lunch"
        )
        XCTAssertEqual(out, "the meeting is at three")
    }

    func test_endsWithComma_continuesMidSentence_doesNotTouchComma() {
        let out = TextInjector.finalizeForInsertion(
            "I'll bring snacks,",
            textBeforeCursor: "",
            textAfterCursor: " also drinks"
        )
        XCTAssertEqual(out, "I'll bring snacks,")
    }

    func test_endsWithColon_continuesMidSentence_doesNotTouchColon() {
        let out = TextInjector.finalizeForInsertion(
            "agenda items:",
            textBeforeCursor: "",
            textAfterCursor: " kickoff, then demo"
        )
        XCTAssertEqual(out, "agenda items:")
    }

    func test_emptyStitched_returnsEmpty() {
        let out = TextInjector.finalizeForInsertion(
            "",
            textBeforeCursor: "Hi,",
            textAfterCursor: " before lunch"
        )
        XCTAssertEqual(out, "")
    }

    func test_internalPunctuationInsideStitched_isNeverTouched() {
        // The function only looks at the very end of `stitched`. A period
        // in the middle (chunk seam) survives untouched.
        let out = TextInjector.finalizeForInsertion(
            "first thing. second thing.",
            textBeforeCursor: "",
            textAfterCursor: " third thing"
        )
        XCTAssertEqual(out, "first thing. second thing")
    }

    // MARK: - stitchChunks (chunk-seam whitespace fix)

    func test_stitch_addsSpaceAfterPeriodWhenNextChunkStartsWithLetter() {
        // The bug we're fixing: the model occasionally returns chunks
        // without the leading space after a sentence-closing prior
        // chunk. Client must insert one.
        let out = TextInjector.stitchChunks(["What's up.", "I'm fine."])
        XCTAssertEqual(out, "What's up. I'm fine.")
    }

    func test_stitch_addsSpaceAfterCommaWhenNextChunkStartsWithLetter() {
        let out = TextInjector.stitchChunks(["Hi John,", "how are you"])
        XCTAssertEqual(out, "Hi John, how are you")
    }

    func test_stitch_addsSpaceAfterColon() {
        let out = TextInjector.stitchChunks(["agenda:", "review Q3"])
        XCTAssertEqual(out, "agenda: review Q3")
    }

    func test_stitch_addsSpaceAfterExclamation() {
        let out = TextInjector.stitchChunks(["nice!", "and the rest"])
        XCTAssertEqual(out, "nice! and the rest")
    }

    func test_stitch_addsSpaceAfterQuestion() {
        let out = TextInjector.stitchChunks(["who?", "the one in red"])
        XCTAssertEqual(out, "who? the one in red")
    }

    func test_stitch_addsSpaceBeforeOpeningQuote() {
        let out = TextInjector.stitchChunks(["He said.", "\"Hello\""])
        XCTAssertEqual(out, "He said. \"Hello\"")
    }

    func test_stitch_doesNotAddSpaceWhenNextChunkAlreadyHasLeadingSpace() {
        // Model did the right thing — don't double-space.
        let out = TextInjector.stitchChunks(["What's up.", " I'm fine."])
        XCTAssertEqual(out, "What's up. I'm fine.")
    }

    func test_stitch_doesNotAddSpaceAfterTerminalIfNextStartsWithPunctuation() {
        // Comma after period sits tight — not a word-opener.
        let out = TextInjector.stitchChunks(["right.", ",which is great"])
        XCTAssertEqual(out, "right.,which is great")
    }

    func test_stitch_addsSpaceBetweenLetters() {
        // Mid-thought VAD-pause boundary: the system prompt tells the
        // model NOT to emit terminal punct on dangling phrases, so
        // letter-to-letter seams are the common case across pauses.
        // Patch them.
        let out = TextInjector.stitchChunks(["the meeting is", "at three"])
        XCTAssertEqual(out, "the meeting is at three")
    }

    func test_stitch_addsSpaceBetweenLetters_cyrillic() {
        // The original repro: Russian dictation across a VAD pause.
        let out = TextInjector.stitchChunks(["пауза", "Продолжай разговор."])
        XCTAssertEqual(out, "пауза Продолжай разговор.")
    }

    func test_stitch_addsSpaceAfterDigit() {
        let out = TextInjector.stitchChunks(["chapter 3", "starts here"])
        XCTAssertEqual(out, "chapter 3 starts here")
    }

    func test_stitch_addsSpaceBeforeDigitFromLetter() {
        let out = TextInjector.stitchChunks(["we have", "5 items"])
        XCTAssertEqual(out, "we have 5 items")
    }

    func test_stitch_addsSpaceAfterClosingParen() {
        let out = TextInjector.stitchChunks(["the answer (yes)", "is final"])
        XCTAssertEqual(out, "the answer (yes) is final")
    }

    func test_stitch_addsSpaceAfterCurlyClosingQuote() {
        let out = TextInjector.stitchChunks(["he said \u{201C}hi\u{201D}", "and waved"])
        XCTAssertEqual(out, "he said \u{201C}hi\u{201D} and waved")
    }

    func test_stitch_doesNotAddSpaceWhenNextChunkStartsLowercaseAfterAmbiguousQuote() {
        // `"` is intentionally not in the closers set — the model decides
        // whether a space is needed around an ambiguous quote.
        let out = TextInjector.stitchChunks(["he said \"", "hi"])
        XCTAssertEqual(out, "he said \"hi")
    }

    func test_stitch_doesNotAddSpaceAfterDash() {
        // Em dash is intentionally NOT in the terminals set — words
        // before/after a dash may or may not want a space and the model
        // is positioned to decide.
        let out = TextInjector.stitchChunks(["wait —", "before that"])
        XCTAssertEqual(out, "wait —before that")
    }

    func test_stitch_preservesEmptyChunks() {
        let out = TextInjector.stitchChunks(["", "Hello.", "", "World."])
        XCTAssertEqual(out, "Hello. World.")
    }

    func test_stitch_singleChunkUnchanged() {
        let out = TextInjector.stitchChunks(["just one thing."])
        XCTAssertEqual(out, "just one thing.")
    }

    func test_stitch_emptyInput() {
        XCTAssertEqual(TextInjector.stitchChunks([]), "")
    }

    func test_stitch_addsSpaceAfterEllipsis() {
        let out = TextInjector.stitchChunks(["thinking…", "ok now"])
        XCTAssertEqual(out, "thinking… ok now")
    }

    func test_stitch_addsSpaceBeforeDigit() {
        let out = TextInjector.stitchChunks(["First.", "2nd is the doc"])
        XCTAssertEqual(out, "First. 2nd is the doc")
    }

    // MARK: - contextKnown=false (AX failed — Electron / web-view path)
    //
    // When AX can't read the focused field, `textBefore` / `textAfter`
    // arrive as empty strings but the meaning is "we don't know", not
    // "field is empty". `finalizeForInsertion` is then defensive — it
    // prepends a leading space when the dictation starts with a word
    // opener, since the cursor is very likely sitting after a non-
    // whitespace character we can't see.

    func test_contextUnknown_emptyTextBefore_prependsDefensiveSpace() {
        // The user-reported bug shape: cursor sits after "Прошлое
        // предложение." in a Telegram-desktop / Slack / Discord message
        // composer. AX returns no AXValue → textBefore arrives empty
        // → without the fix we'd paste `"предложение.Новый ввод"`.
        let out = TextInjector.finalizeForInsertion(
            "Новый ввод",
            textBeforeCursor: "",
            textAfterCursor: "",
            contextKnown: false
        )
        XCTAssertEqual(out, " Новый ввод")
    }

    func test_contextUnknown_quoteOpener_prependsDefensiveSpace() {
        let out = TextInjector.finalizeForInsertion(
            "\"quoted\"",
            textBeforeCursor: "",
            textAfterCursor: "",
            contextKnown: false
        )
        XCTAssertEqual(out, " \"quoted\"")
    }

    func test_contextUnknown_gluePunctuation_noDefensiveSpace() {
        // Even in defensive mode, output that opens with `,.;:!?-—`
        // glues tight — adding a space before a comma is always wrong.
        let out = TextInjector.finalizeForInsertion(
            ", and then",
            textBeforeCursor: "",
            textAfterCursor: "",
            contextKnown: false
        )
        XCTAssertEqual(out, ", and then")
    }

    func test_contextUnknown_alreadyHasLeadingSpace_noDoubleSpace() {
        let out = TextInjector.finalizeForInsertion(
            " модель угадала",
            textBeforeCursor: "",
            textAfterCursor: "",
            contextKnown: false
        )
        XCTAssertEqual(out, " модель угадала")
    }

    func test_contextUnknown_doesNotStripTerminalPunct() {
        // In defensive mode we don't know what comes after the cursor,
        // so we can't decide whether the trailing `.` is stranded
        // mid-sentence or ends the document. Default: keep it. (The
        // model is the source of truth for terminal punct in this
        // branch.)
        let out = TextInjector.finalizeForInsertion(
            "Hello world.",
            textBeforeCursor: "",
            textAfterCursor: "",
            contextKnown: false
        )
        XCTAssertEqual(out, " Hello world.")
    }

    func test_contextUnknown_textBeforeStillBeatsDefensive() {
        // If somehow we have BOTH a non-empty textBefore AND
        // contextKnown=false (unusual but defensive code paths exist),
        // the canonical "textBefore ends non-whitespace → leading space"
        // rule fires. We don't end up with TWO spaces.
        let out = TextInjector.finalizeForInsertion(
            "next words",
            textBeforeCursor: "some text",
            textAfterCursor: "",
            contextKnown: false
        )
        XCTAssertEqual(out, " next words")
    }

    func test_contextKnown_emptyTextBefore_stillNoLeadingSpace() {
        // Regression guard for the existing `test_emptyTextBefore_*`
        // contract: when AX confirmed the field is genuinely empty
        // (contextKnown=true, textBefore=""), do NOT defensively prepend
        // a space. The default-true overload covers this branch already
        // but pin it explicitly with the new parameter spelled out.
        let out = TextInjector.finalizeForInsertion(
            "Hello world.",
            textBeforeCursor: "",
            textAfterCursor: "",
            contextKnown: true
        )
        XCTAssertEqual(out, "Hello world.")
    }
}
