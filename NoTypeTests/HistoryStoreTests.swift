import XCTest
@testable import NoType

/// Last-10 transcript ring. Per-test temp file — no shared state.
/// Coverage shipped by U7 (plan `2026-05-18-001-feat-settings-screen-plan.md`
/// §584-646) — earlier units relied on `StatsStoreTests` only.
final class HistoryStoreTests: XCTestCase {

    private var tempURL: URL!
    private var statsURL: URL!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("history.json")
        statsURL = dir.appendingPathComponent("stats.json")
    }

    override func tearDown() {
        if let parent = tempURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }
        super.tearDown()
    }

    private func entry(text: String, when: Date = Date()) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: when,
            durationSeconds: 1.0
        )
    }

    /// A `history.json` exactly as a build *before* `failedChunkCount`
    /// shipped would have written it: `JSONFileStorage.makeEncoder()`
    /// output — iso8601 dates, sorted keys, pretty-printed — with no
    /// `failedChunkCount` key anywhere.
    ///
    /// Kept as a literal rather than a file under `Fixtures/` so the
    /// bytes and the assertion that reads them sit together, and so a
    /// future `xcodegen generate` can't quietly change what the
    /// backward-compatibility proof runs against.
    private static let legacyHistoryJSON = """
    [
      {
        "durationSeconds" : 4.25,
        "id" : "1B9A1F3E-6C4D-4F0A-9B2E-7A5C81D3E0F1",
        "sourceAppName" : "Slack",
        "sourceBundleID" : "com.tinyspeck.slackmacgap",
        "text" : "ship it by friday",
        "timestamp" : "2026-05-18T09:41:12Z"
      },
      {
        "durationSeconds" : 0,
        "id" : "2C0B2A4F-7D5E-4A1B-8C3F-6B4D92E4F1A2",
        "sourceAppName" : "Mail",
        "sourceBundleID" : "com.apple.mail",
        "text" : "thanks, sending the draft over now",
        "timestamp" : "2026-05-18T10:02:44Z"
      }
    ]
    """

    // MARK: - failedChunkCount / isBroken (U4)

    /// The unit's Definition of Done: a pre-change `history.json`
    /// decodes unchanged. Every legacy row reads back with the field
    /// defaulted to 0 and `isBroken` false — a row written before the
    /// feature existed can never claim to be broken.
    func test_decode_legacyRowsWithoutFailedChunkCount_defaultToZeroAndNotBroken() async throws {
        try Self.legacyHistoryJSON.write(to: tempURL, atomically: true, encoding: .utf8)

        let store = HistoryStore(url: tempURL)
        let entries = await store.allEntries()

        XCTAssertEqual(entries.count, 2, "legacy file must still decode — no rows lost")
        XCTAssertEqual(entries.map(\.text),
            ["ship it by friday", "thanks, sending the draft over now"],
            "text must survive the schema widening byte-for-byte")
        XCTAssertEqual(entries.map(\.failedChunkCount), [0, 0],
            "absent key decodes as 0, same tolerant shape as durationSeconds")
        XCTAssertEqual(entries.map(\.isBroken), [false, false],
            "a pre-feature row is never broken")
        XCTAssertEqual(entries.map(\.durationSeconds), [4.25, 0],
            "the existing tolerant field is unaffected")
    }

    func test_append_brokenRowRoundTripsAcrossInstances() async {
        let broken = HistoryEntry(
            id: UUID(),
            text: "ship it by […] and review after",
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(),
            durationSeconds: 12.0,
            failedChunkCount: 3
        )
        let a = HistoryStore(url: tempURL)
        await a.append(broken)

        let b = HistoryStore(url: tempURL)
        let reloaded = await b.allEntries()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.failedChunkCount, 3,
            "the count is persisted, not derived at read time")
        XCTAssertEqual(reloaded.first?.isBroken, true)
    }

    /// R8's other half: brokenness is the count, not the text. A row
    /// carrying text is broken or not purely on the count, and a count
    /// of zero is not broken no matter what the text holds.
    func test_isBroken_readsOnlyTheCount() {
        let clean = entry(text: "a perfectly ordinary transcript")
        XCTAssertEqual(clean.failedChunkCount, 0,
            "the memberwise default keeps every existing call site honest")
        XCTAssertFalse(clean.isBroken)

        let emptyButBroken = HistoryEntry(
            id: UUID(),
            text: "",
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(),
            durationSeconds: 30.0,
            failedChunkCount: 1
        )
        XCTAssertTrue(emptyButBroken.isBroken,
            "a session that recovered no text at all is still a broken row")
    }

    // MARK: - Corruption recovery

    /// Garbage JSON is renamed aside and the store starts fresh —
    /// the behaviour `NoType/History/CLAUDE.md` documents, pinned here
    /// against the widened schema so a future field can't turn a
    /// decode failure into a crash or a silent data loss without a
    /// backup.
    func test_allEntries_corruptFileIsBackedUpAndReadsEmpty() async throws {
        try "{ not even an array".write(to: tempURL, atomically: true, encoding: .utf8)

        let store = HistoryStore(url: tempURL)
        let entries = await store.allEntries()
        XCTAssertTrue(entries.isEmpty, "corrupt file reads as an empty history")

        let dir = tempURL.deletingLastPathComponent()
        let siblings = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("history.json.corrupt-") }
        XCTAssertEqual(siblings.count, 1,
            "the unreadable file is preserved as history.json.corrupt-<ts>, not deleted")
    }

    // MARK: - Round-trip

    func test_append_roundTripsAcrossInstances() async {
        let a = HistoryStore(url: tempURL)
        await a.append(entry(text: "hello"))
        let b = HistoryStore(url: tempURL)
        let entries = await b.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "hello")
    }

    // MARK: - FIFO eviction at the 10-entry boundary

    func test_append_atCapDropsOldest() async {
        let store = HistoryStore(url: tempURL)
        for i in 0..<12 {
            await store.append(entry(text: "msg-\(i)"))
        }
        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 10, "cap is 10")
        XCTAssertEqual(entries.first?.text, "msg-2",
            "FIFO eviction: oldest 2 entries dropped, msg-2 is now the oldest")
        XCTAssertEqual(entries.last?.text, "msg-11")
    }

    // MARK: - remove(id:)

    func test_remove_dropsTargetedRow() async {
        let store = HistoryStore(url: tempURL)
        let e1 = entry(text: "one")
        let e2 = entry(text: "two")
        await store.append(e1)
        await store.append(e2)
        await store.remove(id: e1.id)
        let entries = await store.allEntries()
        XCTAssertEqual(entries.map { $0.text }, ["two"])
    }

    func test_remove_missingIdIsNoop() async {
        let store = HistoryStore(url: tempURL)
        await store.append(entry(text: "kept"))
        await store.remove(id: UUID())
        let entries = await store.allEntries()
        XCTAssertEqual(entries.map { $0.text }, ["kept"])
    }

    // MARK: - deleteAll (U7)

    func test_deleteAll_emptiesHistory() async {
        let store = HistoryStore(url: tempURL)
        await store.append(entry(text: "a"))
        await store.append(entry(text: "b"))
        await store.append(entry(text: "c"))
        await store.deleteAll()
        let entries = await store.allEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func test_deleteAll_persistsAcrossInstances() async {
        let a = HistoryStore(url: tempURL)
        await a.append(entry(text: "to-be-wiped"))
        await a.deleteAll()

        let b = HistoryStore(url: tempURL)
        let entries = await b.allEntries()
        XCTAssertTrue(entries.isEmpty,
            "wipe must be durable — on-disk file must reflect the empty state")
    }

    func test_deleteAll_isIdempotent() async {
        let store = HistoryStore(url: tempURL)
        await store.deleteAll()
        await store.deleteAll()
        let entries = await store.allEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    /// AE7 cross-store contract: deleting transcripts MUST NOT touch
    /// the lifetime stats file. Word counts, session counts, token
    /// totals, and the per-app breakdown survive a wipe per the
    /// no-telemetry carve-out
    /// (`solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`).
    func test_deleteAll_doesNotTouchStatsFile() async throws {
        // Seed a stats file alongside the history file in the same
        // temp dir. We don't go through `StatsStore.record` — a raw
        // file write is enough to prove `HistoryStore.deleteAll`
        // ignores its sibling.
        let sentinel = "{\"version\":4,\"totalWords\":42}"
        try sentinel.write(to: statsURL, atomically: true, encoding: .utf8)

        let store = HistoryStore(url: tempURL)
        await store.append(entry(text: "before wipe"))
        await store.deleteAll()

        let after = try String(contentsOf: statsURL, encoding: .utf8)
        XCTAssertEqual(after, sentinel,
            "stats.json content must survive byte-for-byte; carve-out boundary")
    }
}
