import XCTest
@testable import NoType

/// Storage contract for `InstructionsStore`: round-trip, manual-vs-auto
/// precedence, override clearing, corruption recovery. Mirrors the
/// `HistoryStoreTests` pattern (temp directory per test, no shared state).
final class InstructionsStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstructionsStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("instructions.json")
    }

    override func tearDown() {
        if let parent = tempURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }
        super.tearDown()
    }

    private func makeStore() -> InstructionsStore {
        InstructionsStore(url: tempURL)
    }

    // MARK: - Empty state

    func test_snapshot_onMissingFile_returnsEmpty() async {
        let store = makeStore()
        let snap = await store.snapshot()
        XCTAssertEqual(snap, .empty)
    }

    // MARK: - User instruction round-trip

    func test_updateUserInstruction_persistsAndTrims() async {
        let store = makeStore()
        await store.updateUserInstruction("   never use colons   \n")
        let after = await store.snapshot()
        XCTAssertEqual(after.userInstruction, "never use colons")

        // Round-trip through a fresh actor instance to confirm disk write.
        let store2 = InstructionsStore(url: tempURL)
        let onReopen = await store2.snapshot()
        XCTAssertEqual(onReopen.userInstruction, "never use colons")
    }

    func test_updateUserInstruction_emptyAfterTrim_storedAsEmpty() async {
        let store = makeStore()
        await store.updateUserInstruction("   \n  ")
        let snap = await store.snapshot()
        XCTAssertEqual(snap.userInstruction, "", "whitespace-only must collapse to empty so the prompt section is omitted")
    }

    // MARK: - Category prompt overrides

    func test_setCategoryPromptOverride_storesAndRetrieves() async {
        let store = makeStore()
        await store.setCategoryPromptOverride(.email, prompt: "always sign off with 'Best,'")
        let snap = await store.snapshot()
        XCTAssertEqual(snap.categoryPromptOverrides[.email], "always sign off with 'Best,'")
    }

    func test_setCategoryPromptOverride_nilClearsOverride() async {
        let store = makeStore()
        await store.setCategoryPromptOverride(.email, prompt: "x")
        await store.setCategoryPromptOverride(.email, prompt: nil)
        let snap = await store.snapshot()
        XCTAssertNil(snap.categoryPromptOverrides[.email], "passing nil must remove the override")
    }

    func test_setCategoryPromptOverride_emptyStringClearsOverride() async {
        let store = makeStore()
        await store.setCategoryPromptOverride(.email, prompt: "x")
        await store.setCategoryPromptOverride(.email, prompt: "   \n  ")
        let snap = await store.snapshot()
        XCTAssertNil(snap.categoryPromptOverrides[.email], "whitespace-only must clear the override")
    }

    // MARK: - Assignments — auto vs manual

    func test_upsertAutoAssignment_writesNewRecord() async {
        let store = makeStore()
        // ISO8601 encoding drops fractional seconds, so use a Date whose
        // value is already whole-second precision so the round-trip
        // through disk is an identity.
        let stableDate = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AppCategoryAssignment(
            bundleID: "com.apple.mail",
            category: .email,
            confidence: .high,
            classifiedAt: stableDate,
            source: .auto
        )
        let written = await store.upsertAutoAssignment(record)
        XCTAssertEqual(written, record)
        let snap = await store.snapshot()
        XCTAssertEqual(snap.categoryAssignments["com.apple.mail"], record)
    }

    func test_upsertAutoAssignment_replacesExistingAuto() async {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        let a1 = AppCategoryAssignment(
            bundleID: "com.example.app",
            category: .messaging,
            confidence: .medium,
            classifiedAt: t0,
            source: .auto
        )
        await store.upsertAutoAssignment(a1)

        let a2 = AppCategoryAssignment(
            bundleID: "com.example.app",
            category: .docs,
            confidence: .high,
            classifiedAt: t0.addingTimeInterval(3600),
            source: .auto
        )
        let stored = await store.upsertAutoAssignment(a2)
        XCTAssertEqual(stored, a2, "auto-over-auto must replace")
    }

    func test_upsertAutoAssignment_doesNotOverrideManual() async {
        let store = makeStore()
        let stableDate = Date(timeIntervalSince1970: 1_700_000_000)
        let manual = await store.setManualAssignment(
            bundleID: "com.example.app",
            category: .docs,
            now: stableDate
        )

        let auto = AppCategoryAssignment(
            bundleID: "com.example.app",
            category: .messaging,
            confidence: .high,
            classifiedAt: stableDate,
            source: .auto
        )
        let returned = await store.upsertAutoAssignment(auto)
        XCTAssertEqual(returned, manual,
                       "auto-over-manual must be refused; existing record returned")

        let snap = await store.snapshot()
        XCTAssertEqual(snap.categoryAssignments["com.example.app"]?.source, .manual)
        XCTAssertEqual(snap.categoryAssignments["com.example.app"]?.category, .docs)
    }

    func test_setManualAssignment_alwaysWins() async {
        let store = makeStore()
        await store.upsertAutoAssignment(AppCategoryAssignment(
            bundleID: "com.example.app",
            category: .messaging,
            confidence: .medium,
            classifiedAt: Date(),
            source: .auto
        ))
        await store.setManualAssignment(bundleID: "com.example.app", category: .code)
        let snap = await store.snapshot()
        XCTAssertEqual(snap.categoryAssignments["com.example.app"]?.category, .code)
        XCTAssertEqual(snap.categoryAssignments["com.example.app"]?.source, .manual)
    }

    func test_removeAssignment_isIdempotent() async {
        let store = makeStore()
        await store.setManualAssignment(bundleID: "com.example.app", category: .code)
        await store.removeAssignment(bundleID: "com.example.app")
        await store.removeAssignment(bundleID: "com.example.app")
        let snap = await store.snapshot()
        XCTAssertNil(snap.categoryAssignments["com.example.app"])
    }

    // MARK: - Disk persistence

    func test_diskWrite_isAtomic_andSurvivesReopen() async {
        let store = makeStore()
        await store.updateUserInstruction("hello")
        await store.setCategoryPromptOverride(.notes, prompt: "use bullet lists")
        let record = AppCategoryAssignment(
            bundleID: "com.acme.notes",
            category: .notes,
            confidence: .high,
            classifiedAt: Date(timeIntervalSince1970: 1700000000),
            source: .auto
        )
        await store.upsertAutoAssignment(record)

        let store2 = InstructionsStore(url: tempURL)
        let snap = await store2.snapshot()
        XCTAssertEqual(snap.userInstruction, "hello")
        XCTAssertEqual(snap.categoryPromptOverrides[.notes], "use bullet lists")
        XCTAssertEqual(snap.categoryAssignments["com.acme.notes"], record)
    }

    // MARK: - Corruption recovery

    func test_corruptFile_isRenamed_andSnapshotIsEmpty() async throws {
        try "not valid json {{{".write(to: tempURL, atomically: true, encoding: .utf8)
        let store = makeStore()
        let snap = await store.snapshot()
        XCTAssertEqual(snap, .empty)

        // Original file should have been renamed to ".corrupt-…".
        let dir = tempURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(names.contains { $0.hasPrefix("instructions.json.corrupt-") },
                      "expected corrupt-backup file in \(names)")
    }
}
