import XCTest
@testable import NoType

/// Pins `AppState`'s half of the failed-recording-retry feature: the
/// broken row a failed session leaves behind, and the promise that the
/// in-memory audio holder never outlives the history rows it is keyed by.
///
/// Two things are deliberately NOT tested here.
///
/// **The disk write.** Both the broken-row append and the delete paths are
/// optimistic-mirror-plus-fire-and-forget (the shape `deleteHistoryEntry`
/// has always used), so there is no join point to await without inventing
/// one. The mirror is what the UI renders and what `peek`/`take` are keyed
/// against, so the mirror is what these tests assert. Restart survival
/// (R8) is step 4 of the plan's manual smoke protocol.
///
/// **Terminal-error classification.** That a terminal error leaves
/// `summary.retained == nil` is U2's contract, pinned by
/// `RetainedRecordingTests`. What is pinned here is the other half of AE1:
/// given nothing retained, `AppState` writes no row and holds nothing.
@MainActor
final class AppStateRetentionTests: XCTestCase {

    // MARK: - Eviction mirrors the history cap (AE5, R5)

    func test_appendPastCap_evictsOldestRow_andDropsItsRetainedPayload() {
        // AE5: a broken row holding retained audio, then enough
        // subsequent sessions to push it out of the ten-entry window.
        let store = RetainedAudioStore()
        let state = makeState(retainedAudio: store)

        let broken = entry(text: "", failedChunkCount: 2)
        state.recordHistoryEntry(broken, retaining: payload())
        XCTAssertNotNil(store.peek(broken.id), "the row just appended keeps its payload")

        // Nine more rows fill the window exactly; the tenth evicts.
        for i in 0..<9 {
            state.recordHistoryEntry(entry(text: "ok \(i)"), retaining: nil)
        }
        XCTAssertEqual(state.history.count, AppState.historyMirrorCap)
        XCTAssertNotNil(store.peek(broken.id), "still inside the window at exactly the cap")

        state.recordHistoryEntry(entry(text: "the tenth"), retaining: nil)

        XCTAssertEqual(state.history.count, AppState.historyMirrorCap)
        XCTAssertFalse(
            state.history.contains { $0.id == broken.id },
            "the oldest row is the one the cap drops"
        )
        XCTAssertNil(
            store.peek(broken.id),
            "a payload for a row the user can no longer see is unreachable memory (R5)"
        )
    }

    func test_appendPastCap_keepsPayloadsOfRowsThatSurvivedTheTrim() {
        // The complement: eviction must drop *only* what the trim dropped.
        let store = RetainedAudioStore()
        let state = makeState(retainedAudio: store)

        var brokenIDs: [UUID] = []
        for _ in 0..<11 {
            let row = entry(text: "", failedChunkCount: 1)
            brokenIDs.append(row.id)
            state.recordHistoryEntry(row, retaining: payload())
        }

        XCTAssertNil(store.peek(brokenIDs[0]), "evicted row's payload is gone")
        for id in brokenIDs.dropFirst() {
            XCTAssertNotNil(store.peek(id), "surviving rows keep theirs")
        }
    }

    // MARK: - The broken row (R6, AE1)

    func test_recordBrokenRow_retainedSession_writesBrokenRow_andHoldsItsAudio() {
        // The unit's verification line: after a simulated all-failed
        // session the history holds one broken row and the store holds
        // one payload under that row's id.
        let store = RetainedAudioStore()
        let state = makeState(retainedAudio: store)
        let broken = entry(text: "", failedChunkCount: 3)

        let written = state.recordBrokenRow(retained: payload(), entry: broken)

        XCTAssertEqual(written?.id, broken.id)
        XCTAssertEqual(state.history.count, 1)
        XCTAssertTrue(state.history[0].isBroken, "failedChunkCount > 0 is what makes it broken")
        XCTAssertTrue(
            state.history[0].text.isEmpty,
            "an all-failed session recovered no text — the empty string is also how "
            + "'lifetime stats never counted this session' is represented (R15/KTD7)"
        )
        XCTAssertNotNil(store.peek(broken.id))
    }

    func test_recordBrokenRow_terminalFailure_writesNoRow_andStoresNothing() {
        // AE1. An expired key aborts the session terminally, which clears
        // the session's retained payload (U2). With nothing retained the
        // catch arm must behave exactly as it does today: the dictation is
        // gone, no row is written, nothing is held.
        let store = RetainedAudioStore()
        let state = makeState(retainedAudio: store)
        let wouldBeRow = entry(text: "", failedChunkCount: 4)

        let written = state.recordBrokenRow(retained: nil, entry: wouldBeRow)

        XCTAssertNil(written)
        XCTAssertTrue(state.history.isEmpty)
        XCTAssertNil(store.peek(wouldBeRow.id))
    }

    func test_recordHistoryEntry_withoutPayload_holdsNothing() {
        // The ordinary successful session: a row, no audio.
        let store = RetainedAudioStore()
        let state = makeState(retainedAudio: store)
        let row = entry(text: "hello there")

        state.recordHistoryEntry(row, retaining: nil)

        XCTAssertEqual(state.history.map(\.id), [row.id])
        XCTAssertFalse(state.history[0].isBroken)
        XCTAssertNil(store.peek(row.id))
    }

    // MARK: - Delete paths release (R5)

    func test_deleteHistoryEntry_dropsThatRowsRetainedPayload_andLeavesTheRest() {
        let store = RetainedAudioStore()
        let state = makeState(retainedAudio: store)
        let doomed = entry(text: "", failedChunkCount: 1)
        let survivor = entry(text: "", failedChunkCount: 1)
        state.recordHistoryEntry(doomed, retaining: payload())
        state.recordHistoryEntry(survivor, retaining: payload())

        state.deleteHistoryEntry(id: doomed.id)

        XCTAssertNil(store.peek(doomed.id))
        XCTAssertNotNil(store.peek(survivor.id), "a targeted delete releases one payload, not all")
        XCTAssertEqual(state.history.map(\.id), [survivor.id])
    }

    func test_deleteAllHistory_emptiesTheRetainedAudioStore() {
        let store = RetainedAudioStore()
        let state = makeState(retainedAudio: store)
        let a = entry(text: "", failedChunkCount: 1)
        let b = entry(text: "", failedChunkCount: 2)
        state.recordHistoryEntry(a, retaining: payload())
        state.recordHistoryEntry(b, retaining: payload())

        state.deleteAllHistory()

        XCTAssertTrue(state.history.isEmpty)
        XCTAssertNil(store.peek(a.id))
        XCTAssertNil(store.peek(b.id))
    }

    func test_refreshHistory_dropsPayloadsForRowsNotOnDisk() async {
        // Reloading the mirror from disk is a mutation like any other: a
        // payload keyed by a row the reload dropped is unreachable memory.
        let store = RetainedAudioStore()
        let historyStore = HistoryStore(url: throwawayURL(named: "history.json"))
        let state = makeState(retainedAudio: store, historyStore: historyStore)

        let onDisk = entry(text: "", failedChunkCount: 1)
        await historyStore.append(onDisk)
        let ghost = entry(text: "", failedChunkCount: 1)
        state.recordHistoryEntry(ghost, retaining: payload())
        state.recordHistoryEntry(onDisk, retaining: payload())

        await state.refreshHistory()

        XCTAssertEqual(state.history.map(\.id), [onDisk.id])
        XCTAssertNotNil(store.peek(onDisk.id))
        XCTAssertNil(store.peek(ghost.id))
    }

    // MARK: - Retry availability (R13, R14, AE6)

    func test_canRetry_idleWithPayload_isAllowed() {
        XCTAssertTrue(
            AppState.canRetry(recordingState: .idle, hasRetainedPayload: true, isRetrying: false)
        )
    }

    func test_canRetry_isRefusedWhileASessionIsActive() {
        // AE6 / R14. A retry alongside a live session would put a second
        // Gemini request beside the session's own.
        XCTAssertFalse(
            AppState.canRetry(
                recordingState: .recording(startedAt: Date()),
                hasRetainedPayload: true,
                isRetrying: false
            ),
            "refused while recording"
        )
        XCTAssertFalse(
            AppState.canRetry(recordingState: .sending, hasRetainedPayload: true, isRetrying: false),
            "refused while the session's own transcription is in flight"
        )
    }

    func test_canRetry_isRefusedForABrokenRowWithNoPayload() {
        // A dead row (R8): the process restarted, the audio is gone, the
        // row stays and keeps copy + delete but loses retry (R10).
        XCTAssertFalse(
            AppState.canRetry(recordingState: .idle, hasRetainedPayload: false, isRetrying: false)
        )
    }

    func test_canRetry_isRefusedWhileThatRowIsAlreadyRetrying() {
        // R13: no second run against audio already in flight.
        XCTAssertFalse(
            AppState.canRetry(recordingState: .idle, hasRetainedPayload: true, isRetrying: true)
        )
    }

    func test_canRetryForEntry_readsTheHolderAndTheRecordingState() {
        let store = RetainedAudioStore()
        let state = makeState(retainedAudio: store)
        let broken = entry(text: "", failedChunkCount: 1)
        let dead = entry(text: "recovered earlier", failedChunkCount: 1)
        state.recordHistoryEntry(broken, retaining: payload())
        state.recordHistoryEntry(dead, retaining: nil)

        XCTAssertTrue(state.canRetry(entryID: broken.id))
        XCTAssertFalse(state.canRetry(entryID: dead.id), "no payload — dead row")
        XCTAssertFalse(state.canRetry(entryID: UUID()), "unknown id")

        state.recordingState = .sending
        XCTAssertFalse(state.canRetry(entryID: broken.id), "R14 gates the live-payload row too")
    }

    func test_historyMirrorCap_matchesTheStoresCap() {
        // The mirror trims optimistically on the main actor and the store
        // trims during its own disk write. If they disagree, the id set
        // `retain(only:)` is called with disagrees with what was persisted.
        XCTAssertEqual(AppState.historyMirrorCap, 10)
    }

    // MARK: - Fixtures

    private func makeState(
        retainedAudio: RetainedAudioStore,
        historyStore: HistoryStore? = nil
    ) -> AppState {
        let perms = PermissionsViewModel()
        let gemini = GeminiClient()
        let instructions = InstructionsStore()
        return AppState(
            permissions: perms,
            hud: HUDController(permissions: perms),
            gemini: gemini,
            // Default to a store under a throwaway directory: these tests
            // exercise delete-all, and the production default URL is the
            // developer's own `history.json`.
            historyStore: historyStore ?? HistoryStore(url: throwawayHistoryURL()),
            statsStore: StatsStore(url: throwawayURL(named: "stats.json")),
            instructionsStore: instructions,
            appCategorizer: AppCategorizer(client: gemini, store: instructions),
            dictionaryStore: DictionaryStore(url: throwawayURL(named: "dictionary.json")),
            onboarding: OnboardingState(),
            retainedAudio: retainedAudio
        )
    }

    private func throwawayHistoryURL() -> URL { throwawayURL(named: "history.json") }

    /// A fresh directory per store, torn down with the test. The
    /// production `init(url: nil)` default resolves to the developer's own
    /// Application Support folder, and these tests call `deleteAllHistory`.
    private func throwawayURL(named name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name)
    }

    private func entry(text: String, failedChunkCount: Int = 0) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(),
            durationSeconds: 12,
            failedChunkCount: failedChunkCount
        )
    }

    private func payload(chunkCount: Int = 1) -> RetainedRecording {
        RetainedRecording(
            chunks: (0..<chunkCount).map {
                RetainedRecording.Chunk(
                    idx: $0,
                    isFinal: $0 == chunkCount - 1,
                    audio: Data([UInt8(0xA0 + $0)]),
                    samples: 16_000
                )
            },
            context: ContextSnapshot.minimal(
                activeApp: AppInfo(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
            ),
            model: .flashLite
        )
    }
}
