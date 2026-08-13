import Foundation
import OSLog

actor HistoryStore {
    private static let log = Logger(subsystem: "app.notype", category: "history")
    /// The rolling window (invariant 1). **Internal, not private, because
    /// it is the single source of truth for a second trim:**
    /// `AppState.historyMirrorCap` is derived from it, so the optimistic
    /// main-actor mirror and this actor's FIFO cannot drift apart. A
    /// private copy here would leave the mirror hand-synced to a literal,
    /// which is the drift `AppState.liveHistoryIDs` cannot survive — see
    /// `AppState.historyMirrorCap`.
    static let cap = 10

    private let url: URL
    private let encoder = JSONFileStorage.makeEncoder()
    private let decoder = JSONFileStorage.makeDecoder()

    init(url: URL? = nil) {
        self.url = url ?? JSONFileStorage.appSupportURL(filename: "history.json")
    }

    /// Every stored row, oldest-first (invariant 2).
    ///
    /// **Decoded row-by-row: a row that cannot be decoded is dropped, and
    /// the rest load.** Before this, `history.json` was decoded as a bare
    /// `[HistoryEntry]`, so a single unreadable row threw for the whole
    /// array, `JSONFileStorage` renamed the file to `.corrupt-<ts>`, and the
    /// user's history came back empty — ten transcripts lost to one bad
    /// field. `HistoryEntry.init(from:)` already tolerates everything it can
    /// tolerate *within* a row (an absent or unusable `segments`, a
    /// wrong-typed `failedChunkCount`); what remained fatal was the row's
    /// five required fields, and no per-field default can fix those without
    /// inventing data. Dropping the row is the answer, and it is a product
    /// ruling rather than a refactor — see the trade-off below.
    ///
    /// **The dropped row has no `.corrupt-` copy to recover from.** That is
    /// the cost the whole-array behaviour was buying: a renamed file is a
    /// complete, hand-recoverable copy of all ten rows. Per-row tolerance
    /// trades that for nine rows the user keeps automatically, and the
    /// maintainer chose it knowing so. `read`'s rename still fires for
    /// damage that cannot be split into rows at all (see `LossyHistoryArray`),
    /// so the recoverable-copy path is narrowed, not removed.
    ///
    /// **A drop is logged at `.error`** — persisted by the unified log, so it
    /// survives to a later diagnosis, which is the only trace a dropped row
    /// leaves anywhere. Positions and a count only: a row's `text` is the
    /// user's speech and never reaches a log line.
    ///
    /// **This read does not rewrite the file** — see the heal-on-write note
    /// below `allEntries()`.
    func allEntries() -> [HistoryEntry] {
        guard let stored = JSONFileStorage.read(
            from: url,
            as: LossyHistoryArray.self,
            decoder: decoder,
            log: Self.log
        ) else { return [] }

        if !stored.droppedPositions.isEmpty {
            let positions = stored.droppedPositions.map(String.init).joined(separator: ",")
            Self.log.error(
                """
                dropped \(stored.droppedPositions.count, privacy: .public) undecodable \
                row(s) at position(s) [\(positions, privacy: .public)]; \
                \(stored.entries.count, privacy: .public) row(s) loaded
                """
            )
        }
        return stored.entries
    }

    // MARK: - Heal-on-write: considered, decided against
    //
    // Should `allEntries()` rewrite the file with just the survivors, so the
    // array on disk matches what loaded?
    //
    // **Decided: no.** A read never rewrites `history.json`, so a dropped
    // row's bytes stay on disk until a real mutation rewrites the array.
    //
    // Healing eagerly is the tidier-looking option and it is the wrong one,
    // for two reasons that outrank the untidiness:
    //
    // - **A read that deletes is a read that cannot be retried.** The dropped
    //   row has no `.corrupt-` sibling (see `allEntries()`), so the bytes left
    //   at `history.json` are the only copy in existence. Healing on read
    //   destroys them at the earliest possible moment — at launch, before
    //   anyone knows a row was lost — and `allEntries()` is called by
    //   `append` / `update` / `remove` as well as by `AppState`'s refresh, so
    //   it would fire on paths that were only meant to look.
    // - **A drop is not proof the row is garbage.** The most likely way this
    //   ever fires in the field is version skew, not disk damage: a future
    //   build adds a required field, the user rolls back, and *this* decoder
    //   drops rows a newer build reads perfectly. Healing on read makes that
    //   downgrade permanently destructive; leaving the file alone makes it
    //   survivable by upgrading again. The rename path this replaces had the
    //   same property — it preserved the file — and that is worth keeping.
    //
    // The consequence is recorded rather than hidden: the survivors *are*
    // written back by the next `append` / `update` / `remove`, because those
    // re-serialize the whole array by design, so the broken row does leave the
    // file on the next mutation. That is incidental heal-on-write and it is
    // the honest ceiling of what this decision buys — a window, not a
    // guarantee. Both halves are pinned by `HistoryStoreTests`
    // (`test_allEntries_droppingARow_doesNotRewriteTheFile`,
    // `test_append_afterADrop_rewritesTheArrayWithoutTheDroppedRow`).

    @discardableResult
    func append(_ entry: HistoryEntry) -> [HistoryEntry] {
        var entries = allEntries()
        entries.append(entry)
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
        }
        write(entries)
        return entries
    }

    /// Replace the stored entry that shares `entry.id`, in place. No-op if
    /// the id isn't present, mirroring `remove(id:)`'s contract.
    ///
    /// **In place, not remove-then-append.** A retry rewrites a broken row's
    /// text and failure count (R12, R16) without changing what the row *is*:
    /// re-appending would move it to the newest slot, reorder the last-10
    /// list under the user, and put the trim in a position to evict a
    /// different row than the one the cap would have taken.
    ///
    /// The no-op case is reachable and benign: `AppState`'s mirror is
    /// optimistic and its disk writes are fire-and-forget, so a retry can
    /// settle against a row whose original `append` has not landed yet. The
    /// row's own append then persists it — carrying the pre-retry text until
    /// the next mutation, which is the same eventual-consistency the mirror
    /// has always had. The mirror is what the UI renders.
    @discardableResult
    func update(_ entry: HistoryEntry) -> [HistoryEntry] {
        var entries = allEntries()
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else {
            return entries
        }
        entries[idx] = entry
        write(entries)
        return entries
    }

    /// Remove the entry with the given id. No-op if not found.
    @discardableResult
    func remove(id: UUID) -> [HistoryEntry] {
        var entries = allEntries()
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before {
            write(entries)
        }
        return entries
    }

    /// Wipe every transcript. Used by Settings → System → "Delete all
    /// transcripts" (plan §584-646, AE7). Privacy-only: does NOT touch
    /// `stats.json` — usage aggregates (word count, session count,
    /// duration, token totals) are preserved per the carve-out
    /// documented in
    /// `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
    /// Always writes — an empty file is the desired post-state — so
    /// the on-disk snapshot reflects the wipe even when history was
    /// already empty in-memory.
    func deleteAll() {
        write([])
    }

    private func write(_ entries: [HistoryEntry]) {
        JSONFileStorage.write(entries, to: url, encoder: encoder, log: Self.log)
    }
}

/// `history.json` decoded element-by-element, dropping rows that fail
/// instead of failing the file. Consumed by `HistoryStore.allEntries()`.
///
/// **It lives here, not in `JSONFileStorage`.** `NoType/Storage/CLAUDE.md`'s
/// "don't add per-store branching here" rule decides it: per-row tolerance is
/// recovery behaviour specific to this one file. The other three stores are
/// single-object snapshots with their own tolerant decoders and nothing to
/// split into rows, so putting this in the shared layer would be precisely
/// the `history.json` branch that rule forbids. It is built *on top of*
/// `JSONFileStorage.read` instead — which is generic over `Decodable`, so it
/// needed no change at all, and the atomic-write and whole-file recovery
/// invariants there are untouched.
///
/// **The `LossyRow` wrapper is required, not stylistic — this is measured.**
/// The obvious shape, `while !c.isAtEnd { if let e = try? c.decode(HistoryEntry.self) … }`,
/// **hangs**: `UnkeyedDecodingContainer.decode` advances `currentIndex` only
/// *after* a successful decode, so a throwing element leaves the cursor in
/// place and the loop re-reads the same bad row forever. Verified against
/// Swift 6.3 / macOS 26 Foundation — a probe on a two-row file with the first
/// row bad spun until its own iteration guard stopped it. `LossyRow.init(from:)`
/// never throws, so the cursor always advances and the failure arrives as a
/// `nil` payload instead of as a thrown error.
///
/// **`decodeNil()` runs first as defence-in-depth, and it is honestly not
/// load-bearing on today's toolchain.** Removing it was mutation-tested and
/// every test stayed green: Swift 6.3 / macOS 26 Foundation routes a JSON
/// `null` element through `LossyRow.init(from:)` like any other, so `try?`
/// already catches it. It is kept because that is an unspecified internal —
/// older Foundation unboxed `NSNull` *before* reaching a non-optional type's
/// initializer, which would throw past the wrapper and fail the whole file,
/// and NoType deploys back to macOS 15. Four lines to not depend on which
/// `JSONDecoder` implementation the host OS ships. The *behaviour* is pinned
/// either way by `test_load_rowsThatArentObjects_areDroppedNotFatal`; this
/// branch only removes a platform assumption from underneath it.
///
/// **Damage that isn't row-shaped still takes the whole-file path.** A
/// truncated write, a non-JSON file, an empty file, or a top-level object
/// throws out of `unkeyedContainer()` (or before it, in the parser), which is
/// what `JSONFileStorage.read` catches to mint the `.corrupt-<ts>` sibling.
/// That is deliberate: those files have no elements to salvage, so the renamed
/// copy is the user's only recourse and must keep being made.
private struct LossyHistoryArray: Decodable {
    /// The rows that decoded, in file order.
    let entries: [HistoryEntry]

    /// Positions in the stored array that did not decode. Positions, not
    /// contents: this value exists to be logged, and a row's text is the
    /// user's speech.
    let droppedPositions: [Int]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var entries: [HistoryEntry] = []
        var dropped: [Int] = []

        while !container.isAtEnd {
            let position = container.currentIndex
            if try container.decodeNil() {
                dropped.append(position)
                continue
            }
            if let row = try container.decode(LossyRow.self).entry {
                entries.append(row)
            } else {
                dropped.append(position)
            }
        }

        self.entries = entries
        self.droppedPositions = dropped
    }
}

/// One array element, decoded so that failure is a value rather than a throw.
/// See `LossyHistoryArray`'s doc-comment for why the throw must not escape.
///
/// Nothing is defaulted into existence here: a row missing its `id` or
/// `timestamp` decodes to `nil` and is dropped, never fabricated. The
/// tolerance `HistoryEntry.init(from:)` already applies *within* a row
/// (absent / unusable `segments`, wrong-typed `failedChunkCount`) is
/// unchanged and still runs first — this wrapper only catches what that
/// decoder still considers fatal.
private struct LossyRow: Decodable {
    let entry: HistoryEntry?

    init(from decoder: Decoder) throws {
        entry = try? HistoryEntry(from: decoder)
    }
}
