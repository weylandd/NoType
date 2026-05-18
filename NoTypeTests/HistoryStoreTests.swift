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
