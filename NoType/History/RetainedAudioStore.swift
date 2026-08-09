import Foundation

/// Holds the encoded audio of failed chunks in memory, keyed by the
/// `HistoryEntry.id` of the broken row that offers to re-send it.
///
/// **This is not a fifth JSON store.** It shares nothing with
/// `HistoryStore` / `StatsStore` / `InstructionsStore` /
/// `DictionaryStore` except the folder: it touches no file, uses no
/// `JSONFileStorage` helper, and has no on-disk representation to
/// recover from. `NoType/Storage/CLAUDE.md`'s "don't add a fifth
/// store" rule is about that one-file-per-snapshot shape and does not
/// bite here — the cap this holder mirrors is the *history window*,
/// not a file. It lives in `NoType/History/` for exactly that reason
/// (KTD2): its lifetime contract is the ten-entry cap, so it belongs
/// beside the store that owns the cap, even though the payload type it
/// holds is defined in `NoType/Recording/`.
///
/// ## Memory-only, for the lifetime of the app process (R1)
///
/// Nothing in this holder is ever serialized. Not to
/// `history.json` alongside the entry it is keyed by, not to a
/// side-car file, not to a crash-recovery cache, not to a temp
/// directory. The whole feature is a bet that a lost dictation is
/// worth holding in RAM until the process exits — **not** a
/// relaxation of the project's nothing-on-disk posture, which
/// `README.md`, the non-goal in `AGENTS.md`, invariant 4 in
/// `NoType/History/CLAUDE.md`, and invariant I4 in
/// `docs/architecture/overview.md` all still assert. Those statements
/// are true only because this holder never writes.
///
/// So: adding `Codable` to `RetainedRecording`, persisting this map,
/// or introducing a "survive a relaunch" cache keyed the same way is a
/// **scope violation, not a refactor** — it silently converts a
/// memory-only promise into a false one, with no test failing to say
/// so. `RetainedRecordingTests.test_retainedRecording_isNotSerializable`
/// is the mechanical half of that guard; this comment is the half that
/// explains why the guard exists. A row whose process died is
/// *supposed* to come back dead (R8) — the audio being gone is the
/// designed outcome, not a gap to fill.
///
/// **Never log a payload or any of its fields.** The chunks are the
/// user's speech and each payload's `ContextSnapshot` carries masked
/// but real on-screen text from other applications. A count or a
/// `UUID` is fine; the payload is not.
///
/// ## Release triggers (R5)
///
/// R5 names four moments a payload is released, and each has exactly
/// one method here, so no method does double duty:
///
/// | Trigger | Method |
/// |---|---|
/// | A retry succeeds | `take(_:)` without a re-put |
/// | The user deletes the row | `remove(_:)` |
/// | The ten-entry cap evicts the row | `retain(only:)` |
/// | The app exits | the process frees it |
///
/// **`retain(only:)` is the only eviction path.** It takes the set of
/// history entry ids that are still live and drops everything else, so
/// eviction is a mirror of the cap rather than a second implementation
/// of it — one call point that cannot drift from `HistoryStore`'s
/// FIFO. Do not implement eviction by looping `remove(_:)`: that
/// re-derives the cap and reintroduces exactly the drift this shape
/// exists to prevent. `remove(_:)` is the targeted user-delete
/// release, nothing more.
///
/// ## Shape
///
/// A `@MainActor final class` rather than an `actor` (KTD1): only
/// main-actor code produces (`AppState.finalizeRecording`) and
/// consumes (the retry action) these payloads, and the project
/// reserves `actor` for genuinely shared mutable state — see
/// `docs/solutions/conventions/swift-6-concurrency-and-async-2026-05-15.md`.
/// A reference type because `AppState` owns one and hands the same
/// identity to every call site; a separate type rather than fields on
/// `AppState` so eviction is testable without constructing `AppState`.
/// Mirrors the `@MainActor final class` shape of `HUDController`, and
/// `HistoryStore`'s idempotent-`remove` contract.
@MainActor
final class RetainedAudioStore {

    /// History entry id → the payload its retry would re-send.
    /// Bounded in practice by the ten-entry history cap, which
    /// `retain(only:)` mirrors.
    private var payloads: [UUID: RetainedRecording] = [:]

    /// Hold `recording` against `entryID`, replacing any payload
    /// already stored under that id.
    ///
    /// Replacement (not merge) is the contract: a retry that recovers
    /// some chunks re-puts a payload holding only the ones that did
    /// not recover, and that reduced payload must supersede the
    /// original rather than accumulate beside it.
    ///
    /// Consumers: U5 (`finalizeRecording` stores a failed session's
    /// payload under the broken row it just appended) and U6 (a
    /// partial retry re-puts what is left, a retry that recovered
    /// nothing re-puts what it took).
    func put(_ recording: RetainedRecording, for entryID: UUID) {
        payloads[entryID] = recording
    }

    /// The payload held against `entryID`, or `nil` if none — without
    /// removing it.
    ///
    /// This is the *presence* read: whether a broken row can offer
    /// retry at all (R10), which is also what separates a broken row
    /// from a dead one (R8). Consumers: U5's retry-availability
    /// predicate and U7's row rendering. Use `take(_:)` instead when
    /// actually running a retry.
    func peek(_ entryID: UUID) -> RetainedRecording? {
        payloads[entryID]
    }

    /// Remove and return the payload held against `entryID`, or `nil`
    /// if none.
    ///
    /// This is the *consumption* read: the retry run takes the payload
    /// out, so a second retry cannot be started against audio already
    /// in flight, and settles the row by re-putting whatever did not
    /// recover (or nothing, when everything did — which is R5's
    /// retry-succeeded release). Consumer: U6.
    func take(_ entryID: UUID) -> RetainedRecording? {
        defer { payloads[entryID] = nil }
        return payloads[entryID]
    }

    /// Drop the payload held against `entryID`. A no-op when the id is
    /// absent, mirroring `HistoryStore.remove(id:)`.
    ///
    /// R5's user-delete release, and only that. Consumer: U5's
    /// `deleteHistoryEntry`. **Not** an eviction primitive — cap
    /// eviction goes through `retain(only:)`.
    func remove(_ entryID: UUID) {
        payloads[entryID] = nil
    }

    /// Drop every payload whose entry id is not in `liveEntryIDs`.
    ///
    /// The single eviction point (R5). `liveEntryIDs` is the id set of
    /// the history rows that still exist, so the holder's contents are
    /// a strict subset of the ten-entry window by construction — no
    /// cap arithmetic is duplicated here, and a change to
    /// `HistoryStore`'s FIFO needs no matching change in this file.
    ///
    /// Called after **every** history mutation that can drop a row:
    /// append-with-trim, delete-one, delete-all. An empty set empties
    /// the holder, which is the delete-all case.
    ///
    /// Consumer: U5.
    func retain(only liveEntryIDs: Set<UUID>) {
        payloads = payloads.filter { liveEntryIDs.contains($0.key) }
    }
}
