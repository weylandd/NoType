import Foundation
import XCTest
@testable import NoType

/// Live-API eval harness for the Gemini transcription prompts. Loads
/// audio fixtures from `NoTypeTests/Fixtures/`, drives them through
/// `GeminiClient.transcribe` / `.transcribeShort`, and provides
/// assertion helpers that check the fixture's `mustContain` /
/// `mustNotContain` / `wordCountFloor` contract.
///
/// Tests using this harness MUST call `skipIfNotIntegration()` at the
/// start of every test so the standard `xcodebuild test` run skips
/// them cleanly. Live API tests fire only when both env vars are set:
///
/// - `NOTYPE_INTEGRATION=1`
/// - `NOTYPE_GEMINI_KEY=<key>`
///
/// Fixture loading uses `#filePath` rather than `Bundle(for:)` /
/// `Bundle.module` — these tests are dev-machine-only by design
/// (gated by `NOTYPE_INTEGRATION`), so the compile-time source path
/// always resolves correctly. This avoids wiring the audio files
/// through `project.yml`'s resource pipeline.
///
/// See `NoTypeTests/Fixtures/README.md` for the fixture format
/// contract and `docs/plans/2026-05-17-001-refactor-gemini-prompt-audit-and-trim-plan.md`
/// U1 for why this exists.
enum PromptEvalHarness {

    // MARK: - Fixture metadata

    /// Decoded entry from `audio_fixtures.json`. Underscore-prefixed
    /// JSON fields are documentation aids (`_duration_s`,
    /// `_natural_path`, `_assertion_note`) and are intentionally not
    /// decoded — they exist for readers of the JSON, not the harness.
    struct Fixture: Decodable, Sendable {
        let id: String
        let file: String
        let language: String
        let expectedTranscript: String
        let mustContain: [String]
        let mustNotContain: [String]
        let wordCountFloor: Int
        /// Upper bound for `promptTokenCount + cachedContentTokenCount`.
        /// Reserved for a later harness iteration — see the TODO at the
        /// bottom of this file. Currently parsed but not asserted.
        let usageTokensCeiling: Int?
        let notes: String?
    }

    struct FixturesFile: Decodable, Sendable {
        let fixtures: [Fixture]
    }

    /// Which Gemini path to drive a fixture through. The choice is
    /// **forced** at the Swift level (different `GeminiClient` method),
    /// not derived from audio duration. This lets the test matrix
    /// exercise both prompts regardless of fixture length.
    enum Path: Sendable {
        case full   // → GeminiClient.transcribe (systemPrompt)
        case lite   // → GeminiClient.transcribeShort (systemPromptLite)
    }

    struct Result: Sendable {
        let fixtureID: String
        let path: Path
        let transcript: String
        let elapsedMs: Int
    }

    // MARK: - Key resolution + skip gates

    /// Dedicated Keychain service for the eval suite — NOT the
    /// production service (`app.notype.gemini`). Production's ACL
    /// is keyed on the main app's designated requirement
    /// (`identifier "app.notype"`); the xctest process's identifier
    /// is different, so it can't silently read the production entry
    /// without prompting the user. This separate service lets the
    /// maintainer drop a test-only key with broad ACL (via
    /// `security … -A`) without weakening the production entry's
    /// security model.
    ///
    /// Setup is documented in `NoTypeTests/Fixtures/README.md` —
    /// see "Setting the API key for the eval suite".
    static let testKeychainService = "app.notype.tests.gemini"
    static let testKeychainAccount = "default"

    /// Source of the resolved API key — useful in test logs so a
    /// failed test makes clear *which* key was used (or that one
    /// wasn't found at all).
    enum KeySource: String, Sendable {
        case environment   // NOTYPE_GEMINI_KEY env var
        case keychain      // app.notype.tests.gemini Keychain entry
        case none
    }

    /// Resolve the eval API key. Priority:
    ///   1. `NOTYPE_GEMINI_KEY` env var (CI, ad-hoc override).
    ///   2. Keychain entry `app.notype.tests.gemini` / `default`.
    ///   3. None — caller should `XCTSkip` with setup instructions.
    ///
    /// **Never** falls back to the production Keychain entry
    /// (`app.notype.gemini`) — that would couple eval runs to the
    /// production key's lifecycle and trip the ACL prompt.
    static func resolveAPIKey() -> (key: String, source: KeySource) {
        // 1. Env var.
        let envKey = (ProcessInfo.processInfo.environment["NOTYPE_GEMINI_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !envKey.isEmpty {
            return (envKey, .environment)
        }

        // 2. Keychain. `try?` collapses both "not found" (nil) and
        // any access error (ACL mismatch, daemon flake) into the
        // same "missing" outcome — the test will skip rather than
        // throw an unhelpful trace.
        if let keychainKey = (try? KeychainStore.load(
            service: testKeychainService,
            account: testKeychainAccount
        ))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainKey.isEmpty {
            return (keychainKey, .keychain)
        }

        return ("", .none)
    }

    /// Throws `XCTSkip` unless `NOTYPE_INTEGRATION=1` is set AND an
    /// API key can be resolved (via env var or Keychain — see
    /// `resolveAPIKey()`). Call at the top of every test method
    /// that uses the harness — this is the only thing that keeps
    /// the standard `xcodebuild test` run free of live API calls.
    static func skipIfNotIntegration() throws {
        guard ProcessInfo.processInfo.environment["NOTYPE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set NOTYPE_INTEGRATION=1 to run prompt eval tests.")
        }
        let (key, source) = resolveAPIKey()
        guard !key.isEmpty else {
            throw XCTSkip("""
            No Gemini API key found for the eval suite. Set one of:
              1. NOTYPE_GEMINI_KEY=<key> env var, OR
              2. Keychain entry: security add-generic-password \\
                   -s \(testKeychainService) -a \(testKeychainAccount) \\
                   -w "<key>" -U -A
            See NoTypeTests/Fixtures/README.md for details.
            """)
        }
        // Source is captured here for diagnostic completeness even
        // though we don't surface it from this gate — the harness's
        // `apiKey` accessor below returns the same resolution.
        _ = source
    }

    /// Resolved API key (env var → Keychain → empty). Trimmed.
    /// Empty string means no key was found — callers are expected
    /// to have already gone through `skipIfNotIntegration()` which
    /// throws `XCTSkip` in that case.
    static var apiKey: String {
        resolveAPIKey().key
    }

    // MARK: - Fixture loading

    /// Path to the `Fixtures/` directory, resolved from this source
    /// file's location at compile time. Tests run from DerivedData,
    /// but `#filePath` is captured at build time so the absolute path
    /// to the repo source tree is always available.
    private static var fixturesDirURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // → NoTypeTests/
            .appendingPathComponent("Fixtures") // → NoTypeTests/Fixtures/
    }

    static func loadFixtures() throws -> [Fixture] {
        let jsonURL = fixturesDirURL.appendingPathComponent("audio_fixtures.json")
        let data = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(FixturesFile.self, from: data)
        return decoded.fixtures
    }

    static func fixture(_ id: String, in fixtures: [Fixture]) throws -> Fixture {
        guard let match = fixtures.first(where: { $0.id == id }) else {
            throw HarnessError.fixtureNotFound(id)
        }
        return match
    }

    static func audio(for fixture: Fixture) throws -> Data {
        try Data(contentsOf: fixturesDirURL.appendingPathComponent(fixture.file))
    }

    // MARK: - Transcription

    /// Drive a fixture through the chosen Gemini path and return the
    /// transcript + wall-clock elapsed time.
    ///
    /// Errors from `GeminiClient` propagate as-is — recoverable failures
    /// (HTTP 5xx, decoding, empty mid-session) are NOT swallowed here;
    /// the harness is intentionally strict so a real production
    /// failure is visible to the test (rather than becoming a `[…]`
    /// marker like `RecordingSession` does in production).
    static func transcribe(
        fixture: Fixture,
        context: ContextSnapshot,
        path: Path,
        client: GeminiClient
    ) async throws -> Result {
        let audioData = try audio(for: fixture)
        let key = apiKey
        let start = Date()
        let transcript: String
        switch path {
        case .full:
            transcript = try await client.transcribe(
                audio: audioData,
                mimeType: "audio/mp4",
                context: context,
                priorTranscripts: [],
                chunkIndex: 1,
                isFinal: true,
                apiKey: key
            )
        case .lite:
            transcript = try await client.transcribeShort(
                audio: audioData,
                mimeType: "audio/mp4",
                context: context,
                apiKey: key
            )
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        return Result(
            fixtureID: fixture.id,
            path: path,
            transcript: transcript,
            elapsedMs: elapsedMs
        )
    }

    // MARK: - Assertions

    /// Run all of a fixture's assertions against a transcript.
    /// Substring match is **case-sensitive** — this is load-bearing
    /// for the German noun-capitalisation contract (the `Dokument` /
    /// `dokument` distinction). If you find yourself wanting to lower
    /// the casing requirement, add an explicit `_caseInsensitive`
    /// variant to the JSON schema rather than relaxing the default.
    static func assertContract(
        _ result: Result,
        against fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for needle in fixture.mustContain {
            XCTAssertTrue(
                result.transcript.contains(needle),
                "\(fixture.id) [\(result.path)] mustContain: missing '\(needle)' in transcript '\(result.transcript)'",
                file: file,
                line: line
            )
        }
        for poison in fixture.mustNotContain {
            XCTAssertFalse(
                result.transcript.contains(poison),
                "\(fixture.id) [\(result.path)] mustNotContain: found forbidden '\(poison)' in transcript '\(result.transcript)'",
                file: file,
                line: line
            )
        }
        if fixture.wordCountFloor > 0 {
            let words = result.transcript
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                .filter { !$0.isEmpty }
            XCTAssertGreaterThanOrEqual(
                words.count,
                fixture.wordCountFloor,
                "\(fixture.id) [\(result.path)] wordCountFloor: got \(words.count) words, need ≥ \(fixture.wordCountFloor). Transcript: '\(result.transcript)'",
                file: file,
                line: line
            )
        } else {
            // wordCountFloor == 0 — silence / empty-audio fixtures.
            // The transcript should be empty or near-empty. We don't
            // enforce strict emptiness here because Gemini occasionally
            // returns a leading whitespace character on silence; the
            // `mustNotContain` list catches actual hallucinated tokens.
        }
    }

    // MARK: - Errors

    enum HarnessError: Error, LocalizedError {
        case fixtureNotFound(String)

        var errorDescription: String? {
            switch self {
            case .fixtureNotFound(let id):
                return "PromptEvalHarness: no fixture with id '\(id)' in audio_fixtures.json"
            }
        }
    }
}

// MARK: - ContextSnapshot helpers
//
// Mirrors `GeminiRequestBuilderTests.ctx(...)` but tuned for the eval
// matrix: every parameter has a sensible default, and the matrix
// variations (insertion-target × category × dictionary) are easy to
// express without repeating field names.

extension PromptEvalHarness {

    /// Default-shape `ContextSnapshot` — uncategorized app, empty
    /// user / category instructions, empty dictionary, empty
    /// insertion target. Use this as the "neutral context" baseline
    /// for fixtures that don't specifically test context interactions.
    static func neutralContext() -> ContextSnapshot {
        ContextSnapshot(
            activeApp: AppInfo(name: "TestApp", bundleID: "app.notype.test.generic"),
            category: .uncategorized,
            userInstruction: "",
            categoryInstruction: nil,
            dictionary: [],
            replacements: [],
            tree: RedactedAXSnapshot(apps: []),
            insertionTarget: InsertionTarget(textBefore: "", textAfter: ""),
            screenText: nil
        )
    }

    /// Context with the user's name / app set so it looks like
    /// dictation into a chat-style messaging app — the worst-case
    /// amplifier for the conversational-reply class. Used by the U4
    /// `greeting_ru` matrix.
    static func messagingContext(
        appName: String = "Telegram",
        bundle: String = "ru.keepcoder.Telegram",
        textBefore: String = "",
        textAfter: String = ""
    ) -> ContextSnapshot {
        ContextSnapshot(
            activeApp: AppInfo(name: appName, bundleID: bundle),
            category: .messaging,
            userInstruction: "",
            categoryInstruction: AppCategory.messaging.defaultPrompt,
            dictionary: [],
            replacements: [],
            tree: RedactedAXSnapshot(apps: []),
            insertionTarget: InsertionTarget(textBefore: textBefore, textAfter: textAfter),
            screenText: nil
        )
    }

    /// Generic context with overridable insertion-target / category —
    /// used by the U4 matrix's other combinations.
    static func context(
        category: AppCategory = .uncategorized,
        appName: String = "TestApp",
        bundle: String = "app.notype.test.generic",
        textBefore: String = "",
        textAfter: String = ""
    ) -> ContextSnapshot {
        ContextSnapshot(
            activeApp: AppInfo(name: appName, bundleID: bundle),
            category: category,
            userInstruction: "",
            categoryInstruction: category == .uncategorized ? nil : category.defaultPrompt,
            dictionary: [],
            replacements: [],
            tree: RedactedAXSnapshot(apps: []),
            insertionTarget: InsertionTarget(textBefore: textBefore, textAfter: textAfter),
            screenText: nil
        )
    }
}

// MARK: - TODO
//
// Token-ceiling assertions (`Fixture.usageTokensCeiling`) are parsed
// but not enforced. To wire them up the harness needs `GeminiClient`
// to surface `UsageMetadata` alongside the transcript — currently
// `transcribe(...)` / `transcribeShort(...)` return `String`.
//
// Options:
//
// 1. Add a test-only `transcribeForEval(...)` entry point that returns
//    `(String, UsageMetadata?)`. Cleanest for prod-API hygiene.
// 2. Publish a `lastUsage` property on the actor that the harness
//    reads after the await returns. Simpler but actor state needs
//    care.
//
// Either way is a separate commit, paired with populating the JSON's
// `usageTokensCeiling` values from a baseline run. See U2 in the plan
// — token deltas are part of the audit, so this lands when U2 starts.
