import XCTest
@testable import NoType

/// Live-API eval suite for the Gemini transcription prompts. Drives
/// each audio fixture in `NoTypeTests/Fixtures/` through the
/// appropriate prompt path and checks the fixture's `mustContain` /
/// `mustNotContain` / `wordCountFloor` contract.
///
/// **Gated on API-key presence only.** Tests skip cleanly via
/// `XCTSkip` when neither `NOTYPE_GEMINI_KEY` env var nor the
/// `app.notype.tests.gemini` Keychain entry is set. On a dev machine
/// with the Keychain entry configured (see
/// `NoTypeTests/Fixtures/README.md`), the suite runs automatically on
/// every `xcodebuild test`. To opt out for a specific run, pass
/// `-skip-testing:NoTypeTests/PromptEvalTests`.
///
/// To run locally (after one-shot Keychain setup):
///
/// ```
/// xcodebuild test -project NoType.xcodeproj -scheme NoType \
///   -only-testing:NoTypeTests/PromptEvalTests
/// ```
///
/// See `NoTypeTests/Fixtures/README.md` for fixture-recording recipes
/// and `NoTypeTests/PromptEvalHarness.swift` for the underlying API.
///
/// Test naming convention: `test_<fixtureID>_<path>_<contextVariant>`
/// — e.g. `test_greetingRuLong_full_messaging_emptyInsertion`. Names
/// are verbose on purpose so a failing-test report tells you exactly
/// which matrix cell broke without cross-referencing this file.
final class PromptEvalTests: XCTestCase {

    // MARK: - Lifecycle

    private var client: GeminiClient!
    private var fixtures: [PromptEvalHarness.Fixture] = []

    override func setUp() async throws {
        try await super.setUp()
        client = GeminiClient()
        fixtures = try PromptEvalHarness.loadFixtures()
    }

    override func tearDown() async throws {
        client = nil
        fixtures = []
        try await super.tearDown()
    }

    // MARK: - Baselines (one per fixture)
    //
    // Each test drives one fixture through the path it would hit in
    // production for its natural duration, with a neutral context.
    // These establish the per-fixture "does the current prompt
    // transcribe this correctly?" baseline that U2's audit + U3's
    // trims must preserve.

    func test_multiSentenceEN_full() async throws {
        try PromptEvalHarness.skipIfMissingKey()
        let fx = try PromptEvalHarness.fixture("multi_sentence_en", in: fixtures)
        let res = try await PromptEvalHarness.transcribe(
            fixture: fx,
            context: PromptEvalHarness.neutralContext(),
            path: .full,
            client: client
        )
        logResult(res)
        PromptEvalHarness.assertContract(res, against: fx)
    }

    func test_multiSentenceDE_full() async throws {
        try PromptEvalHarness.skipIfMissingKey()
        let fx = try PromptEvalHarness.fixture("multi_sentence_de", in: fixtures)
        let res = try await PromptEvalHarness.transcribe(
            fixture: fx,
            context: PromptEvalHarness.neutralContext(),
            path: .full,
            client: client
        )
        logResult(res)
        PromptEvalHarness.assertContract(res, against: fx)
    }

    func test_codeSwitchEnEs_full() async throws {
        try PromptEvalHarness.skipIfMissingKey()
        let fx = try PromptEvalHarness.fixture("code_switch_en_es", in: fixtures)
        let res = try await PromptEvalHarness.transcribe(
            fixture: fx,
            context: PromptEvalHarness.neutralContext(),
            path: .full,
            client: client
        )
        logResult(res)
        PromptEvalHarness.assertContract(res, against: fx)
    }

    func test_singleWordAmbiguous_lite() async throws {
        try PromptEvalHarness.skipIfMissingKey()
        let fx = try PromptEvalHarness.fixture("single_word_ambiguous", in: fixtures)
        // 1.49 s — naturally lite.
        let res = try await PromptEvalHarness.transcribe(
            fixture: fx,
            context: PromptEvalHarness.neutralContext(),
            path: .lite,
            client: client
        )
        logResult(res)
        PromptEvalHarness.assertContract(res, against: fx)
    }

    func test_pleaseSummarizeEN_full() async throws {
        try PromptEvalHarness.skipIfMissingKey()
        let fx = try PromptEvalHarness.fixture("please_summarize_en", in: fixtures)
        let res = try await PromptEvalHarness.transcribe(
            fixture: fx,
            context: PromptEvalHarness.neutralContext(),
            path: .full,
            client: client
        )
        logResult(res)
        PromptEvalHarness.assertContract(res, against: fx)
    }

    func test_silenceOnly_full() async throws {
        try PromptEvalHarness.skipIfMissingKey()
        let fx = try PromptEvalHarness.fixture("silence_only", in: fixtures)
        let res = try await PromptEvalHarness.transcribe(
            fixture: fx,
            context: PromptEvalHarness.neutralContext(),
            path: .full,
            client: client
        )
        logResult(res)
        // Silence → empty string expected. `wordCountFloor: 0` means
        // the assertion contract doesn't enforce a length floor; the
        // `mustNotContain` list catches accidental hallucinated tokens.
        PromptEvalHarness.assertContract(res, against: fx)
    }

    func test_longMonologueEN_full() async throws {
        try PromptEvalHarness.skipIfMissingKey()
        let fx = try PromptEvalHarness.fixture("long_monologue_en", in: fixtures)
        let res = try await PromptEvalHarness.transcribe(
            fixture: fx,
            context: PromptEvalHarness.neutralContext(),
            path: .full,
            client: client
        )
        logResult(res)
        PromptEvalHarness.assertContract(res, against: fx)
    }

    // MARK: - U4 matrix — greeting_ru × natural-path × context
    //
    // 8 combinations. Each greeting variant runs through *its natural
    // path only* (short → lite, long → full) so the test exercises
    // the prompt path that would actually be served in production
    // for that audio length. Insertion-target × category dimensions
    // probe the chat-reflex amplifiers from KTD-5.

    // ─── greeting_ru (1.07 s) → lite path ───

    func test_greetingRu_lite_uncategorized_emptyInsertion() async throws {
        try await runGreeting(
            fixtureID: "greeting_ru",
            path: .lite,
            context: PromptEvalHarness.context(
                category: .uncategorized,
                textBefore: "",
                textAfter: ""
            )
        )
    }

    func test_greetingRu_lite_uncategorized_midSentenceInsertion() async throws {
        try await runGreeting(
            fixtureID: "greeting_ru",
            path: .lite,
            context: PromptEvalHarness.context(
                category: .uncategorized,
                textBefore: "I just wanted to say ",
                textAfter: ""
            )
        )
    }

    func test_greetingRu_lite_messaging_emptyInsertion() async throws {
        try await runGreeting(
            fixtureID: "greeting_ru",
            path: .lite,
            context: PromptEvalHarness.messagingContext(
                textBefore: "",
                textAfter: ""
            )
        )
    }

    func test_greetingRu_lite_messaging_midSentenceInsertion() async throws {
        try await runGreeting(
            fixtureID: "greeting_ru",
            path: .lite,
            context: PromptEvalHarness.messagingContext(
                textBefore: "I just wanted to say ",
                textAfter: ""
            )
        )
    }

    // ─── greeting_ru_long (2.43 s) → full path; this is the variant
    //     that matches the user's reported incident.

    func test_greetingRuLong_full_uncategorized_emptyInsertion() async throws {
        try await runGreeting(
            fixtureID: "greeting_ru_long",
            path: .full,
            context: PromptEvalHarness.context(
                category: .uncategorized,
                textBefore: "",
                textAfter: ""
            )
        )
    }

    func test_greetingRuLong_full_uncategorized_midSentenceInsertion() async throws {
        try await runGreeting(
            fixtureID: "greeting_ru_long",
            path: .full,
            context: PromptEvalHarness.context(
                category: .uncategorized,
                textBefore: "I just wanted to say ",
                textAfter: ""
            )
        )
    }

    func test_greetingRuLong_full_messaging_emptyInsertion() async throws {
        try await runGreeting(
            fixtureID: "greeting_ru_long",
            path: .full,
            context: PromptEvalHarness.messagingContext(
                textBefore: "",
                textAfter: ""
            )
        )
    }

    func test_greetingRuLong_full_messaging_midSentenceInsertion() async throws {
        try await runGreeting(
            fixtureID: "greeting_ru_long",
            path: .full,
            context: PromptEvalHarness.messagingContext(
                textBefore: "I just wanted to say ",
                textAfter: ""
            )
        )
    }

    // MARK: - Helpers

    private func runGreeting(
        fixtureID: String,
        path: PromptEvalHarness.Path,
        context: ContextSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try PromptEvalHarness.skipIfMissingKey()
        let fx = try PromptEvalHarness.fixture(fixtureID, in: fixtures)
        let res = try await PromptEvalHarness.transcribe(
            fixture: fx,
            context: context,
            path: path,
            client: client
        )
        logResult(res, contextDescription: describe(context))
        PromptEvalHarness.assertContract(res, against: fx, file: file, line: line)
    }

    /// Short one-line description of a context for the test log.
    private func describe(_ c: ContextSnapshot) -> String {
        let before = c.insertionTarget.textBefore.isEmpty ? "empty" : "'\(c.insertionTarget.textBefore)'"
        let after = c.insertionTarget.textAfter.isEmpty ? "empty" : "'\(c.insertionTarget.textAfter)'"
        return "cat=\(c.category.rawValue) app=\(c.activeApp.name) before=\(before) after=\(after)"
    }

    /// Print a transcript so passing test runs leave useful audit
    /// signal in the log. XCTest captures stdout per test method.
    private func logResult(
        _ res: PromptEvalHarness.Result,
        contextDescription: String? = nil
    ) {
        let ctx = contextDescription.map { " | ctx: \($0)" } ?? ""
        var tokens = ""
        if let u = res.usage {
            let prompt = u.promptTokenCount ?? 0
            let cached = u.cachedContentTokenCount ?? 0
            let out = u.candidatesTokenCount ?? 0
            tokens = " | tokens prompt=\(prompt) cached=\(cached) out=\(out)"
        }
        print("[\(res.fixtureID) | \(res.path) | \(res.elapsedMs)ms\(tokens)\(ctx)] → \"\(res.transcript)\"")
    }
}
