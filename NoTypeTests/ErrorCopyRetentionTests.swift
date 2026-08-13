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
    /// production.
    ///
    /// Built by calling the **producer itself** rather than re-spelling its
    /// format. Re-spelling it was already one drift risk (the body's shape
    /// is what `NetworkErrorTranslator` parses); it became a correctness
    /// problem for R17, whose whole claim is that the sentence embedded in
    /// the body *is* the one the native-`URLError` branch renders. A stub
    /// like `"offline"` cannot demonstrate that — only the real
    /// `localizedDescription` the producer embeds can.
    private func wrappedURLError(_ code: URLError.Code) -> Error {
        GeminiClient.GeminiError.wrapURLError(URLError(code))
    }

    /// One representative error per recoverable branch of
    /// `payloadForSessionFailure`, labelled for failure messages.
    /// Every one of these satisfies `RecordingSession.shouldRetain(_:)`
    /// — asserted below rather than assumed, so this list cannot drift
    /// out of the class it claims to represent.
    private var recoverableErrors: [(label: String, error: Error)] {
        [
            ("offline (wrapped)",   wrappedURLError(.notConnectedToInternet)),
            ("connection lost",     wrappedURLError(.networkConnectionLost)),
            ("timed out",           wrappedURLError(.timedOut)),
            ("dns failed",          wrappedURLError(.cannotFindHost)),
            // The shape `performOnce`'s no-`HTTPURLResponse` guard throws
            // since the R17 follow-up. In the fixture list so it is swept
            // by the retention, no-loss-claim, no-diagnostic and
            // no-repeated-sentence properties like every other recoverable
            // branch; its copy is pinned verbatim in
            // `test_noHTTPURLResponse_rendersConnectionCopy_notARawStatusNumber`.
            ("no response",         wrappedURLError(.badServerResponse)),
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
        //
        // That convention only holds if the wording is actually pinned
        // *here*. It wasn't: the checks below are a `contains` and a set
        // of negative phrases, both of which survive appending a second
        // imperative to the clause — which would reach every retained
        // recoverable HUD, and would be invisible to the verbatim tests
        // that interpolate this same constant into their fixtures.
        XCTAssertEqual(
            NoTypeErrorKind.retainedRecordingClause,
            "The recording is kept in your history, where you can retry it.",
            "The whole-session consequence clause changed. Deliberate? Update this fixture. Otherwise it just changed under every HUD that interpolates it."
        )
        XCTAssertEqual(
            NoTypeErrorKind.retainedGapClause,
            "The recording is kept in your history, where a retry can fill the gaps.",
            "The gap-filling consequence clause changed. Same reasoning as above."
        )
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

    func test_recoverableKinds_whenNothingRetained_renderThePreRetentionCopyVerbatim() {
        // `describe`'s contract is that `ifLost` is "the pre-retention
        // copy, kept verbatim". Nothing pinned that, and the first
        // version of this change broke it in five of ten branches by
        // folding the retained-only imperative into `cause`: the lost
        // arm then rendered it twice ("Reconnect first. Reconnect and
        // try again — …", "Wait a moment. Wait a moment and try
        // again."). Every assertion below is the exact string this
        // catalog shipped before retention existed, so a future edit
        // that moves an imperative back into `cause` fails here rather
        // than reaching a user.
        //
        // Exact equality on purpose: a `contains` check is what let the
        // stutter through, because the duplicated sentence still
        // contained the phrase the old test looked for.
        let expected: [(label: String, copy: String)] = [
            ("offline (wrapped)", "NoType needs internet to transcribe. Reconnect and try again — your audio wasn't saved."),
            // Reworked by U2. The old copy was "Check your connection and
            // try again", which the 2026-08-11 measurement showed points
            // at the wrong thing: the stall is a dead pooled connection,
            // not a dead link (3 ms connect, ~200 ms TLS, and the same
            // payload succeeding on a fresh connection 1.7 s later).
            ("timed out",         "The transcription request timed out. Try again in a moment."),
            ("rate limited",      "Gemini throttled the request. Wait a moment and try again."),
            ("server error",      "The service returned a server error. Wait a moment and try again."),
            ("region blocked",    "The Gemini API is restricted in your country. Connect through a VPN and try again."),
            ("empty response",    "Gemini returned an empty response. Try speaking a bit louder or holding the hotkey longer."),
            ("decode failure",    "Gemini returned an unexpected format. Try again — if it keeps happening, open an issue on GitHub."),
            ("truncated",         "Gemini stopped before finishing. Try dictating in shorter bursts.")
        ]
        for (label, copy) in expected {
            guard let error = recoverableErrors.first(where: { $0.label == label })?.error else {
                XCTFail("No recoverable fixture labelled '\(label)'.")
                continue
            }
            XCTAssertEqual(
                NoTypeErrorKind.sessionFailure(error, retainedForRetry: false).payload.description,
                copy,
                "\(label): the nothing-retained arm must render the pre-retention sentence verbatim."
            )
        }
    }

    /// The retained arm's complement, and the reason "no branch renders
    /// its imperative twice" is checkable at all.
    ///
    /// The lost arm has been pinned verbatim since the stutter defect; the
    /// kept arm was only ever pinned by *suffix*, which is satisfied by
    /// any prefix at all — including one that has quietly grown a second
    /// imperative, or lost its diagnosis. Both arms verbatim means the
    /// only way copy changes is a fixture diff a human reads, which is the
    /// same discipline `test_rejectedKey_copy_isUnchanged` applies to the
    /// terminal messages.
    ///
    /// The clause is referenced rather than re-spelled, per this file's
    /// convention: the wording lives in
    /// `test_retainedClauses_nameTheHistory_andClaimNoLoss` once.
    func test_recoverableKinds_whenRetained_renderTheirCopyVerbatim() {
        let clause = NoTypeErrorKind.retainedRecordingClause
        let expected: [(label: String, copy: String)] = [
            ("offline (wrapped)", "NoType needs internet to transcribe. Reconnect first. \(clause)"),
            // No advice sentence of its own: the clause already names the
            // row and the retry, and the failure is not something the user
            // can act on beforehand (U2 — the old "Check your connection."
            // sent them to audit a link that was working).
            ("timed out",         "The transcription request timed out. \(clause)"),
            ("rate limited",      "Gemini throttled the request. Wait a moment. \(clause)"),
            ("server error",      "The service returned a server error. \(clause)"),
            ("region blocked",    "The Gemini API is restricted in your country. Connect through a VPN first. \(clause)"),
            ("empty response",    "Gemini returned an empty response. \(clause)"),
            ("decode failure",    "Gemini returned an unexpected format. If it keeps happening, open an issue on GitHub. \(clause)"),
            ("truncated",         "Gemini stopped before finishing. \(clause)")
        ]
        for (label, copy) in expected {
            guard let error = recoverableErrors.first(where: { $0.label == label })?.error else {
                XCTFail("No recoverable fixture labelled '\(label)'.")
                continue
            }
            XCTAssertEqual(
                NoTypeErrorKind.sessionFailure(error, retainedForRetry: true).payload.description,
                copy,
                "\(label): the retained arm's copy changed. If that was deliberate, update the fixture; if not, this is the stutter or a lost diagnosis."
            )
        }
    }

    /// The mechanical half of "no branch renders its imperative twice".
    ///
    /// **Know what it covers.** It catches a *whole repeated sentence* —
    /// which is what you get when the exact `ifLost` advice is also folded
    /// into `cause`. It does **not** catch the near-repeat that actually
    /// shipped ("Reconnect first. Reconnect and try again — …"): no exact
    /// check sees that, and no heuristic sees it without false-positiving
    /// on legitimate copy (two sentences opening "The …" are ordinary).
    /// That case is covered by the two verbatim fixture tests instead,
    /// where a human reads the diff. This test is the cheap,
    /// zero-false-positive floor beneath them, swept over both arms of
    /// every recoverable kind rather than the fixture subset.
    ///
    /// The trailing-period strip is load-bearing and was found by
    /// mutation, not by reasoning: a repeated sentence is terminal in one
    /// position and mid-string in the other, so it renders as
    /// `"Try again in a moment"` and `"Try again in a moment."` — unequal
    /// as strings. Without the strip this test was green under the exact
    /// mutation it exists to catch.
    func test_noBranch_rendersTheSameSentenceTwice() {
        for (label, error) in recoverableErrors {
            for retained in [true, false] {
                let description = NoTypeErrorKind
                    .sessionFailure(error, retainedForRetry: retained)
                    .payload
                    .description
                let sentences = description
                    .components(separatedBy: ". ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
                    .filter { !$0.isEmpty }
                XCTAssertEqual(
                    Set(sentences).count, sentences.count,
                    "\(label) (retained: \(retained)): a sentence is rendered twice — advice folded into `cause` reaches both arms. Got: \(description)"
                )
            }
        }
    }

    // MARK: - R17 — no internal diagnostic reaches the user

    /// The defect: `payloadForURLErrorCode`'s `default:` arm renders
    /// `fallbackDescription` verbatim, and the wrapped branch used to hand
    /// it the **whole** `GeminiError` body — so any network code without a
    /// branch of its own put `URLError code=-1003: …` on screen.
    ///
    /// Swept over the code space rather than asserted for one code,
    /// because the point is that no code can produce it, and the codes
    /// that reach the `default:` arm are exactly the ones nobody
    /// enumerated.
    func test_noNetworkPayload_leaksTheURLErrorDiagnostic() {
        let prefix = GeminiClient.GeminiError.urlErrorBodyPrefix
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .secureConnectionFailed, .badServerResponse, .resourceUnavailable
        ]
        for code in codes {
            for retained in [true, false] {
                let description = NoTypeErrorKind
                    .sessionFailure(
                        GeminiClient.GeminiError.wrapURLError(URLError(code)),
                        retainedForRetry: retained
                    )
                    .payload
                    .description
                XCTAssertFalse(
                    description.contains(prefix),
                    "URLError \(code.rawValue) (retained: \(retained)): an internal diagnostic reached the HUD. Got: \(description)"
                )
            }
        }
    }

    /// The half `test_bothNetworkPaths_renderIdenticalCopy_forTheSameCode`
    /// structurally cannot see, and the only assertion in this file that
    /// pins R17's actual claim.
    ///
    /// Every other fixture here builds `URLError(code)` with no `userInfo`,
    /// whose `localizedDescription` is Foundation's generic "The operation
    /// couldn't be completed. (NSURLErrorDomain error -N.)". That string is
    /// **re-derivable from the code alone** — so for every swept fixture,
    /// the sentence `wrapURLError` embedded and the sentence a synthesized
    /// `URLError(code)` would produce are byte-identical, and a mutation
    /// that ignores `wrapped.message` and always re-synthesizes passes the
    /// entire suite while shipping `(NSURLErrorDomain error -1200.)` to a
    /// user.
    ///
    /// The `userInfo` here is what a **real** `URLSession` failure carries
    /// and a test cannot otherwise obtain: the sentence below is the one a
    /// live TLS stall produced on this machine. It is unreachable from the
    /// code, so this assertion is red under that mutation, red under a
    /// revert to `fallbackDescription: body`, and red under any invented
    /// wording.
    func test_wrappedBody_rendersTheEmbeddedSentence_notOneReDerivedFromTheCode() {
        let sentence = "A TLS error caused the secure connection to fail."
        let live = URLError(
            .secureConnectionFailed,
            userInfo: [NSLocalizedDescriptionKey: sentence]
        )
        XCTAssertNotEqual(
            live.localizedDescription,
            URLError(.secureConnectionFailed).localizedDescription,
            "This fixture is only meaningful while the two differ — if Foundation starts giving synthesized URLErrors real sentences, re-derive a different discriminator."
        )
        for retained in [true, false] {
            let description = NoTypeErrorKind
                .sessionFailure(GeminiClient.GeminiError.wrapURLError(live), retainedForRetry: retained)
                .payload
                .description
            XCTAssertTrue(
                description.hasPrefix(sentence),
                "retained: \(retained): the HUD must render the sentence the producer embedded, not one re-derived from the code. Got: \(description)"
            )
        }
    }

    /// The property behind the fix, and the one worth pinning: after R17
    /// the two ways a network failure reaches the HUD render the **same**
    /// sentence.
    ///
    /// **Know what it cannot see.** Both sides build a *synthesized*
    /// `URLError(code)`, so both sentences come from the same place and a
    /// mutation that always re-synthesizes keeps them equal. That direction
    /// is pinned by
    /// `test_wrappedBody_rendersTheEmbeddedSentence_notOneReDerivedFromTheCode`
    /// above; the two are complementary. Note also that three of the codes
    /// swept below (`.notConnectedToInternet`, `.networkConnectionLost`,
    /// `.timedOut`) have branches of their own that never read
    /// `fallbackDescription` at all — only the `default:`-arm codes
    /// exercise the wiring.
    ///
    /// A bare `URLError` arrives from the legacy / defensive branch; the
    /// wrapped `GeminiError.http(0, …)` is what production actually
    /// rethrows out of `RecordingSession.stop()`. They meet in
    /// `payloadForURLErrorCode`, and before this change the wrapped path
    /// arrived carrying a different string. Equality is stronger than
    /// "contains no prefix": it fails a fix that strips the prefix by
    /// inventing new wording, which KTD12 explicitly did not want.
    ///
    /// `retainedForRetry: false` for both, because that is the only value
    /// the bare-`URLError` call site can pass — see
    /// `test_bareURLError_isTerminal_andKeepsThePreRetentionCopy`.
    func test_bothNetworkPaths_renderIdenticalCopy_forTheSameCode() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .secureConnectionFailed
        ]
        for code in codes {
            let native = NoTypeErrorKind
                .sessionFailure(URLError(code), retainedForRetry: false)
                .payload
            let wrapped = NoTypeErrorKind
                .sessionFailure(
                    GeminiClient.GeminiError.wrapURLError(URLError(code)),
                    retainedForRetry: false
                )
                .payload
            XCTAssertEqual(
                wrapped.description, native.description,
                "URLError \(code.rawValue): the wrapped and native paths disagree. The wrapped body embeds the same `localizedDescription` the native path reads, so any difference means the body itself is being rendered."
            )
            XCTAssertEqual(wrapped.title, native.title, "URLError \(code.rawValue)")
            XCTAssertEqual(wrapped.code, native.code, "URLError \(code.rawValue)")
        }
    }

    /// The field-photographed defect (0.1.13-rc2): a dictation whose
    /// response was not an `HTTPURLResponse` surfaced as **"Gemini rejected
    /// the request / Unexpected response (HTTP 0) / ERR_GEMINI · 0"**.
    /// Every clause of that is false — status 0 is this project's "the
    /// request never reached Gemini" marker, so Gemini rejected nothing,
    /// and 0 is not an HTTP status.
    ///
    /// R17's fix was at the seam, so what this pins is the copy the
    /// reclassified error renders. **The seam itself is not reachable from
    /// a value test** — the bare `http(status: 0, body: "no
    /// HTTPURLResponse")` is still a constructible `GeminiError`, so
    /// reverting `performOnce` to throw it leaves every assertion here
    /// green. That is what
    /// `GeminiClientOfflineShortCircuitTests.test_performOnce_throwsNoBareStatusZero`
    /// exists for; the two are complementary and neither alone is enough.
    func test_noHTTPURLResponse_rendersConnectionCopy_notARawStatusNumber() {
        let error = GeminiClient.GeminiError.wrapURLError(URLError(.badServerResponse))
        let kept = NoTypeErrorKind.sessionFailure(error, retainedForRetry: true).payload
        let lost = NoTypeErrorKind.sessionFailure(error, retainedForRetry: false).payload

        XCTAssertEqual(kept.title, "Couldn't reach Gemini")
        XCTAssertEqual(lost.title, kept.title, "The title does not vary with retention; only the consequence clause does.")
        XCTAssertEqual(
            kept.description,
            "The connection failed unexpectedly. \(NoTypeErrorKind.retainedRecordingClause)",
            "The retained arm carries the diagnosis and the clause, and nothing between them — there is no action to take first."
        )
        XCTAssertEqual(
            lost.description,
            "The connection failed unexpectedly. Try again in a moment.",
            "The nothing-retained arm carries the diagnosis and its own imperative."
        )
    }

    /// The display floor beneath the seam: a status-0 `GeminiError` whose
    /// body is **not** a wrapped `URLError` must still not reach the
    /// generic HTTP arm.
    ///
    /// No producer on the transcription path writes one today — that is
    /// exactly what the seam fix achieved — so this asserts the property
    /// survives someone adding one. Without the floor, a single bare
    /// `throw GeminiError.http(status: 0, …)` anywhere in `GeminiClient`
    /// silently restores the photographed HUD.
    func test_unparseableStatusZero_stillNeverRendersHTTP0() {
        for body in ["no HTTPURLResponse", "", "{\"error\":{}}", "URLError code=abc: bad"] {
            for retained in [true, false] {
                let payload = NoTypeErrorKind
                    .sessionFailure(
                        GeminiClient.GeminiError.http(status: 0, body: body),
                        retainedForRetry: retained
                    )
                    .payload
                XCTAssertEqual(
                    payload.title, "Couldn't reach Gemini",
                    "body '\(body)' (retained: \(retained)): a status-0 failure never reached Gemini, so 'Gemini rejected the request' is a false statement."
                )
                XCTAssertFalse(
                    payload.description.contains("HTTP 0"),
                    "body '\(body)' (retained: \(retained)): the HUD names a status number that is not a status. Got: \(payload.description)"
                )
            }
        }
    }

    /// Sweep: no failure a *transcription* can produce puts `HTTP 0` in
    /// front of the user — the number the photographed HUD showed, and the
    /// one number in this error model that is not a status at all.
    ///
    /// **Scoped deliberately.** A real HTTP status still renders as "HTTP
    /// 404" through the generic arm, and that is out of scope here: it
    /// names a real protocol fact rather than a marker our own error model
    /// invented. Widening this to every status is a copy decision, not a
    /// test decision.
    func test_noTranscriptionPayload_namesHTTP0() {
        var errors: [(String, Error)] = recoverableErrors + terminalErrors
        for code in [
            URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .secureConnectionFailed, .badServerResponse, .cannotParseResponse,
            .resourceUnavailable, .init(rawValue: -4242)
        ] {
            errors.append(("wrapped \(code.rawValue)", GeminiClient.GeminiError.wrapURLError(URLError(code))))
        }
        errors.append(("bare status 0", GeminiClient.GeminiError.http(status: 0, body: "no HTTPURLResponse")))

        for (label, error) in errors {
            for retained in [true, false] {
                let description = NoTypeErrorKind
                    .sessionFailure(error, retainedForRetry: retained)
                    .payload
                    .description
                XCTAssertFalse(
                    description.contains("HTTP 0"),
                    "\(label) (retained: \(retained)): the HUD names a status number that is not a status. Got: \(description)"
                )
            }
        }
    }

    /// The `?? ` floor in the wrapped-`URLError` branch, which is the one
    /// place an `NSError` domain-and-code string could reach a user.
    ///
    /// `parse` accepts a body carrying a code and no sentence
    /// (`"URLError code=-4242"`). No producer writes one — `wrapURLError`
    /// always appends `": \(localizedDescription)"` — so this is a
    /// defensive arm, and its first version re-derived the sentence by
    /// synthesizing a `URLError` from the code. That is precisely what must
    /// not happen: a synthesized `URLError` carries no
    /// `NSLocalizedDescriptionKey`, so `localizedDescription` is
    /// Foundation's "The operation couldn't be completed. (NSURLErrorDomain
    /// error -4242.)" — an internal diagnostic with a raw number, the shape
    /// R17 removes.
    ///
    /// **Note what this cannot assert.** A *wrapped* body built in a test
    /// always embeds that same synthesized string, because only a real
    /// `URLSession` failure carries a real sentence. So the sweep above
    /// deliberately does not check for `NSURLErrorDomain` over wrapped
    /// fixtures — it would be measuring the fixture, not the code. This
    /// test targets the one arm where the synthesis was ours.
    func test_wrappedBodyWithNoSentence_doesNotSynthesizeAnNSErrorDiagnostic() {
        for retained in [true, false] {
            let description = NoTypeErrorKind
                .sessionFailure(
                    GeminiClient.GeminiError.http(status: 0, body: "URLError code=-4242"),
                    retainedForRetry: retained
                )
                .payload
                .description
            XCTAssertFalse(
                description.contains("NSURLErrorDomain"),
                "retained: \(retained): the floor synthesized a URLError and rendered its generic description. Got: \(description)"
            )
            XCTAssertTrue(
                description.hasPrefix("The connection failed unexpectedly."),
                "retained: \(retained): the floor must reuse the ruled sentence rather than invent copy. Got: \(description)"
            )
        }
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
