import XCTest
@testable import NoType

/// Pins the retention classifier (`RecordingSession.shouldRetain(_:)`)
/// and the value type that carries a retained chunk set
/// (`RetainedRecording`).
///
/// `shouldRetain` decides whether a failed chunk's encoded audio is
/// held in memory so the user can re-send it from the history row.
/// Its contract is R4 of the failed-recording-retry plan: retention
/// fires for exactly the failure class that today produces a `[…]`
/// gap marker (network, 5xx, 429, empty, decoding, truncated) and for
/// nothing else. Terminal failures — rejected key, content block,
/// cancellation, encode failure — retain nothing.
///
/// The classifier is a `nonisolated static` beside
/// `RecordingSession.isTerminal(_:)`, so both can be exercised without
/// standing up a session (which owns AudioRecorder / SileroVAD /
/// GeminiClient / HistoryStore — not unit-test-friendly). Mirrors the
/// seam shape of `RecordingSessionShortPathTests`.
///
/// See `NoType/Recording/CLAUDE.md` "Partial recovery" for the
/// case-for-case table this matrix must match.
final class RetainedRecordingTests: XCTestCase {

    /// One classification fixture. `expectedRetain` is the R4 verdict;
    /// `expectedTerminal` is today's `isTerminal(_:)` verdict, recorded
    /// here so the no-drift test can assert the two classifiers against
    /// one shared list rather than two hand-maintained ones.
    private struct Fixture {
        let label: String
        let error: Error
        let expectedRetain: Bool
        let expectedTerminal: Bool
    }

    /// Stand-in for the non-Gemini terminal class — an AAC encode
    /// failure out of `ChunkBuilder`, or anything AVFAudio raises.
    private struct EncodeFailure: Error {}

    /// Stand-in for the `Error` payload `GeminiError.decoding` wraps.
    private struct DecodeFailure: Error {}

    private var fixtures: [Fixture] {
        [
            // --- Terminal: retains nothing (R4) ---
            Fixture(label: "cancellation",
                    error: CancellationError(),
                    expectedRetain: false, expectedTerminal: true),
            Fixture(label: "missingKey",
                    error: GeminiClient.GeminiError.missingKey,
                    expectedRetain: false, expectedTerminal: true),
            Fixture(label: "http 401 (rejected key)",
                    error: GeminiClient.GeminiError.http(status: 401, body: ""),
                    expectedRetain: false, expectedTerminal: true),
            Fixture(label: "http 403 (key not authorised)",
                    error: GeminiClient.GeminiError.http(status: 403, body: ""),
                    expectedRetain: false, expectedTerminal: true),
            Fixture(label: "content block",
                    error: GeminiClient.GeminiError.blocked("SAFETY"),
                    expectedRetain: false, expectedTerminal: true),
            Fixture(label: "encode failure",
                    error: EncodeFailure(),
                    expectedRetain: false, expectedTerminal: true),

            // --- Recoverable: retains (R4) ---
            Fixture(label: "http 0 (network failure)",
                    error: GeminiClient.GeminiError.http(status: 0, body: ""),
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "http 429 (rate limit)",
                    error: GeminiClient.GeminiError.http(status: 429, body: ""),
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "http 500",
                    error: GeminiClient.GeminiError.http(status: 500, body: ""),
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "http 503",
                    error: GeminiClient.GeminiError.http(status: 503, body: ""),
                    expectedRetain: true, expectedTerminal: false),
            // R4's governing clause is "the class that today produces a
            // gap marker", not only the six kinds it then names. A
            // generic 4xx is in that class today, so it retains — the
            // plan's Scope Boundaries forbid changing which errors abort
            // a session versus continue with a marker.
            Fixture(label: "http 400 (generic 4xx)",
                    error: GeminiClient.GeminiError.http(status: 400, body: ""),
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "empty response",
                    error: GeminiClient.GeminiError.empty,
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "decoding failure",
                    error: GeminiClient.GeminiError.decoding(DecodeFailure()),
                    expectedRetain: true, expectedTerminal: false),
            Fixture(label: "truncated response",
                    error: GeminiClient.GeminiError.truncated,
                    expectedRetain: true, expectedTerminal: false),
        ]
    }

    // MARK: - Classification matrix

    func test_shouldRetain_matchesTheGapMarkerClass() {
        for f in fixtures {
            XCTAssertEqual(
                RecordingSession.shouldRetain(f.error),
                f.expectedRetain,
                "shouldRetain(\(f.label)) should be \(f.expectedRetain)"
            )
        }
    }

    // MARK: - Terminal cases retain nothing (AE1, AE2)

    func test_rejectedKey_doesNotRetain() {
        // AE1 — an expired / rejected key aborts the session and keeps
        // no audio. Both statuses `isTerminal` singles out.
        XCTAssertFalse(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.http(status: 401, body: "")))
        XCTAssertFalse(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.http(status: 403, body: "")))
    }

    func test_cancellation_doesNotRetain() {
        // AE2 — the user pressed the cancel binding; nothing is kept.
        XCTAssertFalse(RecordingSession.shouldRetain(CancellationError()))
    }

    func test_contentBlock_doesNotRetain() {
        XCTAssertFalse(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.blocked("PROHIBITED_CONTENT")))
    }

    func test_missingKey_doesNotRetain() {
        XCTAssertFalse(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.missingKey))
    }

    func test_unrecognisedError_doesNotRetain() {
        // Encode failure / AVFAudio / anything else: terminal by
        // default, exactly as `isTerminal` treats it.
        XCTAssertFalse(RecordingSession.shouldRetain(EncodeFailure()))
    }

    // MARK: - Recoverable cases retain

    func test_networkAndServerFailures_retain() {
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.http(status: 0, body: "")))
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.http(status: 500, body: "")))
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.http(status: 429, body: "")))
    }

    func test_emptyDecodingTruncated_retain() {
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.empty))
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.decoding(DecodeFailure())))
        XCTAssertTrue(RecordingSession.shouldRetain(
            GeminiClient.GeminiError.truncated))
    }

    // MARK: - No drift between the two classifiers

    func test_everyTerminalCase_declinesRetention() {
        // The load-bearing assertion (KTD8): the two classifiers sit
        // next to each other so a new error case is added to both. If
        // someone adds a case to `isTerminal` and forgets `shouldRetain`,
        // this fails — provided the new case is added to `fixtures` too,
        // which the shared list makes the obvious move.
        for f in fixtures {
            XCTAssertEqual(
                RecordingSession.isTerminal(f.error),
                f.expectedTerminal,
                "isTerminal(\(f.label)) should be \(f.expectedTerminal)"
            )
            if RecordingSession.isTerminal(f.error) {
                XCTAssertFalse(
                    RecordingSession.shouldRetain(f.error),
                    "\(f.label) is terminal, so it must retain nothing"
                )
            }
        }
    }

    // MARK: - RetainedRecording payload

    func test_retainedRecording_carriesChunksContextAndModel() {
        let app = AppInfo(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let context = ContextSnapshot.minimal(activeApp: app)
        let payload = RetainedRecording(
            chunks: [
                RetainedRecording.Chunk(idx: 1, isFinal: false,
                                        audio: Data([0x01, 0x02]), samples: 16_000),
                RetainedRecording.Chunk(idx: 2, isFinal: true,
                                        audio: Data([0x03]), samples: 8_000),
            ],
            context: context,
            model: .flash
        )

        XCTAssertEqual(payload.chunks.map(\.idx), [1, 2])
        XCTAssertEqual(payload.chunks.map(\.isFinal), [false, true])
        XCTAssertEqual(payload.chunks.map(\.samples), [16_000, 8_000])
        XCTAssertEqual(payload.chunks.first?.audio, Data([0x01, 0x02]))
        XCTAssertEqual(payload.context.activeApp.bundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(payload.model, .flash)
    }
}
