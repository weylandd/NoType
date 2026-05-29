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
        /// Optional upper bound on transcript word count. Set this
        /// for fixtures where the model is expected to produce zero
        /// or near-zero words (e.g. `silence_only` — empty audio).
        /// Catches hallucinated content that wouldn't trigger a
        /// `mustNotContain` substring (since you can't enumerate
        /// every possible English sentence a model might invent).
        /// When `nil`, no ceiling is enforced.
        let wordCountCeiling: Int?
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
        /// Token usage from Gemini's `usageMetadata`. Populated when
        /// the response carried it (typically present on every
        /// successful 200). Nil indicates the harness couldn't read
        /// it — usually means the call failed before the response
        /// was parsed.
        let usage: GeminiAPI.UsageMetadata?
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

    /// Throws `XCTSkip` if no API key can be resolved (neither
    /// `NOTYPE_GEMINI_KEY` env var nor Keychain entry — see
    /// `resolveAPIKey()`). Call at the top of every test method
    /// that uses the harness.
    ///
    /// **Gate design.** Earlier iterations of this harness used a
    /// `NOTYPE_INTEGRATION=1` env-var gate on top of key resolution.
    /// That gate was removed because `xcodebuild test` does not
    /// forward shell env vars to the spawned test process, which
    /// meant the gate could only be flipped via scheme edits — at
    /// which point the env-var ceremony adds no security and
    /// just blocks legitimate "I want these to run automatically"
    /// flows. The Keychain-presence gate is the real safety net:
    /// dev machines with the key configured → run; CI / fresh
    /// machines without setup → skip. To skip the eval suite on
    /// a specific xcodebuild invocation, use
    /// `-skip-testing:NoTypeTests/PromptEvalTests`.
    static func skipIfMissingKey() throws {
        let (key, _) = resolveAPIKey()
        guard !key.isEmpty else {
            throw XCTSkip("""
            No Gemini API key found for the eval suite. Set one of:
              1. NOTYPE_GEMINI_KEY=<key> env var (CI / one-off), OR
              2. Keychain entry: security add-generic-password \\
                   -s \(testKeychainService) -a \(testKeychainAccount) \\
                   -w "<key>" -U -A
            See NoTypeTests/Fixtures/README.md for details.
            """)
        }
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
                apiKey: key,
                model: .flashLite
            )
        case .lite:
            transcript = try await client.transcribeShort(
                audio: audioData,
                mimeType: "audio/mp4",
                context: context,
                apiKey: key,
                model: .flashLite
            )
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        let usage = await client.lastUsage
        return Result(
            fixtureID: fixture.id,
            path: path,
            transcript: transcript,
            elapsedMs: elapsedMs,
            usage: usage
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
        let words = result.transcript
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .filter { !$0.isEmpty }
        if fixture.wordCountFloor > 0 {
            XCTAssertGreaterThanOrEqual(
                words.count,
                fixture.wordCountFloor,
                "\(fixture.id) [\(result.path)] wordCountFloor: got \(words.count) words, need ≥ \(fixture.wordCountFloor). Transcript: '\(result.transcript)'",
                file: file,
                line: line
            )
        }
        if let ceiling = fixture.wordCountCeiling {
            XCTAssertLessThanOrEqual(
                words.count,
                ceiling,
                "\(fixture.id) [\(result.path)] wordCountCeiling: got \(words.count) words, expected ≤ \(ceiling). Transcript: '\(result.transcript)'",
                file: file,
                line: line
            )
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
    /// insertion target, empty user-languages. Use this as the
    /// "neutral context" baseline for fixtures that don't
    /// specifically test context interactions.
    static func neutralContext(userLanguages: [String] = []) -> ContextSnapshot {
        ContextSnapshot(
            activeApp: AppInfo(name: "TestApp", bundleID: "app.notype.test.generic"),
            category: .uncategorized,
            userInstruction: "",
            categoryInstruction: nil,
            dictionary: [],
            replacements: [],
            userLanguages: userLanguages,
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
        textAfter: String = "",
        userLanguages: [String] = []
    ) -> ContextSnapshot {
        ContextSnapshot(
            activeApp: AppInfo(name: appName, bundleID: bundle),
            category: .messaging,
            userInstruction: "",
            categoryInstruction: AppCategory.messaging.defaultPrompt,
            dictionary: [],
            replacements: [],
            userLanguages: userLanguages,
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
        textAfter: String = "",
        userLanguages: [String] = []
    ) -> ContextSnapshot {
        ContextSnapshot(
            activeApp: AppInfo(name: appName, bundleID: bundle),
            category: category,
            userInstruction: "",
            categoryInstruction: category == .uncategorized ? nil : category.defaultPrompt,
            dictionary: [],
            replacements: [],
            userLanguages: userLanguages,
            tree: RedactedAXSnapshot(apps: []),
            insertionTarget: InsertionTarget(textBefore: textBefore, textAfter: textAfter),
            screenText: nil
        )
    }

    /// Context with a non-empty `RedactedAXSnapshot` containing a
    /// specified proper noun in a neighbour-app window. Used by U6's
    /// AX-content fixtures to exercise section #9 (`# Using on-screen
    /// context`) behavioural defenses — the first such coverage per
    /// `solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md`.
    ///
    /// `properNoun` is rendered as a single `StaticText` value in a
    /// non-active app's window. Active app stays the messaging-style
    /// context (Telegram) so the user-typing-into-messenger pattern is
    /// realistic. The line shape matches what `formatLine` would emit
    /// for a real AX dump (no caller-side indent — renderer adds it).
    static func contextWithAX(
        properNoun: String,
        neighbourAppName: String = "Notes",
        neighbourBundle: String = "com.apple.Notes",
        neighbourWindowTitle: String = "Project notes",
        textBefore: String = "",
        textAfter: String = ""
    ) -> ContextSnapshot {
        let neighbourDump = RedactedAppDump(
            appName: neighbourAppName,
            bundleID: neighbourBundle,
            windows: [
                RedactedWindowDump(
                    title: neighbourWindowTitle,
                    lines: ["- StaticText = \(properNoun)"]
                )
            ]
        )
        return ContextSnapshot(
            activeApp: AppInfo(name: "Telegram", bundleID: "ru.keepcoder.Telegram"),
            category: .messaging,
            userInstruction: "",
            categoryInstruction: AppCategory.messaging.defaultPrompt,
            dictionary: [],
            replacements: [],
            tree: RedactedAXSnapshot(apps: [neighbourDump]),
            insertionTarget: InsertionTarget(textBefore: textBefore, textAfter: textAfter),
            screenText: nil
        )
    }

    /// Test-helper: returns `true` if the fixture's audio file exists on
    /// disk. Used by tests whose audio hasn't been recorded yet to
    /// `XCTSkip` cleanly rather than crash on file-not-found.
    static func audioFileExists(for fixture: Fixture) -> Bool {
        let url = fixturesDirURL.appendingPathComponent(fixture.file)
        return FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - Token-ceiling assertions (deferred)
//
// `Fixture.usageTokensCeiling` is parsed and surfaced in `Result.usage`
// but not yet enforced by `assertContract`. Wiring it up is cheap once
// per-fixture ceilings are populated from a calm baseline run. Until
// then `usage` is available in test logs and to the U2 audit
// machinery, but the suite doesn't fail a fixture just because token
// counts crept up. Re-evaluate after U3 (post-trim) lands.
