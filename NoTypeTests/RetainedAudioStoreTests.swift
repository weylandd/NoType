import XCTest
@testable import NoType

/// Pins `RetainedAudioStore` — the memory-only holder that keeps a
/// failed session's audio alive against the history row that offers to
/// re-send it.
///
/// Two contracts are under test. **R1**: the holder is memory-only, so
/// the only lifetime that matters is the process's — nothing here
/// round-trips through a file, and these tests deliberately touch no
/// temp directory (unlike `HistoryStoreTests` / `StatsStoreTests`,
/// whose per-test temp dir exists because those stores write). **R5**:
/// a payload is released on exactly four triggers, and each has its own
/// method — `take` without a re-put (retry succeeded), `remove` (user
/// deleted the row), `retain(only:)` (the ten-entry cap evicted it),
/// and process exit.
///
/// `retain(only:)` carries the weight: it is the single eviction point,
/// so the holder mirrors `HistoryStore`'s cap instead of re-deriving
/// it. The eviction cases below are what stop that mirror from drifting
/// silently.
@MainActor
final class RetainedAudioStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// A payload whose audio byte is `tag`, so a mis-keyed lookup shows
    /// up as the wrong payload rather than as a plausible one.
    private func payload(_ tag: UInt8) -> RetainedRecording {
        RetainedRecording(
            chunks: [
                RetainedRecording.Chunk(
                    idx: 0,
                    isFinal: true,
                    audio: Data([tag]),
                    samples: 16_000
                )
            ],
            context: ContextSnapshot.minimal(
                activeApp: AppInfo(name: "Slack",
                                   bundleID: "com.tinyspeck.slackmacgap")
            ),
            model: .flashLite
        )
    }

    /// The `tag` byte a payload was built with — the identity handle
    /// these tests assert on. `RetainedRecording` is deliberately not
    /// `Equatable` (it holds a `ContextSnapshot`), so identity is read
    /// off the audio blob.
    private func tag(_ recording: RetainedRecording?) -> UInt8? {
        recording?.chunks.first?.audio.first
    }

    // MARK: - put / peek / take

    func test_putThenPeek_returnsThePayload_withoutConsumingIt() {
        let store = RetainedAudioStore()
        let id = UUID()

        store.put(payload(0xA1), for: id)

        // `peek` is the presence read behind "can this row offer
        // retry" (R10) and behind the broken-vs-dead distinction (R8),
        // so it must be safe to call on every render. Peeking twice is
        // what separates it from `take`.
        XCTAssertEqual(tag(store.peek(id)), 0xA1)
        XCTAssertEqual(tag(store.peek(id)), 0xA1,
                       "peek must not consume — U7 renders the row repeatedly")
    }

    func test_putThenTake_returnsThePayload_andLeavesTheIdEmpty() {
        let store = RetainedAudioStore()
        let id = UUID()

        store.put(payload(0xB2), for: id)

        XCTAssertEqual(tag(store.take(id)), 0xB2)
        // R5's retry-succeeded release: U6 takes the payload to run
        // the retry and simply does not re-put it when every chunk
        // recovered. Taking must therefore be what actually frees it.
        XCTAssertNil(store.peek(id),
                     "take must consume — a second retry cannot re-send audio in flight")
        XCTAssertNil(store.take(id), "taking twice yields nothing the second time")
    }

    func test_peekAndTake_forAnAbsentID_returnNil() {
        let store = RetainedAudioStore()

        XCTAssertNil(store.peek(UUID()))
        XCTAssertNil(store.take(UUID()))
    }

    func test_putTwiceForTheSameID_replacesRatherThanAccumulates() {
        let store = RetainedAudioStore()
        let id = UUID()

        store.put(payload(0xC3), for: id)
        store.put(payload(0xD4), for: id)

        // R16's partial retry re-puts a payload holding only the
        // chunks that did not recover. If a second `put` merged or
        // appended instead of replacing, the recovered chunks would be
        // re-sent (and re-billed) on the next retry.
        XCTAssertEqual(tag(store.peek(id)), 0xD4)
        XCTAssertEqual(store.peek(id)?.chunks.count, 1,
                       "the second put replaces the first, it does not accumulate chunks")
    }

    // MARK: - remove (R5: the user deleted the row)

    func test_removeForAnAbsentID_isANoOp() {
        let store = RetainedAudioStore()
        let held = UUID()
        store.put(payload(0xE5), for: held)

        store.remove(UUID())

        // Mirrors `HistoryStore.remove(id:)`'s idempotent contract:
        // U5's `deleteHistoryEntry` fires for every row the user
        // trashes, and most rows never had a payload.
        XCTAssertEqual(tag(store.peek(held)), 0xE5,
                       "removing an unknown id must not disturb what is held")
    }

    func test_removeForAHeldID_dropsOnlyThatPayload() {
        let store = RetainedAudioStore()
        let deleted = UUID()
        let kept = UUID()
        store.put(payload(0x11), for: deleted)
        store.put(payload(0x22), for: kept)

        store.remove(deleted)

        XCTAssertNil(store.peek(deleted))
        XCTAssertEqual(tag(store.peek(kept)), 0x22)
    }

    func test_removeIsIdempotent() {
        let store = RetainedAudioStore()
        let id = UUID()
        store.put(payload(0x33), for: id)

        store.remove(id)
        store.remove(id)

        XCTAssertNil(store.peek(id))
    }

    // MARK: - retain(only:) — the single eviction point (R5)

    func test_retainOnly_dropsExcludedIDs_andKeepsTheRest() {
        let store = RetainedAudioStore()
        let evicted = UUID()
        let survivorA = UUID()
        let survivorB = UUID()
        store.put(payload(0x41), for: evicted)
        store.put(payload(0x42), for: survivorA)
        store.put(payload(0x43), for: survivorB)

        store.retain(only: [survivorA, survivorB])

        XCTAssertNil(store.peek(evicted),
                     "a row that left the history window releases its audio")
        XCTAssertEqual(tag(store.peek(survivorA)), 0x42)
        XCTAssertEqual(tag(store.peek(survivorB)), 0x43)
    }

    func test_retainOnly_withAnEmptySet_emptiesTheStore() {
        let store = RetainedAudioStore()
        let ids = (0..<3).map { _ in UUID() }
        for (offset, id) in ids.enumerated() {
            store.put(payload(UInt8(0x50 + offset)), for: id)
        }

        // The delete-all-history case: every row is gone, so every
        // payload goes with it.
        store.retain(only: [])

        for id in ids {
            XCTAssertNil(store.peek(id))
        }
    }

    func test_retainOnly_toleratesLiveIDsThatWereNeverHeld() {
        let store = RetainedAudioStore()
        let broken = UUID()
        store.put(payload(0x61), for: broken)

        // Most history rows are ordinary rows with no retained audio,
        // so the live-id set is routinely a superset of the keys held.
        store.retain(only: [broken, UUID(), UUID()])

        XCTAssertEqual(tag(store.peek(broken)), 0x61)
    }

    /// The unit's verification line: after `retain(only:)` with the ids
    /// of a ten-row history, the store holds no id outside that set.
    ///
    /// Shaped as the real eviction event — a broken row falls out of
    /// the ten-entry window when an eleventh session is appended, and
    /// `AppState` calls `retain(only:)` with whatever `HistoryStore`
    /// returned after the trim. The holder never counts to ten itself;
    /// that is the point of mirroring rather than re-deriving the cap.
    func test_retainOnly_afterTheCapTrims_holdsNoIDOutsideTheWindow() {
        let store = RetainedAudioStore()

        // Eleven sessions, every one of them broken and retained.
        let allIDs = (0..<11).map { _ in UUID() }
        for (offset, id) in allIDs.enumerated() {
            store.put(payload(UInt8(0x70 + offset)), for: id)
        }

        // `HistoryStore` caps at 10 and drops the oldest, so the
        // surviving window is the last ten.
        let window = Set(allIDs.suffix(10))
        store.retain(only: window)

        let evicted = allIDs[0]
        XCTAssertNil(store.peek(evicted),
                     "the row the cap dropped must not keep its audio alive")
        for id in window {
            XCTAssertNotNil(store.peek(id),
                            "a row still inside the window keeps its payload")
        }
    }

    // MARK: - Memory-only contract (R1)

    /// Runtime conformance probe, written generically for the same
    /// reason as its sibling in `RetainedRecordingTests`: a direct
    /// `RetainedAudioStore.self is any Encodable.Type` lets the
    /// compiler resolve the cast statically and warn that it always
    /// fails, which the plan's warning-free bar forbids.
    private func conformsToCoding<T>(_ type: T.Type) -> Bool {
        type is any Encodable.Type || type is any Decodable.Type
    }

    func test_store_isNotSerializable() {
        // R1: the holder's contents never reach disk — not beside
        // `history.json`, not in a crash-recovery cache. The payload
        // type is guarded in `RetainedRecordingTests`; this is the
        // container half, so a `Codable` conformance added here to
        // "persist broken rows properly" fails a test instead of
        // quietly falsifying the README's no-audio-retention claim.
        XCTAssertFalse(conformsToCoding(RetainedAudioStore.self),
                       "RetainedAudioStore must never be serializable (R1)")
    }
}
