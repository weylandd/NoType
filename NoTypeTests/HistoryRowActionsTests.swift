import XCTest
@testable import NoType

/// Pins U7 — what a history row offers and what it shows in each of its
/// states (R7, R9-as-superseded, R10, R13, R18, R19).
///
/// The project ships no UI tests, so the row's logic is pulled out into
/// two `nonisolated static` functions on `HistoryRowView` and those are
/// what is proved here: `actions(...)` (R10's truth table) and
/// `displayText(for:)` (how a broken row renders its gaps). The rendering
/// that consumes them — which tile fills the leading slot, whether the
/// action row is hover-gated — is checked by eye against the drawn
/// design, per the unit's verification line.
///
/// The two facts that are *not* pure get behavioural coverage instead:
/// R18's shared retry slot is driven through a real `AppState` with a
/// gated sender, and R19's visible outcome is asserted on the real
/// `HUDController`.
@MainActor
final class HistoryRowActionsTests: XCTestCase {

    private let marker = RecordingSession.failureMarker

    // MARK: - Action set (R10, R13, AE4)

    func test_actions_brokenWithPayloadAndText_offersRetryCopyDelete() {
        // AE4, first row of the table: the live broken row, mid-window,
        // audio still held.
        XCTAssertEqual(
            HistoryRowView.actions(
                isBroken: true, canRetry: true, hasText: true, isRetrying: false
            ),
            [.retry, .copy, .delete]
        )
    }

    func test_actions_brokenWithoutPayloadButWithText_offersCopyAndDelete() {
        // AE4, second row: a *dead* row after a relaunch. The audio is
        // gone so retry disappears, but the partial transcript is still
        // worth copying and the row itself stays (R8).
        XCTAssertEqual(
            HistoryRowView.actions(
                isBroken: true, canRetry: false, hasText: true, isRetrying: false
            ),
            [.copy, .delete]
        )
    }

    func test_actions_brokenWithoutPayloadOrText_offersDeleteOnly() {
        // AE4, third row: nothing was recovered and nothing can be. The
        // row survives as the record that a dictation was lost, and the
        // markers it renders are not something worth copying.
        XCTAssertEqual(
            HistoryRowView.actions(
                isBroken: true, canRetry: false, hasText: false, isRetrying: false
            ),
            [.delete]
        )
    }

    func test_actions_retrying_offersDeleteOnly_withNoRetryAndNoCancel() {
        // R13. Delete stays available — it is the only exit from a run
        // that cannot be cancelled (KTD7) — and nothing else is offered.
        let busy = HistoryRowView.actions(
            isBroken: true, canRetry: false, hasText: true, isRetrying: true
        )
        XCTAssertEqual(busy, [.delete])
        XCTAssertFalse(busy.contains(.retry), "one run at a time")
        XCTAssertFalse(busy.contains(.copy), "matches the drawn retrying row")
    }

    func test_actions_retrying_winsOverEveryOtherInput() {
        // The busy branch is a short-circuit, not one term among four:
        // even a row that would otherwise offer all three collapses to
        // delete. Without the early return this reads [.retry,.copy,.delete].
        XCTAssertEqual(
            HistoryRowView.actions(
                isBroken: true, canRetry: true, hasText: true, isRetrying: true
            ),
            [.delete]
        )
    }

    func test_actions_normalRow_isUnchanged() {
        // The ordinary successful session: copy and delete, exactly as
        // before this unit. (Hover-gating is the *visibility* half and
        // lives in the view; this is the membership half.)
        XCTAssertEqual(
            HistoryRowView.actions(
                isBroken: false, canRetry: false, hasText: true, isRetrying: false
            ),
            [.copy, .delete]
        )
    }

    func test_actions_retryIsNeverOfferedOnANonBrokenRow() {
        // A row with no marker left in its text has nowhere for a
        // recovery to land, so retry would spend the user's Gemini
        // budget on a request that settles straight onto R19's
        // nothing-recovered exit. Dropping `isBroken &&` from the
        // predicate makes this [.retry, .copy, .delete].
        XCTAssertEqual(
            HistoryRowView.actions(
                isBroken: false, canRetry: true, hasText: true, isRetrying: false
            ),
            [.copy, .delete]
        )
    }

    func test_actions_deleteIsOfferedInEveryState() {
        // R10's "delete always", swept over the whole input space rather
        // than asserted case by case.
        for isBroken in [true, false] {
            for canRetry in [true, false] {
                for hasText in [true, false] {
                    for isRetrying in [true, false] {
                        XCTAssertTrue(
                            HistoryRowView.actions(
                                isBroken: isBroken,
                                canRetry: canRetry,
                                hasText: hasText,
                                isRetrying: isRetrying
                            ).contains(.delete),
                            "delete missing for broken=\(isBroken) canRetry=\(canRetry) "
                            + "hasText=\(hasText) retrying=\(isRetrying)"
                        )
                    }
                }
            }
        }
    }

    func test_actions_orderIsRetryThenCopyThenDelete() {
        // Declaration order is render order, matching the design's
        // markup. A row is never rendered with delete in the middle.
        let all = HistoryRowView.actions(
            isBroken: true, canRetry: true, hasText: true, isRetrying: false
        )
        XCTAssertEqual(all, HistoryRowView.RowAction.allCases)
    }

    // MARK: - How a broken row renders its gaps (R9 as superseded)

    func test_displayText_normalRow_isTheStoredTextVerbatim() {
        XCTAssertEqual(
            HistoryRowView.displayText(for: entry(text: "Ship it by Friday.")),
            "Ship it by Friday."
        )
    }

    func test_displayText_partiallyFailedRow_isTheStoredTextVerbatim() {
        // The markers are already in the stored text — they were pasted
        // into the target app that way. Nothing is synthesised.
        let text = "Ship it by \(marker) and review after."
        XCTAssertEqual(
            HistoryRowView.displayText(for: entry(text: text, failedChunkCount: 1)),
            text
        )
    }

    func test_displayText_rowThatRecoveredNothing_rendersOneMarkerPerFailedChunk() {
        // The maintainer's directive: a row that recovered nothing shows
        // only markers — one per chunk, so the row says how much was lost.
        XCTAssertEqual(
            HistoryRowView.displayText(for: entry(text: "", failedChunkCount: 3)),
            "\(marker) \(marker) \(marker)"
        )
        XCTAssertEqual(
            HistoryRowView.displayText(for: entry(text: "", failedChunkCount: 1)),
            marker
        )
    }

    func test_displayText_emptyNonBrokenRow_synthesisesNothing() {
        // A successful session whose transcript normalised away to "" is
        // not broken and must not sprout markers. (Reachable — see
        // `RecordingSession.brokenHistoryEntry()`'s doc-comment.)
        XCTAssertEqual(HistoryRowView.displayText(for: entry(text: "")), "")
    }

    func test_displayText_isTheSameShapeARetryMergesInto() {
        // The load-bearing agreement. The markers are synthesised for
        // display but stored as an empty string, so a retry merges into
        // `""` — through `RetryMerge`'s empty-text branch — while the
        // user is looking at `[…] […] […]`. Both sides go through
        // `TextInjector.stitchChunks`, so the two must produce the same
        // string or the row visibly reflows the moment a retry lands its
        // first chunk. A different join here (newlines, no spaces,
        // `joined()`) makes this red.
        let row = entry(text: "", failedChunkCount: 3)
        let displayed = HistoryRowView.displayText(for: row)

        let recovered: [String?] = ["Ship it", nil, nil]
        let fromStoredText   = RetryMerge.merge(existingText: row.text,  recovered: recovered)
        let fromDisplayedText = RetryMerge.merge(existingText: displayed, recovered: recovered)

        XCTAssertEqual(fromStoredText, fromDisplayedText)
        XCTAssertEqual(fromStoredText, "Ship it \(marker) \(marker)")
    }

    func test_displayText_survivesAPartialRecovery_asAnOrdinaryBrokenRow() {
        // The whole point of storing empty and rendering markers: after a
        // partial retry the row *does* carry text, with the unrecovered
        // chunks still sitting in position. From then on it is an
        // ordinary partially-failed row and nothing is synthesised.
        let partially = entry(text: "Ship it \(marker) \(marker)", failedChunkCount: 2)
        XCTAssertEqual(HistoryRowView.displayText(for: partially), partially.text)
        XCTAssertEqual(
            HistoryRowView.actions(
                isBroken: true, canRetry: true, hasText: !partially.text.isEmpty, isRetrying: false
            ),
            [.retry, .copy, .delete],
            "and it is copyable now, where the all-failed row was not"
        )
    }

    // MARK: - One shared retry slot drives both surfaces (AE7, R18)

    func test_theSharedSlot_makesOneRowBusyAndBlocksTheOthers_whileARunIsInFlight() async {
        // AE7's mechanism, driven end to end: both surfaces pass
        // `AppState.retryingEntryID` and `AppState.canRetry(entryID:)`
        // straight into the row, so whatever those two say *while a run
        // is in flight* is what both surfaces render. Asserted here on
        // the shared values plus the action table they feed.
        let fx = Fixture(self)
        let busyRow  = fx.appendBrokenRow(text: "", failedChunkCount: 1, chunkCount: 1)
        let otherRow = fx.appendBrokenRow(text: "a \(marker) b", failedChunkCount: 1, chunkCount: 1)

        let gate = Gate()
        fx.state.retryChunkSender = { _, _, _, _ in
            gate.entered = true
            while !gate.released { await Task.yield() }
            return ("recovered", .zero)
        }

        let run = Task { await fx.state.retryEntry(id: busyRow.id) }
        await spin(until: { gate.entered }, "the retry never reached its first request")

        // The one slot names exactly one row …
        XCTAssertEqual(fx.state.retryingEntryID, busyRow.id)
        XCTAssertEqual(
            HistoryRowView.actions(
                isBroken: true,
                canRetry: fx.state.canRetry(entryID: busyRow.id),
                hasText: false,
                isRetrying: fx.state.retryingEntryID == busyRow.id
            ),
            [.delete],
            "R13: the busy row offers delete and nothing else"
        )
        // … and every other row is blocked while it runs, in both
        // surfaces, because both read the same two values.
        XCTAssertFalse(fx.state.canRetry(entryID: otherRow.id))
        XCTAssertEqual(
            HistoryRowView.actions(
                isBroken: true,
                canRetry: fx.state.canRetry(entryID: otherRow.id),
                hasText: true,
                isRetrying: fx.state.retryingEntryID == otherRow.id
            ),
            [.copy, .delete],
            "not busy itself, but it cannot start a second run either"
        )

        gate.released = true
        await run.value

        XCTAssertNil(fx.state.retryingEntryID, "and the slot is free again once it settles")
        XCTAssertEqual(fx.row(busyRow.id)?.text, "recovered")
        XCTAssertEqual(fx.row(busyRow.id)?.failedChunkCount, 0, "no longer broken")
    }

    func test_bothHistorySurfaces_passTheSharedSlot_andNeitherKeepsALocalCopy() throws {
        // The wiring half of R18, which no runtime assertion can reach:
        // the popover and the Home tab must hand the row the *same*
        // `AppState` values rather than each computing its own.
        //
        // Presence first — an absence-only scan would stay green on a
        // surface that dropped the retry affordance entirely.
        let popover = try Self.source("NoType/UI/HistoryPopover.swift")
        let home    = try Self.source("NoType/UI/HomeView.swift")
        let row     = try Self.source("NoType/UI/HistoryRowView.swift")

        for (name, src) in [("HistoryPopover.swift", popover), ("HomeView.swift", home)] {
            XCTAssertTrue(
                src.contains("appState.retryingEntryID"),
                "\(name) must pass the shared retry slot, not a local flag"
            )
            XCTAssertTrue(
                src.contains("appState.canRetry(entryID:"),
                "\(name) must use AppState's retry gate rather than re-deriving it"
            )
            XCTAssertTrue(
                src.contains("appState.retryEntry(id:"),
                "\(name) must drive the shared orchestration"
            )
            // Absence: neither surface may own retry state of its own.
            for line in src.split(separator: "\n") where line.contains("@State") {
                XCTAssertFalse(
                    line.lowercased().contains("retry"),
                    "\(name) declares local retry state — R18 requires one shared value: \(line)"
                )
            }
        }

        // And the row consumes the slot as a parameter; it never owns it.
        XCTAssertTrue(
            row.contains("var retryingEntryID: UUID?"),
            "HistoryRowView must take the shared slot as a parameter"
        )
        for line in row.split(separator: "\n") where line.contains("@State") {
            XCTAssertFalse(
                line.contains("retryingEntryID"),
                "HistoryRowView must not own the shared slot: \(line)"
            )
        }
    }

    // MARK: - A retry that recovers nothing (R19)

    func test_retryThatRecoversNothing_leavesTheErrorHUDUp_andTheRowBackInItsRetryableState() async {
        // R19, from the row's side. The row *does* return to exactly how
        // it looked before the tap — broken, retryable, same markers —
        // which is precisely why the failure has to be surfaced
        // somewhere else, or the tap reads as having done nothing at all.
        let fx = Fixture(self)
        let row = fx.appendBrokenRow(text: "", failedChunkCount: 2, chunkCount: 2)

        let before = HistoryRowView.actions(
            isBroken: true,
            canRetry: fx.state.canRetry(entryID: row.id),
            hasText: false,
            isRetrying: false
        )
        XCTAssertEqual(before, [.retry, .delete])
        XCTAssertFalse(fx.hud.errorHUDVisible, "nothing surfaced yet")

        fx.state.retryChunkSender = { _, _, _, _ in
            throw GeminiClient.GeminiError.http(status: 0, body: "offline")
        }
        await fx.state.retryEntry(id: row.id)

        let settled = fx.row(row.id)
        XCTAssertEqual(
            settled.map { HistoryRowView.displayText(for: $0) },
            "\(marker) \(marker)",
            "the row renders exactly what it rendered before the tap"
        )
        XCTAssertEqual(
            HistoryRowView.actions(
                isBroken: true,
                canRetry: fx.state.canRetry(entryID: row.id),
                hasText: false,
                isRetrying: fx.state.retryingEntryID == row.id
            ),
            before,
            "and offers the same actions — the user can try again"
        )
        XCTAssertTrue(
            fx.hud.errorHUDVisible,
            "R19: so the *only* signal that the run happened is the Error HUD. "
            + "Drop the surfaceError call and the tap becomes invisible."
        )
    }

    // MARK: - Helpers

    private func entry(text: String, failedChunkCount: Int = 0) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: "Slack",
            sourceBundleID: Fixture.bundleID,
            timestamp: Date(),
            durationSeconds: 12,
            failedChunkCount: failedChunkCount
        )
    }

    /// Yield until `condition` holds. Both the test and the gated sender
    /// run on the main actor, so a yield is all it takes to hand control
    /// over; the bound turns a wiring mistake into a failure rather than
    /// a hung suite.
    private func spin(
        until condition: () -> Bool,
        _ message: String,
        limit: Int = 10_000
    ) async {
        for _ in 0..<limit {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(message)
    }

    private static func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NoTypeTests/
            .deletingLastPathComponent()    // repo root
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// Main-actor-confined rendezvous for the gated sender. Not
    /// `Sendable` and does not need to be: the sender closure, the run
    /// `Task` and the test method are all `@MainActor`.
    @MainActor
    private final class Gate {
        var entered  = false
        var released = false
    }

    /// A real `AppState` over throwaway stores, matching the shape
    /// `AppStateRetryTests` uses. Kept local rather than shared: that
    /// fixture is `private` to its own file, and a U7-visible copy of it
    /// would couple two units' test surfaces.
    @MainActor
    private final class Fixture {
        static let bundleID = "com.tinyspeck.slackmacgap"

        let store = RetainedAudioStore()
        let hud: HUDController
        let state: AppState

        init(_ test: XCTestCase) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

            let perms = PermissionsViewModel()
            let gemini = GeminiClient()
            let instructions = InstructionsStore()
            self.hud = HUDController(permissions: perms)
            self.state = AppState(
                permissions: perms,
                hud: hud,
                gemini: gemini,
                historyStore: HistoryStore(url: dir.appendingPathComponent("history.json")),
                statsStore: StatsStore(url: dir.appendingPathComponent("stats.json")),
                instructionsStore: instructions,
                appCategorizer: AppCategorizer(client: gemini, store: instructions),
                dictionaryStore: DictionaryStore(url: dir.appendingPathComponent("dictionary.json")),
                onboarding: OnboardingState(),
                retainedAudio: store
            )
        }

        @discardableResult
        func appendBrokenRow(
            text: String,
            failedChunkCount: Int,
            chunkCount: Int
        ) -> HistoryEntry {
            let entry = HistoryEntry(
                id: UUID(),
                text: text,
                sourceAppName: "Slack",
                sourceBundleID: Self.bundleID,
                timestamp: Date(),
                durationSeconds: 12,
                failedChunkCount: failedChunkCount
            )
            state.recordHistoryEntry(entry, retaining: payload(chunkCount: chunkCount))
            return entry
        }

        func row(_ id: UUID) -> HistoryEntry? { state.history.first { $0.id == id } }

        private func payload(chunkCount: Int) -> RetainedRecording {
            RetainedRecording(
                chunks: (0..<chunkCount).map {
                    RetainedRecording.Chunk(
                        idx: $0,
                        isFinal: $0 == chunkCount - 1,
                        audio: Data([UInt8(0xA0 + $0)]),
                        // 4 s of audio — comfortably above
                        // `HallucinationLengthGate`'s floor, so a short
                        // fixture answer is never filtered as a
                        // hallucination.
                        samples: 64_000
                    )
                },
                context: ContextSnapshot.minimal(
                    activeApp: AppInfo(name: "Slack", bundleID: Self.bundleID)
                ),
                model: .flashLite
            )
        }
    }
}
