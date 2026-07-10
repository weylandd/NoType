import XCTest
@testable import NoType

/// Pins `DictionaryStore`'s contract — atomic round-trip, FIFO trim
/// over 100 with user-stickiness, case-insensitive dedup, length cap,
/// and corruption recovery.
final class DictionaryStoreTests: XCTestCase {

    private var tempDir: URL!
    private var url: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictionaryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        url = tempDir.appendingPathComponent("dictionary.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Round-trip

    func test_emptyFile_returnsEmptySnapshot() async {
        let store = DictionaryStore(url: url)
        let snap = await store.snapshot()
        XCTAssertTrue(snap.entries.isEmpty)
        XCTAssertTrue(snap.replacements.isEmpty)
    }

    func test_addUserEntry_persistsAndRoundTrips() async {
        let store = DictionaryStore(url: url)
        _ = await store.addUserEntry("NoType")
        _ = await store.addUserEntry("Anthropic")

        let other = DictionaryStore(url: url)
        let snap = await other.snapshot()
        XCTAssertEqual(snap.entries.count, 2)
        XCTAssertEqual(Set(snap.entries.map { $0.word }), ["NoType", "Anthropic"])
        XCTAssertTrue(snap.entries.allSatisfy { $0.source == .user })
    }

    func test_addReplacement_persistsAndRoundTrips() async {
        let store = DictionaryStore(url: url)
        _ = await store.addReplacement(from: "то есть", to: "т.е.")

        let other = DictionaryStore(url: url)
        let snap = await other.snapshot()
        XCTAssertEqual(snap.replacements.count, 1)
        XCTAssertEqual(snap.replacements.first?.from, "то есть")
        XCTAssertEqual(snap.replacements.first?.to, "т.е.")
    }

    // MARK: - Dedup

    func test_addUserEntry_dedupesCaseInsensitive() async {
        let store = DictionaryStore(url: url)
        _ = await store.addUserEntry("NoType")
        let snap = await store.addUserEntry("notype")
        XCTAssertEqual(snap.entries.count, 1,
            "case-insensitive duplicate must not add a second entry")
    }

    func test_addUserEntry_promotesExistingAutoToUser() async {
        let store = DictionaryStore(url: url)
        _ = await store.addAutoEntries(["Anthropic"])
        var snap = await store.snapshot()
        XCTAssertEqual(snap.entries.first?.source, .auto)

        snap = await store.addUserEntry("Anthropic")
        XCTAssertEqual(snap.entries.count, 1)
        XCTAssertEqual(snap.entries.first?.source, .user,
            "case-insensitive duplicate of an .auto entry promotes it to .user (sticky)")
    }

    // MARK: - maxEntryLength cap

    func test_addUserEntry_rejectsOverLengthInput() async {
        let store = DictionaryStore(url: url)
        let overLong = String(repeating: "a", count: DictionarySnapshot.maxEntryLength + 1)
        _ = await store.addUserEntry(overLong)
        let snap = await store.snapshot()
        XCTAssertTrue(snap.entries.isEmpty,
            "entries longer than maxEntryLength must be rejected")
    }

    func test_addAutoEntries_filtersOverLengthWords() async {
        let store = DictionaryStore(url: url)
        _ = await store.addAutoEntries([
            "ok",
            String(repeating: "x", count: DictionarySnapshot.maxEntryLength + 5),
            "fine",
        ])
        let snap = await store.snapshot()
        XCTAssertEqual(Set(snap.entries.map { $0.word }), ["ok", "fine"])
    }

    // MARK: - FIFO trim with user-stickiness

    func test_addAutoEntries_trimsOldestAutoFirst_overCap() async {
        let store = DictionaryStore(url: url)
        // Fill with 100 auto entries.
        let initial = (0..<100).map { "auto\($0)" }
        _ = await store.addAutoEntries(initial)
        var snap = await store.snapshot()
        XCTAssertEqual(snap.entries.count, 100)

        // Add 5 more — oldest 5 auto should be evicted.
        _ = await store.addAutoEntries(["new1", "new2", "new3", "new4", "new5"])
        snap = await store.snapshot()
        XCTAssertEqual(snap.entries.count, 100, "cap honoured")
        let words = Set(snap.entries.map { $0.word })
        XCTAssertTrue(words.contains("new1"))
        XCTAssertTrue(words.contains("new5"))
        XCTAssertFalse(words.contains("auto0"),
            "oldest auto entries must be evicted FIFO")
    }

    func test_addAutoEntries_refreshesExistingEntryTimestamp() async {
        // Existing auto entry → `addAutoEntries` re-encountering it
        // should bump its `addedAt`, not skip it. This is what lets
        // the FIFO trim see frequently-mentioned auto entries as
        // "newer" and evict actually-stale ones first.
        let store = DictionaryStore(url: url)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = await store.addAutoEntries(["Anthropic"], now: t0)
        let snap1 = await store.snapshot()
        let original = try? XCTUnwrap(snap1.entries.first(where: { $0.word == "Anthropic" }))

        // Re-encounter the same word an hour later.
        let t1 = t0.addingTimeInterval(3600)
        _ = await store.addAutoEntries(["Anthropic"], now: t1)
        let snap2 = await store.snapshot()
        let refreshed = try? XCTUnwrap(snap2.entries.first(where: { $0.word == "Anthropic" }))

        XCTAssertEqual(snap2.entries.count, 1, "no new entry — same word refreshed")
        XCTAssertEqual(original?.id, refreshed?.id, "id is stable across refresh")
        XCTAssertTrue((refreshed?.addedAt ?? .distantPast) > (original?.addedAt ?? .distantFuture),
            "addedAt should be bumped on refresh")
    }

    func test_addAutoEntries_refreshKeepsExistingSource() async {
        // Refreshing an existing USER entry must not silently downgrade
        // it to `.auto`. The store updates timestamp only; source stays.
        let store = DictionaryStore(url: url)
        _ = await store.addUserEntry("Anthropic")
        _ = await store.addAutoEntries(["Anthropic"])
        let snap = await store.snapshot()
        XCTAssertEqual(snap.entries.count, 1)
        XCTAssertEqual(snap.entries.first?.source, .user,
            "user entry stays user across auto-harvest refresh")
    }

    func test_userEntries_stickyOnAutoOverflow() async {
        let store = DictionaryStore(url: url)
        _ = await store.addUserEntry("Anthropic")
        _ = await store.addUserEntry("NoType")
        // Now pour in 99 auto entries — total would be 101, one must
        // be dropped, and it must be the oldest auto, NOT a user.
        let autos = (0..<99).map { "x\($0)" }
        _ = await store.addAutoEntries(autos)
        let snap = await store.snapshot()
        XCTAssertEqual(snap.entries.count, 100)
        let userWords = Set(snap.entries.filter { $0.source == .user }.map { $0.word })
        XCTAssertEqual(userWords, ["Anthropic", "NoType"],
            "user entries remain sticky over the trim")
    }

    // MARK: - Remove

    func test_removeEntry_byID() async {
        let store = DictionaryStore(url: url)
        let snap = await store.addUserEntry("NoType")
        let id = try? XCTUnwrap(snap.entries.first?.id)
        _ = await store.removeEntry(id: id ?? UUID())
        let after = await store.snapshot()
        XCTAssertTrue(after.entries.isEmpty)
    }

    func test_removeEntry_missingID_isNoOp() async {
        let store = DictionaryStore(url: url)
        _ = await store.addUserEntry("NoType")
        _ = await store.removeEntry(id: UUID())
        let after = await store.snapshot()
        XCTAssertEqual(after.entries.count, 1)
    }

    func test_removeEntries_bySource_wipesAutoButKeepsUser() async {
        let store = DictionaryStore(url: url)
        _ = await store.addUserEntry("NoType")
        _ = await store.addUserEntry("Aura")
        _ = await store.addAutoEntries(["Anthropic", "GitHub"])

        let after = await store.removeEntries(source: .auto)

        XCTAssertEqual(after.entries.count, 2)
        XCTAssertTrue(after.entries.allSatisfy { $0.source == .user })
        XCTAssertTrue(after.entries.contains { $0.word == "NoType" })
        XCTAssertTrue(after.entries.contains { $0.word == "Aura" })
    }

    func test_removeEntries_bySource_wipesUser() async {
        let store = DictionaryStore(url: url)
        _ = await store.addUserEntry("NoType")
        _ = await store.addAutoEntries(["Anthropic"])

        let after = await store.removeEntries(source: .user)

        XCTAssertEqual(after.entries.count, 1)
        XCTAssertEqual(after.entries.first?.source, .auto)
        XCTAssertEqual(after.entries.first?.word, "Anthropic")
    }

    func test_removeEntries_bySource_noMatches_isNoOp() async {
        let store = DictionaryStore(url: url)
        _ = await store.addUserEntry("NoType")

        // No auto entries to wipe — call must not nuke the user entry.
        let after = await store.removeEntries(source: .auto)
        XCTAssertEqual(after.entries.count, 1)
        XCTAssertEqual(after.entries.first?.word, "NoType")
    }

    // MARK: - Replacements

    func test_addReplacement_dedupesCaseInsensitiveFromKey() async {
        let store = DictionaryStore(url: url)
        _ = await store.addReplacement(from: "то есть", to: "т.е.")
        _ = await store.addReplacement(from: "ТО ЕСТЬ", to: "ТЕ")
        let snap = await store.snapshot()
        XCTAssertEqual(snap.replacements.count, 1,
            "duplicate `from` (case-insensitive) replaces existing pair")
        XCTAssertEqual(snap.replacements.first?.to, "ТЕ")
    }

    func test_addReplacement_rejectsEmptyFromOrTo() async {
        let store = DictionaryStore(url: url)
        _ = await store.addReplacement(from: "", to: "т.е.")
        _ = await store.addReplacement(from: "то есть", to: "")
        _ = await store.addReplacement(from: "   ", to: "т.е.")
        let snap = await store.snapshot()
        XCTAssertTrue(snap.replacements.isEmpty,
            "replacements with empty / whitespace sides must be rejected")
    }

    func test_updateReplacement_byID() async {
        let store = DictionaryStore(url: url)
        var snap = await store.addReplacement(from: "то есть", to: "т.е.")
        let id = try? XCTUnwrap(snap.replacements.first?.id)
        snap = await store.updateReplacement(id: id ?? UUID(), from: "то есть", to: "ТЕ")
        XCTAssertEqual(snap.replacements.first?.to, "ТЕ")
    }

    func test_updateReplacement_rejectsCaseInsensitiveFromCollision() async {
        // Two pairs A(`ml`) and B(`ai`). Editing B.from to `ML` collides
        // (case-insensitively) with A → the edit is REJECTED, leaving the
        // pairs untouched. There must never be two rows whose `from` is
        // case-insensitively equal.
        let store = DictionaryStore(url: url)
        _ = await store.addReplacement(from: "ml", to: "machine learning")
        var snap = await store.addReplacement(from: "ai", to: "artificial intelligence")
        let idB = try? XCTUnwrap(snap.replacements.first(where: { $0.from == "ai" })?.id)

        snap = await store.updateReplacement(id: idB ?? UUID(), from: "ML", to: "artificial intelligence")

        XCTAssertEqual(snap.replacements.count, 2, "collision must not add or drop a row")
        let froms = snap.replacements.map { $0.from.lowercased() }.sorted()
        XCTAssertEqual(froms, ["ai", "ml"],
            "B.from must stay `ai` — the colliding edit is rejected")
        XCTAssertEqual(snap.replacements.first(where: { $0.id == idB })?.from, "ai",
            "the edited pair keeps its original `from`")
    }

    func test_updateReplacement_toOnly_succeeds() async {
        // Editing only the `to` side (same `from`) is not a collision.
        let store = DictionaryStore(url: url)
        _ = await store.addReplacement(from: "ml", to: "machine learning")
        var snap = await store.addReplacement(from: "ai", to: "artificial intelligence")
        let idA = try? XCTUnwrap(snap.replacements.first(where: { $0.from == "ml" })?.id)

        snap = await store.updateReplacement(id: idA ?? UUID(), from: "ml", to: "meta learning")

        XCTAssertEqual(snap.replacements.first(where: { $0.id == idA })?.to, "meta learning")
        XCTAssertEqual(snap.replacements.count, 2)
    }

    func test_updateReplacement_fromToNewValue_succeeds() async {
        // Editing B.from to a genuinely new value (`dl`) is accepted.
        let store = DictionaryStore(url: url)
        _ = await store.addReplacement(from: "ml", to: "machine learning")
        var snap = await store.addReplacement(from: "ai", to: "artificial intelligence")
        let idB = try? XCTUnwrap(snap.replacements.first(where: { $0.from == "ai" })?.id)

        snap = await store.updateReplacement(id: idB ?? UUID(), from: "dl", to: "deep learning")

        XCTAssertEqual(snap.replacements.first(where: { $0.id == idB })?.from, "dl")
        XCTAssertEqual(snap.replacements.count, 2)
    }

    func test_updateReplacement_ownCasingChange_succeeds() async {
        // Changing a pair's OWN casing (`ml` → `ML`) is allowed — the
        // collision check excludes the pair being edited via `id != id`.
        let store = DictionaryStore(url: url)
        var snap = await store.addReplacement(from: "ml", to: "machine learning")
        let idA = try? XCTUnwrap(snap.replacements.first?.id)

        snap = await store.updateReplacement(id: idA ?? UUID(), from: "ML", to: "machine learning")

        XCTAssertEqual(snap.replacements.count, 1)
        XCTAssertEqual(snap.replacements.first?.from, "ML")
    }

    func test_removeReplacement_byID() async {
        let store = DictionaryStore(url: url)
        let snap = await store.addReplacement(from: "то есть", to: "т.е.")
        let id = try? XCTUnwrap(snap.replacements.first?.id)
        _ = await store.removeReplacement(id: id ?? UUID())
        let after = await store.snapshot()
        XCTAssertTrue(after.replacements.isEmpty)
    }

    // MARK: - promptEntries

    func test_promptEntries_includesBothBuckets_userFirst() async {
        let store = DictionaryStore(url: url)
        _ = await store.addUserEntry("NoType")
        _ = await store.addAutoEntries(["Anthropic"])
        let snap = await store.snapshot()
        let prompt = snap.promptEntries()
        XCTAssertTrue(prompt.contains("NoType"))
        XCTAssertTrue(prompt.contains("Anthropic"))
        XCTAssertLessThan(prompt.firstIndex(of: "NoType")!,
                          prompt.firstIndex(of: "Anthropic")!,
                          "user entries should come before auto entries")
    }

    func test_promptEntries_capsAtMaxTotalEntries() async {
        let store = DictionaryStore(url: url)
        for i in 0..<DictionarySnapshot.maxTotalEntries {
            _ = await store.addUserEntry("user\(i)")
        }
        // Adding auto on top must not push the prompt past the 100 cap.
        // Store's `addAutoEntries` itself trims, so promptEntries should
        // never exceed 100.
        _ = await store.addAutoEntries(["autoA", "autoB", "autoC"])
        let snap = await store.snapshot()
        let prompt = snap.promptEntries()
        XCTAssertEqual(prompt.count, DictionarySnapshot.maxTotalEntries)
    }

    // MARK: - Corruption recovery

    func test_corruptFile_isQuarantined_andEmptySnapshotReturned() async throws {
        try Data("{ not valid json".utf8).write(to: url)
        let store = DictionaryStore(url: url)
        let snap = await store.snapshot()
        XCTAssertTrue(snap.entries.isEmpty)
        XCTAssertTrue(snap.replacements.isEmpty)
        // A `.corrupt-*` sibling file should exist now.
        let siblings = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(siblings.contains { $0.pathExtension.hasPrefix("corrupt-") },
            "corrupt file must be renamed with .corrupt-<ts> suffix")
    }
}
