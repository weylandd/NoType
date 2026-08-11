import XCTest
import AppKit
@testable import NoType

/// Pins the withheld-paste notice (R25, R29, R30 / KTD8, KTD9).
///
/// U3 made a session whose destination process changed skip the paste and
/// still write the row. That left the user with the worst possible
/// outcome of the two: they watched a transcription finish and nothing
/// appeared, anywhere, with no explanation. This notice is the other half
/// — it says the transcript exists, names where it had been headed, and
/// puts it one click from the clipboard.
///
/// Four properties are pinned here, and they are not the same property:
///
/// 1. **Neutral, and it names the destination.** The dictation succeeded;
///    only its delivery was refused. The application named is the one the
///    user *stopped* in, frozen there by U3 and carried on the summary —
///    never re-read, because by the time this panel draws, the frontmost
///    application is wherever the user has drifted to since.
/// 2. **No transcript content, in either string (R29).** This panel
///    renders above whatever the user moved to, which may be a screen
///    share or a call. This is a privacy property, not a style note.
/// 3. **Copy places exactly what the row shows (R30)**, via the row's own
///    accessor, so the notice and the history row cannot hand the user two
///    different transcripts.
/// 4. **Copy is offered exactly when the row offers it** (the 2026-08-11
///    ruling). A transcript that is nothing but gap markers is one the row
///    deliberately won't copy; the notice matches, losing its label and its
///    handler together and degrading to a pure informational panel. Same
///    reason as 3 — the two surfaces answer for the same entry.
/// 5. **Exactly one notice per session, and this is the one (KTD9).**
///    `HUDController.showErrorHUD` replaces rather than stacks.
@MainActor
final class AppStateFocusNoticeTests: XCTestCase {

    // MARK: - Payload shape (KTD8)

    func test_payload_isNeutral_withAnInfoCode_andANonAlarmingIcon() {
        let payload = NoTypeErrorKind
            .pasteWithheld(entry: Self.entry(), summary: Self.summary())
            .payload

        XCTAssertEqual(
            payload.severity, .neutral,
            "The dictation succeeded — only the delivery was refused. Danger or warning severity would tell the user something broke."
        )
        XCTAssertTrue(
            payload.code?.hasPrefix("INFO_") == true,
            "Expected an INFO_ code like the pasted-with-gaps notice; got \(payload.code ?? "nil")."
        )
        XCTAssertFalse(
            payload.iconSymbol.contains("exclamationmark")
                || payload.iconSymbol.contains("slash")
                || payload.iconSymbol.contains("xmark"),
            "The icon reads as a failure (\(payload.iconSymbol)). Nothing failed here."
        )
    }

    func test_payload_advertisesCopy_asThePrimaryAffordance() {
        let payload = NoTypeErrorKind
            .pasteWithheld(entry: Self.entry(), summary: Self.summary())
            .payload

        XCTAssertEqual(payload.retryLabel, "Copy")
        XCTAssertEqual(
            payload.retryKind, .accent,
            "Copy is the only thing this notice offers — it renders as the primary button, like Open Settings."
        )
    }

    // MARK: - The notice matches the row (2026-08-11 ruling)
    //
    // A transcript that is nothing but gap markers is one the history row
    // deliberately offers no copy button for — it is not worth putting on
    // the clipboard. The notice must not disagree with the row about the
    // same entry, which is the whole reason R30 routes the copied string
    // through the row's own accessor. So on that entry the notice ships no
    // action at all and degrades to a pure informational panel.

    func test_copyIsOfferedExactlyWhenTheRowWouldOfferIt() {
        // The gate is the row's predicate, and this asks the row rather
        // than restating the answer: for each text, whichever way
        // `HistoryRowView.actions(...)` votes on `.copy`, the notice's
        // label and handler must vote the same way. A second spelling of
        // the predicate on the notice's side fails here the moment the two
        // drift.
        let texts = [
            "the transcript",                 // ordinary
            "kept some \(Self.marker) lost some",  // partially recovered
            Self.marker,                      // AE4: the ruling's case
            "\(Self.marker) \(Self.marker)",  // ditto, plural
            "",                               // recovered nothing
            "   ",                            // whitespace-only
        ]
        for text in texts {
            let rowOffersCopy = HistoryRowView.actions(
                isBroken: true, canRetry: false, text: text, isRetrying: false
            ).contains(.copy)

            let kind = NoTypeErrorKind.pasteWithheld(
                entry: Self.entry(text: text, failedChunkCount: 2),
                summary: Self.summary(failed: 2, dispatched: 4)
            )

            XCTAssertEqual(
                kind.payload.retryLabel != nil, rowOffersCopy,
                "The notice and the history row disagree about whether \(text.debugDescription) is worth copying. Both surfaces answer for the same entry, and the user sees them minutes apart."
            )
            XCTAssertEqual(
                kind.retryHandler != nil, rowOffersCopy,
                "The notice's Copy handler and its Copy label disagree for \(text.debugDescription) — either a dead button or dead code."
            )
        }
    }

    func test_aGapsOnlyTranscript_shipsNoActionAtAll() {
        let kind = NoTypeErrorKind.pasteWithheld(
            entry: Self.entry(text: Self.marker, failedChunkCount: 1),
            summary: Self.summary(failed: 1, dispatched: 2)
        )

        XCTAssertNil(
            kind.payload.retryLabel,
            "The notice offers Copy for a transcript the row itself won't copy."
        )
        XCTAssertNil(
            kind.retryHandler,
            "The label is gone but the handler is still wired — dead code, and the pair is what MissingKeyHUDRetryTests sweeps."
        )
        XCTAssertEqual(
            kind.payload.severity, .neutral,
            "Losing the action does not make this a failure — the panel degrades to pure information, not to an alarm."
        )
    }

    // MARK: - What the description says (R25)

    func test_description_namesTheApplicationTheTranscriptWasDestinedFor() {
        let payload = NoTypeErrorKind.pasteWithheld(
            entry: Self.entry(),
            summary: Self.summary(destination: "Mail")
        ).payload

        XCTAssertTrue(
            payload.description.contains("Mail"),
            "The notice must name where the transcript was headed. Without it the user is told a transcript exists with no idea which dictation it was: \(payload.description)"
        )
    }

    func test_description_namesTheStopMomentDestination_notTheSessionsOwnApp() {
        // The 2026-08-11 ruling: the destination is the process the user
        // was in when they *stopped*, which for a hands-free dictation
        // that walked somewhere else is not the application the row is
        // attributed to. `HistoryEntry.sourceAppName` stays frozen at
        // session start because it feeds per-app lifetime statistics, and
        // reaching for it here — the obvious "the entry already knows the
        // app" simplification — names the wrong window on exactly the
        // flow this ruling exists for.
        let payload = NoTypeErrorKind.pasteWithheld(
            entry: Self.entry(sourceApp: "Slack"),
            summary: Self.summary(destination: "Mail")
        ).payload

        XCTAssertTrue(payload.description.contains("Mail"))
        XCTAssertFalse(
            payload.description.contains("Slack"),
            "The notice named the application the session *started* in. The transcript was aimed at where the user stopped."
        )
    }

    func test_description_doesNotBlameTheUser() {
        // Not an exhaustive proof of tone — it cannot be. It pins the
        // specific second-person-fault constructions this copy was written
        // to avoid, so a rewrite that reaches for one fails loudly.
        let blame = [
            "you switched", "you moved", "you left", "you changed",
            "you should", "make sure", "your fault", "because you"
        ]
        for summary in [Self.summary(), Self.summary(failed: 2, dispatched: 4)] {
            let text = NoTypeErrorKind
                .pasteWithheld(entry: Self.entry(), summary: summary)
                .payload
                .description
                .lowercased()
            for phrase in blame {
                XCTAssertFalse(
                    text.contains(phrase),
                    "Description blames the user with '\(phrase)': \(text)"
                )
            }
        }
    }

    // MARK: - The gap count folds in (KTD9)

    func test_whenTheSessionAlsoLostChunks_theDescriptionNamesTheCount() {
        let payload = NoTypeErrorKind.pasteWithheld(
            entry: Self.entry(),
            summary: Self.summary(failed: 2, dispatched: 4)
        ).payload

        XCTAssertTrue(
            payload.description.contains("2 of 4 chunks didn't transcribe"),
            "A withheld session that also lost chunks must say how many, in the same words the gap notice uses: \(payload.description)"
        )
        XCTAssertTrue(
            payload.description.contains(RecordingSession.failureMarker),
            "Copy is about to hand the user a transcript with holes in it. The notice has to say so before they take it."
        )
    }

    func test_gapSentenceMatchesTheGapNoticesCountPhrase() {
        // The two notices are free to differ on what follows the count —
        // one describes markers sitting in the user's document, the other
        // markers in a transcript that never left the app — but the count
        // itself comes from one place and must read identically.
        let summary = Self.summary(failed: 1, dispatched: 3)
        let withheld = NoTypeErrorKind
            .pasteWithheld(entry: Self.entry(), summary: summary)
            .payload.description
        let gaps = NoTypeErrorKind
            .partialTranscription(summary: summary)
            .payload.description

        let phrase = "1 of 3 chunks didn't transcribe"
        XCTAssertTrue(withheld.contains(phrase), withheld)
        XCTAssertTrue(gaps.contains(phrase), gaps)
    }

    func test_withoutGaps_theDescriptionMakesNoGapClaim() {
        let payload = NoTypeErrorKind
            .pasteWithheld(entry: Self.entry(), summary: Self.summary())
            .payload

        XCTAssertFalse(
            payload.description.contains(RecordingSession.failureMarker),
            "A complete transcript must not be described as having gaps: \(payload.description)"
        )
        XCTAssertFalse(
            payload.description.contains("didn't transcribe"),
            "A complete transcript must not be described as having gaps: \(payload.description)"
        )
    }

    func test_pluralisesTheGapSentence() {
        let one = NoTypeErrorKind.pasteWithheld(
            entry: Self.entry(), summary: Self.summary(failed: 1, dispatched: 3)
        ).payload.description
        let many = NoTypeErrorKind.pasteWithheld(
            entry: Self.entry(), summary: Self.summary(failed: 2, dispatched: 3)
        ).payload.description

        XCTAssertTrue(one.contains("marks the gap."), one)
        XCTAssertTrue(many.contains("marks the gaps."), many)
    }

    // MARK: - No transcript content anywhere (R29)

    func test_neitherTitleNorDescription_carriesAnyTranscriptContent() {
        // The panel draws over whatever the user moved to. If that is a
        // screen share, a call, or a recording, every word of it is
        // published. The transcript below is a plausible thing to dictate
        // and a bad thing to broadcast.
        let secret = "my account password is hunter2 and the wire clears friday"
        let entry = Self.entry(text: secret)

        for summary in [Self.summary(), Self.summary(failed: 1, dispatched: 3)] {
            let payload = NoTypeErrorKind
                .pasteWithheld(entry: entry, summary: summary)
                .payload

            XCTAssertFalse(payload.title.contains(secret), payload.title)
            XCTAssertFalse(payload.description.contains(secret), payload.description)
            // A preview or first-N-characters rendering is the realistic
            // regression, not the whole string, so pin the distinctive
            // words individually.
            for word in ["password", "hunter2", "wire", "friday"] {
                XCTAssertFalse(
                    payload.title.lowercased().contains(word),
                    "Transcript content leaked into the notice title: \(payload.title)"
                )
                XCTAssertFalse(
                    payload.description.lowercased().contains(word),
                    "Transcript content leaked into the notice description: \(payload.description)"
                )
            }
        }
    }

    func test_payloadReadsExactlyOneBitOffTheEntry_andItIsNotContent() {
        // The needle test above samples: it proves *those* words are
        // absent from *that* fixture. This proves the property R29
        // actually needs — a first-N-character preview, a word count, an
        // "it starts with…" hint all fail here, and none of them need a
        // needle to be guessed in advance.
        //
        // The property used to be "the payload is a function of the summary
        // alone". The 2026-08-11 ruling widened it by exactly one bit —
        // whether the row would offer Copy — so the pin is now: two entries
        // agreeing on that bit and sharing no other field render the same
        // payload. That bit is a `Bool` and cannot carry a word of what was
        // said; the leak this test exists to catch is unchanged.
        //
        // Cheap because `ErrorPayload` is `Equatable`. Both gap shapes, and
        // both sides of the bit — a pair that is copyable and a pair that
        // is not, since a gate that leaked content only on the no-copy arm
        // would otherwise sweep past.
        let pairs: [(HistoryEntry, HistoryEntry)] = [
            (
                Self.entry(text: "the wire clears friday", sourceApp: "Slack"),
                Self.entry(text: "ship it monday", sourceApp: "Mail", failedChunkCount: 2)
            ),
            (
                Self.entry(text: Self.marker, sourceApp: "Slack", failedChunkCount: 1),
                Self.entry(text: "", sourceApp: "Mail", failedChunkCount: 2)
            ),
        ]

        for (a, b) in pairs {
            for summary in [Self.summary(), Self.summary(failed: 1, dispatched: 3)] {
                XCTAssertEqual(
                    NoTypeErrorKind.pasteWithheld(entry: a, summary: summary).payload,
                    NoTypeErrorKind.pasteWithheld(entry: b, summary: summary).payload,
                    "The notice's payload varies with the entry beyond the copy bit, so something about the transcript reaches the panel. R29 is a privacy property — this panel draws over whatever the user moved to."
                )
            }
        }
    }

    // MARK: - The destination fallback

    func test_aNamelessDestination_fallsBackWithoutRenderingAnEmptyGap() {
        // Reachable: the withhold gate needs a non-zero pid, but the name
        // is `NSRunningApplication.localizedName` — optional, and the
        // process's own answer rather than one we validate. Both shapes
        // must reach the fallback; `?? ` alone catches only the first and
        // renders "headed for , which is no longer the active app."
        let namelessCases: [String?] = [nil, "", "   "]
        for nameless in namelessCases {
            let payload = NoTypeErrorKind.pasteWithheld(
                entry: Self.entry(),
                summary: Self.summary(destination: nameless)
            ).payload

            XCTAssertTrue(
                payload.description.contains("the app you were in"),
                "A destination with no usable name (\(String(describing: nameless))) skipped the fallback: \(payload.description)"
            )
            XCTAssertFalse(
                payload.description.contains("headed for ,"),
                "The empty name rendered as a gap in the sentence: \(payload.description)"
            )
        }
    }

    // MARK: - The rendered copy, verbatim
    //
    // `contains` assertions are green on a sentence that has lost half its
    // meaning — the precedent is `ErrorCopyRetentionTests`, where a
    // `contains` check stayed green on copy that stuttered its imperative
    // twice and only exact equality caught it. These two pin the whole
    // string, so any wording change is a deliberate, visible edit.

    func test_withheldCopy_rendersVerbatim_withAndWithoutGaps() {
        XCTAssertEqual(
            NoTypeErrorKind.pasteWithheld(entry: Self.entry(), summary: Self.summary()).payload.description,
            "This dictation was headed for Mail, which is no longer the active app. Nothing was pasted — the transcript is in your history, and Copy puts it on your clipboard."
        )
        XCTAssertEqual(
            NoTypeErrorKind.pasteWithheld(
                entry: Self.entry(), summary: Self.summary(failed: 2, dispatched: 4)
            ).payload.description,
            "This dictation was headed for Mail, which is no longer the active app. 2 of 4 chunks didn't transcribe, so \(RecordingSession.failureMarker) marks the gaps. Nothing was pasted — the transcript is in your history, and Copy puts it on your clipboard."
        )
    }

    func test_withheldCopy_onTheNoCopyArm_rendersVerbatim() {
        // The 2026-08-11 ruling's arm, pinned whole. Only the final clause
        // moves, and it moves by subtraction — the sentence still says
        // where the transcript is and stops before promising a button that
        // is not rendered. Exact equality, not `contains`: the failure this
        // shape catches is a clause left half-standing ("…is in your
        // history, and puts it on your clipboard."), which every `contains`
        // check on the surviving words stays green for.
        XCTAssertEqual(
            NoTypeErrorKind.pasteWithheld(
                entry: Self.entry(text: Self.marker, failedChunkCount: 1),
                summary: Self.summary(failed: 1, dispatched: 2)
            ).payload.description,
            "This dictation was headed for Mail, which is no longer the active app. 1 of 2 chunks didn't transcribe, so \(RecordingSession.failureMarker) marks the gap. Nothing was pasted — the transcript is in your history."
        )
        XCTAssertFalse(
            NoTypeErrorKind.pasteWithheld(
                entry: Self.entry(text: Self.marker, failedChunkCount: 1),
                summary: Self.summary(failed: 1, dispatched: 2)
            ).payload.description.contains("Copy"),
            "The description still names a Copy the panel does not render."
        )
    }

    func test_gapNoticeCopy_survivedTheSharedCountPhraseExtraction_byteForByte() {
        // U4 pulled the count phrase into `chunkLossPhrase` and, in the
        // singular arm, replaced a hardcoded "1" with an interpolation.
        // That is only byte-identical because the arm is unreachable for
        // any other count — an invariant no other test states. If someone
        // later widens the singular arm, this is what notices.
        XCTAssertEqual(
            NoTypeErrorKind.partialTranscription(
                summary: Self.summary(failed: 1, dispatched: 3, withheld: false)
            ).payload.description,
            "1 of 3 chunks didn't transcribe — \(RecordingSession.failureMarker) was inserted in its place. Re-dictate just that part if you need it."
        )
        XCTAssertEqual(
            NoTypeErrorKind.partialTranscription(
                summary: Self.summary(failed: 2, dispatched: 5, withheld: false)
            ).payload.description,
            "2 of 5 chunks didn't transcribe — \(RecordingSession.failureMarker) was inserted in their place. Re-dictate the missing parts if you need them."
        )
    }

    // MARK: - Copy places what the row shows (R30)

    func test_copyAction_placesExactlyWhatTheRowShows() throws {
        // **This test can no longer prove the accessor, and saying so is
        // better than the green.** It used to run on a session that
        // recovered nothing — stored `""`, rendered as synthesised markers
        // — precisely because `entry.text` and the shown string diverge
        // there, so a handler written against `entry.text` failed. Under
        // the 2026-08-11 ruling that fixture is exactly the row that offers
        // no Copy at all, and the two facts are one fact:
        // `displayText(for:)` synthesises only when the stored text is
        // empty, and empty text is not copyable. So wherever Copy *is*
        // offered the two strings are equal by construction, which is what
        // `test_everyEntryWhoseShownTextDiverges_offersNoCopy` below pins
        // in place of the divergence. The accessor stays as the single
        // source of truth if `displayText` ever starts trimming or eliding;
        // it is now belt-and-braces rather than load-bearing.
        let entry = Self.entry(text: "recovered \(Self.marker) partially", failedChunkCount: 1)
        let shown = HistoryRowView.displayText(for: entry)

        let handler = try XCTUnwrap(
            NoTypeErrorKind.pasteWithheld(entry: entry, summary: Self.summary()).retryHandler,
            "The notice advertises Copy but ships no handler — the dead-button regression."
        )

        let saved = PasteboardSnapshot.capture(.general)
        defer { saved.restore(to: .general) }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("something else entirely", forType: .string)
        handler(nil)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string), shown,
            "Copy and the history row disagree about what was transcribed."
        )
    }

    func test_everyEntryWhoseShownTextDiverges_offersNoCopy() {
        // What the test above lost, stated directly: the only rows where
        // `displayText(for:)` returns something other than `entry.text` are
        // rows the notice now refuses to offer Copy for. That is what makes
        // "a handler written against `entry.text` would pass" harmless
        // rather than a hole — there is no reachable case where the two
        // strings differ *and* a clipboard write happens. If a future change
        // gives `displayText` a second synthesising branch, this fails and
        // R30 needs its divergent fixture back.
        let divergent = [
            Self.entry(text: "", failedChunkCount: 2),
            Self.entry(text: "   ", failedChunkCount: 1),
        ]
        for entry in divergent {
            XCTAssertNotEqual(
                HistoryRowView.displayText(for: entry), entry.text,
                "Fixture no longer diverges — it proves nothing about the divergent case."
            )
            XCTAssertNil(
                NoTypeErrorKind.pasteWithheld(entry: entry, summary: Self.summary()).retryHandler,
                "A row whose shown text differs from its stored text still offers Copy, so which of the two strings is placed is once again load-bearing — and untested."
            )
        }
    }

    func test_copyAction_worksWithoutAnAppState() throws {
        // The wrapper in `AppState.surfaceError` captures `[weak self]`,
        // so a click landing after teardown passes `nil`. Unlike
        // `.missingAPIKey`'s handler — which early-returns and does
        // nothing — this one must still copy: the clipboard write needs
        // no AppState at all, and a user whose click silently did nothing
        // would have lost the only affordance the notice offered.
        let entry = Self.entry(text: "still copyable")
        let handler = try XCTUnwrap(
            NoTypeErrorKind.pasteWithheld(entry: entry, summary: Self.summary()).retryHandler
        )

        let saved = PasteboardSnapshot.capture(.general)
        defer { saved.restore(to: .general) }

        NSPasteboard.general.clearContents()
        handler(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "still copyable")
    }

    // MARK: - Exactly one notice, and which one (KTD9)

    func test_withheldSessionWithGaps_surfacesTheWithheldNotice_notTheGapNotice() {
        // The ordinary bad session: a stalled network drops chunks *and*
        // creates the wait during which the user switches away. Both
        // conditions hold, one notice may be shown, and it must be this
        // one — `.partialTranscription` is titled "Pasted with gaps" and
        // advises re-dictating "just that part", and on a session that
        // pasted nothing both halves are false.
        let notice = NoTypeErrorKind.noticeForFinishedSession(
            entry: Self.entry(),
            summary: Self.summary(failed: 2, dispatched: 4)
        )

        guard let notice, case .pasteWithheld = notice else {
            return XCTFail("Expected the withheld notice; got \(String(describing: notice)).")
        }
        XCTAssertFalse(
            notice.payload.description.contains("Pasted with gaps"),
            "The surviving notice still claims a paste happened."
        )
    }

    func test_gapsWithoutAWithheldPaste_stillSurfacesTheGapNotice() {
        let notice = NoTypeErrorKind.noticeForFinishedSession(
            entry: Self.entry(),
            summary: Self.summary(failed: 1, dispatched: 3, withheld: false)
        )
        guard case .partialTranscription = notice else {
            return XCTFail("Expected the gap notice; got \(String(describing: notice)).")
        }
    }

    func test_withheldPasteWithNoGaps_stillSurfacesTheWithheldNotice() {
        // The condition that fires this notice is the withhold, not the
        // gaps. A clean transcription the user simply walked away from is
        // the flow KD8 was written for.
        let notice = NoTypeErrorKind.noticeForFinishedSession(
            entry: Self.entry(),
            summary: Self.summary()
        )
        guard case .pasteWithheld = notice else {
            return XCTFail("Expected the withheld notice; got \(String(describing: notice)).")
        }
    }

    func test_anOrdinarySession_surfacesNothing() {
        XCTAssertNil(
            NoTypeErrorKind.noticeForFinishedSession(
                entry: Self.entry(),
                summary: Self.summary(failed: 0, dispatched: 3, withheld: false)
            ),
            "A session that pasted everything it transcribed must not interrupt the user."
        )
    }

    // MARK: - The wiring the seam cannot prove
    //
    // `AppState.finalizeRecording` needs a live `RecordingSession` — an
    // `AudioRecorder`, a `SileroVAD`, a `GeminiClient` and a `HistoryStore`
    // — so no test drives it. Every assertion above is therefore satisfiable
    // by a seam nothing calls, which is precisely the failure mode
    // `solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`
    // names: a guard that proves only the absence of the bad shape stays
    // green when the feature is dead. So the destination gets pinned too,
    // in the same source-scan shape as `RecordingSessionFocusGuardTests`
    // and with the same limits — it reads text, not the built
    // configuration, and a rename fails it loudly rather than silently.

    func test_finalizeRecording_routesItsNoticeThroughTheSeam() throws {
        let body = try XCTUnwrap(
            Self.body(ofFuncNamed: "finalizeRecording", in: Self.appStateSource()),
            "Could not parse finalizeRecording() — the guard lost its anchor."
        )

        XCTAssertTrue(
            body.contains("NoTypeErrorKind.noticeForFinishedSession("),
            "finalizeRecording no longer asks the seam which notice to show. Every assertion in this file would still pass while the user saw nothing — or saw the wrong notice."
        )
        // Asking the seam is not showing the answer. Without this, deleting
        // the `surfaceError(notice)` line — or replacing it with a log —
        // leaves the needle above satisfied, every payload assertion in
        // this file green, and the user back to the silent non-delivery
        // U4 exists to end. The guard's own failure message above claims
        // to cover that case; this is the assertion that makes it true.
        XCTAssertTrue(
            body.contains("surfaceError(notice)"),
            "finalizeRecording computes the notice and never shows it. The seam is consulted and its answer discarded — silent non-delivery, which is the exact bug U4 was written to fix."
        )
        // Exactly one consultation. A second `if let notice = …` block —
        // the plausible shape of a later edit that wants to special-case
        // something — satisfies every needle here while `showErrorHUD`'s
        // replace-not-stack semantics decide the survivor by source order.
        // That is KTD9 being resolved by accident rather than by the seam.
        XCTAssertEqual(
            body.components(separatedBy: "NoTypeErrorKind.noticeForFinishedSession(").count - 1, 1,
            "finalizeRecording consults the seam more than once. `showErrorHUD` replaces rather than stacks, so whichever call runs last wins — and that is an ordering nobody decided."
        )
        XCTAssertFalse(
            body.contains("surfaceError(.partialTranscription"),
            "The gap notice is surfaced directly again, beside the seam. `showErrorHUD` replaces rather than stacks, so on a session that both lost chunks and changed destination one of the two is silently discarded — and the survivor is whichever ran last, which is not a decision anyone made."
        )
        XCTAssertFalse(
            body.contains("surfaceError(.pasteWithheld"),
            "The withheld notice is constructed at the call site rather than by the seam. That is where KTD9's ordering lives; a second construction here can disagree with it."
        )
        // A `#if` would satisfy every literal above while compiling the
        // call out of the shipping configuration.
        XCTAssertFalse(
            body.contains("#if"),
            "finalizeRecording grew a conditional-compilation block. The scan matches text, not the built configuration, so a notice inside `#if DEBUG` reads as present here and is absent from the release binary. Re-derive this guard before adding one."
        )
    }

    // MARK: - Fixtures for the extractor itself
    //
    // Without these, an extractor that silently matched the whole file
    // would pass the guard above on a `finalizeRecording` that had lost
    // the seam entirely.

    func test_bodyExtractor_isScopedToTheNamedFunction() throws {
        let source = """
        private func other() {
            NoTypeErrorKind.noticeForFinishedSession(entry: e, summary: s)
        }

        private func finalizeRecording(session: RecordingSession) {
            let marker = 1
        }
        """
        let body = try XCTUnwrap(Self.body(ofFuncNamed: "finalizeRecording", in: source))
        XCTAssertTrue(body.contains("let marker = 1"))
        XCTAssertFalse(
            body.contains("noticeForFinishedSession"),
            "The extractor ran past its function — the presence assertion would be satisfiable by a neighbouring one."
        )
    }

    func test_commentStripping_hidesDisabledCodeAndProse() {
        let stripped = Self.strippingComments("""
        // NoTypeErrorKind.noticeForFinishedSession(entry: e, summary: s)
        let kept = 1  /* surfaceError(.partialTranscription(summary: s)) */
        let feed = "https://weylandd.github.io/NoType/appcast.xml"
        """)
        XCTAssertFalse(
            stripped.contains("NoTypeErrorKind.noticeForFinishedSession("),
            "A commented-out call still matched — the guard would pass on a file where the notice was disabled."
        )
        XCTAssertFalse(
            stripped.contains("surfaceError(.partialTranscription"),
            "A block comment survived — this file's own prose names that call while explaining where it must not appear, so an absence assertion over un-stripped text fails on the comments alone."
        )
        XCTAssertTrue(stripped.contains("let kept = 1"))
        XCTAssertTrue(
            stripped.contains("https://weylandd.github.io/NoType/appcast.xml"),
            "A URL literal's `//` was read as a comment. Truncating a line is how an absence assertion passes for the wrong reason."
        )
    }

    // MARK: - Fixtures

    /// The gap marker a failed chunk leaves behind. Spelled once so a
    /// fixture built out of markers cannot drift from the thing the
    /// production code substitutes.
    private static let marker = RecordingSession.failureMarker

    private static func summary(
        failed: Int = 0,
        dispatched: Int = 3,
        withheld: Bool = true,
        destination: String? = "Mail"
    ) -> RecordingSession.SessionSummary {
        RecordingSession.SessionSummary(
            failedChunkCount: failed,
            dispatchedChunkCount: dispatched,
            tokens: .zero,
            model: .flashLite,
            pasteWithheldForDestinationChange: withheld,
            pasteDestinationAppName: withheld ? destination : nil
        )
    }

    private static func entry(
        text: String = "the transcript",
        sourceApp: String = "Slack",
        failedChunkCount: Int = 0
    ) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: sourceApp,
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(),
            failedChunkCount: failedChunkCount
        )
    }

    // MARK: - Extractors
    //
    // Duplicated from `RecordingSessionFocusGuardTests` rather than
    // shared, following the precedent that file records against
    // `SplitRetryNetworkBoundTests`: each guard owns its own extractor and
    // its own fidelity fixtures, so tightening one cannot quietly change
    // what another proves. Same caveats — naive about braces inside string
    // literals, adequate for the one Swift file it reads.

    private static func body(ofFuncNamed name: String, in source: String) -> String? {
        guard let decl = source.range(of: "func \(name)(") else { return nil }
        guard let open = source.range(of: "{", range: decl.upperBound..<source.endIndex) else { return nil }
        return block(from: open.lowerBound, in: source)
    }

    private static func block(from open: String.Index, in source: String) -> String? {
        var depth = 0
        var idx = open
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return String(source[source.index(after: open)..<idx]) }
            }
            idx = source.index(after: idx)
        }
        return nil
    }

    /// Comments are stripped before any assertion runs, and that is
    /// load-bearing rather than tidiness: this file's own prose names
    /// `surfaceError(.partialTranscription` while explaining where it must
    /// not appear, and a commented-out seam call would satisfy a raw
    /// `contains`. Block comments too — a `/* … */` around the call
    /// disables the notice while leaving every literal intact.
    private static func strippingComments(_ source: String) -> String {
        // The sentinel must not itself contain `//`, or the line pass
        // below truncates every URL literal at the scheme.
        let urlSchemeSentinel = "\u{1}"
        var s = source.replacingOccurrences(of: "://", with: urlSchemeSentinel)

        while let open = s.range(of: "/*"),
              let close = s.range(of: "*/", range: open.upperBound..<s.endIndex) {
            s.replaceSubrange(open.lowerBound..<close.upperBound, with: "")
        }

        return s
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: urlSchemeSentinel, with: "://")
    }

    private static func appStateSource() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NoTypeTests/
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("NoType/AppState.swift")
        return strippingComments((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }
}
