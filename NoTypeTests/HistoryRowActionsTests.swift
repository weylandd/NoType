import XCTest
@testable import NoType

/// Pins what a history row offers, and the wiring that feeds it (R5, R8,
/// R10, R13, R18).
///
/// The project ships no UI tests, so the row's logic lives in two
/// `nonisolated static` functions on `HistoryRowView` and those are what is
/// proved here: `actions(...)` (R10's truth table, minus the marker term R8
/// removed) and `hasCopyableText(_:)`. What the row *shows* moved out
/// entirely — it is `HistoryText.rendered`, pinned by `HistoryTextTests`,
/// because `StatsStore` needs the same string and cannot reach into the UI
/// module for it.
///
/// The facts that are not pure get behavioural coverage instead: R18's
/// shared retry slot is driven through a real `AppState` with a gated
/// sender, R19's visible outcome is asserted on the real `HUDController`,
/// and the per-surface threading is a source scan.
@MainActor
final class HistoryRowActionsTests: XCTestCase {

    private let marker = RecordingSession.failureMarker

    // MARK: - Action set (R8, R10, R13, AE4)

    /// A partially-failed session: one response carried text, one was a
    /// gap. Copyable, and broken.
    private var partialRow: HistoryEntry {
        row([.carrying("Ship it", at: [0]), .gap(at: [1]), .carrying("and review after.", at: [2])])
    }

    /// A session that lost every chunk — the shape `brokenHistoryEntry()`
    /// writes. Nothing worth copying.
    private var allGapRow: HistoryEntry {
        row([.gap(at: [0]), .gap(at: [1])])
    }

    func test_actions_brokenWithPayloadAndText_offersRetryCopyDelete() {
        // The live broken row, mid-window, audio still held.
        XCTAssertEqual(
            HistoryRowView.actions(entry: partialRow, canRetry: true, isRetrying: false),
            [.retry, .copy, .delete]
        )
    }

    func test_actions_brokenWithoutPayloadButWithText_offersCopyAndDelete() {
        // A *dead* row after a relaunch. The audio is gone so retry
        // disappears, but the partial transcript is still worth copying
        // and the row itself stays (R8).
        XCTAssertEqual(
            HistoryRowView.actions(entry: partialRow, canRetry: false, isRetrying: false),
            [.copy, .delete]
        )
    }

    func test_actions_allGapRowWithoutPayload_offersDeleteOnly() {
        // Nothing was recovered and nothing can be. The row survives as
        // the record that a dictation was lost, and the markers it
        // renders are not something worth copying.
        XCTAssertEqual(
            HistoryRowView.actions(entry: allGapRow, canRetry: false, isRetrying: false),
            [.delete]
        )
    }

    func test_actions_allGapRowWithPayload_offersRetryAndDelete_butNoCopy() {
        XCTAssertEqual(
            HistoryRowView.actions(entry: allGapRow, canRetry: true, isRetrying: false),
            [.retry, .delete]
        )
    }

    func test_actions_aGateFilteredChunkIsTextAndDoesNotMakeARowBroken() {
        // AE10 from the row's side. `""` is a text segment (R27): Gemini
        // answered and `HallucinationLengthGate` filtered the answer, so
        // the chunk is not lost and the row is not broken.
        let gated = row([.carrying("Ship it.", at: [0]), .carrying("", at: [1])])
        XCTAssertFalse(gated.isBroken)
        XCTAssertEqual(
            HistoryRowView.actions(entry: gated, canRetry: true, isRetrying: false),
            [.copy, .delete],
            "a filtered chunk is not a gap, so there is nothing to retry"
        )
    }

    func test_actions_retrying_offersNoRetryAndNoCancel_butKeepsDelete() {
        // R13. Delete stays available — it is the only exit from a run
        // that cannot be cancelled (KTD7) — and retry never doubles up.
        let busy = HistoryRowView.actions(entry: partialRow, canRetry: false, isRetrying: true)
        XCTAssertFalse(busy.contains(.retry), "one run at a time")
        XCTAssertTrue(busy.contains(.delete), "the only exit stays open")
    }

    func test_actions_retryingRowStillOffersCopy_whenItIsShowingText() {
        // A busy row renders whatever it already recovered, dimmed.
        // Withholding copy would leave the user looking at text they
        // cannot take, for a run they cannot cancel.
        XCTAssertEqual(
            HistoryRowView.actions(entry: partialRow, canRetry: true, isRetrying: true),
            [.copy, .delete]
        )
    }

    func test_actions_retryingRowWithNothingToShow_offersDeleteOnly() {
        // The drawn retrying row: no transcript, one trash button.
        XCTAssertEqual(
            HistoryRowView.actions(entry: allGapRow, canRetry: true, isRetrying: true),
            [.delete]
        )
    }

    func test_actions_normalRow_isUnchanged() {
        // The ordinary successful session: copy and delete, exactly as
        // before this unit. (Hover-gating is the *visibility* half and
        // lives in the view; this is the membership half.)
        XCTAssertEqual(
            HistoryRowView.actions(
                entry: row([.carrying("Ship it by Friday.", at: [0])]),
                canRetry: false,
                isRetrying: false
            ),
            [.copy, .delete]
        )
    }

    func test_actions_retryIsNeverOfferedOnANonBrokenRow() {
        // Dropping `entry.isBroken &&` from the predicate makes this
        // [.retry, .copy, .delete].
        XCTAssertEqual(
            HistoryRowView.actions(
                entry: row([.carrying("Ship it by Friday.", at: [0])]),
                canRetry: true,
                isRetrying: false
            ),
            [.copy, .delete]
        )
    }

    // MARK: - The defect this unit exists for (AE1)

    func test_actions_retryIsOfferedEvenWhenAPairRewritesEveryMarker() {
        // **The headline case.** A user pair on the ellipsis rewrites
        // every `[…]` the row renders — the shipped build responded by
        // hiding the retry button, because the marker *was* the storage
        // and a recovery had nowhere to land. The gap is a position now,
        // so the pair restyles it and the retry stays.
        let pairs = [DictionaryReplacement(from: "…", to: "...")]
        let shown = HistoryText.rendered(partialRow, replacements: pairs)

        XCTAssertFalse(
            shown.contains(marker),
            "fixture no longer exercises the rewrite — it proves nothing"
        )
        XCTAssertTrue(shown.contains("[...]"), "the pair restyled the gap rather than deleting it")
        XCTAssertTrue(partialRow.isBroken, "and the row is still broken")
        XCTAssertEqual(
            HistoryRowView.actions(entry: partialRow, canRetry: true, isRetrying: false),
            [.retry, .copy, .delete],
            "the user's own dictionary must not cost them their recovery"
        )
    }

    func test_actions_ignoreTheLegacyTextMirror() {
        // Two rows with identical sequences and wildly different `text`
        // mirrors read identically. This is what "the sequence is the
        // source of truth" means operationally — and it is what fails if
        // any term of `actions` slips back to reading the mirror.
        let segments: [HistoryEntry.Segment] = [.carrying("kept", at: [0]), .gap(at: [1])]
        let a = row(segments, text: "kept \(marker)")
        let b = row(segments, text: "")

        XCTAssertEqual(
            HistoryRowView.actions(entry: a, canRetry: true, isRetrying: false),
            HistoryRowView.actions(entry: b, canRetry: true, isRetrying: false)
        )
        XCTAssertEqual(
            HistoryRowView.hasCopyableText(a),
            HistoryRowView.hasCopyableText(b)
        )
    }

    // MARK: - What counts as worth copying (AE4)

    func test_hasCopyableText_isDerivedFromTheSequence_notFromSplittingTheText() {
        XCTAssertTrue(HistoryRowView.hasCopyableText(partialRow))
        XCTAssertFalse(HistoryRowView.hasCopyableText(allGapRow))
        XCTAssertFalse(
            HistoryRowView.hasCopyableText(row([.carrying("   ", at: [0]), .gap(at: [1])])),
            "a segment holding whitespace is nothing to the user"
        )
        XCTAssertFalse(
            HistoryRowView.hasCopyableText(row([.carrying("", at: [0]), .gap(at: [1])])),
            "and neither is a gate-filtered empty segment on its own"
        )
    }

    func test_hasCopyableText_isUnmovedByAnyReplacementPair() {
        // The predicate takes no pair list on purpose: a pair that turns
        // the marker into ordinary words makes the *rendered* string look
        // full of prose, and copy-ability must not follow it. Otherwise
        // the row and the withheld-paste notice — which render with the
        // same list today but need not — could disagree.
        let pairs = [DictionaryReplacement(from: "…", to: "nothing was lost here")]
        let shown = HistoryText.rendered(allGapRow, replacements: pairs)

        XCTAssertTrue(shown.contains("nothing was lost here"), "fixture check")
        XCTAssertFalse(
            HistoryRowView.hasCopyableText(allGapRow),
            "every segment is still a gap — there is no transcript under that prose"
        )
        XCTAssertEqual(
            HistoryRowView.actions(entry: allGapRow, canRetry: false, isRetrying: false),
            [.delete]
        )
    }

    func test_actions_deleteIsOfferedInEveryState() {
        // R10's "delete always", swept over the input space rather than
        // asserted case by case.
        let rows = [
            partialRow,
            allGapRow,
            row([.carrying("plain", at: [0])]),
            row([.carrying("   ", at: [0])]),
            row([.carrying("", at: [0]), .gap(at: [1])]),
        ]
        for entry in rows {
            for canRetry in [true, false] {
                for isRetrying in [true, false] {
                    XCTAssertTrue(
                        HistoryRowView.actions(
                            entry: entry, canRetry: canRetry, isRetrying: isRetrying
                        ).contains(.delete),
                        "delete missing for broken=\(entry.isBroken) canRetry=\(canRetry) "
                        + "retrying=\(isRetrying)"
                    )
                }
            }
        }
    }

    func test_actions_orderIsRetryThenCopyThenDelete() {
        // Declaration order is render order, matching the design's
        // markup. A row is never rendered with delete in the middle.
        XCTAssertEqual(
            HistoryRowView.actions(entry: partialRow, canRetry: true, isRetrying: false),
            HistoryRowView.RowAction.allCases
        )
    }

    // MARK: - Display and copy are one string (R6, AE6)

    func test_theRowRendersAndCopiesTheSameProperty() throws {
        // R6 is a structural claim — the transcript `Text` and the copy
        // button read one property — and no unit test can observe a
        // SwiftUI body or a private method. So it is pinned where it
        // lives: both must go through `shownText`, and neither may
        // re-derive the string or reach for the legacy mirror.
        //
        // Presence first: a scan that only forbade `entry.text` would
        // stay green on a row that rendered nothing at all.
        let source = try Self.source("NoType/UI/HistoryRowView.swift")

        XCTAssertTrue(
            source.contains("Text(shownText)"),
            "the transcript no longer renders the shared property — display and copy can now diverge"
        )
        XCTAssertTrue(
            source.contains("setString(shownText"),
            "the copy button no longer places the shared property — R6's whole guarantee is that these are one string"
        )
        XCTAssertTrue(
            source.contains("HistoryText.rendered(entry, replacements: replacements)"),
            "`shownText` no longer applies the user's current pairs (R5)"
        )
        XCTAssertFalse(
            source.contains("entry.text"),
            "the row reads the legacy mirror again — it is frozen to the session's pairs and un-reassembled (R13)"
        )
    }

    // MARK: - One shared retry slot drives both surfaces (AE7, R18)

    func test_theSharedSlot_makesOneRowBusyAndBlocksTheOthers_whileARunIsInFlight() async {
        // Both surfaces pass `AppState.retryingEntryID` and
        // `AppState.canRetry(entryID:)` straight into the row, so whatever
        // those two say *while a run is in flight* is what both surfaces
        // render. Asserted here on the shared values plus the action table
        // they feed.
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
                entry: busyRow,
                canRetry: fx.state.canRetry(entryID: busyRow.id),
                isRetrying: fx.state.retryingEntryID == busyRow.id
            ),
            [.delete],
            "R13: this row recovered nothing, so delete is all it can offer"
        )
        // … and every other row is blocked while it runs, in both
        // surfaces, because both read the same two values.
        XCTAssertFalse(fx.state.canRetry(entryID: otherRow.id))
        XCTAssertEqual(
            HistoryRowView.actions(
                entry: otherRow,
                canRetry: fx.state.canRetry(entryID: otherRow.id),
                isRetrying: fx.state.retryingEntryID == otherRow.id
            ),
            [.copy, .delete],
            "not busy itself, but it cannot start a second run either"
        )

        gate.released = true
        await run.value

        XCTAssertNil(fx.state.retryingEntryID, "and the slot is free again once it settles")
        XCTAssertEqual(
            fx.row(busyRow.id).map { HistoryText.rendered($0, replacements: []) },
            "recovered"
        )
        XCTAssertEqual(fx.row(busyRow.id)?.isBroken, false, "no longer broken")
    }

    func test_bothHistorySurfaces_passTheSharedSlot_andNeitherKeepsALocalCopy() throws {
        // The wiring half of R18 and R5, which no runtime assertion can
        // reach: the popover and the Home tab must hand the row the *same*
        // `AppState` values — the retry slot, the retry gate, and the pair
        // mirror — rather than each computing its own.
        //
        // Presence first — an absence-only scan would stay green on a
        // surface that dropped the affordance entirely.
        //
        // **The presence half must pin the destination, not the file.**
        // Every parameter the row takes here is defaulted, so deleting a
        // surface's forwarding still compiles; and `HomeView.swift`
        // reaches the row through `HomeRecentList`, ~870 lines from the
        // `appState.` needles. A whole-file `contains` is therefore
        // satisfied by the outer hop while the actual construction
        // forwards nothing — measured, not reasoned about: deleting
        // HomeRecentList's forwarding arguments left an earlier version of
        // this test green with the Home tab's retry and busy states
        // entirely gone. So assert on each `HistoryRowView(...)`
        // argument list itself. See
        // `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`.
        let popover = try Self.source("NoType/UI/HistoryPopover.swift")
        let home    = try Self.source("NoType/UI/HomeView.swift")
        let row     = try Self.source("NoType/UI/HistoryRowView.swift")

        for (name, src) in [("HistoryPopover.swift", popover), ("HomeView.swift", home)] {
            let constructions = Self.rowConstructions(in: src)
            XCTAssertFalse(
                constructions.isEmpty,
                "\(name) must construct HistoryRowView — this guard is meaningless otherwise"
            )
            for call in constructions {
                for label in ["retryingEntryID:", "canRetry:", "onRetry:", "replacements:"] {
                    XCTAssertTrue(
                        call.contains(label),
                        "\(name) builds a HistoryRowView without `\(label)`. Every one of "
                        + "these is defaulted, so this compiles and silently drops R18 / R5 "
                        + "in this surface: \(call)"
                    )
                }
            }
            // …and the values reaching that call must originate in the
            // one shared mirror rather than a per-surface derivation.
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
            XCTAssertTrue(
                src.contains("appState.dictionaryReplacements"),
                "\(name) must pass the observable pair mirror. A frozen or re-fetched list "
                + "means editing a pair stops re-rendering stored rows (R5 / AE7)"
            )
            // Absence: neither surface may own retry state of its own.
            // The needle set covers the names a local busy flag would
            // plausibly take — keying on "retry" alone let `isBusy` /
            // `inFlight` / `pendingID` through.
            for line in src.split(separator: "\n") where line.contains("@State") {
                let lowered = line.lowercased()
                for needle in ["retry", "busy", "inflight", "in_flight", "pending"] {
                    XCTAssertFalse(
                        lowered.contains(needle),
                        "\(name) declares local retry state (`\(needle)`) — "
                        + "R18 requires one shared value: \(line)"
                    )
                }
            }
        }

        // And the row consumes both as parameters; it never owns them.
        XCTAssertTrue(
            row.contains("var retryingEntryID: UUID?"),
            "HistoryRowView must take the shared slot as a parameter"
        )
        XCTAssertTrue(
            row.contains("var replacements: [DictionaryReplacement]"),
            "HistoryRowView must take the pair list as a parameter, not read a store"
        )
        for line in row.split(separator: "\n") where line.contains("@State") {
            for needle in ["retryingEntryID", "replacements"] {
                XCTAssertFalse(
                    line.contains(needle),
                    "HistoryRowView must not own `\(needle)`: \(line)"
                )
            }
        }
    }

    func test_theRowConstructionScanner_separatesCalls_andExposesADroppedArgument() {
        // The guard above is worth exactly as much as this extraction, so
        // pin the extraction on fixtures instead of trusting it against
        // the real files — where it is green either way. Three things
        // have to hold: a multi-line call with nested parentheses comes
        // back whole, two adjacent calls do not merge into one blob that
        // one wired call could satisfy for both, and a call missing an
        // argument reads as missing.
        let wired = """
        HistoryRowView(
            entry: entry,
            retryingEntryID: retryingEntryID,
            canRetry: canRetry(entry.id),
            replacements: replacements,
            onRetry: { onRetry(entry.id) },
            onDelete: { onDelete(entry.id) }
        )
        """
        let bare = "HistoryRowView(entry: entry, onDelete: { onDelete(entry.id) })"

        let found = Self.rowConstructions(in: wired + "\n" + bare)
        XCTAssertEqual(found.count, 2, "two constructions, not one merged blob")
        XCTAssertTrue(found[0].contains("canRetry(entry.id)"), "nested parens survive")
        XCTAssertTrue(found[0].contains("onRetry:"))
        XCTAssertFalse(
            found[1].contains("retryingEntryID:"),
            "the dropped-argument case — the one the real guard must catch — is visible"
        )
        XCTAssertFalse(found[1].contains("replacements:"))
        XCTAssertTrue(Self.rowConstructions(in: "HistoryRowView.separatorLeading").isEmpty)
    }

    // MARK: - A retry that recovers nothing (R19)

    func test_retryThatRecoversNothing_leavesTheErrorHUDUp_andTheRowBackInItsRetryableState() async {
        // R19, from the row's side. The row *does* return to exactly how
        // it looked before the tap — broken, retryable, same markers —
        // which is precisely why the failure has to be surfaced
        // somewhere else, or the tap reads as having done nothing at all.
        let fx = Fixture(self)
        let entry = fx.appendBrokenRow(text: "", failedChunkCount: 2, chunkCount: 2)

        let before = HistoryRowView.actions(
            entry: entry,
            canRetry: fx.state.canRetry(entryID: entry.id),
            isRetrying: false
        )
        XCTAssertEqual(before, [.retry, .delete])
        XCTAssertFalse(fx.hud.errorHUDVisible, "nothing surfaced yet")

        fx.state.retryChunkSender = { _, _, _, _ in
            throw GeminiClient.GeminiError.http(status: 0, body: "offline")
        }
        await fx.state.retryEntry(id: entry.id)

        let settled = fx.row(entry.id)
        XCTAssertEqual(
            settled.map { HistoryText.rendered($0, replacements: []) },
            "\(marker) \(marker)",
            "the row renders exactly what it rendered before the tap"
        )
        XCTAssertEqual(
            settled.map {
                HistoryRowView.actions(
                    entry: $0,
                    canRetry: fx.state.canRetry(entryID: entry.id),
                    isRetrying: fx.state.retryingEntryID == entry.id
                )
            },
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

    /// A row built from a real response sequence. `text` is the legacy
    /// mirror (KTD10) and defaults to something deliberately *wrong* for
    /// the segments, so any reader that slips back to it is visible.
    private func row(
        _ segments: [HistoryEntry.Segment],
        text: String = "LEGACY MIRROR — NOT WHAT THIS ROW SAYS"
    ) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: "Slack",
            sourceBundleID: Fixture.bundleID,
            timestamp: Date(),
            durationSeconds: 12,
            segments: segments
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

    /// Every `HistoryRowView(...)` construction in `source`, returned as
    /// the text of its argument list.
    ///
    /// Balanced-paren scan rather than a line or regex match, because the
    /// call spans several lines and its arguments contain parentheses of
    /// their own (`canRetry(entry.id)`, `onDelete(entry.id)`).
    static func rowConstructions(in source: String) -> [String] {
        var out: [String] = []
        var searchStart = source.startIndex
        while let hit = source.range(
            of: "HistoryRowView(", range: searchStart..<source.endIndex
        ) {
            var depth = 0
            var i = source.index(before: hit.upperBound)   // the "(" itself
            var close: String.Index?
            while i < source.endIndex {
                switch source[i] {
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { close = i }
                default: break
                }
                if close != nil { break }
                i = source.index(after: i)
            }
            guard let close else { break }
            out.append(String(source[hit.upperBound..<close]))
            searchStart = close
        }
        return out
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
    /// fixture is `private` to its own file, and a copy of it here would
    /// couple two units' test surfaces.
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

        /// Appends a row described the pre-sequence way — a flat string
        /// plus a count — because that is still exactly what
        /// `AppState.settleRetry` produces when a retry lands. Its
        /// sequence is derived by R12's rule, which is what keeps the
        /// merged text and the rendered row in step until U7 writes by
        /// index.
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
