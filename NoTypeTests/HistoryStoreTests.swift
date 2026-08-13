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

    private func entry(
        text: String,
        when: Date = Date(),
        failedChunkCount: Int = 0
    ) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: when,
            durationSeconds: 1.0,
            failedChunkCount: failedChunkCount
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
            "the sequence — not the mirrored count — is what survives the round-trip, "
            + "and it must still report three lost positions")
        XCTAssertEqual(reloaded.first?.isBroken, true)
    }

    /// Brokenness is the sequence, and the count is what a *reconstructed*
    /// sequence is built from. A row carrying text is broken or not purely
    /// on the count it was described with, and a count of zero is not broken
    /// no matter what the text holds — including a `[…]` the user dictated.
    func test_isBroken_derivesFromTheSequence_reconstructedFromTheCount() {
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

    // MARK: - Response sequence + migration (U5)

    private static let marker = RecordingSession.failureMarker

    /// A `history.json` exactly as the build *before* the response
    /// sequence shipped would have written it — one row per pre-sequence
    /// shape R12 has to migrate, in the order the requirement lists them:
    ///
    /// 1. count 1, text carrying exactly that many markers;
    /// 2. count 3, text empty (the session that lost everything);
    /// 3. count 1, text carrying **no** marker — a replacement pair on the
    ///    ellipsis rewrote it. **This is the row the change exists for.**
    /// 4. count 0, text carrying a `[…]` the user dictated verbatim.
    ///
    /// A sibling literal rather than a `Fixtures/` file, for the same
    /// reason `legacyHistoryJSON` above is one: the bytes and the
    /// assertion that reads them belong together, and no project
    /// regeneration can quietly change what the proof runs against.
    private static let legacyBrokenHistoryJSON = """
    [
      {
        "durationSeconds" : 8.5,
        "failedChunkCount" : 1,
        "id" : "3D1C3B50-8E6F-4B2C-9D40-7C5E03F5A2B3",
        "sourceAppName" : "Slack",
        "sourceBundleID" : "com.tinyspeck.slackmacgap",
        "text" : "Ship it by […] and review after.",
        "timestamp" : "2026-08-01T09:41:12Z"
      },
      {
        "durationSeconds" : 30,
        "failedChunkCount" : 3,
        "id" : "4E2D4C61-9F70-4C3D-AE51-8D6F14061B3C",
        "sourceAppName" : "Mail",
        "sourceBundleID" : "com.apple.mail",
        "text" : "",
        "timestamp" : "2026-08-01T10:02:44Z"
      },
      {
        "durationSeconds" : 8.5,
        "failedChunkCount" : 1,
        "id" : "5F3E5D72-A081-4D4E-BF62-9E70251721D4",
        "sourceAppName" : "Slack",
        "sourceBundleID" : "com.tinyspeck.slackmacgap",
        "text" : "Ship it by ... and review after.",
        "timestamp" : "2026-08-01T11:15:03Z"
      },
      {
        "durationSeconds" : 6,
        "failedChunkCount" : 0,
        "id" : "604F6E83-B192-4E5F-C073-AF81362832E5",
        "sourceAppName" : "Notes",
        "sourceBundleID" : "com.apple.Notes",
        "text" : "He said […] and left.",
        "timestamp" : "2026-08-01T12:20:00Z"
      }
    ]
    """

    /// AE5, end to end and through the real store: a pre-sequence
    /// `history.json` loads with every row still looking like itself, and
    /// — the half a per-row unit test cannot see — **without minting a
    /// `history.json.corrupt-*` sibling**. A migration that threw would
    /// read as an empty history here, which is why the file's survival is
    /// asserted rather than just the rows'.
    func test_load_legacyFileOfEveryPreSequenceShape_migratesAndRendersAsBefore() async throws {
        try Self.legacyBrokenHistoryJSON.write(to: tempURL, atomically: true, encoding: .utf8)

        let rows = await HistoryStore(url: tempURL).allEntries()
        XCTAssertEqual(rows.count, 4, "no row lost to the schema widening")

        XCTAssertEqual(rows.map(\.text), [
            "Ship it by […] and review after.",
            "",
            "Ship it by ... and review after.",
            "He said […] and left.",
        ], "every row's text survives verbatim")

        XCTAssertEqual(rows.map(\.isBroken), [true, true, true, false],
            "the stored count decides brokenness — including the row whose "
            + "markers a replacement pair erased, and excluding the row whose "
            + "marker the user dictated")
        XCTAssertEqual(rows.map(\.failedChunkCount), [1, 3, 1, 0])

        XCTAssertEqual(rows[0].segments, [
            .carrying("Ship it by ", at: [0]),
            .gap(at: [1]),
            .carrying(" and review after.", at: [2]),
        ])
        XCTAssertEqual(rows[1].segments, [.gap(at: [0]), .gap(at: [1]), .gap(at: [2])])
        XCTAssertEqual(rows[2].segments, [
            .carrying("Ship it by ... and review after.", at: [0]),
            .gap(at: [1]),
        ], "no marker left to split on, so the gap is appended to match the count")
        XCTAssertEqual(rows[3].segments, [.carrying("He said […] and left.", at: [0])],
            "a count of zero never looks for a marker at all")

        let siblings = try FileManager.default
            .contentsOfDirectory(atPath: tempURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("history.json.corrupt-") }
        XCTAssertTrue(siblings.isEmpty,
            "migrating must not look like corruption — a rename here costs the user all ten rows")
    }

    /// R12 case 1. The count is the only thing that can make a row broken;
    /// a dictated marker is text like any other.
    func test_migration_zeroCount_isOneVerbatimTextSegment_whateverTheTextHolds() {
        for text in ["He said \(Self.marker) and left.", "", "\(Self.marker)\(Self.marker)"] {
            let segments = HistoryEntry.migratedSegments(text: text, failedChunkCount: 0)
            XCTAssertEqual(segments, [.carrying(text, at: [0])],
                "count 0 must never be parsed for markers (text: \(text.debugDescription))")
            XCTAssertFalse(segments.contains(where: \.isGap))
        }
    }

    /// R12 case 2. Alternating text and gap, one gap per stored failure.
    func test_migration_markersMatchingTheCount_splitIntoAlternatingSegments() {
        let text = "one \(Self.marker) two \(Self.marker) three"
        XCTAssertEqual(
            HistoryEntry.migratedSegments(text: text, failedChunkCount: 2),
            [
                .carrying("one ", at: [0]),
                .gap(at: [1]),
                .carrying(" two ", at: [2]),
                .gap(at: [3]),
                .carrying(" three", at: [4]),
            ]
        )
    }

    /// R12 case 3 — **the row the whole change exists for.** A replacement
    /// pair on the ellipsis rewrote the markers out of the text; the stored
    /// count is the only surviving evidence the session lost anything, and
    /// the row must stay broken.
    func test_migration_countWithFewerMarkersThanStored_appendsGapsAndStaysBroken() {
        // No marker left at all.
        XCTAssertEqual(
            HistoryEntry.migratedSegments(text: "Ship it by ... and review after.", failedChunkCount: 1),
            [.carrying("Ship it by ... and review after.", at: [0]), .gap(at: [1])]
        )
        // Some erased, some not: split on what remains, append the rest.
        XCTAssertEqual(
            HistoryEntry.migratedSegments(text: "a \(Self.marker) b", failedChunkCount: 3),
            [
                .carrying("a ", at: [0]),
                .gap(at: [1]),
                .carrying(" b", at: [2]),
                .gap(at: [3]),
                .gap(at: [4]),
            ]
        )
    }

    /// R12 case 4. It falls out of case 3's arm rather than being special
    /// cased, so it is pinned in its own right.
    func test_migration_emptyTextWithACount_isThatManyGaps() {
        let segments = HistoryEntry.migratedSegments(text: "", failedChunkCount: 3)
        XCTAssertEqual(segments, [.gap(at: [0]), .gap(at: [1]), .gap(at: [2])])
        XCTAssertTrue(segments.allSatisfy(\.isGap),
            "every segment is a gap — the shape the never-counted-session signal reads")
    }

    /// The other direction of "the count decides": a marker beyond the
    /// stored count is text the user dictated, not a fourth gap.
    func test_migration_markersBeyondTheCount_stayLiteralText() {
        XCTAssertEqual(
            HistoryEntry.migratedSegments(text: "a \(Self.marker) b \(Self.marker) c", failedChunkCount: 1),
            [
                .carrying("a ", at: [0]),
                .gap(at: [1]),
                .carrying(" b \(Self.marker) c", at: [2]),
            ]
        )
    }

    /// The migration's *shape* edges, none of which R12 enumerates and all
    /// of which drive `migratedSegments`' empty-head / empty-tail branches
    /// — the ones that decide whether a zero-length text segment gets
    /// emitted and therefore whether the ordinal indices stay contiguous.
    /// A stray empty segment is invisible in the rendered row and lethal to
    /// the index write a later unit keys on.
    func test_migration_markerAtEitherEdge_andAdjacentMarkers_emitNoEmptySegments() {
        let cases: [(String, Int, [HistoryEntry.Segment])] = [
            // Leading marker: no head, so no empty text segment before it.
            ("\(Self.marker) tail", 1, [.gap(at: [0]), .carrying(" tail", at: [1])]),
            // Trailing marker: no remainder, so nothing appended after it.
            ("head \(Self.marker)", 1, [.carrying("head ", at: [0]), .gap(at: [1])]),
            // Adjacent markers: the second iteration's head is empty too.
            ("a \(Self.marker)\(Self.marker) b", 2,
             [.carrying("a ", at: [0]), .gap(at: [1]), .gap(at: [2]), .carrying(" b", at: [3])]),
            // The whole transcript was one lost chunk.
            (Self.marker, 1, [.gap(at: [0])]),
            // Whitespace is text, not absence — it must not collapse away.
            ("   ", 2, [.carrying("   ", at: [0]), .gap(at: [1]), .gap(at: [2])]),
            // A marker with no spaces around it still splits on real bounds.
            ("wait\(Self.marker), go", 1,
             [.carrying("wait", at: [0]), .gap(at: [1]), .carrying(", go", at: [2])]),
        ]
        for (text, count, expected) in cases {
            let segments = HistoryEntry.migratedSegments(text: text, failedChunkCount: count)
            XCTAssertEqual(segments, expected, "text \(text.debugDescription) count \(count)")
            XCTAssertFalse(
                segments.contains { $0.text?.isEmpty == true },
                "an empty-string text segment is not a gap and renders as nothing — "
                + "it would silently shift every later position"
            )
            XCTAssertEqual(
                segments.flatMap(\.chunkIndices), Array(0..<segments.count),
                "ordinal positions stay contiguous from 0"
            )
        }
    }

    /// The count is read straight off disk and the reconstruction turns it
    /// into that many allocations, so ten bytes of JSON buy an unbounded
    /// array. Left unclamped this is **worse than the outcome the whole
    /// tolerant decoder exists to avoid**: a throw gets `history.json`
    /// renamed aside and the app starts fresh, but an unbounded allocation
    /// hangs or OOM-kills the app *at launch*, every launch, and
    /// `JSONFileStorage` cannot rescue what never returns. Measured before
    /// the clamp: 5 000 000 built in 0.09 s, `Int.max` never returned.
    ///
    /// The row must stay **broken** through the clamp — that is the fact
    /// the user sees, and a clamp that quietly healed the row would trade
    /// a hang for a lie.
    func test_migration_absurdCount_isClampedAndStillReadsAsBroken() throws {
        for count in [HistoryEntry.maxMigratedGaps + 1, 5_000_000, Int.max] {
            let segments = HistoryEntry.migratedSegments(text: "a transcript", failedChunkCount: count)
            XCTAssertEqual(segments.count, HistoryEntry.maxMigratedGaps + 1,
                "one text segment plus the clamped gaps, for count \(count)")
            XCTAssertEqual(segments.filter(\.isGap).count, HistoryEntry.maxMigratedGaps)
        }
        // And through the real decoder, because that is where a corrupt
        // file actually arrives.
        let json = """
        [
          {
            "durationSeconds" : 8.5,
            "failedChunkCount" : 9223372036854775807,
            "id" : "3D1C3B50-8E6F-4B2C-9D40-7C5E03F5A2B3",
            "sourceAppName" : "Slack",
            "sourceBundleID" : "com.tinyspeck.slackmacgap",
            "text" : "a transcript",
            "timestamp" : "2026-08-01T09:41:12Z"
          }
        ]
        """
        let rows = try JSONFileStorage.makeDecoder()
            .decode([HistoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(rows.first?.failedChunkCount, HistoryEntry.maxMigratedGaps)
        XCTAssertEqual(rows.first?.isBroken, true, "a clamped row is still a broken row")
        XCTAssertEqual(rows.first?.text, "a transcript", "and its transcript is untouched")
    }

    /// A count no honest session could reach is clamped, but a count a
    /// session *could* reach must survive verbatim — otherwise the clamp
    /// is silently rewriting real rows. Pins the boundary from below.
    func test_migration_countAtTheCeiling_isNotClamped() {
        let segments = HistoryEntry.migratedSegments(
            text: "", failedChunkCount: HistoryEntry.maxMigratedGaps
        )
        XCTAssertEqual(segments.count, HistoryEntry.maxMigratedGaps)
        XCTAssertTrue(segments.allSatisfy(\.isGap))
    }

    /// The claim `init(from:)`'s doc-comment rests on — "one malformed row
    /// must not cost the user the other nine" — asserted the only way it
    /// can be: through the **real store**, on a **multi-row** file, with
    /// the damage in the middle. The per-row sweep above decodes one row at
    /// a time and so cannot see this: a decoder that let the bad row throw
    /// would fail the whole array, and both good rows would vanish with it.
    ///
    /// The `.corrupt-` check is the half that makes it a data-loss test
    /// rather than a parsing test — a thrown row renames the file, so the
    /// user's next launch starts from empty.
    func test_load_multiRowFileWithOneMalformedSequence_keepsTheOtherRows() async throws {
        let json = """
        [
          {
            "durationSeconds" : 3,
            "failedChunkCount" : 0,
            "id" : "1B9A1F3E-6C4D-4F0A-9B2E-7A5C81D3E0F1",
            "sourceAppName" : "Slack",
            "sourceBundleID" : "com.tinyspeck.slackmacgap",
            "text" : "the first one",
            "timestamp" : "2026-08-01T09:41:12Z"
          },
          {
            "durationSeconds" : 4,
            "failedChunkCount" : 1,
            "id" : "4E2D4C61-9F70-4C3D-AE51-8D6F14061B3C",
            "segments" : "this is not a sequence",
            "sourceAppName" : "Mail",
            "sourceBundleID" : "com.apple.mail",
            "text" : "lost \(Self.marker) here",
            "timestamp" : "2026-08-01T10:02:44Z"
          },
          {
            "durationSeconds" : 5,
            "failedChunkCount" : 0,
            "id" : "5F3E5D72-A081-4D4E-BF62-9E70251721D4",
            "sourceAppName" : "Notes",
            "sourceBundleID" : "com.apple.Notes",
            "text" : "the third one",
            "timestamp" : "2026-08-01T11:15:03Z"
          }
        ]
        """
        try json.write(to: tempURL, atomically: true, encoding: .utf8)

        let rows = await HistoryStore(url: tempURL).allEntries()
        XCTAssertEqual(rows.map(\.text), ["the first one", "lost \(Self.marker) here", "the third one"],
            "the rows either side of the damage survive it")
        XCTAssertEqual(rows.map(\.isBroken), [false, true, false],
            "and the damaged row still reconstructs from its legacy pair")

        let siblings = try FileManager.default
            .contentsOfDirectory(atPath: tempURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("history.json.corrupt-") }
        XCTAssertTrue(siblings.isEmpty,
            "an unusable sequence must never reach JSONFileStorage's rename path")
    }

    /// KTD10's discriminator, proved by making the two answers *differ*:
    /// the stored sequence puts the gap first, the row's text puts the
    /// marker last. A decoder that re-parsed the text would hand back the
    /// mirror image, so this fails loudly if the sequence is ever ignored.
    func test_decode_rowWrittenByThisBuild_usesItsSequence_neverTheMarkerParser() throws {
        let written = HistoryEntry(
            id: UUID(),
            text: "head \(Self.marker)",
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            durationSeconds: 3,
            segments: [.gap(at: [0]), .carrying("tail", at: [1])]
        )

        let data = try JSONFileStorage.makeEncoder().encode([written])
        let read = try JSONFileStorage.makeDecoder().decode([HistoryEntry].self, from: data)

        XCTAssertEqual(read.first?.segments, [.gap(at: [0]), .carrying("tail", at: [1])],
            "the stored sequence wins; re-parsing the text would have produced "
            + "[.carrying(\"head \"), .gap] instead")
    }

    /// KTD10's other half, and the reason the mirrors are written at all:
    /// a row this build wrote must still decode under the **pre-sequence**
    /// decoder. Without `text` and `failedChunkCount` beside the sequence
    /// that decoder throws, the whole top-level array fails, and
    /// `JSONFileStorage` renames `history.json` aside — a rollback would
    /// cost the user all ten transcripts.
    func test_encode_rowWrittenByThisBuild_stillDecodesUnderThePreSequenceDecoder() throws {
        let written = HistoryEntry(
            id: UUID(),
            text: "Ship it by \(Self.marker) and review after.",
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            durationSeconds: 8.5,
            segments: [
                .carrying("Ship it by ", at: [0]),
                .gap(at: [1]),
                .carrying(" and review after.", at: [2]),
            ]
        )

        let data = try JSONFileStorage.makeEncoder().encode([written])
        let old = try JSONFileStorage.makeDecoder()
            .decode([PreSequenceHistoryEntry].self, from: data)

        XCTAssertEqual(old.count, 1, "the old decoder must not throw on the whole array")
        XCTAssertEqual(old.first?.text, "Ship it by \(Self.marker) and review after.")
        XCTAssertEqual(old.first?.failedChunkCount, 1,
            "the mirrored count is the sequence's gap count, so a rolled-back "
            + "build still renders the row as broken")
        XCTAssertEqual(old.first?.durationSeconds, 8.5)
    }

    /// A sequence that is present but unusable falls back to the same
    /// reconstruction a legacy row gets, rather than throwing out of the
    /// decoder. One malformed row must not cost the user the other nine.
    func test_decode_unusableSequence_degradesToReconstruction_ratherThanThrowing() throws {
        let shapes = [
            #""segments" : []"#,                                  // empty
            #""segments" : "not an array""#,                      // wrong type
            #""segments" : [ { "text" : "no positions" } ]"#,     // missing chunkIndices
            #""segments" : [ { "chunkIndices" : [], "text" : "x" } ]"#, // empty positions
        ]
        for shape in shapes {
            let json = """
            [
              {
                "durationSeconds" : 8.5,
                "failedChunkCount" : 1,
                "id" : "3D1C3B50-8E6F-4B2C-9D40-7C5E03F5A2B3",
                \(shape),
                "sourceAppName" : "Slack",
                "sourceBundleID" : "com.tinyspeck.slackmacgap",
                "text" : "Ship it by \(Self.marker) and review after.",
                "timestamp" : "2026-08-01T09:41:12Z"
              }
            ]
            """
            let rows = try JSONFileStorage.makeDecoder()
                .decode([HistoryEntry].self, from: Data(json.utf8))
            XCTAssertEqual(rows.first?.segments, [
                .carrying("Ship it by ", at: [0]),
                .gap(at: [1]),
                .carrying(" and review after.", at: [2]),
            ], "shape \(shape) must reconstruct, not throw")
        }
    }

    /// AE10 / R19 / R27. A chunk the hallucination gate filtered is stored
    /// as a text segment holding `""` — Gemini answered and *we* dropped the
    /// answer — so it renders no marker and its row is not broken. A `nil`
    /// in the same slot would be the failure class instead.
    func test_emptyTextSegment_isTextNotAGap_soItsRowIsNotBroken() throws {
        let gated = HistoryEntry(
            id: UUID(),
            text: "first third",
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            durationSeconds: 5,
            segments: [
                .carrying("first", at: [0]),
                .carrying("", at: [1]),
                .carrying("third", at: [2]),
            ]
        )
        XCTAssertFalse(gated.isBroken, "an empty-text segment is not a lost chunk")
        XCTAssertEqual(gated.failedChunkCount, 0)

        // And the distinction survives the round-trip, which is where an
        // encoder that collapsed `""` onto `nil` would show up.
        let data = try JSONFileStorage.makeEncoder().encode([gated])
        let read = try JSONFileStorage.makeDecoder().decode([HistoryEntry].self, from: data)
        XCTAssertEqual(read.first?.segments[1].text, "")
        XCTAssertFalse(read.first?.segments[1].isGap ?? true)
        XCTAssertFalse(read.first?.isBroken ?? true)
    }

    /// A segment covers *one or more* positions, because one Gemini call
    /// can answer for several chunks with a single joined transcript. Order
    /// and positions both have to survive a fresh reader, or a retry writes
    /// into the wrong slot.
    func test_roundTrip_preservesSegmentOrderAndPositions() async {
        let batched = HistoryEntry(
            id: UUID(),
            text: "alpha bravo charlie",
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(),
            durationSeconds: 9,
            segments: [
                .carrying("alpha", at: [0]),
                .gap(at: [1, 2]),
                .carrying("bravo charlie", at: [3, 4]),
            ]
        )
        await HistoryStore(url: tempURL).append(batched)

        let reloaded = await HistoryStore(url: tempURL).allEntries()
        XCTAssertEqual(reloaded.first?.segments, batched.segments,
            "order and the positions each segment covers survive verbatim")
        XCTAssertEqual(reloaded.first?.failedChunkCount, 2,
            "a gap spanning two positions counts as two lost chunks, "
            + "matching SessionSummary.failedChunkCount")
    }

    /// The sequence is never empty. `isBroken` and `failedChunkCount` read
    /// an empty array correctly, but "every segment is a gap" is vacuously
    /// *true* over one — the shape the never-counted-session signal reads —
    /// so the degenerate case is normalised away at construction instead.
    func test_segments_areNeverEmpty() {
        let noResponses = HistoryEntry(
            id: UUID(),
            text: "",
            sourceAppName: "Slack",
            sourceBundleID: "com.tinyspeck.slackmacgap",
            timestamp: Date(),
            durationSeconds: 0,
            segments: []
        )
        XCTAssertEqual(noResponses.segments, [.carrying("", at: [0])])
        XCTAssertFalse(noResponses.isBroken)
        XCTAssertFalse(noResponses.segments.allSatisfy(\.isGap),
            "an empty sequence must not read as 'every segment is a gap'")
    }

    /// The pre-sequence decoder, copied verbatim from the build this shape
    /// replaced. It exists to prove KTD10's rollback claim by construction
    /// rather than by inspection: `text` is decoded **non-optionally**, so
    /// dropping that mirror from `HistoryEntry.encode(to:)` makes the test
    /// above throw.
    private struct PreSequenceHistoryEntry: Decodable {
        let id: UUID
        let text: String
        let sourceAppName: String
        let sourceBundleID: String
        let timestamp: Date
        let durationSeconds: Double
        let failedChunkCount: Int

        enum CodingKeys: String, CodingKey {
            case id, text, sourceAppName, sourceBundleID
            case timestamp, durationSeconds, failedChunkCount
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id              = try c.decode(UUID.self,   forKey: .id)
            self.text            = try c.decode(String.self, forKey: .text)
            self.sourceAppName   = try c.decode(String.self, forKey: .sourceAppName)
            self.sourceBundleID  = try c.decode(String.self, forKey: .sourceBundleID)
            self.timestamp       = try c.decode(Date.self,   forKey: .timestamp)
            self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
            self.failedChunkCount = try c.decodeIfPresent(Int.self, forKey: .failedChunkCount) ?? 0
        }
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
        // The backup must be a *move*, not a copy. A copy would leave the
        // undecodable bytes at `history.json`, so every subsequent read
        // would re-fail and mint another `.corrupt-<ts>` sibling forever.
        // Asserting only "reads empty" + "a backup exists" is green under
        // that regression — see
        // `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
            "the corrupt file is renamed aside, not copied — nothing is left at history.json")
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

    // MARK: - update(_:) (U6 — the retry's disk write)

    func test_update_replacesTheRowInPlace_withoutMovingIt() async {
        // A retry rewrites a broken row's text and failure count without
        // changing what the row *is*. Re-appending would move it to the
        // newest slot, reorder the last-10 list under the user, and put
        // the trim in a position to evict a different row than the cap
        // would have taken.
        let store = HistoryStore(url: tempURL)
        let first = entry(text: "first")
        let broken = entry(text: "second \(RecordingSession.failureMarker)", failedChunkCount: 1)
        let last = entry(text: "third")
        await store.append(first)
        await store.append(broken)
        await store.append(last)

        let recovered = HistoryEntry(
            id: broken.id,
            text: "second recovered",
            sourceAppName: broken.sourceAppName,
            sourceBundleID: broken.sourceBundleID,
            timestamp: broken.timestamp,
            durationSeconds: broken.durationSeconds,
            failedChunkCount: 0
        )
        await store.update(recovered)

        let entries = await store.allEntries()
        XCTAssertEqual(entries.map(\.id), [first.id, broken.id, last.id], "order is preserved")
        XCTAssertEqual(entries.map(\.text), ["first", "second recovered", "third"])
        XCTAssertEqual(entries[1].isBroken, false, "and the row is no longer broken")
    }

    func test_update_persistsAcrossAFreshReader() async {
        // The mirror is not the assertion — the file is.
        let broken = entry(text: "gap \(RecordingSession.failureMarker)", failedChunkCount: 1)
        await HistoryStore(url: tempURL).append(broken)

        await HistoryStore(url: tempURL).update(
            HistoryEntry(
                id: broken.id,
                text: "gap filled",
                sourceAppName: broken.sourceAppName,
                sourceBundleID: broken.sourceBundleID,
                timestamp: broken.timestamp,
                durationSeconds: broken.durationSeconds,
                failedChunkCount: 0
            )
        )

        let entries = await HistoryStore(url: tempURL).allEntries()
        XCTAssertEqual(entries.map(\.text), ["gap filled"])
    }

    func test_update_missingIdIsNoop_andAddsNoRow() async {
        // Mirrors `remove(id:)`'s contract. Reachable when a retry settles
        // before the row's own fire-and-forget append has landed — the row
        // must not be conjured into existence out of order.
        let store = HistoryStore(url: tempURL)
        let kept = entry(text: "kept")
        await store.append(kept)

        await store.update(entry(text: "never appended"))

        let entries = await store.allEntries()
        XCTAssertEqual(entries.map(\.text), ["kept"], "no row added, none changed")
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
