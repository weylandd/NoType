import XCTest
@testable import NoType

/// Pins the Error HUD's **consequence clause** against the retention
/// contract this branch shipped.
///
/// Before retention, a session whose Gemini calls all failed evaporated,
/// and the offline HUD closed with "your audio wasn't saved" — true at
/// the time. Retention (plan R4 / R6) makes a recoverable-class failure
/// keep the audio in a history row that carries a retry action, and that
/// sentence became the single most consequential false statement in the
/// product: a user who reads it stops looking, never notices the retry,
/// and re-dictates something NoType is holding for them. The plan's own
/// smoke protocol makes it an acceptance criterion — "no Error HUD claims
/// the session was merely lost".
///
/// Three properties are pinned here, and they are deliberately not the
/// same property:
///
/// 1. **Recoverable + retained** ends with the retained clause and makes
///    no loss claim. This is the defect.
/// 2. **Recoverable + nothing retained** keeps the pre-retention copy.
///    That case writes no row (`AppState.recordBrokenRow` returns `nil`
///    when the session retained nothing), so the audio genuinely is gone
///    and promising a retry would be the mirror-image lie.
/// 3. **Terminal** is untouched in both directions. A rejected key, a
///    content block, a cancellation or an encode failure retains nothing
///    by `RecordingSession.shouldRetain(_:)`, and their copy must never
///    start advertising a retry that will not be there.
///
/// The diagnosis half is pinned separately: each recoverable cause stays
/// a distinct sentence, because collapsing offline / timed out /
/// throttled / server error into one generic string would trade a false
/// statement for a useless one.
final class ErrorCopyRetentionTests: XCTestCase {

    // MARK: - Fixtures

    /// `GeminiClient.performOnce` wraps every `URLError` in
    /// `http(0, "URLError code=N: …")`, and that wrapped form is what
    /// `RecordingSession.stop()` actually rethrows — so it, not a bare
    /// `URLError`, is the shape the offline HUD is reached through in
    /// production. Built from the producer's own constant so a rename
    /// cannot leave these tests exercising a branch nothing hits.
    private func wrappedURLError(_ code: URLError.Code, _ text: String = "offline") -> Error {
        GeminiClient.GeminiError.http(
            status: 0,
            body: "\(GeminiClient.GeminiError.urlErrorBodyPrefix)\(code.rawValue): \(text)"
        )
    }

    /// One representative error per recoverable branch of
    /// `payloadForSessionFailure`, labelled for failure messages.
    /// Every one of these satisfies `RecordingSession.shouldRetain(_:)`
    /// — asserted below rather than assumed, so this list cannot drift
    /// out of the class it claims to represent.
    private var recoverableErrors: [(label: String, error: Error)] {
        [
            ("offline (wrapped)",   wrappedURLError(.notConnectedToInternet)),
            ("connection lost",     wrappedURLError(.networkConnectionLost, "lost")),
            ("timed out",           wrappedURLError(.timedOut, "timed out")),
            ("dns failed",          wrappedURLError(.cannotFindHost, "no such host")),
            ("rate limited",        GeminiClient.GeminiError.http(status: 429, body: "")),
            ("server error",        GeminiClient.GeminiError.http(status: 503, body: "")),
            ("region blocked",      GeminiClient.GeminiError.http(status: 400, body: "User location is not supported")),
            ("generic http",        GeminiClient.GeminiError.http(status: 418, body: "{}")),
            ("empty response",      GeminiClient.GeminiError.empty),
            ("decode failure",      GeminiClient.GeminiError.decoding(StubDecodeError())),
            ("truncated",           GeminiClient.GeminiError.truncated),
        ]
    }

    /// The terminal branches whose payload is a fixed string — every one
    /// of them is built without the retention helper, so the flag cannot
    /// reach their copy at all. `.noSpeech` and the unrecognised
    /// catch-all are included because both reach
    /// `payloadForSessionFailure` and both retain nothing.
    ///
    /// A bare `URLError` is terminal too (`shouldRetain(_:)` admits only
    /// `GeminiError`) but is deliberately **not** here: it routes into
    /// the shared network payload builder, which does thread the flag.
    /// See `test_bareURLError_isTerminal_andKeepsThePreRetentionCopy`.
    private var terminalErrors: [(label: String, error: Error)] {
        [
            ("missing key",     GeminiClient.GeminiError.missingKey),
            ("rejected key",    GeminiClient.GeminiError.http(status: 401, body: "")),
            ("key not authed",  GeminiClient.GeminiError.http(status: 403, body: "")),
            ("content block",   GeminiClient.GeminiError.blocked("SAFETY")),
            ("no speech",       RecordingSession.SessionError.noSpeech),
            ("unrecognised",    StubDecodeError()),
        ]
    }

    /// Look a fixture's rendered cause up by label rather than by index,
    /// so adding a case to `recoverableErrors` can't silently repoint an
    /// assertion at a different branch.
    private func cause(of label: String) throws -> String {
        let error = try XCTUnwrap(
            recoverableErrors.first(where: { $0.label == label })?.error,
            "No recoverable fixture labelled '\(label)'."
        )
        let full = NoTypeErrorKind
            .sessionFailure(error, retainedForRetry: true)
            .payload
            .description
        return String(full.dropLast(NoTypeErrorKind.retainedRecordingClause.count))
    }

    // MARK: - The clauses themselves

    func test_retainedClauses_nameTheHistory_andClaimNoLoss() {
        // The one place the literal copy is asserted. Every other test
        // in this file references the constant, so the wording lives
        // here once instead of being re-spelled per kind.
        for clause in [
            NoTypeErrorKind.retainedRecordingClause,
            NoTypeErrorKind.retainedGapClause
        ] {
            XCTAssertTrue(
                clause.contains("kept in your history"),
                "The clause must tell the user where the recording is — that pointer is the whole fix. Got: \(clause)"
            )
            for lie in Self.lossPhrases {
                XCTAssertFalse(
                    clause.localizedCaseInsensitiveContains(lie),
                    "The retained clause must not claim loss. '\(lie)' in: \(clause)"
                )
            }
        }
        // The two are not interchangeable: a partial session already
        // pasted its text, and its retry fills the gaps in the history
        // row rather than re-running a whole dictation (plan KD5).
        XCTAssertNotEqual(
            NoTypeErrorKind.retainedRecordingClause,
            NoTypeErrorKind.retainedGapClause,
            "The whole-session and gap-filling consequences are different promises; keep them different sentences."
        )
    }

    // MARK: - Property 1 — recoverable + retained

    func test_recoverableKinds_whenRetained_endWithTheRetainedClause() {
        for (label, error) in recoverableErrors {
            // Guard the fixture list first: a case that is not actually
            // retainable would make this test green for the wrong reason.
            XCTAssertTrue(
                RecordingSession.shouldRetain(error),
                "\(label) is in the recoverable fixture list but shouldRetain(_:) rejects it."
            )
            let description = NoTypeErrorKind
                .sessionFailure(error, retainedForRetry: true)
                .payload
                .description
            XCTAssertTrue(
                description.hasSuffix(NoTypeErrorKind.retainedRecordingClause),
                "\(label): a retained recording's HUD must close with the retained clause. Got: \(description)"
            )
        }
    }

    func test_recoverableKinds_whenRetained_neverClaimTheRecordingWasLost() {
        // The acceptance criterion from the plan's smoke protocol, as an
        // assertion. Separate from the suffix test above on purpose: a
        // future edit could append the clause to a sentence that still
        // opens with "your audio wasn't saved", and the suffix check
        // alone would pass.
        for (label, error) in recoverableErrors {
            let description = NoTypeErrorKind
                .sessionFailure(error, retainedForRetry: true)
                .payload
                .description
            for lie in Self.lossPhrases {
                XCTAssertFalse(
                    description.localizedCaseInsensitiveContains(lie),
                    "\(label): HUD claims the recording is gone ('\(lie)') while it is held for retry. Got: \(description)"
                )
            }
        }
    }

    func test_recoverableCauses_stayDistinct_underRetention() throws {
        // The consequence clause is shared; the diagnosis must not be.
        // Offline, timed out, throttled and server-error are four
        // different things to do something about, and the HUD is the
        // only place the reason is named — the broken row deliberately
        // does not carry it (plan R7).
        let offline = try cause(of: "offline (wrapped)")
        let timedOut = try cause(of: "timed out")
        let throttled = try cause(of: "rate limited")
        let serverError = try cause(of: "server error")
        let region = try cause(of: "region blocked")
        let distinct = Set([offline, timedOut, throttled, serverError, region])
        XCTAssertEqual(
            distinct.count, 5,
            "Four network / service causes collapsed into fewer sentences — the user can no longer tell what went wrong."
        )
        for (label, _) in recoverableErrors {
            let cause = try cause(of: label)
            XCTAssertFalse(
                cause.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(label): the cause was collapsed away — the HUD would name the consequence but not the failure."
            )
        }
    }

    // MARK: - Property 2 — recoverable, nothing retained

    func test_offline_whenNothingRetained_keepsThePreRetentionCopy() {
        // Reachable defensively: `shouldRetain(_:)` admits the error, but
        // the session retained no chunk, so `recordBrokenRow` writes no
        // row and there is nothing to point the user at. Here the old
        // sentence is the true one and must survive.
        let description = NoTypeErrorKind
            .sessionFailure(wrappedURLError(.notConnectedToInternet), retainedForRetry: false)
            .payload
            .description
        XCTAssertTrue(
            description.contains("your audio wasn't saved"),
            "With nothing retained there is no row to point at — the honest copy is still the pre-retention one. Got: \(description)"
        )
        XCTAssertFalse(
            description.contains(NoTypeErrorKind.retainedRecordingClause),
            "Promising a history row that was never written is the mirror image of the bug being fixed."
        )
    }

    func test_recoverableKinds_whenNothingRetained_neverPromiseARetry() {
        for (label, error) in recoverableErrors {
            let description = NoTypeErrorKind
                .sessionFailure(error, retainedForRetry: false)
                .payload
                .description
            XCTAssertFalse(
                description.contains("kept in your history"),
                "\(label): no row was written, so the HUD must not send the user to the history list. Got: \(description)"
            )
        }
    }

    // MARK: - Property 3 — terminal kinds are untouched

    func test_terminalKinds_neverPromiseARetry_evenIfTheFlagIsSet() {
        // The flag is an outcome reported by the call site, and the
        // terminal branches ignore it by construction. Passing `true`
        // here is not a reachable production state for most of these —
        // it is the assertion that the branches are genuinely independent
        // of the flag, so a future refactor that threads it through the
        // whole switch cannot silently start advertising retries on a
        // rejected key.
        for retained in [true, false] {
            for (label, error) in terminalErrors {
                XCTAssertFalse(
                    RecordingSession.shouldRetain(error),
                    "\(label) is in the terminal fixture list but shouldRetain(_:) admits it."
                )
                let description = NoTypeErrorKind
                    .sessionFailure(error, retainedForRetry: retained)
                    .payload
                    .description
                XCTAssertFalse(
                    description.contains("kept in your history"),
                    "\(label) (retained: \(retained)): a terminal failure keeps nothing — this copy would promise a retry that isn't there. Got: \(description)"
                )
            }
        }
    }

    func test_bareURLError_isTerminal_andKeepsThePreRetentionCopy() {
        // Found by this file's own fixture guard, and worth pinning: a
        // *bare* `URLError` is not a `GeminiError`, so
        // `shouldRetain(_:)` rejects it and `isTerminal(_:)` admits it —
        // the session retains nothing and writes no row. In production
        // it should never reach the HUD at all (`GeminiClient` wraps
        // every `URLError` as `http(0, "URLError code=N: …")`, which is
        // the retainable form the tests above use), so this arm is
        // legacy / defensive.
        //
        // The consequence: the call site can only ever pass
        // `retainedForRetry: false` for it, and the pre-retention copy —
        // the sentence this whole change exists to remove — is the
        // correct one here, because there really is nothing kept.
        let bare = URLError(.notConnectedToInternet)
        XCTAssertFalse(
            RecordingSession.shouldRetain(bare),
            "A bare URLError is not a GeminiError; if this flips, the offline HUD's retention branch needs revisiting."
        )
        XCTAssertTrue(RecordingSession.isTerminal(bare))
        let description = NoTypeErrorKind
            .sessionFailure(bare, retainedForRetry: false)
            .payload
            .description
        XCTAssertTrue(description.contains("your audio wasn't saved"))
    }

    func test_rejectedKey_copy_isUnchanged() {
        // The one terminal message spelled out verbatim, as the anchor
        // for "do not touch the terminal messages". If a future change
        // rewrites it, that should be a deliberate edit here too.
        let payload = NoTypeErrorKind
            .sessionFailure(GeminiClient.GeminiError.http(status: 401, body: ""), retainedForRetry: true)
            .payload
        XCTAssertEqual(payload.title, "API key rejected")
        XCTAssertEqual(
            payload.description,
            "Gemini didn't accept the key. Check it in Settings or generate a new one in Google AI Studio."
        )
    }

    // MARK: - Partial transcription (the session that did paste)

    func test_partialTranscription_whenRetained_pointsAtTheRow_notReDictation() {
        let payload = NoTypeErrorKind
            .partialTranscription(summary: Self.summary(failed: 1, dispatched: 3, retained: true))
            .payload
        XCTAssertTrue(
            payload.description.hasSuffix(NoTypeErrorKind.retainedGapClause),
            "A partially-failed session's row holds the failed chunks' audio and offers a retry. Got: \(payload.description)"
        )
        XCTAssertFalse(
            payload.description.localizedCaseInsensitiveContains("re-dictate"),
            "Telling the user to re-dictate contradicts the retry action on the row they just got. Got: \(payload.description)"
        )
        // The diagnosis half survives — how much was lost, and the marker
        // they will find in the pasted text.
        XCTAssertTrue(payload.description.contains("1 of 3 chunks"))
        XCTAssertTrue(payload.description.contains(RecordingSession.failureMarker))
    }

    func test_partialTranscription_whenNothingRetained_keepsReDictateAdvice() {
        // A partially-failed session that retained nothing writes a row
        // with no retry (the "dead" row state), so re-dictating really is
        // the only way back and the original advice is still correct.
        for (failed, expected) in [(1, "Re-dictate just that part"), (2, "Re-dictate the missing parts")] {
            let payload = NoTypeErrorKind
                .partialTranscription(summary: Self.summary(failed: failed, dispatched: 3, retained: false))
                .payload
            XCTAssertTrue(
                payload.description.contains(expected),
                "failed=\(failed): expected the pre-retention advice. Got: \(payload.description)"
            )
            XCTAssertFalse(payload.description.contains("kept in your history"))
        }
    }

    func test_partialTranscription_pluraliseBothHalves() {
        // The cause and the consequence are built from the same count;
        // pin that a multi-chunk loss still reads correctly now that the
        // consequence no longer varies with it in the retained branch.
        let payload = NoTypeErrorKind
            .partialTranscription(summary: Self.summary(failed: 2, dispatched: 5, retained: true))
            .payload
        XCTAssertTrue(payload.description.contains("2 of 5 chunks"))
        XCTAssertTrue(payload.description.contains("in their place"))
        XCTAssertTrue(payload.description.hasSuffix(NoTypeErrorKind.retainedGapClause))
    }

    // MARK: - Helpers

    /// Phrases that assert the recording is gone. Any of them in a
    /// retained-recording HUD is the defect.
    private static let lossPhrases = [
        "wasn't saved",
        "was not saved",
        "wasn't kept",
        "was lost",
        "is gone"
    ]

    private static func summary(
        failed: Int,
        dispatched: Int,
        retained: Bool
    ) -> RecordingSession.SessionSummary {
        RecordingSession.SessionSummary(
            failedChunkCount: failed,
            dispatchedChunkCount: dispatched,
            tokens: .zero,
            model: .flashLite,
            retained: retained ? Self.payload() : nil
        )
    }

    private static func payload() -> RetainedRecording {
        RetainedRecording(
            chunks: [
                RetainedRecording.Chunk(idx: 0, isFinal: true, audio: Data([0x01]), samples: 16_000)
            ],
            context: ContextSnapshot.minimal(
                activeApp: AppInfo(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
            ),
            model: .flashLite
        )
    }
}

private struct StubDecodeError: Error {}
