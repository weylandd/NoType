import XCTest
@testable import NoType

/// Pins the cached-prefix shape of every Gemini request. **The order and
/// labels of these parts are load-bearing for the implicit-cache discount
/// — see `NoType/Gemini/CLAUDE.md` and ADR I3 in `docs/architecture.md`.**
///
/// The cached prefix is now up to 8 textual sections (was 7 before
/// `User dictionary:` was introduced in ADR-016). Two sections are
/// conditionally omitted: `User instruction:` when empty, `Category
/// instruction:` when nil (typical for `.uncategorized`). The
/// `User dictionary:` section is **always present** even when the
/// dictionary is empty (body renders as `(empty)`); dropping it would
/// invalidate cache across sessions where the dictionary differs.
///
/// If a test in this file changes, the cache invariant changed → reviewer
/// must explicitly bless it.
final class GeminiRequestBuilderTests: XCTestCase {

    // MARK: - Fixtures

    /// Default fixture: uncategorized + no user instruction + empty
    /// dictionary. Produces the 6-text-part shape (App+Category, User
    /// dictionary, Insertion target, On-screen context, Prior chunks,
    /// per-call instruction).
    private func ctx(
        appName: String = "Slack",
        bundle: String = "com.tinyspeck.slackmacgap",
        category: AppCategory = .uncategorized,
        userInstruction: String = "",
        categoryInstruction: String? = nil,
        dictionary: [String] = [],
        before: String = "",
        after: String = "",
        screenText: RedactedScreenText? = nil
    ) -> ContextSnapshot {
        ContextSnapshot(
            activeApp: AppInfo(name: appName, bundleID: bundle),
            category: category,
            userInstruction: userInstruction,
            categoryInstruction: categoryInstruction,
            dictionary: dictionary,
            replacements: [],
            tree: RedactedAXSnapshot(apps: []),
            insertionTarget: InsertionTarget(textBefore: before, textAfter: after),
            screenText: screenText
        )
    }

    /// Full-shape fixture: non-empty user instruction + classified
    /// category with its prompt resolved + non-empty dictionary.
    /// Produces the 8-text-part shape.
    private func fullCtx(
        category: AppCategory = .messaging,
        userInstruction: String = "always sign off with 'Best,'",
        categoryInstruction: String = "Messaging formatting: keep it short.",
        dictionary: [String] = ["NoType", "Anthropic"],
        before: String = "",
        after: String = "",
        screenText: RedactedScreenText? = nil
    ) -> ContextSnapshot {
        ctx(
            category: category,
            userInstruction: userInstruction,
            categoryInstruction: categoryInstruction,
            dictionary: dictionary,
            before: before,
            after: after,
            screenText: screenText
        )
    }

    private func ocrFixture(lines: [String] = ["#engineering", "John Doe", "design review draft"]) -> RedactedScreenText {
        RedactedScreenText(
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            windowTitle: "engineering — Acme",
            scrubbedLines: lines,
            truncated: false
        )
    }

    private func textParts(_ body: GeminiAPI.Request) -> [String] {
        guard let user = body.contents.first else { return [] }
        return user.parts.compactMap { part in
            if case .text(let s) = part { return s } else { return nil }
        }
    }

    private func inlineCount(_ body: GeminiAPI.Request) -> Int {
        guard let user = body.contents.first else { return 0 }
        return user.parts.reduce(0) { acc, part in
            if case .inlineData = part { return acc + 1 } else { return acc }
        }
    }

    /// Index of the first text part whose body starts with `prefix`, or
    /// `nil` if none match. Tests use this instead of bare positional
    /// access because section indices shift depending on which optional
    /// sections (`User instruction:` / `Category instruction:`) are
    /// present.
    private func indexOfPart(prefix: String, in texts: [String]) -> Int? {
        texts.firstIndex { $0.hasPrefix(prefix) }
    }

    // MARK: - Minimum shape (no user, uncategorized, empty dict)

    func test_minimumShape_sixPartsInOrder() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0x00]), "audio/mp4")],
            context: ctx(before: "Hi ", after: " then"),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        XCTAssertEqual(texts.count, 6,
            "uncategorized + empty user instruction + empty dictionary collapses to the 6-text-part shape")
        XCTAssertTrue(texts[0].hasPrefix("App: "))
        XCTAssertTrue(texts[0].contains("Category: uncategorized"),
            "first part must carry the Category line")
        XCTAssertTrue(texts[1].hasPrefix("User dictionary:"))
        XCTAssertTrue(texts[2].hasPrefix("Insertion target:"))
        XCTAssertTrue(texts[3].hasPrefix("On-screen context:"))
        XCTAssertTrue(texts[4].hasPrefix("Prior chunks (this session):"))
        XCTAssertTrue(texts[5].hasPrefix("Now transcribe chunk_"))
        XCTAssertEqual(inlineCount(body), 1)
    }

    func test_styleHintLabel_removed_anywhereInRequest() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0x00]), "audio/mp4")],
            context: fullCtx(),
            priorTranscripts: ["hello"],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 2)
        )
        for t in textParts(body) {
            XCTAssertFalse(t.contains("Style hint:"),
                "'Style hint:' must be gone everywhere — replaced by 'Category:'. Got: \(t)")
        }
    }

    // MARK: - Full shape (8 parts, both optional sections present)

    func test_fullShape_eightPartsInOrder() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0x00]), "audio/mp4")],
            context: fullCtx(before: "Hi ", after: " then"),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        XCTAssertEqual(texts.count, 8,
            "non-empty user instruction + non-nil category instruction + non-empty dictionary → 8 text parts")
        XCTAssertTrue(texts[0].hasPrefix("App: "))
        XCTAssertTrue(texts[0].contains("Category: messaging"))
        XCTAssertTrue(texts[1].hasPrefix("User instruction:"))
        XCTAssertTrue(texts[1].contains("always sign off"))
        XCTAssertTrue(texts[2].hasPrefix("Category instruction:"))
        XCTAssertTrue(texts[2].contains("Messaging formatting"))
        XCTAssertTrue(texts[3].hasPrefix("User dictionary:"))
        XCTAssertTrue(texts[3].contains("NoType, Anthropic"))
        XCTAssertTrue(texts[4].hasPrefix("Insertion target:"))
        XCTAssertTrue(texts[5].hasPrefix("On-screen context:"))
        XCTAssertTrue(texts[6].hasPrefix("Prior chunks (this session):"))
        XCTAssertTrue(texts[7].hasPrefix("Now transcribe chunk_"))
    }

    func test_userInstruction_appearsBeforeCategoryInstruction() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0x00]), "audio/mp4")],
            context: fullCtx(),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        let userIdx = indexOfPart(prefix: "User instruction:", in: texts)
        let categoryIdx = indexOfPart(prefix: "Category instruction:", in: texts)
        XCTAssertNotNil(userIdx)
        XCTAssertNotNil(categoryIdx)
        XCTAssertLessThan(userIdx!, categoryIdx!,
            "user instruction must appear before category instruction (user wins on conflicts)")
    }

    func test_userDictionary_appearsAfterCategoryInstruction_beforeInsertionTarget() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0x00]), "audio/mp4")],
            context: fullCtx(),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        let categoryIdx = indexOfPart(prefix: "Category instruction:", in: texts)
        let dictIdx = indexOfPart(prefix: "User dictionary:", in: texts)
        let insertIdx = indexOfPart(prefix: "Insertion target:", in: texts)
        XCTAssertNotNil(categoryIdx)
        XCTAssertNotNil(dictIdx)
        XCTAssertNotNil(insertIdx)
        XCTAssertLessThan(categoryIdx!, dictIdx!,
            "User dictionary must appear after Category instruction")
        XCTAssertLessThan(dictIdx!, insertIdx!,
            "User dictionary must appear before Insertion target")
    }

    // MARK: - Conditional omission

    func test_emptyUserInstruction_sectionOmitted() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(
                category: .messaging,
                userInstruction: "",
                categoryInstruction: "messaging stays short"
            ),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        XCTAssertEqual(texts.count, 7,
            "empty user instruction omits the User instruction section (7 parts: app+cat instr+dict+target+screen+priors+instr)")
        XCTAssertNil(indexOfPart(prefix: "User instruction:", in: texts),
            "User instruction section must be absent when empty")
        XCTAssertNotNil(indexOfPart(prefix: "Category instruction:", in: texts))
        XCTAssertNotNil(indexOfPart(prefix: "User dictionary:", in: texts),
            "User dictionary section must always be present")
    }

    func test_uncategorized_categoryInstructionOmitted() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(
                category: .uncategorized,
                userInstruction: "prefer Em-dashes",
                categoryInstruction: nil
            ),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        XCTAssertEqual(texts.count, 7,
            "nil category instruction omits the Category instruction section (7 parts)")
        XCTAssertNotNil(indexOfPart(prefix: "User instruction:", in: texts))
        XCTAssertNil(indexOfPart(prefix: "Category instruction:", in: texts),
            "Category instruction section must be absent when nil")
        XCTAssertNotNil(indexOfPart(prefix: "User dictionary:", in: texts),
            "User dictionary section must always be present")
        XCTAssertTrue(texts[0].contains("Category: uncategorized"))
    }

    func test_searchCategory_inFirstPart() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(
                category: .search,
                userInstruction: "",
                categoryInstruction: AppCategory.search.defaultPrompt
            ),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        XCTAssertTrue(texts[0].contains("Category: search"),
            "search-override resolved category must appear in the first prompt part")
        XCTAssertNotNil(indexOfPart(prefix: "Category instruction:", in: texts))
    }

    func test_userInstruction_bodyMatchesContextValue() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(
                category: .messaging,
                userInstruction: "use markdown sparingly",
                categoryInstruction: "chat: keep it short"
            ),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        let userPart = try? XCTUnwrap(texts.first { $0.hasPrefix("User instruction:") })
        XCTAssertEqual(userPart, "User instruction:\nuse markdown sparingly")
    }

    func test_categoryInstruction_bodyPicksWhateverContextHolds() {
        let custom = "MY CUSTOM EMAIL PROMPT — never use semicolons"
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(category: .email, categoryInstruction: custom),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        let catPart = try? XCTUnwrap(texts.first { $0.hasPrefix("Category instruction:") })
        XCTAssertEqual(catPart, "Category instruction:\n\(custom)")
    }

    // MARK: - User dictionary rendering

    func test_userDictionary_emptyRendersEmptyBody_sectionStillPresent() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(dictionary: []),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        let dict = try? XCTUnwrap(texts.first { $0.hasPrefix("User dictionary:") })
        XCTAssertEqual(dict, "User dictionary:\n  (empty)",
            "empty dictionary renders as `(empty)`, section is never dropped")
    }

    func test_userDictionary_rendersCommaSeparated() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(dictionary: ["NoType", "Anthropic", "Wispr Flow"]),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        let dict = try? XCTUnwrap(texts.first { $0.hasPrefix("User dictionary:") })
        XCTAssertEqual(dict, "User dictionary:\n  NoType, Anthropic, Wispr Flow")
    }

    func test_userDictionary_byteStable_betweenChunks_ofSameSession() {
        let dict = ["Apple", "Cyrillic"]
        let bodyA = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: fullCtx(dictionary: dict),
            priorTranscripts: ["a"],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 2)
        )
        let bodyB = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: fullCtx(dictionary: dict),
            priorTranscripts: ["a", "b"],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 3)
        )
        let a = textParts(bodyA)
        let b = textParts(bodyB)
        let aIdx = indexOfPart(prefix: "User dictionary:", in: a)!
        let bIdx = indexOfPart(prefix: "User dictionary:", in: b)!
        XCTAssertEqual(a[aIdx], b[bIdx],
            "User dictionary section must be byte-stable across chunks of the same session")
    }

    // MARK: - System instruction & generation config

    func test_systemInstructionAndGenerationConfig() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        XCTAssertNotNil(body.systemInstruction)
        XCTAssertEqual(body.generationConfig?.topP, 0.2)
        XCTAssertEqual(body.generationConfig?.responseMimeType, "text/plain")
        XCTAssertEqual(body.generationConfig?.thinkingConfig?.thinkingLevel, "MINIMAL")
    }

    /// Pins the anti-completion clause in BOTH system prompts. Closes the
    /// autoregressive-completion class of hallucinations (model adds words
    /// at the end of a phrase, or inserts smoothing connectives in the
    /// middle, that the speaker did not actually say) which is orthogonal
    /// to context leakage. Anchor phrase "Never extend, smooth, or
    /// complete" is intentionally unique — `smooth` does not appear
    /// anywhere else in either prompt.
    func test_systemPrompts_pinAntiCompletionClause() {
        func systemText(_ body: GeminiAPI.Request) -> String {
            guard let parts = body.systemInstruction?.parts else { return "" }
            for p in parts {
                if case .text(let s) = p { return s }
            }
            return ""
        }
        let fullBody = GeminiClient.buildRequestBody(
            audios: [(Data([0x00]), "audio/mp4")],
            context: ctx(),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let liteBody = GeminiClient.buildLiteRequestBody(
            audio: Data([0x00]),
            mimeType: "audio/mp4",
            context: ctx(),
            instruction: GeminiClient.liteChunkInstruction()
        )
        let fullSys = systemText(fullBody)
        let liteSys = systemText(liteBody)

        XCTAssertTrue(fullSys.contains("Never extend, smooth, or complete"),
            "Full system prompt must forbid LM-driven extension/smoothing/completion of audio")
        XCTAssertTrue(fullSys.contains("An abruptly ending sentence is correct"),
            "Full system prompt must include the anchor preferring abrupt cut-off over invented completion")

        XCTAssertTrue(liteSys.contains("never extend, smooth, or complete"),
            "Lite system prompt must forbid LM-driven extension/smoothing/completion of audio")
        XCTAssertTrue(liteSys.contains("An abruptly ending sentence is correct"),
            "Lite system prompt must include the anchor preferring abrupt cut-off over invented completion")
    }

    // MARK: - Empty-section preservation for non-optional sections

    func test_emptyInsertionTarget_sectionStillPresent() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(before: "", after: ""),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let texts = textParts(body)
        let it = try? XCTUnwrap(texts.first { $0.hasPrefix("Insertion target:") })
        XCTAssertTrue(it?.contains("Text before cursor: \"\"") == true)
        XCTAssertTrue(it?.contains("Text after cursor: \"\"") == true)
    }

    func test_emptyPriors_renderedAsNoneYet_notDropped() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let priors = try? XCTUnwrap(textParts(body).first { $0.hasPrefix("Prior chunks (this session):") })
        XCTAssertTrue(priors?.contains("(none yet)") == true)
    }

    // MARK: - Cache-friendly monotonicity

    func test_priorsAreMonotone_chunkN_isPrefixOf_chunkNPlus1() {
        let priors2 = GeminiClient.formatPriorTranscripts(["first chunk text"])
        let priors3 = GeminiClient.formatPriorTranscripts(["first chunk text", "second chunk text"])
        XCTAssertTrue(priors3.hasPrefix(priors2),
                      "priors for N+1 must extend priors for N (cache monotonicity)")
    }

    func test_emptyPriors_isPrefixOf_oneChunk_FALSE() {
        let none = GeminiClient.formatPriorTranscripts([])
        let one = GeminiClient.formatPriorTranscripts(["hello"])
        XCTAssertFalse(one.hasPrefix(none))
    }

    func test_byteStable_betweenChunks_ofSameSession() {
        // Same context (user instruction + category + dictionary frozen
        // for the session) — parts 0..6 must be byte-equal between
        // chunks N and N+1, with part 6 (priors) growing monotonically.
        // Only the per-call instruction differs.
        let context = fullCtx(
            category: .email,
            userInstruction: "use plain language",
            categoryInstruction: "Email: greet and sign off.",
            dictionary: ["Anthropic"]
        )
        let bodyN = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: context,
            priorTranscripts: ["hello"],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 2)
        )
        let bodyN1 = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: context,
            priorTranscripts: ["hello", "world"],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 3)
        )
        let n = textParts(bodyN)
        let n1 = textParts(bodyN1)
        XCTAssertEqual(n.count, 8)
        XCTAssertEqual(n1.count, 8)
        for i in 0..<6 {
            XCTAssertEqual(n[i], n1[i],
                "part \(i) must be byte-stable across chunks of the same session")
        }
        XCTAssertTrue(n1[6].hasPrefix(n[6]),
            "priors must extend monotonically between consecutive chunks")
        XCTAssertNotEqual(n[7], n1[7], "per-call instruction differs by chunk number")
    }

    // MARK: - Insertion target rendering

    func test_insertionTarget_escapesQuotesAndNewlines() {
        let it = InsertionTarget(
            textBefore: "Hi \"John\"\nand bye",
            textAfter: "tab\there"
        )
        let rendered = GeminiClient.formatInsertionTarget(it)
        XCTAssertFalse(rendered.contains("Hi \"John\""))
        XCTAssertTrue(rendered.contains("Hi 'John'"))
        XCTAssertTrue(rendered.contains("\\n"))
        XCTAssertTrue(rendered.contains("\\t"))
    }

    func test_insertionTarget_emptyStrings_renderAsEmptyQuoted() {
        let rendered = GeminiClient.formatInsertionTarget(.empty)
        XCTAssertTrue(rendered.contains("Text before cursor: \"\""))
        XCTAssertTrue(rendered.contains("Text after cursor: \"\""))
    }

    // MARK: - Per-chunk instruction templates

    func test_midChunkInstruction_includesChunkIndexAndIsFinalFalse() {
        let s = GeminiClient.midChunkInstruction(chunkIndex: 3)
        XCTAssertTrue(s.contains("chunk_3"))
        XCTAssertTrue(s.contains("is_final=false"))
    }

    func test_finalChunkInstruction_referencesTextAfterCursor() {
        let s = GeminiClient.finalChunkInstruction(chunkIndex: 4)
        XCTAssertTrue(s.contains("chunk_4"))
        XCTAssertTrue(s.contains("is_final=true"))
        XCTAssertTrue(s.contains("Text after cursor"))
    }

    // MARK: - Batched request

    func test_batchedChunkInstruction_describesRange() {
        let s = GeminiClient.batchedChunkInstruction(indices: [3, 4, 5], isFinal: true)
        XCTAssertTrue(s.contains("chunks 3 through 5"))
        XCTAssertTrue(s.contains("is_final=true"))
        XCTAssertTrue(s.contains("Text after cursor"))
    }

    func test_batchedRequest_hasNInlineDataParts_andSamePrefixShape() {
        let audios: [(Data, String)] = [
            (Data([0x01]), "audio/mp4"),
            (Data([0x02]), "audio/mp4"),
            (Data([0x03]), "audio/mp4"),
        ]
        let body = GeminiClient.buildRequestBody(
            audios: audios,
            context: fullCtx(before: "Hi ", after: " then"),
            priorTranscripts: ["earlier text"],
            instruction: GeminiClient.batchedChunkInstruction(indices: [2, 3, 4], isFinal: true)
        )
        let texts = textParts(body)
        XCTAssertEqual(texts.count, 8, "full-shape prefix has 8 text parts regardless of audio count")
        XCTAssertEqual(inlineCount(body), 3, "3 inline_data parts for a 3-chunk batch")
        XCTAssertTrue(texts[0].hasPrefix("App: "))
        XCTAssertTrue(texts[1].hasPrefix("User instruction:"))
        XCTAssertTrue(texts[2].hasPrefix("Category instruction:"))
        XCTAssertTrue(texts[3].hasPrefix("User dictionary:"))
        XCTAssertTrue(texts[4].hasPrefix("Insertion target:"))
        XCTAssertTrue(texts[5].hasPrefix("On-screen context:"))
        XCTAssertTrue(texts[6].hasPrefix("Prior chunks (this session):"))
        XCTAssertTrue(texts[7].hasPrefix("Now transcribe chunks "))
    }

    func test_singleVsBatch_prefixIsByteIdentical_throughPriors() {
        let context = fullCtx(before: "Same before ", after: " same after")
        let priors = ["chunk1 text"]
        let singleBody = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: context,
            priorTranscripts: priors,
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 2)
        )
        let batchBody = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4"), (Data([1]), "audio/mp4")],
            context: context,
            priorTranscripts: priors,
            instruction: GeminiClient.batchedChunkInstruction(indices: [2, 3], isFinal: true)
        )
        let single = textParts(singleBody)
        let batch = textParts(batchBody)
        XCTAssertEqual(single.count, batch.count, "both paths must have same part count")
        // texts[N-1] is the per-call instruction (differs); everything
        // before that must match byte-for-byte.
        for i in 0..<(single.count - 1) {
            XCTAssertEqual(single[i], batch[i],
                "part \(i) must be byte-equal between single and batched paths")
        }
    }

    // MARK: - OCR fallback sub-block (cache shape unchanged)

    func test_ocrSubBlock_livesInsideOnScreenContextPart_partCountUnchanged() {
        let withoutOCR = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: fullCtx(),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let withOCR = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: fullCtx(screenText: ocrFixture()),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let a = textParts(withoutOCR)
        let b = textParts(withOCR)
        XCTAssertEqual(a.count, b.count,
            "OCR must not introduce a new prompt part")

        let aOnScreenIdx = indexOfPart(prefix: "On-screen context:", in: a)!
        let bOnScreenIdx = indexOfPart(prefix: "On-screen context:", in: b)!
        XCTAssertEqual(aOnScreenIdx, bOnScreenIdx, "On-screen section sits at same index")
        XCTAssertTrue(b[bOnScreenIdx].contains("Screen text (OCR — active window)"))
        XCTAssertTrue(b[bOnScreenIdx].contains("#engineering"))
    }

    func test_ocrSubBlock_absent_whenScreenTextNil_partBodyUnchanged() {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let onScreen = try? XCTUnwrap(textParts(body).first { $0.hasPrefix("On-screen context:") })
        XCTAssertFalse(onScreen?.contains("Screen text (OCR") == true)
    }

    func test_partOrderAndLabels_stableWithAndWithoutOCR() {
        // Full-prefix fixture exercises the 8-part shape — User
        // dictionary section is always present at index 3 (after the
        // two optional `*_instruction` sections), and the OCR sub-block
        // lives inside the `On-screen context:` part regardless.
        let prefixesFullShape = [
            "App: ",
            "User instruction:",
            "Category instruction:",
            "User dictionary:",
            "Insertion target:",
            "On-screen context:",
            "Prior chunks (this session):",
        ]
        for screenText in [nil, ocrFixture()] {
            let body = GeminiClient.buildRequestBody(
                audios: [(Data([0]), "audio/mp4")],
                context: fullCtx(screenText: screenText),
                priorTranscripts: [],
                instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
            )
            let texts = textParts(body)
            XCTAssertEqual(texts.count, 8, "full-prefix shape always has 8 text parts")
            for (i, prefix) in prefixesFullShape.enumerated() {
                XCTAssertTrue(texts[i].hasPrefix(prefix),
                    "part \(i) must start with '\(prefix)' (screenText=\(screenText == nil ? "nil" : "set"))")
            }
        }
    }

    // MARK: - JSON encoding (ground-truth)

    func test_encodedJSON_partsOrderSurvivesEncoding() throws {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0xAB]), "audio/mp4")],
            context: fullCtx(before: "before ", after: " after"),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let user = try XCTUnwrap(contents.first)
        let parts = try XCTUnwrap(user["parts"] as? [[String: Any]])

        // 8 text parts + 1 inline_data = 9
        XCTAssertEqual(parts.count, 9)
        XCTAssertTrue((parts[0]["text"] as? String)?.hasPrefix("App: ") ?? false)
        XCTAssertTrue((parts[1]["text"] as? String)?.hasPrefix("User instruction:") ?? false)
        XCTAssertTrue((parts[2]["text"] as? String)?.hasPrefix("Category instruction:") ?? false)
        XCTAssertTrue((parts[3]["text"] as? String)?.hasPrefix("User dictionary:") ?? false)
        XCTAssertTrue((parts[4]["text"] as? String)?.hasPrefix("Insertion target:") ?? false)
        XCTAssertTrue((parts[5]["text"] as? String)?.hasPrefix("On-screen context:") ?? false)
        XCTAssertTrue((parts[6]["text"] as? String)?.hasPrefix("Prior chunks (this session):") ?? false)
        XCTAssertTrue((parts[7]["text"] as? String)?.hasPrefix("Now transcribe chunk_") ?? false)
        XCTAssertNotNil(parts[8]["inline_data"])
    }

    // MARK: - Tools / classifier (negative)

    func test_transcriptionRequest_doesNotIncludeTools() throws {
        let body = GeminiClient.buildRequestBody(
            audios: [(Data([0]), "audio/mp4")],
            context: ctx(),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["tools"], "transcription requests must not declare tools")
    }

    // MARK: - Short-session lite path
    //
    // The lite path (see `GeminiClient.buildLiteRequestBody` and
    // `RecordingSession.shouldUseLitePath`) has a different prompt shape
    // from the full path on purpose: it drops `On-screen context:` and
    // `Prior chunks (this session):`, uses `systemPromptLite`, and uses
    // a single-audio per-call instruction. Lite and full are different
    // cache namespaces — by design.

    func test_litePrompt_omitsOnScreenContext_andPriorChunks() {
        let body = GeminiClient.buildLiteRequestBody(
            audio: Data([0x00]),
            mimeType: "audio/mp4",
            context: ctx(before: "Hi ", after: " then"),
            instruction: GeminiClient.liteChunkInstruction()
        )
        let texts = textParts(body)
        for t in texts {
            XCTAssertFalse(t.hasPrefix("On-screen context:"),
                "lite path must not include the On-screen context section: \(t)")
            XCTAssertFalse(t.hasPrefix("Prior chunks (this session):"),
                "lite path must not include the Prior chunks section: \(t)")
        }
    }

    func test_litePrompt_keepsInsertionTarget_andUserDictionary() {
        let body = GeminiClient.buildLiteRequestBody(
            audio: Data([0x00]),
            mimeType: "audio/mp4",
            context: ctx(dictionary: ["NoType", "Anthropic"], before: "Hi ", after: " then"),
            instruction: GeminiClient.liteChunkInstruction()
        )
        let texts = textParts(body)
        XCTAssertNotNil(indexOfPart(prefix: "Insertion target:", in: texts),
            "lite path must keep Insertion target — boundary handling depends on it")
        let dictIdx = indexOfPart(prefix: "User dictionary:", in: texts)
        XCTAssertNotNil(dictIdx, "lite path must keep User dictionary")
        XCTAssertTrue(texts[dictIdx!].contains("NoType, Anthropic"))
    }

    func test_litePrompt_minimumShape_fivePartsInOrder() {
        // Uncategorized + no user instruction + empty dictionary →
        // App+Category, User dictionary, Insertion target, instruction,
        // audio. Five textual parts + one inline_data.
        let body = GeminiClient.buildLiteRequestBody(
            audio: Data([0x00]),
            mimeType: "audio/mp4",
            context: ctx(),
            instruction: GeminiClient.liteChunkInstruction()
        )
        let texts = textParts(body)
        XCTAssertEqual(texts.count, 4,
            "lite minimum: App+Category, User dictionary, Insertion target, instruction (4 text parts)")
        XCTAssertTrue(texts[0].hasPrefix("App: "))
        XCTAssertTrue(texts[0].contains("Category: uncategorized"))
        XCTAssertTrue(texts[1].hasPrefix("User dictionary:"))
        XCTAssertTrue(texts[2].hasPrefix("Insertion target:"))
        XCTAssertTrue(texts[3].hasPrefix("Transcribe the audio."),
            "lite per-call instruction starts with 'Transcribe the audio.'")
        XCTAssertEqual(inlineCount(body), 1)
    }

    func test_litePrompt_fullShape_sixPartsInOrder() {
        // Classified category + non-empty user instruction + non-empty
        // dictionary → App+Category, User instruction, Category
        // instruction, User dictionary, Insertion target, instruction.
        // Six textual parts + one inline_data.
        let body = GeminiClient.buildLiteRequestBody(
            audio: Data([0x00]),
            mimeType: "audio/mp4",
            context: fullCtx(before: "Hi ", after: " then"),
            instruction: GeminiClient.liteChunkInstruction()
        )
        let texts = textParts(body)
        XCTAssertEqual(texts.count, 6,
            "lite full: +User instruction, +Category instruction → 6 text parts")
        XCTAssertTrue(texts[0].hasPrefix("App: "))
        XCTAssertTrue(texts[1].hasPrefix("User instruction:"))
        XCTAssertTrue(texts[2].hasPrefix("Category instruction:"))
        XCTAssertTrue(texts[3].hasPrefix("User dictionary:"))
        XCTAssertTrue(texts[4].hasPrefix("Insertion target:"))
        XCTAssertTrue(texts[5].hasPrefix("Transcribe the audio."))
        XCTAssertEqual(inlineCount(body), 1)
    }

    func test_litePrompt_usesSeparateSystemInstruction() {
        let liteBody = GeminiClient.buildLiteRequestBody(
            audio: Data([0x00]),
            mimeType: "audio/mp4",
            context: ctx(),
            instruction: GeminiClient.liteChunkInstruction()
        )
        let fullBody = GeminiClient.buildRequestBody(
            audios: [(Data([0x00]), "audio/mp4")],
            context: ctx(),
            priorTranscripts: [],
            instruction: GeminiClient.midChunkInstruction(chunkIndex: 1)
        )
        func systemText(_ body: GeminiAPI.Request) -> String? {
            guard let parts = body.systemInstruction?.parts else { return nil }
            for p in parts {
                if case .text(let s) = p { return s }
            }
            return nil
        }
        let liteSys = systemText(liteBody)
        let fullSys = systemText(fullBody)
        XCTAssertNotNil(liteSys)
        XCTAssertNotNil(fullSys)
        XCTAssertNotEqual(liteSys, fullSys,
            "lite must use a separate, trimmed system instruction (different cache namespace)")
        // Spot-check: lite must NOT reference omitted sections.
        let liteText = liteSys ?? ""
        XCTAssertFalse(liteText.contains("On-screen context"),
            "lite system prompt must not reference On-screen context")
        XCTAssertFalse(liteText.contains("Prior chunks"),
            "lite system prompt must not reference Prior chunks")
        XCTAssertFalse(liteText.contains("Screen text (OCR"),
            "lite system prompt must not reference OCR sub-block")
        XCTAssertFalse(liteText.contains("batched"),
            "lite system prompt must not reference batched mode")
    }

    func test_litePrompt_doesNotIncludeTools() throws {
        let body = GeminiClient.buildLiteRequestBody(
            audio: Data([0x00]),
            mimeType: "audio/mp4",
            context: ctx(),
            instruction: GeminiClient.liteChunkInstruction()
        )
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["tools"], "lite transcription requests must not declare tools")
    }
}
