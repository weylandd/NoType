import AppKit
import Foundation
import OSLog

/// Orchestrates one push-to-talk session.
///
/// On `start()`:
/// 1. Captures focused-app metadata + kicks off the AX walk and
///    insertion-target capture in parallel (see `NoType/Context/CLAUDE.md`).
/// 2. Starts the audio recorder and gets back an `AsyncStream<[Float]>` of
///    16 kHz / mono / float32 frames sized for `SileroVAD`.
/// 3. Spins up a detached VAD consumer that drives `PauseDetector`. Each
///    chunk boundary is appended to `pending` and a single sender task
///    drains the queue (see `runSender`). When chunks pile up behind a
///    slow Gemini call, the next sender wake batches them into one
///    `transcribeBatch` request (one round-trip instead of N).
///
/// On `stop()`:
/// 1. Stops the recorder, which finishes the audio stream.
/// 2. Drains any in-flight VAD frames, then asks the pause detector to
///    finalize whatever's left as the last chunk (`is_final=true`). This
///    final chunk goes into `pending` alongside any earlier queued
///    chunks — they all drain together in one batched request.
/// 3. Waits for the sender to drain, concatenates per-call transcripts
///    client-side (invariant I2), runs `finalizeForInsertion` against
///    the captured `Text after cursor`, pastes, and writes history.
///
/// Threading: the session itself lives on `@MainActor`; the VAD consumer
/// runs on a detached task; the sender encode + Gemini call runs on a
/// detached task. The actor barriers around `SileroVAD` and `GeminiClient`
/// keep all of this race-free.
@MainActor
final class RecordingSession {
    nonisolated static let log = Logger(subsystem: "app.notype", category: "session")

    /// Final-only batch audio under this threshold triggers the
    /// short-session lite-context path: empty AX tree, no OCR, no
    /// `On-screen context` / `Prior chunks` prompt sections, and a
    /// trimmed system instruction (`Self.systemPromptLite` in
    /// `GeminiClient`). At 16 kHz, 32 000 samples = 2.0 s of audio.
    /// Empirically covers 1–3 word utterances with breathing room.
    nonisolated static let shortSessionMaxSamples = 32_000

    /// VAD inference call is considered "slow" above this duration. Each
    /// VAD window covers 256 ms of audio, so on a healthy ANE we observe
    /// ~1–10 ms per call; anything above 50 ms is a strong signal of ANE
    /// contention (another ML workload on the chip). Used by the VAD
    /// consumer to count slow events for the session-end warning log.
    nonisolated static let slowInferenceThreshold: Duration = .milliseconds(50)

    /// Pure-function discriminator for the lite path. Extracted so
    /// `RecordingSessionShortPathTests` can pin the contract without
    /// standing up a full `RecordingSession`.
    ///
    /// Lite path fires iff ALL hold:
    ///   1. `isFinalBatch` — batch contains the final chunk (user release).
    ///   2. `priorTranscriptCount == 0` — no previous chunks went out
    ///      (i.e. VAD didn't split off any mid-session chunks). Once
    ///      transcripts exist, the prompt has to carry `Prior chunks`
    ///      and the lite shape no longer fits.
    ///   3. `totalBatchSamples < shortSessionMaxSamples` — audio fits
    ///      under the 2 s short-utterance threshold.
    ///   4. `batchChunkCount == 1` — the batch encodes to exactly one
    ///      audio chunk. The lite dispatch ships `encoded[0]` only
    ///      (`GeminiClient.transcribeShort` is single-audio by
    ///      construction), so a ≥2-chunk batch routed through the lite
    ///      path would silently drop every chunk after the first while
    ///      still recording all of them as covered. Gating on the
    ///      post-encode count keeps a short-but-multi-chunk final batch
    ///      on the normal batched path. See `NoType/Recording/CLAUDE.md`
    ///      invariant 11.
    nonisolated static func shouldUseLitePath(
        isFinalBatch: Bool,
        priorTranscriptCount: Int,
        totalBatchSamples: Int,
        batchChunkCount: Int
    ) -> Bool {
        isFinalBatch
            && priorTranscriptCount == 0
            && totalBatchSamples < shortSessionMaxSamples
            && batchChunkCount == 1
    }

    /// Pure-function gate for the screenshot + OCR context fallback.
    /// Extracted so `RecordingSessionOCRGateTests` can pin the contract
    /// without standing up a full `RecordingSession`.
    ///
    /// OCR runs iff ALL hold:
    ///   1. `fallbackEnabled` — the user's in-app "Use screen capture for
    ///      context" toggle (frozen at session start). Default on.
    ///   2. `permissionGranted` — Screen Recording TCC permission is granted.
    ///   3. `pid > 0` — there is a frontmost app to screenshot.
    ///
    /// The toggle is an independent off-switch layered on top of the TCC
    /// permission: a user can keep the permission granted but disable OCR.
    nonisolated static func shouldRunOCR(
        fallbackEnabled: Bool,
        permissionGranted: Bool,
        pid: pid_t
    ) -> Bool {
        fallbackEnabled && permissionGranted && pid > 0
    }

    /// Pure gate: should `stop()` abort immediately before committing the
    /// paste? Extracted so `RecordingSessionCancellationTests` can pin the
    /// paste-abort contract without standing up a full session.
    ///
    /// Returns `true` when either:
    ///   1. `failureIsSet` — the cancellation latch is installed
    ///      (`cancel()` sets `failure = CancellationError()` as its first
    ///      statement, but a terminal Gemini error also sets it), or
    ///   2. `taskIsCancelled` — the enclosing task was cancelled.
    ///
    /// `stop()` calls this synchronously right before `TextInjector.paste`,
    /// after its drain-loop suspension point, so a cancel that lands while
    /// `stop()` was suspended is honoured: no paste, no history write.
    nonisolated static func shouldAbortBeforePaste(
        failureIsSet: Bool,
        taskIsCancelled: Bool
    ) -> Bool {
        failureIsSet || taskIsCancelled
    }

    /// Pure gate: has the user moved to a different application since
    /// they stopped dictating, so that pasting would edit a document
    /// they never meant to touch? Extracted so
    /// `RecordingSessionFocusGuardTests` can pin the table without
    /// standing up a full session.
    ///
    /// Returns `true` — withhold the paste — iff **both** identifiers are
    /// known and they differ.
    ///
    /// **The destination is frozen at the *stop*, not at session start.**
    /// Product ruling (2026-08-11): the transcript belongs wherever the
    /// cursor was when the user pressed stop. Freezing at start broke
    /// hands-free dictation outright — with the recording locked, a user
    /// who starts talking in one application, walks to another and taps
    /// to stop there is *deliberately* aiming at the second one, and a
    /// start-frozen identity withheld that paste every single time, so a
    /// whole hands-free dictation delivered nothing. What KD8 protects
    /// against is untouched: a transcript is still withheld when the user
    /// moves away **during transcription**, which is the long wait this
    /// guard exists for. Only moving around *during recording* stopped
    /// costing the delivery. `AppState.finalizeRecording` performs the
    /// freeze via `freezePasteDestination(_:)`.
    ///
    /// **Conservative by construction.** An unknown identifier on either
    /// side pastes. A missing fact is never evidence of a mismatch, and
    /// the failure modes are not symmetric: a wrong withhold silently
    /// swallows an ordinary dictation every time the frontmost app can't
    /// be read, whereas the case this gate exists for is rare and
    /// recoverable from the history row. `NSWorkspace` answers `nil` when
    /// nothing is frontmost (stored as `0`), and
    /// `NSRunningApplication.processIdentifier` is documented to answer
    /// `-1` when it has no pid for the application. So "known" is
    /// `> 0` rather than "non-zero": a plain `!=` comparison would read
    /// the `-1` sentinel as a live mismatch and withhold against it.
    ///
    /// **Process identity, not bundle identity** (KD9): an application
    /// that quits and relaunches mid-transcription counts as changed,
    /// which is the accepted cost of not pasting into a fresh process
    /// whose document state has nothing to do with what the user saw.
    /// **Window identity is not considered** (R26): two windows of one
    /// process share a pid and therefore compare equal.
    ///
    /// NoType itself being frontmost — the user opened the popover while
    /// waiting — withholds like any other mismatch. There is deliberately
    /// no self-carve-out: it is not the process they stopped in.
    ///
    /// **The stop-moment freeze adds the mirror case, and it is not the
    /// same case.** A user who *stops* with NoType frontmost makes NoType
    /// the destination, so if they are still there at paste time nothing
    /// mismatches and ⌘V lands in whatever field they left focused —
    /// dictating into our own Dictionary or Instructions fields works, and
    /// a popover left open swallows the paste into nothing. Both follow
    /// from the rule rather than escaping it: NoType is only ever the
    /// destination when the user deliberately put it in front, and the
    /// transcript is in history either way. Do not "fix" this by excluding
    /// our own pid — that reintroduces a withhold for a place the user
    /// chose, which is the shape the 2026-08-11 ruling reversed.
    ///
    /// **That absence is only safe because NoType's own windows never
    /// take frontmost by themselves.** `HUDPanel` is a
    /// `.nonactivatingPanel` that refuses both key and main, so the
    /// transcribing HUD on screen during *every* session cannot make
    /// this gate fire; only a deliberate click on NoType can. If that
    /// panel configuration ever regresses, this gate stops being rare —
    /// it withholds every dictation, silently. Anything that makes a
    /// NoType window activate on its own has to be weighed here first.
    ///
    /// **This is not `shouldAbortBeforePaste`, and must not be folded
    /// into it** (KTD6). That gate aborts by *throwing*, which routes
    /// `stop()` into `finalizeRecording`'s catch arm and writes no
    /// history row at all. Here the transcript is good and the user must
    /// keep it (R24): the caller skips only the paste and falls through
    /// to the entry build and `history.append` unchanged.
    nonisolated static func shouldWithholdPaste(
        destinationPID: pid_t,
        currentPID: pid_t
    ) -> Bool {
        guard destinationPID > 0, currentPID > 0 else { return false }
        return destinationPID != currentPID
    }

    /// Pure gate: was this session's cursor context read in a *different*
    /// application than the one the transcript is going to land in — so
    /// that `TextInjector.finalizeForInsertion` would be correcting the
    /// paste against another document's text?
    ///
    /// Returns `true` — discard the context and hand
    /// `finalizeForInsertion` `InsertionTarget.unknown` instead — iff
    /// **both** identifiers are known and they differ.
    ///
    /// **Why this exists.** `InsertionTarget` is captured once, in the
    /// context phase of `start()`, from the focused field of whatever
    /// application was frontmost then (`NoType/Context/CLAUDE.md`
    /// invariant 6). Under the 2026-08-11 product ruling the transcript no
    /// longer necessarily lands there: a hands-free locked dictation
    /// starts in application A, walks to B, and stops — and is delivered
    /// into B. `textBefore` / `textAfter` then describe A's document while
    /// the paste happens in B's, and both of `finalizeForInsertion`'s
    /// corrections become guesses about the wrong text. One of them is
    /// destructive: it **strips a sentence-final `.` / `!` / `?`** when
    /// `textAfter` looks like the middle of a sentence, so a period the
    /// user dictated is silently deleted on the strength of a character
    /// read out of an entirely different window. The maintainer's ruling:
    /// "if I started recording in one window and pressed stop in a
    /// different window, then everything has already changed, and those
    /// formatting corrections should not be applied."
    ///
    /// **Why `.unknown` and not `.empty`.** `.unknown` is precisely "we do
    /// not know what is around the cursor" — the branch that already
    /// exists for Electron and web-views, where `kAXValueAttribute` is not
    /// exposed. It prepends the defensive leading space and skips the
    /// trailing-punctuation strip, which is exactly the right behaviour
    /// under the same uncertainty. `.empty` would be a *claim* that the
    /// field is empty: it suppresses the leading space and re-enables the
    /// strip, asserting a fact we do not have.
    ///
    /// **This is not `shouldWithholdPaste`, and the two must not be
    /// conflated.** That gate compares the frozen destination against the
    /// frontmost process *at paste time* and answers "may we paste at
    /// all". This one compares the frozen destination against the process
    /// the session *started* in and answers "is the context we captured
    /// about the place we are pasting into". Both can be true, both can be
    /// false, and neither implies the other:
    ///
    ///   * hands-free — start in A, stop in B, still in B when the
    ///     transcript is ready: this gate fires, the paste gate does not,
    ///     and the paste goes through with a defensive boundary;
    ///   * ordinary — start and stop in A, then switch to B during
    ///     transcription: the paste gate fires, this one does not.
    ///
    /// **Conservative in the same direction as the paste gate** (KD9): an
    /// unknown identifier on either side keeps the context, i.e. keeps the
    /// behaviour that shipped before this gate existed. That is a
    /// deliberate choice, not the only defensible one — the defensive path
    /// is *milder* than the destructive correction it avoids, so "discard
    /// when unsure" could be argued. It was rejected for two reasons.
    /// Reading `> 0` as "known" the same way `shouldWithholdPaste` does
    /// keeps one notion of process identity in the paste region rather
    /// than two that can drift apart. And an unknown identifier is not
    /// evidence of a move: it is a failed `NSWorkspace` read on what is
    /// almost always an ordinary same-application dictation, which would
    /// then acquire a stray leading space for nothing.
    ///
    /// **Process identity, not bundle identity** (KD9), and **window
    /// identity is not considered** (R26) — inherited by comparing the
    /// same two identifiers the paste gate does.
    nonisolated static func shouldDiscardInsertionContext(
        sourcePID: pid_t,
        destinationPID: pid_t
    ) -> Bool {
        guard sourcePID > 0, destinationPID > 0 else { return false }
        return sourcePID != destinationPID
    }

    enum SessionError: Error, LocalizedError {
        case notStarted
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .notStarted: "Recording wasn't started."
            case .noSpeech:   "No speech detected — try again, holding ⌥ a bit longer."
            }
        }
    }

    /// Marker substituted into the pasted text in place of a chunk
    /// whose Gemini call failed recoverably (network, 5xx, decoding,
    /// etc — see `isTerminal(_:)`). The user sees `[…]` where the gap
    /// is, knows the surrounding text is intact, and can re-dictate
    /// just the missing piece — vs the old all-or-nothing behaviour
    /// which threw away a 3-minute monologue on a single dropped
    /// chunk. See `NoType/Recording/CLAUDE.md` "Partial recovery".
    nonisolated static let failureMarker = "[…]"

    /// Outcome bookkeeping for a session — exposed to `AppState` so
    /// the post-`stop()` HUD can nudge the user when the pasted text
    /// contains `failureMarker` placeholders. The marker itself is
    /// visible in the text; this struct gives the caller a count
    /// without parsing.
    struct SessionSummary: Sendable {
        /// Count of chunks whose Gemini call failed recoverably and
        /// were replaced with `failureMarker` in the pasted text.
        let failedChunkCount: Int
        /// Total chunks the session accounted for (excludes sub-150 ms
        /// drops). `failedChunkCount <= dispatchedChunkCount`.
        ///
        /// Almost always the count of chunks actually sent to Gemini. The
        /// one exception is a split-retry abandoned on the network class
        /// (`shouldAbandonSplitRetry`), whose remaining chunks are counted
        /// here without ever being dispatched — deliberately, because this
        /// number's only consumer is the "N of M chunks" copy in the
        /// pasted-with-gaps HUD, and a chunk that produced a `[…]` belongs
        /// in that denominator whether or not a request was issued for it.
        let dispatchedChunkCount: Int
        /// Sum of `TokenUsage` across every successful Gemini call
        /// in this session (single-chunk, batched, lite, split-
        /// retry). Failed calls (terminal or recoverable) contribute
        /// nothing — the `*WithUsage` overload only returns on the
        /// success path, so retried-then-succeeded calls already
        /// carry only the final successful attempt's usage (matches
        /// Gemini's per-response billing). Read by
        /// `AppState.finalizeRecording` and folded into
        /// `StatsStore.record(_:tokens:)` for per-day token totals.
        let tokens: TokenUsage
        /// Transcription model this session ran on (frozen at start).
        /// Folded into `StatsStore` so token costs are priced at the
        /// right per-model rate.
        let model: GeminiModel
        /// Encoded audio of this session's chunks whose Gemini call
        /// failed in the class `shouldRetain(_:)` admits, plus the
        /// context and model needed to re-issue them unchanged (R2, R3).
        ///
        /// `nil` for the ordinary successful session, for a session whose
        /// only losses came from the hallucination gate, and for every
        /// session that aborted on a terminal error — nothing is held
        /// that a retry could not use.
        ///
        /// Memory-only for the lifetime of the process; the contract and
        /// the reasons it is load-bearing live on `RetainedRecording`.
        /// **Never log this value or any of its fields** — the chunks are
        /// the user's speech and the context carries masked but real
        /// on-screen text from other applications.
        let retained: RetainedRecording?
        /// `true` when the transcript was withheld because the user had
        /// moved to a different process by the time it was ready
        /// (`shouldWithholdPaste`, R23 / R24 / KD8). The row was still
        /// written; only the paste was skipped.
        ///
        /// Read by `AppState` to tell the user the transcript is ready
        /// and offer to copy it, since nothing appeared where they were
        /// looking. Orthogonal to `hasFailures` and to `retained`: a
        /// session can change destination without losing a chunk, and
        /// lose chunks without changing destination.
        let pasteWithheldForDestinationChange: Bool
        /// Localized name of the application this session's transcript was
        /// aimed at — the one frontmost when the user *stopped* recording,
        /// frozen there by `freezePasteDestination(_:)`.
        ///
        /// This is what the withheld-paste notice names (R25): the place
        /// the transcript was destined for, which since the 2026-08-11
        /// product ruling is the stop-moment application rather than the
        /// one the session started in. Frozen rather than re-read at
        /// notice time — by then the user has moved again and the
        /// frontmost app answers a different question entirely.
        ///
        /// Deliberately **not** the same fact as `HistoryEntry.sourceAppName`,
        /// which stays frozen at session start because it records where the
        /// dictation *happened* and feeds lifetime per-app statistics. The
        /// two coincide for every session that stops where it started.
        ///
        /// `nil` when nothing was frontmost at the stop, or when the freeze
        /// never ran.
        let pasteDestinationAppName: String?
        /// The finalized transcript `stop()` produced — the exact string
        /// it pasted, or would have pasted on the withheld arm (R15).
        ///
        /// Carried here because it exists nowhere else once the row stops
        /// storing it as its display text: `HistoryEntry` holds raw
        /// segments plus a legacy `text` mirror, and the string a reader
        /// assembles from those segments is neither insertion-normalised
        /// nor frozen to the pairs this session ran with. The dictionary
        /// harvester wants the real one. See
        /// `RecordingSession.finalizedTranscript`.
        ///
        /// `""` for a session that threw *before reaching the finalize
        /// step* — a terminal Gemini error, an empty stitch, an encode
        /// failure. The broken-row path reads this summary too, and there
        /// is no transcript there to describe.
        ///
        /// **Not** `""` for a session cancelled in the narrow window
        /// between finalizing and pasting: `stop()` records the string one
        /// statement before its last cancellation re-check, so an Escape
        /// landing there leaves a real transcript on the summary. Nothing
        /// consumes it — `finalizeRecording`'s `catch is CancellationError`
        /// arm neither harvests nor counts — and the alternative (record
        /// after the re-check) would cost the withheld arm its transcript,
        /// which is the case R15 exists for.
        ///
        /// **Never log it** — it is the user's speech, verbatim.
        let finalizedTranscript: String

        var hasFailures: Bool { failedChunkCount > 0 }

        /// Spelled out rather than synthesized so the trailing fields can
        /// default: the pre-retention call sites (the summary-field tests
        /// in `RecordingSessionPartialRecoveryTests`) keep compiling, and
        /// the single production caller — `RecordingSession.summary` —
        /// always passes them explicitly. New facts about a session's
        /// outcome are added here the same way (KTD7).
        init(
            failedChunkCount: Int,
            dispatchedChunkCount: Int,
            tokens: TokenUsage,
            model: GeminiModel,
            retained: RetainedRecording? = nil,
            pasteWithheldForDestinationChange: Bool = false,
            pasteDestinationAppName: String? = nil,
            finalizedTranscript: String = ""
        ) {
            self.failedChunkCount = failedChunkCount
            self.dispatchedChunkCount = dispatchedChunkCount
            self.tokens = tokens
            self.model = model
            self.retained = retained
            self.pasteWithheldForDestinationChange = pasteWithheldForDestinationChange
            self.pasteDestinationAppName = pasteDestinationAppName
            self.finalizedTranscript = finalizedTranscript
        }
    }

    /// Classify a Gemini / system error as terminal (abort the
    /// session, surface via Error HUD) or recoverable (insert
    /// `failureMarker` and continue draining remaining chunks).
    ///
    /// Terminal errors are ones where continuing the session can't
    /// help: a bad key won't authenticate the next chunk; a blocked
    /// prompt won't unblock; an encode failure means PCM is corrupt
    /// or AVFAudio is wedged; a user cancellation is, well, user-
    /// initiated. Everything else (HTTP 4xx/5xx/network/decoding/
    /// empty/truncated) is treated as a transient gap — paste what we
    /// have, mark the gap, let the user decide whether to re-dictate.
    ///
    /// Sibling classifier: `shouldRetain(_:)` immediately below decides
    /// whether the same error keeps the chunk's audio for a retry. A new
    /// error case belongs in both.
    nonisolated static func isTerminal(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let gerr = error as? GeminiClient.GeminiError {
            switch gerr {
            case .missingKey, .blocked:
                return true
            case .http(let status, _):
                // 401 (bad key) / 403 (key not authorised for this
                // model) are terminal — no point burning N×retries on
                // every chunk of a session whose authentication is
                // already broken. The user needs to fix the key in
                // Settings. Other 4xx / 5xx / network (status=0) stay
                // recoverable: gap marker, continue draining.
                return status == 401 || status == 403
            case .empty, .decoding, .truncated:
                // `.truncated` (finishReason == MAX_TOKENS) is a cut
                // response, not a broken session — recover it as a `[…]`
                // gap marker so the rest of the session still pastes.
                return false
            }
        }
        return true
    }

    /// Decide whether a failed chunk's encoded audio is worth keeping in
    /// memory so the user can re-send it from its history row.
    ///
    /// Sibling classifier: `isTerminal(_:)` immediately above decides
    /// whether the same error aborts the session. **A new error case
    /// belongs in both** — that adjacency is the entire reason this
    /// function lives here rather than beside the retry code (plan
    /// KTD8). The two are complementary today, but deliberately written
    /// as separate switches: retention may narrow (a failure class we
    /// keep recovering from but never successfully retry) without
    /// changing which errors abort a session, and vice versa.
    /// `RetainedRecordingTests` pins the one direction that must always
    /// hold — every terminal error retains nothing.
    ///
    /// The governing rule (plan R4) is "retain exactly the class that
    /// today produces a `[…]` gap marker": network failure (status 0),
    /// 429, 5xx, and any other non-auth HTTP status, plus empty,
    /// decoding and truncated responses. Retention deliberately does
    /// **not** extend to terminal failures — a rejected key, a content
    /// block, a cancellation or an encode failure keeps nothing and
    /// aborts the session exactly as before. A retry could not fix any
    /// of them, and holding audio the user can never recover is a
    /// privacy cost with no payoff.
    nonisolated static func shouldRetain(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let gerr = error as? GeminiClient.GeminiError else {
            // Encoder / AVFAudio / anything unrecognised: terminal, and
            // in the encode case the audio never made it to a blob.
            return false
        }
        switch gerr {
        case .missingKey, .blocked:
            return false
        case .http(let status, _):
            // Same auth carve-out as `isTerminal`: 401 (bad key) and
            // 403 (key not authorised for this model) abort the
            // session, so there is nothing to retry against.
            return status != 401 && status != 403
        case .empty, .decoding, .truncated:
            return true
        }
    }

    /// `true` for the **network class** — a `GeminiError.http` with status
    /// 0, which is how `GeminiClient.performOnce` wraps every `URLError`
    /// and how its pre-flight reachability check reports no path at all.
    ///
    /// Third classifier in this family, and the narrowest. `isTerminal` and
    /// `shouldRetain` answer "what does this failure mean for the
    /// session"; this one answers a much smaller question used in exactly
    /// one place — "is the *transport* down, such that dispatching the next
    /// chunk is certain to fail the same way?" A 5xx or a 429 is
    /// per-request and deliberately excluded: the next chunk genuinely
    /// might succeed. Swept over the whole status space by
    /// `SplitRetryNetworkBoundTests` rather than spot-checked, so a widened
    /// range cannot slip through.
    ///
    /// **Its twin is `GeminiClient.requiresFreshConnection(after:)`**, which
    /// asks the same status-0 question one layer down to decide whether the
    /// retry must drop the connection pool. Unlike the two classifiers
    /// above, this pair has no adjacency to lean on and no compiler term
    /// either — neither is an exhaustive switch, so widening one raises
    /// nothing at the other. `GeminiRetryPolicyTests` pins them equal across
    /// the status space instead; widen one and you have to widen the other.
    nonisolated static func isNetworkClass(_ error: Error) -> Bool {
        guard let gerr = error as? GeminiClient.GeminiError,
              case .http(let status, _) = gerr else { return false }
        return status == 0
    }

    /// Whether `splitRetry` should stop dispatching and account for its
    /// remaining chunks directly.
    ///
    /// Fires only when the batched call **and** the first split chunk have
    /// both failed in the network class. Two independent observations of a
    /// dead transport, one of them a request issued on its own after the
    /// batch failed — at that point every remaining chunk is a guaranteed
    /// `GeminiClient` round-trip that ends in the same error, and with the
    /// 250 ms `splitRetryBackoff` between them a long session spends
    /// minutes proving it.
    ///
    /// Each term is load-bearing and each removal is a distinct bug:
    /// dropping the batch term abandons a run on a single blip; dropping
    /// the offset term abandons chunks after a mid-run failure the run had
    /// already proved were reachable; dropping the chunk term abandons on
    /// the batch's evidence alone, when the split call is exactly the
    /// second opinion worth having; dropping the latency term abandons on
    /// two instant pre-check short-circuits, which is one observation read
    /// twice rather than two — see ``abandonMinChunkFailureLatency``.
    nonisolated static func shouldAbandonSplitRetry(
        batchFailureWasNetwork: Bool,
        chunkOffset: Int,
        chunkFailureWasNetwork: Bool,
        chunkFailureLatency: Duration
    ) -> Bool {
        batchFailureWasNetwork
            && chunkOffset == 0
            && chunkFailureWasNetwork
            && chunkFailureLatency >= abandonMinChunkFailureLatency
    }

    /// Minimum wall-clock cost of the first split chunk's failure before
    /// abandoning the rest of the run is worth doing.
    ///
    /// **This term exists because the reachability pre-check took the cost
    /// out of the case the bound was measuring.** The bound was designed
    /// when a network-class failure meant a 30 s `URLSession` timeout, so
    /// two of them was ~60 s of evidence that the transport was down and
    /// every remaining chunk was another 30 s. `GeminiClient`'s pre-flight
    /// check now fails an `.unsatisfied`-path request in ~0 ms — so on a
    /// genuinely offline machine the batched call and the first split chunk
    /// both fail *instantly*, and "two independent observations" collapses
    /// into one cached path status read twice, microseconds apart.
    ///
    /// That is the case where abandoning is simultaneously pointless and
    /// harmful: dispatching the remaining chunks costs ~0 ms each (they
    /// short-circuit too), while abandoning turns a Wi-Fi blip that ends
    /// two seconds later into `[…]` in the pasted text for every chunk
    /// after the first — permanently, because a retry rewrites the history
    /// row and never the text already pasted into the user's document.
    ///
    /// 2 s sits far above a short-circuit (~0 ms) and far below the 30 s
    /// timeout the bound is actually for, so the predicate fires on exactly
    /// the case that motivated it: a `.satisfied` path whose requests still
    /// time out — captive portal, dead router, DNS blackhole.
    nonisolated static let abandonMinChunkFailureLatency: Duration = .seconds(2)

    /// What an abandoned split-retry owes the chunks it will never
    /// dispatch.
    ///
    /// **Both fields exist to make an undispatched chunk indistinguishable
    /// from a dispatched-and-failed one.** That is not a nicety: retention
    /// is normally driven by classifying a real error, and a chunk that was
    /// never sent has no error, so the naive version of this bound would
    /// drop its audio on the floor — converting a bounded wait into
    /// permanent data loss, the exact inverse of what the retry feature is
    /// for.
    struct AbandonedAccounting: Sendable {
        /// One entry per undispatched chunk, at its original chunk index.
        /// Each becomes a `text: nil` response, so it counts toward
        /// `SessionSummary.failedChunkCount` and renders a `failureMarker`
        /// in its own slot at stitch time.
        let markerChunkIndices: [Int]
        /// The subset whose encoded audio must be retained — every one of
        /// them whenever the abandoning error is retainable.
        let retainable: Set<Int>
    }

    /// Derive the accounting above. Pure, for the same reason
    /// `retainedPayload` is: the session is not drivable end to end, so
    /// this is where the behaviour is proved. Pinned by
    /// `SplitRetryNetworkBoundTests`.
    ///
    /// Retention goes through `shouldRetain(_:)` rather than being assumed.
    /// Production cannot reach this arm with a non-retainable error — the
    /// trigger requires the network class, which is retainable — but
    /// hard-coding `true` would break silently the day the trigger widens.
    nonisolated static func abandonedAccounting(
        undispatched: [RetainedRecording.Chunk],
        error: Error
    ) -> AbandonedAccounting {
        let indices = undispatched.map(\.idx)
        return AbandonedAccounting(
            markerChunkIndices: indices,
            retainable: shouldRetain(error) ? Set(indices) : []
        )
    }

    /// Derive one batch's retained payload: the encoded chunks whose
    /// Gemini call failed in the class `shouldRetain(_:)` admits, in
    /// ascending chunk order, carrying the context and model the failed
    /// requests actually used (R2, R3).
    ///
    /// Pure and `nonisolated` so the retain set is provable without
    /// standing up a `RecordingSession` — which owns an `AudioRecorder`,
    /// a `SileroVAD`, a `GeminiClient` and a `HistoryStore`, none of them
    /// unit-test-friendly. Same seam shape as `shouldUseLitePath`; pinned
    /// by `RetainedRecordingTests`.
    ///
    /// `failedChunkIndices` carries **only** indices the caller has
    /// already run through `shouldRetain(_:)`. Three kinds of chunk are
    /// therefore absent from it by construction, for three different
    /// reasons:
    ///
    /// - a chunk that transcribed — R2 releases its audio on the existing
    ///   schedule;
    /// - a chunk the `HallucinationLengthGate` dropped — Gemini answered
    ///   and we filtered the answer, which is stored as `text: ""` and is
    ///   deliberately *not* a failure (see `NoType/Recording/CLAUDE.md`
    ///   "Post-response hallucination gate"). Retaining it would hold
    ///   audio for a call that succeeded;
    /// - a chunk whose failure was terminal — R4 holds those to retaining
    ///   nothing.
    ///
    /// Chunks are filtered against the batch rather than trusted from the
    /// index set, so an index with no matching chunk contributes nothing
    /// instead of fabricating one. Returns `nil` rather than an empty
    /// payload when nothing survives, so the ordinary successful session
    /// carries no payload at all and `AppState` can branch on presence.
    nonisolated static func retainedPayload(
        inBatch chunks: [RetainedRecording.Chunk],
        failedChunkIndices: Set<Int>,
        context: ContextSnapshot,
        model: GeminiModel
    ) -> RetainedRecording? {
        guard !failedChunkIndices.isEmpty else { return nil }
        let kept = chunks
            .filter { failedChunkIndices.contains($0.idx) }
            .sorted { $0.idx < $1.idx }
        guard !kept.isEmpty else { return nil }
        return RetainedRecording(chunks: kept, context: context, model: model)
    }

    private let recorder: AudioRecorder
    private let vad:      SileroVAD
    private let gemini:   GeminiClient
    private let history:  HistoryStore

    private var startedAt: Date?
    /// Wall-clock time `stop()` began — i.e. hotkey release.
    ///
    /// Captured so `brokenHistoryEntry()` can compute the same
    /// press-to-release duration the success path does. `stop()` itself
    /// returns long after release when the Gemini calls it drains are
    /// failing and retrying, so `Date()` at throw time would credit the
    /// row with the whole failed-transcription window instead of the
    /// time the user actually spoke.
    private var stoppedAt: Date?
    private var sourceApp: NSRunningApplication?
    /// Process identifier of the application the session *started* in —
    /// the one whose focused field `InsertionTarget` was read from, and
    /// therefore the one this session's cursor context describes. Frozen
    /// from the same `NSWorkspace` read `start()` already performs for
    /// `sourceApp` and the OCR gate; never re-derived, for the same reason
    /// `destinationPID` is not (an `NSRunningApplication` answers `-1`
    /// once its process is gone, which reads as "unknown" precisely when
    /// the identity has changed).
    ///
    /// Read once, by `shouldDiscardInsertionContext` in `stop()`. It is
    /// deliberately **not** what the paste gate compares — the destination
    /// is the stop-moment application (KD9 as amended), and this is where
    /// the dictation began.
    ///
    /// `0` when nothing was frontmost at session start — the "unknown"
    /// `shouldDiscardInsertionContext` keeps the context for.
    private var sourcePID: pid_t = 0
    /// Process identifier of the application this session's transcript is
    /// aimed at — the one frontmost at the moment the user *stopped*
    /// recording. Written once by `freezePasteDestination(_:)`; read in
    /// `stop()` by the destination gate and, against `sourcePID`, by
    /// `shouldDiscardInsertionContext`.
    ///
    /// Stored rather than derived from an `NSRunningApplication` on
    /// demand. `NSRunningApplication.processIdentifier` is documented to
    /// answer `-1` when it has no pid for the application, and an exited
    /// process is observed to reach that state; either way, reading it
    /// later risks reporting the destination as unknown precisely when it
    /// has been replaced — which is the case the gate exists to catch.
    /// Freezing it removes the question.
    ///
    /// `0` until the freeze runs, and after it when nothing was
    /// frontmost — the "unknown" `shouldWithholdPaste` pastes through.
    private var destinationPID: pid_t = 0
    /// Localized name of that same application, frozen alongside the pid
    /// so the withheld-paste notice can say where the transcript was
    /// headed without re-reading the frontmost app at notice time (R25).
    /// `nil` when unknown. Surfaced on `SessionSummary` (KTD7).
    private var destinationAppName: String?
    /// Set by `stop()` when `shouldWithholdPaste` fired, and surfaced on
    /// `SessionSummary` for `AppState` (KTD7). Stays `false` for every
    /// session that pasted, including one that never reached the gate.
    private var pasteWithheldForDestinationChange = false
    /// The string `stop()` handed to the paste — stitched, boundary-
    /// normalised for insertion, and with the session's frozen
    /// replacement pairs applied. Set immediately before the paste gate,
    /// so it holds on the withheld arm too: nothing was pasted there, but
    /// this is still the string that *would* have been, and the
    /// distinction matters to nobody downstream.
    ///
    /// **It exists so the dictionary harvester keeps its input (R15).**
    /// The harvester intersects what the user actually said with what was
    /// on screen, and until this unit it read `HistoryEntry.text` — which
    /// was that same string. It no longer is: a row now assembles from
    /// raw segments and takes the user's *current* pairs at render time,
    /// so `entry.text` is a legacy mirror and the assembled string is
    /// neither insertion-normalised nor frozen to the session's pairs.
    /// Harvesting from it would quietly change which terms are learned.
    /// Riding `SessionSummary` (KTD7's defaulted-field channel) is what
    /// gets the real string to `AppState` without widening `stop()`'s
    /// return type.
    ///
    /// **Never log it** — it is the user's speech, verbatim.
    private var finalizedTranscript = ""
    /// Find/replace pairs to apply between `finalizeForInsertion` and
    /// `paste`. Captured from `DictionaryContext` at session start and
    /// frozen — independent of `contextTask` so a quick-release session
    /// still picks them up even when the context snapshot fell back to
    /// `.minimal(activeApp:)` (which carries empty replacements). Empty
    /// when the user has no replacement pairs configured.
    private var replacementsFrozen: [DictionaryReplacement] = []
    /// Frozen `InstructionsContext` captured at session start. Used by
    /// the short-session lite path (`buildLiteSnapshot`) to assemble a
    /// minimal `ContextSnapshot` synchronously on the main actor without
    /// touching the (possibly still-running) `contextTask`.
    private var instructionsFrozen: InstructionsContext = .empty
    /// Frozen `DictionaryContext` captured at session start. Same role
    /// as `instructionsFrozen` — feeds `buildLiteSnapshot` for the
    /// short-session path.
    private var dictionaryFrozen: DictionaryContext = .empty
    /// Frozen BCP-47 language codes captured at session start. Mirrors
    /// `dictionaryFrozen` for the always-present `User languages:`
    /// cache-prefix section. Frozen for the session's lifetime so the
    /// Gemini cache prefix stays byte-stable across chunks.
    private var userLanguagesFrozen: [String] = []
    /// Transcription model frozen at session start (Settings → API &
    /// Usage). Threaded into every Gemini call for this session so a
    /// mid-session settings change can't split one session across two
    /// models / implicit-cache namespaces. Defaults to `.flashLite`
    /// until `start` overwrites it.
    private var modelFrozen: GeminiModel = .flashLite
    /// User's "Use screen capture for context" toggle, frozen at session
    /// start. Layered on top of the Screen Recording TCC permission inside
    /// `shouldRunOCR` — a mid-session flip must not affect the in-flight
    /// session (the context-frozen-at-start invariant). Defaults to `true`
    /// until `start` overwrites it.
    private var screenCaptureFallbackFrozen: Bool = true
    private var contextTask: Task<ContextSnapshot, Never>?
    /// Mirror of `contextTask`'s eventual value, populated on the main
    /// actor the moment the snapshot is ready. Used by the **final-chunk**
    /// dispatch path to consult context without `await`ing — so a
    /// quick-release session (user holds <500 ms) doesn't sit waiting for
    /// AX / OCR siblings under their safety caps. Mid-session chunks
    /// (VAD-pause-triggered) still use the awaiting path, because we
    /// have time to spare and richer context = better transcription.
    /// `nil` means "not yet produced"; the consumer falls back to
    /// `ContextSnapshot.minimal(activeApp:)`.
    private(set) var cachedContext: ContextSnapshot?
    private var vadTask: Task<Void, Never>?

    /// One pending chunk waiting to be encoded + sent. The sender drains
    /// `pending` in FIFO order, batching whatever has accumulated each
    /// time it wakes (see `runSender`).
    private struct PendingChunk: Sendable {
        let index: Int
        let pcmStart: Int
        let pcmEnd: Int
        let isFinal: Bool
    }

    /// Chunks ready to be encoded + sent, FIFO. Mutated only on the main
    /// actor; the sender takes the whole list, processes it, then loops.
    private var pending: [PendingChunk] = []

    /// Single drain task that pulls from `pending`. Spawned lazily when
    /// the first chunk is enqueued; exits when `pending` is empty; gets
    /// respawned on the next enqueue. This is what coalesces piled-up
    /// chunks into one batched Gemini call (invariant I1, v2 form: one
    /// in-flight request per session — but a batch may carry several
    /// chunks at once).
    private var senderTask: Task<Void, Never>?

    /// Outcome of one Gemini call. A single `transcribe` produces
    /// one response covering a single chunk; a `transcribeBatch`
    /// produces one response covering several chunks (the model
    /// returns one contiguous text — we don't try to split it back
    /// out per-chunk). On a recoverable failure, `text == nil` and
    /// the stitched session output substitutes `failureMarker` for
    /// this entry's slot. See `runSender` / `processBatch` / `stop()`
    /// + `NoType/Recording/CLAUDE.md` "Partial recovery".
    /// Internal rather than private so `chunkCounts(in:)` — the arithmetic
    /// behind `SessionSummary.failedChunkCount` — can be pinned against
    /// real values. Nothing outside this file constructs one in
    /// production.
    struct ChunkResponse: Sendable {
        let chunkIndices: [Int]
        let text: String?
    }

    /// The counting behind `SessionSummary`: a chunk is *failed* when its
    /// response carries no text, and *dispatched* counts every chunk the
    /// session accounted for.
    ///
    /// Extracted as a pure function so the accounting an abandoned
    /// split-retry produces can be proved without driving a session — an
    /// undispatched chunk must land in `failed` exactly like a
    /// dispatched-and-failed one. Note the third state stays out of
    /// `failed`: `text: ""` is the hallucination gate's verdict on a call
    /// that *answered*, not a failure (see `NoType/Recording/CLAUDE.md`
    /// "Post-response hallucination gate").
    nonisolated static func chunkCounts(
        in responses: [ChunkResponse]
    ) -> (failed: Int, dispatched: Int) {
        var failed = 0
        var dispatched = 0
        for r in responses {
            dispatched += r.chunkIndices.count
            if r.text == nil { failed += r.chunkIndices.count }
        }
        return (failed, dispatched)
    }

    /// One Silero-cut chunk after PCM read, sub-150 ms drop, and AAC
    /// encode have all succeeded — the unit `processBatch` ships to
    /// Gemini and `splitRetry` re-issues on recoverable failure.
    /// `samples` is the raw PCM sample count (not encoded byte size);
    /// `HallucinationLengthGate` divides it by `AudioRecorder.outputSampleRate`
    /// to get audio duration. Named struct (over a 4-tuple) so a future
    /// field addition errors at the compile site rather than silently
    /// mis-positioning at one of three call sites.
    ///
    /// Mirrored field-for-field by `RetainedRecording.Chunk` — this type
    /// is private to the session, that one is its escaping counterpart
    /// for chunks whose audio is kept for a retry. **A field added here
    /// belongs there too**, or the retained copy stops reproducing the
    /// original request; the back-reference is on both sides so neither
    /// is edited without seeing the other.
    private struct EncodedChunk: Sendable {
        let idx: Int
        let isFinal: Bool
        let audio: Data
        let samples: Int

        /// This chunk in its escaping form, for the retention path. The
        /// field-for-field mirroring contract is in the doc-comment
        /// above; this is where it is exercised — but only in ONE
        /// direction. A field added to `RetainedRecording.Chunk` breaks
        /// this memberwise-init call and fails the build; a field added
        /// to `EncodedChunk` alone compiles silently and is dropped on
        /// the floor here. That second direction is a review
        /// responsibility, not a compiler-enforced one — don't read the
        /// mirroring note above as covering it.
        /// `audio` is a `Data` — copy-on-write, so this is a reference
        /// bump, not a second copy of the blob.
        var retainable: RetainedRecording.Chunk {
            RetainedRecording.Chunk(
                idx: idx,
                isFinal: isFinal,
                audio: audio,
                samples: samples
            )
        }
    }

    /// Outputs of completed Gemini calls, in dispatch order (also
    /// chunk-index order: the sender drains serially and we never
    /// dispatch out-of-order). Stitched at `stop()` — each entry's
    /// `text ?? Self.failureMarker` becomes one piece of the output.
    private var responses: [ChunkResponse] = []
    /// Per-session accumulator for Gemini token usage. Sums one
    /// `TokenUsage` per successful `*WithUsage` call (single-chunk,
    /// batched, lite, split-retry). Failed calls contribute nothing
    /// (the only call sites that mutate this are the success arms).
    /// `ChunkResponse` deliberately does NOT carry per-chunk
    /// tokens — Gemini bills per-request and a batched response's
    /// usage doesn't split cleanly across its chunks (plan §475 +
    /// `TokenUsage` doc-comment).
    private var sessionTokens: TokenUsage = .zero
    private var chunkCounter: Int = 0
    /// Set when a terminal error aborts the session (auth, blocked,
    /// encode failure, cancellation). `stop()` rethrows this — the
    /// recoverable-failure path leaves this nil and falls back to
    /// `lastRecoverableError` only when *every* response failed.
    private var failure: Error?
    /// Most recent recoverable error captured during a marker
    /// append. Used by `stop()` when every chunk's call failed —
    /// throwing this instead of `SessionError.noSpeech` gives the
    /// AppState error catalog the real cause (offline, 5xx, etc) to
    /// surface in the Error HUD.
    private var lastRecoverableError: Error?
    /// Encoded audio of the chunks whose calls failed in the retainable
    /// class, accumulated across this session's batches (R2, R3), plus
    /// the frozen context and model a retry needs to reproduce their
    /// requests. `nil` until the first such failure — a session that
    /// never loses a chunk allocates nothing here.
    ///
    /// Handed to `AppState` through `summary` and then dropped with the
    /// session like everything else on this type; the session does not
    /// outlive its release (invariant 10). **Never log this.**
    private var retained: RetainedRecording?
    private var apiKey: String = ""

    init(recorder: AudioRecorder, vad: SileroVAD, gemini: GeminiClient, history: HistoryStore) {
        self.recorder = recorder
        self.vad = vad
        self.gemini = gemini
        self.history = history
    }

    /// Captures focused-app metadata, kicks off the AX walk, starts the
    /// recorder and the VAD consumer.
    ///
    /// `instructions` is a frozen snapshot of the global user instruction
    /// + per-category prompt overrides + cached `bundleID → category`
    /// assignments. Captured once on the main actor by AppState and held
    /// for the session's lifetime — that's what keeps the
    /// `User instruction:` / `Category instruction:` cached prefix
    /// sections byte-stable across chunks.
    ///
    /// `dictionary` is a frozen snapshot of the user's personal
    /// dictionary entries (the `User dictionary:` cache-prefix section)
    /// and replacement pairs (applied at paste time in `stop()`). Same
    /// invariant as `instructions`: captured once, never re-read mid-
    /// session, so an edit on the Dictionary tab between press and
    /// release doesn't perturb the in-flight session.
    ///
    /// `userLanguages` is a frozen snapshot of the user's preferred
    /// dictation languages (BCP-47 codes) shipped in the always-present
    /// `User languages:` cache-prefix section. Same invariant — read
    /// once on the main actor as a local constant by AppState before
    /// invoking `start`, never re-read mid-session.
    func start(
        apiKey: String,
        instructions: InstructionsContext,
        dictionary: DictionaryContext,
        userLanguages: [String],
        model: GeminiModel,
        screenCaptureFallbackEnabled: Bool
    ) throws {
        self.apiKey = apiKey
        self.replacementsFrozen = dictionary.replacements
        self.instructionsFrozen = instructions
        self.dictionaryFrozen = dictionary
        self.userLanguagesFrozen = userLanguages
        self.modelFrozen = model
        self.screenCaptureFallbackFrozen = screenCaptureFallbackEnabled
        let frontmost = NSWorkspace.shared.frontmostApplication
        sourceApp = frontmost
        startedAt = Date()

        let appInfo = AppInfo(
            name: frontmost?.localizedName ?? "Unknown",
            bundleID: frontmost?.bundleIdentifier ?? "unknown.bundle"
        )
        // Consumed by the OCR gate below and frozen into `sourcePID` for
        // the cursor-context gate in `stop()`. One read of `NSWorkspace`
        // feeds all three, so the application this session believes it
        // began in cannot drift between them.
        //
        // The paste *destination* is deliberately not frozen here: it is
        // the application the user is in when they stop, which
        // `AppState.finalizeRecording` freezes via
        // `freezePasteDestination(_:)`. See `shouldWithholdPaste`. What is
        // frozen here is the other end of that comparison — where the
        // dictation began, which is what the cursor context describes.
        let pid: pid_t = frontmost?.processIdentifier ?? 0
        sourcePID = pid

        // OCR fallback is opt-in via Screen Recording permission AND the
        // user's in-app "Use screen capture for context" toggle (frozen
        // above). When both hold, run it in parallel with the AX walk; the
        // snapshot is built once all three subtasks settle. When either is
        // off, the OCR limb is not spawned (returns nil immediately).
        let screenRecordingGranted = ScreenRecordingPermission.current() == .granted
        let ocrEnabled = Self.shouldRunOCR(
            fallbackEnabled: screenCaptureFallbackFrozen,
            permissionGranted: screenRecordingGranted,
            pid: pid
        )

        // AX, insertion target, and OCR run as three independent siblings
        // under per-subtask wall-clock caps (no joint deadline). Rationale:
        // the sender's `await contextTask.value` before the first Gemini
        // call serialises chunk dispatch anyway, and the first audio chunk
        // can't arrive until VAD detects a ≥1 s pause OR the user releases
        // the hotkey. So most realistic sessions give OCR plenty of slack
        // before the snapshot is needed downstream. The per-task caps are
        // safety belts against wedged AX / wedged Vision, not perceived-
        // latency budgets.
        let dictionaryEntries = dictionary.activeEntries
        let dictionaryReplacements = dictionary.replacements
        // Bind to a local constant so the detached task captures the
        // value, not `self` (we're @MainActor and the task is detached
        // / non-isolated).
        let userLanguagesLocal = userLanguages
        // Same value as the frozen field `screenCaptureFallbackFrozen`
        // (assigned from this parameter above); aliased to a local so the
        // detached log-tag branch captures the value, not `self`.
        let screenCaptureFallbackLocal = screenCaptureFallbackEnabled
        // Capture `activeBundleID` once on @MainActor (already done above
        // as `frontmost?.bundleIdentifier`) and pass it into the detached
        // AX task. Guardrail against re-introducing an
        // `NSWorkspace.frontmostApplication` read inside the detached
        // context — that would race with app-switch events between
        // session start and the AX walk. Mirrors the existing rationale
        // on `InsertionTarget` (parameter-passed identity vs round-trip
        // through NSWorkspace).
        let activeBundleID = frontmost?.bundleIdentifier
        contextTask = Task.detached(priority: .userInitiated) {
            let t0 = Date()
            async let treeOpt: RedactedAXSnapshot? = Self.withDeadline(ms: 1500) {
                await AccessibilityTree.snapshot(activeBundleID: activeBundleID)
            }
            async let resolvedTarget: InsertionTarget = InsertionTarget.capture()
            async let resolvedOCR: RedactedScreenText? = Self.runOCRIfEnabled(
                enabled: ocrEnabled,
                appInfo: appInfo,
                pid: pid
            )

            // Stored category lookup is a synchronous (and trivially fast)
            // dictionary access on the captured `InstructionsContext`. The
            // search-field AX override runs synchronously here; it reads
            // the system-wide focused element off this detached task, so
            // no actor hops.
            let storedCategory = instructions.cachedCategoryForBundle(appInfo.bundleID) ?? .uncategorized
            let resolvedCategory = CategoryResolver.resolveFromAX(stored: storedCategory)
            let categoryInstruction = instructions.promptForCategory(resolvedCategory)

            let optTree = await treeOpt
            let resolvedTree = optTree ?? RedactedAXSnapshot(apps: [])
            let target = await resolvedTarget
            let ocr = await resolvedOCR
            let axTimedOut = optTree == nil

            let shouldAttachOCR = ocr != nil && !resolvedTree.hasContent(for: appInfo.bundleID)
            let snapshot = ContextSnapshot(
                activeApp: appInfo,
                category: resolvedCategory,
                userInstruction: instructions.userInstruction,
                categoryInstruction: categoryInstruction,
                dictionary: dictionaryEntries,
                replacements: dictionaryReplacements,
                userLanguages: userLanguagesLocal,
                tree: resolvedTree,
                insertionTarget: target,
                screenText: shouldAttachOCR ? ocr : nil
            )

            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let ocrTag: String
            if !ocrEnabled {
                if !screenRecordingGranted {
                    ocrTag = "ocr=off (no-permission)"
                } else if !screenCaptureFallbackLocal {
                    ocrTag = "ocr=off (disabled-by-setting)"
                } else {
                    ocrTag = "ocr=off (no-frontmost-app)"
                }
            } else if ocr == nil {
                ocrTag = "ocr=off (capture-failed-or-timeout)"
            } else if shouldAttachOCR {
                ocrTag = "ocr=on (ax-empty-for-active-app)"
            } else {
                ocrTag = "ocr=off (ax-has-content)"
            }
            let axSuffix = axTimedOut ? " [ax-timeout]" : ""
            Self.log.info(
                "context snapshot: \(ms)ms (tree=\(snapshot.tree.apps.count) apps, before=\(snapshot.insertionTarget.textBefore.count)c after=\(snapshot.insertionTarget.textAfter.count)c category=\(resolvedCategory.rawValue, privacy: .public)) \(ocrTag, privacy: .public)\(axSuffix, privacy: .public)"
            )
            return snapshot
        }

        // Mirror the context task's eventual value into the main-actor
        // cache so the final-chunk dispatch path can consult it without
        // `await`. Cheap — one Task spawn per session.
        if let ctxTask = contextTask {
            Task { @MainActor [weak self] in
                let snap = await ctxTask.value
                self?.cachedContext = snap
            }
        }

        // Silero state is reset as the first line of the VAD consumer
        // (`spawnVADConsumer`) so the actor's serial execution order
        // guarantees reset completes before the first `probability(_:)`
        // call — regardless of how the scheduler interleaves this start
        // path with the recorder's tap thread.
        let stream = try recorder.start()
        spawnVADConsumer(stream: stream)
    }

    /// Most recent N samples from the live recorder. Used by the
    /// recording HUD's spectrum meter — returns an empty array between
    /// sessions or before enough audio has accumulated.
    func recentSamples(count: Int) -> [Float] {
        recorder.recentSamples(count: count)
    }

    /// Best-effort cancel: stop capturing, drop any in-flight sender,
    /// and discard accumulated responses. Pasting is skipped.
    func cancel() async {
        // Set the cancellation latch FIRST — synchronously, before
        // `recorder.stop()` and both `await` points below. A racing
        // `stop()` re-checks `failure` right before it pastes (see
        // `shouldAbortBeforePaste`), so latching here guarantees that a
        // `stop()` suspended in its sender drain-loop observes the
        // cancelled state the moment it resumes and bails without
        // pasting or writing history. Deferring the latch until after
        // the two awaits (the previous ordering) left a window where a
        // resuming `stop()` slipped past its `failure` guard while this
        // task was still suspended on `await senderTask?.value`.
        // Routed through `markFailure` rather than assigning `failure`
        // inline so the retained-audio reset rides the same latch every
        // other terminal path uses (R4 / AE2) — synchronously, before
        // the two awaits below, rather than only after them.
        markFailure(CancellationError())
        recorder.stop()
        senderTask?.cancel()
        vadTask?.cancel()
        await senderTask?.value
        await vadTask?.value
        responses.removeAll()
        pending.removeAll()
        // Reset the companion fields together so a partial-recovery
        // state from a previous cancellation can't leak into the next
        // session via a re-used `RecordingSession` (the class is one-
        // session-per-instance today, but keeping these in lockstep
        // prevents a future refactor from introducing a subtle stale-
        // state bug).
        lastRecoverableError = nil
        // Cancellation is terminal (R4): a cancelled session keeps no
        // audio, so anything a mid-session network blip had already
        // retained is dropped rather than surfacing as a broken history
        // row for a session the user deliberately abandoned. The
        // `markFailure` latch above already did this synchronously;
        // repeating it keeps the companion-field reset in one place and
        // is idempotent.
        retained = nil
    }

    /// Post-session diagnostics — read by `AppState.finalizeRecording`
    /// after `stop()` returns to decide whether to nudge the user with
    /// a "some parts didn't transcribe" HUD. Cheap to compute (loops
    /// over `responses` once); safe to call from the main actor.
    var summary: SessionSummary {
        let counts = Self.chunkCounts(in: responses)
        return SessionSummary(
            failedChunkCount: counts.failed,
            dispatchedChunkCount: counts.dispatched,
            tokens: sessionTokens,
            model: modelFrozen,
            retained: retained,
            pasteWithheldForDestinationChange: pasteWithheldForDestinationChange,
            pasteDestinationAppName: destinationAppName,
            finalizedTranscript: finalizedTranscript
        )
    }

    /// **The single place that turns this session into a `HistoryEntry`.**
    ///
    /// Both rows this session can produce come from here: the pasted row
    /// on the success path, and the broken row `AppState` writes when
    /// `stop()` threw after retaining audio (R6). Keeping one factory is
    /// the point — the app / bundle-id / timestamp / duration fields are
    /// derived from session state the caller does not have, and a second
    /// builder would drift on the first field either of them gains.
    ///
    /// The row's response sequence comes from `responses` rather than
    /// being passed in, so the persisted row and `SessionSummary` can
    /// never disagree about which chunks were lost — one source, and now
    /// a structural one: `HistoryEntry.failedChunkCount` and
    /// `SessionSummary.failedChunkCount` are two readings of the same
    /// per-response data (`chunkCounts(in:)` and the segment reduce count
    /// the identical thing).
    private func makeHistoryEntry(text: String) -> HistoryEntry {
        // Duration = hotkey press → release. `stoppedAt` is captured at
        // the very top of `stop()`, which runs once the user has already
        // released, so it's the best proxy we have for release time.
        // Drives WPM / Time saved on the Home tab.
        let endedAt = stoppedAt ?? Date()
        return HistoryEntry(
            id: UUID(),
            text: text,
            sourceAppName: sourceApp?.localizedName ?? "Unknown",
            sourceBundleID: sourceApp?.bundleIdentifier ?? "",
            timestamp: startedAt ?? Date(),
            durationSeconds: max(0, endedAt.timeIntervalSince(startedAt ?? endedAt)),
            segments: Self.historySegments(from: responses)
        )
    }

    /// This session's responses in the shape a history row stores them
    /// (R1) — a straight one-to-one map, because `ChunkResponse` already
    /// *is* the segment: the positions one Gemini call covered plus the
    /// text it answered with, or `nil` where it failed recoverably.
    ///
    /// Two properties fall out of that map rather than being enforced
    /// here, and both are contracts elsewhere:
    ///
    /// - The **text is raw** (R2). `responses` holds what the model
    ///   returned; `TextInjector.finalizeForInsertion` and
    ///   `TextReplacementEngine.apply` run on the stitched whole, on the
    ///   paste path, and never touch these. The row's `text` mirror is
    ///   post-replacement, the segments are not, and that is the point:
    ///   the user's *current* pairs are applied when a row is displayed
    ///   or copied, by `HistoryText.rendered`. So editing a pair changes
    ///   how rows already on disk read, and a pair whose phrase spans a
    ///   chunk seam still matches — neither of which per-chunk
    ///   substitution at write time could do (KD2).
    /// - A chunk the hallucination gate filtered stays a **text segment
    ///   holding `""`**, not a gap (R19, R27). The gate stores `""` (not
    ///   `nil`) precisely so a call that answered can be told apart from
    ///   one that failed; carrying that distinction onto disk unchanged
    ///   is what keeps such a row out of the broken state.
    ///
    /// Pure and `nonisolated` so both properties can be proved without
    /// standing up a session.
    nonisolated static func historySegments(
        from responses: [ChunkResponse]
    ) -> [HistoryEntry.Segment] {
        responses.map {
            HistoryEntry.Segment(chunkIndices: $0.chunkIndices, text: $0.text)
        }
    }

    /// The history row for a session whose `stop()` threw after every
    /// dispatched chunk failed recoverably (R6, KTD3).
    ///
    /// **The text is empty as a mirror, and nothing reads its emptiness
    /// any more.** It used to carry two facts on its own. It no longer
    /// decides what the row *shows*: the markers used to be synthesised
    /// from `failedChunkCount` because the stored string carried none,
    /// and `HistoryText.assemble` now renders one per gap segment
    /// straight from the sequence this factory already stores — the two
    /// encodings of a gap have collapsed into one (AE2). And it no longer
    /// carries "lifetime stats never counted this session": that is
    /// `HistoryEntry.isEntirelyLost` now (R18, KTD11), read off the
    /// sequence rather than off a string that boundary normalisation and
    /// replacement pairs both run over. `text: ""` stays because KTD10
    /// wants the legacy mirror written on every row.
    ///
    /// **What this factory owes that predicate is the session-side half
    /// of its argument, and it is `stop()`'s, not this method's:** a
    /// session that produced responses and lost every one of them
    /// *throws* — `!responses.isEmpty && responses.allSatisfy { $0.text
    /// == nil }`. Quote that guard in full when you check it: the
    /// `!responses.isEmpty` term looks like a hole, because `allSatisfy`
    /// is vacuously true over nothing, and it is not one — a session
    /// with no responses at all stitches to `""` and throws `.noSpeech`
    /// at the `guard !stitched.isEmpty` below it. So on either shape the
    /// success arm — the one path that reaches `StatsStore.record` —
    /// can never produce an all-gap sequence, and this factory is the
    /// only producer of one. Keep those two in step, and note the
    /// second one carries the empty case alone: a change that let an
    /// empty-response session past it would need the
    /// `HistoryEntry(segments:)` normalisation to keep
    /// `isEntirelyLost` false. A change that let a fully-failed session
    /// reach the success arm, or that seeded this row with anything other
    /// than gaps, would silently make every recovered session
    /// double-count.
    ///
    /// The row carries the session's response sequence, which for this
    /// factory is **all gaps** — every dispatched chunk failed, so every
    /// `ChunkResponse` has `text == nil`. That is what makes the row's
    /// brokenness structural (R3) rather than a count, and it is what
    /// `isEntirelyLost` reads.
    ///
    /// Only meaningful once `stop()` has thrown; calling it on a live
    /// session dates the row from `Date()` instead of release time.
    /// `AppState.finalizeRecording`'s catch arm is the only caller.
    func brokenHistoryEntry() -> HistoryEntry {
        makeHistoryEntry(text: "")
    }

    /// Fold one batch's retained payload into the session accumulator.
    ///
    /// The first payload's context and model win. Both are frozen at
    /// session start, so every batch that can produce a payload in the
    /// same session carries the same pair — except the quick-release
    /// fallback, where a batch that ran before `contextTask` settled
    /// would carry `ContextSnapshot.minimal`. Keeping the first payload's
    /// context therefore keeps the richest snapshot the session ever
    /// actually sent, which is the one a retry wants (R3, R11).
    ///
    /// Chunks are re-sorted on merge rather than trusted to arrive in
    /// order, so `RetainedRecording`'s ascending-order contract holds
    /// without depending on the sender's drain order staying serial.
    private func accumulateRetained(_ payload: RetainedRecording?) {
        retained = Self.mergeRetained(existing: retained, incoming: payload)
    }

    /// The merge rule itself, as a pure function so the two properties
    /// U6 depends on can be pinned without driving a session: the result
    /// is in ascending chunk order whatever order the batches arrived
    /// in, and the first payload's context/model survive. Same seam
    /// shape as `retainedPayload` / `shouldUseLitePath`; pinned by
    /// `RetainedRecordingTests`.
    nonisolated static func mergeRetained(
        existing: RetainedRecording?,
        incoming: RetainedRecording?
    ) -> RetainedRecording? {
        guard let incoming else { return existing }
        guard let existing else { return incoming }
        return RetainedRecording(
            chunks: (existing.chunks + incoming.chunks).sorted { $0.idx < $1.idx },
            context: existing.context,
            model: existing.model
        )
    }

    /// Freeze the application this session's transcript is aimed at.
    ///
    /// **Called from `AppState.finalizeRecording`, synchronously with the
    /// user's stop action and before any `await` on that path.** That
    /// ordering is the contract, not an implementation detail: every
    /// suspension between the stop and this read is a window in which the
    /// frontmost application can change, and a destination captured after
    /// one of them is no longer the place the user was looking at when
    /// they stopped — which is exactly the identity the guard is supposed
    /// to defend. Reading it inside `stop()` would already be too late:
    /// `stop()` runs from a `Task` the release handler schedules, so the
    /// main actor can service an app-switch in between.
    ///
    /// Freezing here rather than at session start is the 2026-08-11
    /// product ruling — see `shouldWithholdPaste` for what it fixes (a
    /// hands-free locked dictation that starts in one application and
    /// ends in another) and for what it deliberately leaves in force.
    ///
    /// Never called → `0` / `nil`, which the gate reads as unknown and
    /// pastes through, matching the pre-guard behaviour.
    ///
    /// **Returns the frozen name so the transcribing HUD can label itself
    /// from the same statement that arms the gate.** The HUD tells the
    /// user where the transcript is about to land, so it has to name the
    /// destination, not the application the session began in — under the
    /// 2026-08-11 ruling those differ for every hands-free dictation that
    /// walks somewhere else, and a label naming the wrong one is the same
    /// class of false statement as the "Pasted with gaps" notice that used
    /// to advise re-dictating a part that was never pasted. Returning it
    /// rather than exposing a second accessor is what makes the two
    /// impossible to drift: there is one read of `NSWorkspace`, and the
    /// label and the comparison are the same value by construction.
    func freezePasteDestination(_ app: NSRunningApplication?) -> String? {
        destinationPID = app?.processIdentifier ?? 0
        destinationAppName = app?.localizedName
        return destinationAppName
    }

    /// Stop audio capture immediately, without draining or sending.
    /// Called by `AppState.finalizeRecording` at hotkey-release so a
    /// `.mute` music-interruption can be lifted the instant the mic
    /// goes quiet — rather than a few ms later when `stop()`'s
    /// `recorder.stop()` would otherwise run, a window in which
    /// newly-unmuted speaker audio could bleed into the final chunk's
    /// tail. `AudioRecorder.stop()` is idempotent, so the `recorder.stop()`
    /// inside `stop()` below is a harmless no-op afterwards; the PCM ring
    /// is untouched, so `emitFinalChunkIfAny` still harvests the full tail.
    func stopCapture() {
        recorder.stop()
    }

    /// Stops capture, awaits the sender draining the pending queue,
    /// pastes the concatenated transcript, and writes a history entry.
    func stop() async throws -> HistoryEntry {
        let t0 = Date()
        // Every `throw` below leaves `AppState` holding this session, and
        // the broken-row path (R6) needs release time to date the row.
        // Record it before the first await rather than at each throw site.
        stoppedAt = t0
        recorder.stop()                 // finishes the AsyncStream
        await vadTask?.value            // VAD consumer drains and exits
        let tStream = Date()

        // Final chunk: whatever the pause detector still has, plus the tail
        // PCM up to "now" in the recorder's buffer. This goes into
        // `pending`; if there are still earlier chunks queued (because the
        // sender was busy on a slow Gemini call), they get drained
        // together as one batched request.
        await emitFinalChunkIfAny()

        // Drain the sender. A single `await senderTask?.value` would
        // capture whichever Task ref is current at evaluation time —
        // but `markSenderFinished` may respawn into a fresh Task while
        // we're suspended on the dying one (the same race the respawn
        // fix in `markSenderFinished` already half-closes). Loop until
        // the field is genuinely nil so every respawn is awaited.
        while let task = senderTask {
            await task.value
        }
        let tGemini = Date()

        if let err = failure {
            throw err
        }

        // If every dispatched response failed (text == nil), there's
        // nothing user-meaningful to paste — only a string of `[…]`
        // markers. Surface the real cause (offline / 5xx / decoding /
        // …) so the AppState error catalog can render the right Error
        // HUD instead of "pasted N gaps". `lastRecoverableError` was
        // set every time we appended a `text: nil` response; falling
        // back to `.noSpeech` is defensive (a successful append should
        // always set the field, but the guard keeps `stop()` total).
        if !responses.isEmpty && responses.allSatisfy({ $0.text == nil }) {
            throw lastRecoverableError ?? SessionError.noSpeech
        }

        // The model is supposed to emit a leading space when its chunk
        // starts a new word after the prior chunk ended non-whitespace,
        // but with `thinkingLevel: .minimal` it occasionally forgets and
        // we get seams like `"What's up.I'm fine."`. `stitchChunks` is a
        // deterministic conservative fix: it inserts a single space
        // between a sentence-internal terminal (`.`, `!`, `?`, `,`, `:`,
        // `;`, `…`) and a word-starter on the next chunk. Trim outer
        // whitespace so a fully blank session returns "".
        //
        // Failed chunks contribute `failureMarker` ("[…]") in place
        // of their text — the user sees a visible gap surrounded by
        // intact transcription and can re-dictate just that piece.
        //
        // Assembled through `HistoryText.assemble` over this session's own
        // segments rather than by re-spelling the map/stitch/trim here.
        // The two used to be independent copies of one rule feeding two
        // user-visible surfaces — what gets pasted, and what the history
        // row shows — so a change to the join or the trim in one of them
        // would have surfaced as "the row I re-open doesn't match what was
        // pasted", which is the class of bug this plan exists to remove.
        // `historySegments(from:)` is the same conversion `makeHistoryEntry`
        // uses below, and every `ChunkResponse` carries at least one index
        // (`processBatch` returns early on an empty batch), so the
        // `Segment` precondition this now reaches earlier cannot trip.
        let stitched = HistoryText.assemble(Self.historySegments(from: responses))
        guard !stitched.isEmpty else {
            throw SessionError.noSpeech
        }

        // Source of truth for boundary handling is the client — we
        // always have both sides of the cursor; the model only sees
        // a per-chunk view. `finalizeForInsertion` adds the leading
        // space when needed and strips a stranded trailing terminal
        // punct when the cursor is mid-text.
        //
        // Read from the main-actor cache, NOT from `contextTask.value`.
        // The sender already handled "context might not be ready" for
        // the final batch; mirroring that here means a quick-release
        // session doesn't sit blocked on AX / OCR safety caps just so
        // we can compute boundary punctuation. Empty target → benign
        // (no leading-space insertion, no trailing-punct strip).
        // Default to `.unknown` (not `.empty`) when no context was ever
        // computed — same reasoning as `InsertionTarget.unknown` itself:
        // we genuinely don't know what's around the cursor, so let
        // `finalizeForInsertion` use its defensive leading-space path.
        //
        // And take that same `.unknown` path when the context was read in
        // a different application than the one we're pasting into — the
        // hands-free flow, where the user dictates in A, walks to B and
        // stops there. The text around A's cursor says nothing about B's
        // document, and acting on it would silently delete a period the
        // user dictated. `shouldDiscardInsertionContext` carries the
        // reasoning, including why this is a different question from the
        // paste gate further down.
        let target: InsertionTarget
        if Self.shouldDiscardInsertionContext(
            sourcePID: sourcePID,
            destinationPID: destinationPID
        ) {
            // Fact only — no transcript, no application names, no cursor
            // text. `.info`: this is a formatting nuance on a session that
            // still pastes, not an outcome the user would report.
            Self.log.info("insertion context discarded: the session started in a different process than the one it is pasting into")
            target = .unknown
        } else {
            target = cachedContext?.insertionTarget ?? .unknown
        }
        let finalRaw = TextInjector.finalizeForInsertion(
            stitched,
            textBeforeCursor: target.textBefore,
            textAfterCursor: target.textAfter,
            contextKnown: target.isKnown
        )
        // User-defined word replacements ("то есть" → "т.е."). Applied
        // after boundary normalisation so spacing/punctuation rules
        // operate on the un-substituted text first — replacements only
        // touch interior words, never the cursor-boundary glue. Source
        // of truth for the pair list is `replacementsFrozen`, captured
        // at session start; that way a Dictionary-tab edit during a
        // session doesn't perturb the result.
        let final = TextReplacementEngine.apply(finalRaw, replacements: replacementsFrozen)
        // R15. This string used to survive as `HistoryEntry.text` and be
        // read back from there by the dictionary harvester; the row now
        // stores raw segments, so the harvester's input has to travel on
        // its own channel (KTD7's defaulted `SessionSummary` field).
        // Recorded here rather than after the paste gate so it holds on
        // the withheld arm too — nothing was pasted there, but this is
        // still what the user said.
        finalizedTranscript = final

        // Re-check the cancellation latch immediately before committing
        // the paste. `cancel()` installs `failure` as its first statement,
        // but it may have fired while we were suspended in the sender
        // drain-loop above — after the early `if let err = failure` guard
        // near the top of `stop()`. Everything between that guard and this
        // point runs synchronously on the main actor, so this is the last
        // safe place to bail: without it, a cancel landing during the
        // drain would still paste and write history. Throwing here routes
        // into `finalizeRecording`'s `catch is CancellationError` arm
        // (no paste, no history, no double sleep-assertion release). A
        // cancel that lands *after* `TextInjector.paste` begins is
        // genuinely late and acceptable — the text is already in flight.
        if Self.shouldAbortBeforePaste(
            failureIsSet: failure != nil,
            taskIsCancelled: Task.isCancelled
        ) {
            throw failure ?? CancellationError()
        }

        // Last synchronous instruction before the paste (KTD5). Everything
        // from the cancellation guard above to here runs without suspending
        // on the main actor, and `TextInjector.paste` posts ⌘V before its
        // own first suspension point, so this is the freshest reading of
        // the frontmost process that can still be acted on. Compared
        // against the destination frozen at the *stop* by
        // `freezePasteDestination(_:)`, so what withholds is the user
        // moving away during transcription — not moving around while
        // still recording. Why a mismatch skips only the paste — and must
        // not be folded into the throwing gate above — is on
        // `shouldWithholdPaste`'s doc-comment (R24, KTD6).
        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        pasteWithheldForDestinationChange = Self.shouldWithholdPaste(
            destinationPID: destinationPID,
            currentPID: currentPID
        )
        if pasteWithheldForDestinationChange {
            // Fact only — never the transcript, and never the app's name
            // or bundle id: this line is about where the user went.
            //
            // `.notice` rather than `.info`: this is the one session
            // outcome that ends in *nothing appearing* for the user, so
            // "my dictation vanished" has to be answerable from the log
            // store after the fact, and `.info` is not persisted there.
            // Not `.warning` — the guard doing its job is correct
            // behaviour, not a degradation the app caused.
            Self.log.notice("paste withheld: destination process changed after the user stopped recording")
        } else {
            await TextInjector.paste(final)
        }
        let tPaste = Date()

        let entry = makeHistoryEntry(text: final)
        await history.append(entry)

        // `paste=` names a paste. On the withheld arm there wasn't one, so
        // report that rather than timing the guard and passing it off as
        // paste latency. Explicitly `.public`: a non-literal String
        // interpolation is redacted by default, and this value is a
        // fixed word or a duration, never user content.
        let pasteField = pasteWithheldForDestinationChange
            ? "withheld"
            : "\(Int(tPaste.timeIntervalSince(tGemini)*1000))ms"
        Self.log.info(
            "session timing: drain=\(Int(tStream.timeIntervalSince(t0)*1000))ms gemini=\(Int(tGemini.timeIntervalSince(tStream)*1000))ms paste=\(pasteField, privacy: .public) total=\(Int(Date().timeIntervalSince(t0)*1000))ms chunks=\(self.chunkCounter)"
        )
        return entry
    }

    // MARK: - VAD consumer

    private func spawnVADConsumer(stream: AsyncStream<[Float]>) {
        let vad = self.vad
        // Detached so VAD inference doesn't block @MainActor; cross back
        // for `enqueueChunk` and `takePauseDetector`.
        vadTask = Task.detached(priority: .userInitiated) { [weak self] in
            // First message to the VAD actor — clears hiddenState /
            // cellState / carriedContext left over from the previous
            // session. Doing it here (rather than fire-and-forget from
            // `start()`) makes the ordering against the first
            // `probability(_:)` call deterministic: both go through the
            // actor's serial executor in submission order.
            try? await vad.reset()
            var detector = PauseDetector()
            var frameStart = 0
            // Each VAD window covers 256 ms of audio, so a single
            // `probability(_:)` call must finish in well under 256 ms to
            // keep up with realtime. When ANE is contended (other ML
            // workloads — local LLMs, photo analysis, Final Cut) inference
            // can spike to 50–200 ms. Audio keeps flowing into the
            // AsyncStream's buffer, so nothing breaks, but the user feels
            // it as "paste took 8 seconds instead of 2 after release".
            // Counting slow inferences here lets us connect those reports
            // to ANE contention without guessing. `ContinuousClock` is
            // both monotonic (immune to NTP clock-skew during a 3-min
            // session) and cheaper to read than `Date()`.
            var slowInferences = 0
            var totalInferences = 0
            for await frame in stream {
                // Stop submitting to the app-shared `SileroVAD` actor the
                // moment this session is cancelled. Without this, a
                // cancelled session A keeps feeding `vad.probability(...)`
                // to the shared actor while session B's `vad.reset()`
                // interleaves — corrupting B's hidden/cell state (R3).
                // `cancel()` calls `vadTask?.cancel()`, so the flag is set
                // by the time the next frame arrives.
                if Task.isCancelled { break }
                let frameEnd = frameStart + frame.count
                let inferenceStart = ContinuousClock.now
                let prob: Float
                do {
                    prob = try await vad.probability(for: frame)
                } catch {
                    Self.log.error("vad inference failed: \(error.localizedDescription, privacy: .public)")
                    frameStart = frameEnd
                    continue
                }
                let inferenceDuration = ContinuousClock.now - inferenceStart
                totalInferences += 1
                if inferenceDuration > Self.slowInferenceThreshold {
                    slowInferences += 1
                }

                if let chunk = detector.observe(
                    probability: prob,
                    frameStart: frameStart,
                    frameEnd: frameEnd
                ) {
                    await self?.enqueueChunk(start: chunk.start, end: chunk.end, isFinal: false)
                }
                frameStart = frameEnd
            }
            if slowInferences > 0 {
                Self.log.warning(
                    "VAD lag: \(slowInferences)/\(totalInferences) inferences > \(Self.slowInferenceThreshold) (ANE likely contended)"
                )
            }
            // Stream finished. Hand the in-progress chunk over to the
            // session so it can call finalize() with the up-to-date sample
            // count.
            await self?.takePauseDetector(detector)
        }
    }

    /// Stash the VAD consumer's pause detector at stream end so `stop()`
    /// can finalize it on the main actor.
    private var pendingDetector: PauseDetector?

    private func takePauseDetector(_ d: PauseDetector) {
        self.pendingDetector = d
    }

    private func emitFinalChunkIfAny() async {
        var detector = pendingDetector ?? PauseDetector()
        let total = recorder.totalSamples
        guard let chunk = detector.finalize(currentEnd: total) else {
            return
        }
        pendingDetector = detector
        enqueueChunk(start: chunk.start, end: chunk.end, isFinal: true)
    }

    // MARK: - Chunk dispatch

    /// Append a new chunk to `pending` and ensure the sender is running.
    /// Cheap and non-blocking — actual encoding + Gemini happens in the
    /// detached sender task.
    private func enqueueChunk(start: Int, end: Int, isFinal: Bool) {
        guard end > start else { return }
        chunkCounter += 1
        pending.append(PendingChunk(
            index: chunkCounter,
            pcmStart: start,
            pcmEnd: end,
            isFinal: isFinal
        ))
        ensureSenderRunning()
    }

    /// Spawn the sender task if it isn't already alive. The sender runs
    /// until `pending` is empty, then exits and clears `senderTask`. The
    /// next `enqueueChunk` will respawn it. This pattern lets us treat
    /// "what's pending right now" as the natural batch boundary —
    /// whatever has piled up while the previous request was in flight
    /// goes out in one batched call.
    private func ensureSenderRunning() {
        guard senderTask == nil else { return }
        senderTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runSender()
            await self?.markSenderFinished()
        }
    }

    private func markSenderFinished() {
        senderTask = nil
        // Close the respawn race: a chunk enqueued in the window between
        // `runSender` returning and this method running on the main actor
        // would otherwise hit `ensureSenderRunning`'s `senderTask != nil`
        // guard and silently never get drained — manifesting as a
        // `.noSpeech` after a normal-looking session. `stop()`'s
        // `emitFinalChunkIfAny()` is the worst case because it runs
        // before `await senderTask?.value`, so the orphan chunk just
        // sits in `pending` forever. `failure == nil` keeps us from
        // pointlessly respawning after a `markFailure` exit.
        if !pending.isEmpty && failure == nil {
            ensureSenderRunning()
        }
    }

    /// Atomically take the entire pending queue. Returning [] tells the
    /// sender it's done.
    private func takeAllPending() -> [PendingChunk] {
        let copy = pending
        pending.removeAll(keepingCapacity: true)
        return copy
    }

    private var didFail: Bool { failure != nil }

    private func runSender() async {
        while true {
            if didFail { return }
            let batch = takeAllPending()
            if batch.isEmpty { return }
            await processBatch(batch)
        }
    }

    /// Encode every chunk in `batch`, then issue either a single or
    /// batched Gemini request. One `ChunkResponse` is appended per
    /// request — we don't try to split a batched response back into
    /// per-chunk strings.
    ///
    /// Partial recovery: when a batched call fails with a recoverable
    /// error (network, 5xx, etc — see `isTerminal(_:)`), we split it
    /// into N single-chunk `transcribe` calls. Each independent call
    /// either succeeds (text appended) or fails (`nil` text →
    /// `failureMarker` at stitch time). The session only aborts on
    /// terminal errors (auth, blocked, encode); recoverable failures
    /// leave gaps and continue draining.
    private func processBatch(_ batch: [PendingChunk]) async {
        let recorder = self.recorder
        let gemini = self.gemini

        // Encode + drop sub-150 ms chunks (Silero false starts on breath
        // / lip clicks would otherwise produce empty Gemini calls).
        // `samples` carries the PCM sample count for the downstream
        // `HallucinationLengthGate` (audio duration = samples / 16 kHz).
        //
        // Encoding runs BEFORE the lite-path discriminator below so the
        // gate can key on the post-drop chunk count (`encoded.count`):
        // the lite dispatch ships a single audio, so a batch that encodes
        // to ≥2 chunks must never take that path (R1).
        //
        // `ChunkBuilder.encodeAAC` round-trips PCM through a temp m4a file
        // (write + flush + read-back). That blocking file IO must not run
        // on the @MainActor — it would hitch the menu-bar UI / spectrum
        // meter once per chunk. Offload each encode onto a detached task
        // and `await` its `Data` result; only the PCM read (`recorder.samples`)
        // and the `encoded` bookkeeping + `markFailure` stay on the main
        // actor. `pcm` is a `Sendable [Float]` captured by value, so the
        // detached closure is race-free (R17 / KTD-8). Order is preserved:
        // each encode is awaited in turn and appended in loop order, so
        // `encoded.count` still feeds the gate unchanged.
        var encoded: [EncodedChunk] = []
        for pc in batch {
            let pcm = recorder.samples(from: pc.pcmStart, to: pc.pcmEnd)
            if pcm.count < 2_400 {
                Self.log.info("chunk_\(pc.index) too short (\(pcm.count) samples) — skipping")
                continue
            }
            do {
                let aac = try await Task.detached { try ChunkBuilder.encodeAAC(pcm) }.value
                encoded.append(EncodedChunk(idx: pc.index, isFinal: pc.isFinal, audio: aac, samples: pcm.count))
            } catch {
                Self.log.error("encode chunk_\(pc.index) failed: \(error.localizedDescription, privacy: .public)")
                markFailure(error)
                return
            }
        }
        if encoded.isEmpty { return }

        let containsFinal = encoded.contains { $0.isFinal }
        let label = encoded.count == 1
            ? "chunk_\(encoded[0].idx)"
            : "chunks_\(encoded.first?.idx ?? -1)..\(encoded.last?.idx ?? -1)"

        // Batches containing the **final** chunk come from a user release.
        // For those we don't wait on the context task — if AX / OCR
        // happened to finish already we use the cached value; otherwise
        // we fall back to a minimal snapshot. Rationale: a fast tap-and-
        // release session shouldn't sit blocked behind the 2.5 s OCR cap.
        // Mid-session batches (pause-triggered) keep the awaiting path
        // since the user is clearly speaking and we have time to spare.
        //
        // Additionally: when the final batch is short (<2 s) AND this is
        // the only batch of the session AND it encoded to a single chunk,
        // route through the lite path — a synchronous trimmed snapshot
        // (no AX, no OCR) + a smaller system prompt at the Gemini layer.
        // Reduces prompt by ~70% on single-word sessions where context
        // never helps anyway.
        let isFinalBatch = batch.contains { $0.isFinal }
        let totalBatchSamples = batch.reduce(0) { $0 + ($1.pcmEnd - $1.pcmStart) }
        // Lite path requires no prior transcript text to ship in the
        // `Prior chunks (this session):` section. Recoverable failures
        // (markers) don't produce text, so they don't disqualify the
        // lite path — if every prior call failed, the prompt's prior
        // section would be `(none yet)` anyway and the trimmed shape
        // still fits. Use `currentPriors().count` rather than
        // `responses.count` for this reason. `batchChunkCount` is the
        // post-encode chunk count so a short-but-multi-chunk final batch
        // stays on the batched path (see invariant 11 / R1).
        let isShortFinalOnly = Self.shouldUseLitePath(
            isFinalBatch: isFinalBatch,
            priorTranscriptCount: currentPriors().count,
            totalBatchSamples: totalBatchSamples,
            batchChunkCount: encoded.count
        )
        guard let snap = await snapshotForChunk(
            allowMinimalFallback: isFinalBatch,
            forceLite: isShortFinalOnly
        ) else { return }

        // Chunk indices whose Gemini call failed in the class
        // `shouldRetain(_:)` admits — collected across this batch's
        // failure arms and turned into a retained payload below (R2).
        // Stays empty for a batch that fully succeeded and for one the
        // hallucination gate dropped: the gate fires on a call that
        // *answered*, which is not a failure and must retain nothing.
        var retainableFailures: Set<Int> = []

        do {
            let result: (text: String, tokens: TokenUsage)
            if snap.isLite {
                // Lite path is reachable only via the discriminator in
                // `processBatch`, which gates on `batchChunkCount == 1`
                // — so `encoded.count == 1` is enforced (not merely
                // implied by the <2 s threshold) and `containsFinal` is
                // true (final-only batch, no successful priors). Shipping
                // `encoded[0]` therefore covers the whole batch (R1).
                let one = encoded[0]
                result = try await gemini.transcribeShortWithUsage(
                    audio: one.audio,
                    mimeType: "audio/mp4",
                    context: snap.context,
                    apiKey: snap.apiKey,
                    model: snap.model
                )
            } else if encoded.count == 1 {
                let one = encoded[0]
                result = try await gemini.transcribeWithUsage(
                    audio: one.audio,
                    mimeType: "audio/mp4",
                    context: snap.context,
                    priorTranscripts: snap.priors,
                    chunkIndex: one.idx,
                    isFinal: one.isFinal,
                    apiKey: snap.apiKey,
                    model: snap.model
                )
            } else {
                Self.log.info("batching \(encoded.count) chunks (\(encoded.first?.idx ?? -1)..\(encoded.last?.idx ?? -1)) final=\(containsFinal)")
                result = try await gemini.transcribeBatchWithUsage(
                    audios: encoded.map { ($0.audio, "audio/mp4") },
                    context: snap.context,
                    priorTranscripts: snap.priors,
                    chunkIndices: encoded.map { $0.idx },
                    isFinal: containsFinal,
                    apiKey: snap.apiKey,
                    model: snap.model
                )
            }
            sessionTokens = sessionTokens + result.tokens
            // Post-response length-proportional gate. Drops Gemini
            // conversational-fallback hallucinations on short low-info
            // audio (e.g. 1 s of degraded BT-HFP mic → "Can you help me
            // with this?"). See `HallucinationLengthGate` doc-comment
            // for rationale. AND-mode keeps borderline legitimate
            // dense utterances (Russian "Привет, как дела?" at 1 s)
            // alive. Sample rate is the recorder's fixed 16 kHz output.
            let batchSamples = encoded.reduce(0) { $0 + $1.samples }
            let durationSec = Double(batchSamples) / AudioRecorder.outputSampleRate
            let filteredText = HallucinationLengthGate.apply(
                to: result.text,
                durationSeconds: durationSec
            )
            if filteredText != result.text {
                Self.log.warning("\(label) hallucination gate fired — dropped \(result.text.count, privacy: .public) chars over \(durationSec, privacy: .public) s")
            }
            responses.append(ChunkResponse(
                chunkIndices: encoded.map { $0.idx },
                text: filteredText
            ))
        } catch {
            if Self.isTerminal(error) {
                Self.log.error("\(label) failed terminally: \(error.localizedDescription, privacy: .public)")
                markFailure(error)
                discardProcessedPCM(batch: batch, containsFinal: containsFinal)
                return
            }

            // Recoverable failure. For a batched call, split-retry per
            // chunk — each independent call has its own retry budget in
            // `GeminiClient` and one bad chunk shouldn't poison the
            // others. For a single-chunk call, there's nothing to
            // split; record a marker. The lite path falls here too —
            // it's single-chunk by construction, so the user gets a
            // `[…]` for a 1–2 word session, which `stop()`'s "all
            // chunks failed" branch then translates into the proper
            // Error HUD.
            if encoded.count > 1 {
                Self.log.warning("\(label) failed (\(error.localizedDescription, privacy: .public)) — splitting into \(encoded.count) single calls")
                retainableFailures = await splitRetry(
                    encoded: encoded,
                    snap: snap,
                    batchFailureWasNetwork: Self.isNetworkClass(error)
                )
            } else {
                let c = encoded[0]
                Self.log.error("\(label) failed: \(error.localizedDescription, privacy: .public) — inserting marker")
                recordRecoverableFailure(error: error, indices: [c.idx])
                if Self.shouldRetain(error) { retainableFailures.insert(c.idx) }
            }
        }

        // Keep the failed chunks' encoded audio instead of letting it go
        // out of scope with `encoded` (R2, R3) — the one thing this
        // function stops releasing. PCM is untouched either way: the
        // retained form is the AAC blob, so `discardProcessedPCM` below
        // runs on its existing schedule.
        //
        // Skipped once a terminal error has latched — which `splitRetry`
        // can do after it has already collected recoverable indices. That
        // session aborts, and R4 holds terminal failures to retaining
        // nothing. This guard covers only THIS batch; the session-wide
        // half (dropping what an earlier batch retained) lives in
        // `markFailure`, which is the latch every terminal path shares.
        //
        // The emptiness term is not just an optimisation: without it
        // `encoded.map(\.retainable)` materialises a chunk struct for
        // every chunk of every batch — including the ordinary successful
        // one — only for `retainedPayload` to discard it. Keeping the
        // success path allocation-free is what makes the `retained`
        // field's "a session that never loses a chunk allocates nothing
        // here" literally true.
        if !didFail && !retainableFailures.isEmpty {
            accumulateRetained(Self.retainedPayload(
                inBatch: encoded.map(\.retainable),
                failedChunkIndices: retainableFailures,
                context: snap.context,
                model: snap.model
            ))
        }

        discardProcessedPCM(batch: batch, containsFinal: containsFinal)
    }

    /// Inter-iteration backoff for `splitRetry` after a recoverable
    /// failure. The batched call has already exhausted its
    /// HTTP-class retries inside `GeminiClient.sendRequest` (3 attempts
    /// under 429), and now each split sub-call also has its own
    /// retry budget. Without a gap, a 6-chunk batch under sustained
    /// 429 / 5xx fires up to N×3 requests back-to-back — amplifying
    /// the very condition we're trying to recover from. 250 ms isn't
    /// a rate-limit-aware exponential backoff; it just caps the burst
    /// rate at 4 sub-calls per second so we surface a few markers and
    /// fail visibly rather than burning the user's quota.
    nonisolated static let splitRetryBackoff: Duration = .milliseconds(250)

    /// Fallback for a batched Gemini call that failed recoverably:
    /// re-issue each chunk as an independent `transcribe`. Successful
    /// chunks become priors for the next ones (network blip recovered
    /// → chunk 3 sees chunk 2's text). A terminal error in any
    /// sub-call aborts the rest of the split — the session-level
    /// `markFailure` is already set; `stop()` will rethrow.
    ///
    /// Returns the chunk indices whose failure falls in the retainable
    /// class (R2) — this is the common landing site for a long offline
    /// session, since a multi-chunk batch always splits before any
    /// marker is recorded. The caller turns the set into a payload;
    /// collecting rather than retaining in place keeps the derivation a
    /// pure function. An early return on a terminal error still yields
    /// whatever was collected first, and the caller drops it — see the
    /// `didFail` guard at the `processBatch` call site.
    ///
    /// `batchFailureWasNetwork` carries whether the batched call that sent
    /// us here failed in the network class; combined with the first split
    /// chunk's own verdict it bounds the run — see the abandon arm below.
    private func splitRetry(
        encoded: [EncodedChunk],
        snap: ChunkSnapshot,
        batchFailureWasNetwork: Bool
    ) async -> Set<Int> {
        var retainable: Set<Int> = []
        for (offset, chunk) in encoded.enumerated() {
            if didFail { return retainable }
            // Re-query priors each iteration so a chunk that just
            // succeeded becomes context for the next one.
            let priors = currentPriors()
            // Timed so the abandon arm can tell a 30 s timeout from a
            // ~0 ms reachability short-circuit — see
            // `abandonMinChunkFailureLatency`.
            let dispatchedAt = ContinuousClock.now
            do {
                let result = try await gemini.transcribeWithUsage(
                    audio: chunk.audio,
                    mimeType: "audio/mp4",
                    context: snap.context,
                    priorTranscripts: priors,
                    chunkIndex: chunk.idx,
                    isFinal: chunk.isFinal,
                    apiKey: snap.apiKey,
                    model: snap.model
                )
                sessionTokens = sessionTokens + result.tokens
                // Same gate as the primary path — per-chunk duration
                // here since each split sub-call carries one chunk.
                let durationSec = Double(chunk.samples) / AudioRecorder.outputSampleRate
                let filteredText = HallucinationLengthGate.apply(
                    to: result.text,
                    durationSeconds: durationSec
                )
                if filteredText != result.text {
                    Self.log.warning("chunk_\(chunk.idx) split-retry: hallucination gate fired — dropped \(result.text.count, privacy: .public) chars over \(durationSec, privacy: .public) s")
                }
                responses.append(ChunkResponse(
                    chunkIndices: [chunk.idx],
                    text: filteredText
                ))
            } catch {
                if Self.isTerminal(error) {
                    Self.log.error("chunk_\(chunk.idx) split-retry failed terminally: \(error.localizedDescription, privacy: .public)")
                    markFailure(error)
                    return retainable
                }
                Self.log.error("chunk_\(chunk.idx) split-retry failed: \(error.localizedDescription, privacy: .public) — inserting marker")
                recordRecoverableFailure(error: error, indices: [chunk.idx])
                if Self.shouldRetain(error) { retainable.insert(chunk.idx) }

                // Transport is down, we have two independent observations
                // of it — the batched call and this standalone one — and
                // this one cost real time rather than being answered from
                // the reachability cache. Every remaining chunk is a
                // guaranteed 30 s round-trip ending in the same error,
                // 250 ms apart, so account for them here instead of
                // spending minutes proving it. Each still gets its marker
                // AND its audio retained, which is what keeps an
                // undispatched chunk indistinguishable from this one — see
                // `abandonedAccounting`.
                if Self.shouldAbandonSplitRetry(
                    batchFailureWasNetwork: batchFailureWasNetwork,
                    chunkOffset: offset,
                    chunkFailureWasNetwork: Self.isNetworkClass(error),
                    chunkFailureLatency: ContinuousClock.now - dispatchedAt
                ) {
                    let acct = Self.abandonedAccounting(
                        undispatched: encoded.dropFirst(offset + 1).map(\.retainable),
                        error: error
                    )
                    // Unreachable by construction — `processBatch` only
                    // splits an `encoded.count > 1` batch and this arm only
                    // fires at offset 0, so `dropFirst(1)` always leaves at
                    // least one chunk. Kept as insurance against a second
                    // call site: without it an empty set would still log
                    // "0 chunk(s) marked", which reads like a bug report.
                    guard !acct.markerChunkIndices.isEmpty else { return retainable }
                    Self.log.warning("split-retry abandoned after chunk_\(chunk.idx): no network — \(acct.markerChunkIndices.count) chunk(s) marked without dispatch, audio retained")
                    for idx in acct.markerChunkIndices {
                        recordRecoverableFailure(error: error, indices: [idx])
                    }
                    retainable.formUnion(acct.retainable)
                    return retainable
                }

                // Brief pause before the next sub-call so we don't
                // burst-fire against a rate-limited API. Skip the
                // sleep when we're already on the last chunk —
                // nothing comes after.
                if offset < encoded.count - 1 {
                    try? await Task.sleep(for: Self.splitRetryBackoff)
                }
            }
        }
        return retainable
    }

    /// Append a `text: nil` response for a chunk (or batched group)
    /// whose Gemini call failed recoverably. Also stashes the error
    /// so `stop()` can rethrow it as the session-level failure when
    /// *every* dispatched call failed — gives the AppState error
    /// catalog the real cause (offline, 5xx, …) to surface rather
    /// than the generic `.noSpeech`.
    private func recordRecoverableFailure(
        error: Error,
        indices: [Int]
    ) {
        lastRecoverableError = error
        responses.append(ChunkResponse(
            chunkIndices: indices,
            text: nil
        ))
    }

    /// Free PCM for non-final chunks once their AAC blobs have been
    /// dispatched (successfully or not). PCM is the largest in-memory
    /// thing in a session; holding it past the dispatch point inflates
    /// memory for nothing — the AAC blob is already encoded and the
    /// only consumer of the PCM was `ChunkBuilder.encodeAAC`. If the
    /// batch contained the final chunk we leave the buffer alone —
    /// the recorder is about to be torn down anyway.
    private func discardProcessedPCM(batch: [PendingChunk], containsFinal: Bool) {
        guard !containsFinal else { return }
        if let lastEnd = batch.last(where: { !$0.isFinal })?.pcmEnd {
            recorder.discardSamples(beforeAbsolute: lastEnd)
        }
    }

    // MARK: - Main-actor snapshot helpers

    private struct ChunkSnapshot {
        let context: ContextSnapshot
        let priors: [String]
        let apiKey: String
        /// `true` when assembled via `buildLiteSnapshot` — instructs the
        /// caller to route through `GeminiClient.transcribeShort` (which
        /// uses `systemPromptLite` and omits the On-screen context +
        /// Prior chunks prompt parts).
        let isLite: Bool
        /// Transcription model frozen at session start — threaded into
        /// every Gemini call so the whole session stays on one model.
        let model: GeminiModel
    }

    /// Resolve the `ContextSnapshot` to attach to the next Gemini call.
    /// - Parameter allowMinimalFallback: when `true`, use whatever the
    ///   `contextTask` has produced so far without awaiting (final-chunk
    ///   path on quick release); when `false`, block until the task
    ///   completes (mid-session-chunk path).
    /// - Parameter forceLite: when `true`, ignore `contextTask` entirely
    ///   and synthesize a lite snapshot synchronously (no AX, no OCR,
    ///   keeps insertion target + instructions + dictionary). Triggers
    ///   the `systemPromptLite` path at the Gemini layer.
    private func snapshotForChunk(
        allowMinimalFallback: Bool = false,
        forceLite: Bool = false
    ) async -> ChunkSnapshot? {
        let context: ContextSnapshot
        let isLite: Bool
        if forceLite {
            context = buildLiteSnapshot()
            isLite = true
            Self.log.info("short final-only batch: using lite context (no AX, no OCR)")
        } else if allowMinimalFallback {
            if let cached = cachedContext {
                context = cached
                Self.log.info("final batch: using cached context (ready=true)")
            } else {
                // Pass `userLanguagesFrozen` so the `User languages:`
                // cache-prefix part stays byte-stable across chunks of
                // the same session even on this quick-release fallback.
                // `buildLiteSnapshot` already threads the same value.
                context = ContextSnapshot.minimal(
                    activeApp: AppInfo(
                        name: sourceApp?.localizedName ?? "Unknown",
                        bundleID: sourceApp?.bundleIdentifier ?? "unknown.bundle"
                    ),
                    userLanguages: userLanguagesFrozen
                )
                Self.log.info("final batch: context not ready, using minimal fallback")
            }
            isLite = false
        } else if let task = contextTask {
            context = await task.value
            isLite = false
        } else {
            context = ContextSnapshot.minimal(
                activeApp: AppInfo(
                    name: sourceApp?.localizedName ?? "Unknown",
                    bundleID: sourceApp?.bundleIdentifier ?? "unknown.bundle"
                ),
                userLanguages: userLanguagesFrozen
            )
            isLite = false
        }
        return ChunkSnapshot(context: context, priors: currentPriors(), apiKey: apiKey, isLite: isLite, model: modelFrozen)
    }

    /// Successful transcript texts from completed Gemini calls, in
    /// dispatch order. Used as the `priorTranscripts` argument to the
    /// next request and for the lite-path discriminator. Failed
    /// chunks (`text == nil`) contribute nothing — they exist as
    /// `failureMarker` placeholders only in the final pasted text,
    /// never in the Gemini-facing prior list. Sending markers as
    /// priors would teach the model to emit them.
    ///
    /// Also filters empty-string entries — those come from the
    /// `HallucinationLengthGate` filtering out a hallucinated
    /// response. An empty string isn't a real prior chunk; treating
    /// it as one would (a) feed Gemini a `""` as "previous chunk
    /// transcribed to nothing", which the model misreads as a stop
    /// signal, and (b) bump the lite-path discriminator's
    /// `priorTranscriptCount` above zero, disqualifying the next
    /// short chunk from the lite path despite no real prior content.
    private func currentPriors() -> [String] {
        responses.compactMap { resp in
            guard let text = resp.text, !text.isEmpty else { return nil }
            return text
        }
    }

    /// Synchronously assemble a small `ContextSnapshot` for short
    /// final-only sessions: full instructions + dictionary + insertion
    /// target, but empty AX tree and no OCR. Doesn't touch `contextTask`
    /// — if AX/OCR is still running we don't care; this path doesn't need
    /// it. Returns in <50 ms typical (one synchronous AX read for the
    /// search-field override + a sync `InsertionTarget.captureSync()`
    /// when `cachedContext` isn't ready yet).
    private func buildLiteSnapshot() -> ContextSnapshot {
        let appInfo = AppInfo(
            name: sourceApp?.localizedName ?? "Unknown",
            bundleID: sourceApp?.bundleIdentifier ?? "unknown.bundle"
        )

        // Category resolution mirrors what `contextTask` does — stored
        // lookup plus the synchronous AX search-field override. The
        // override is the highest-leverage case (search bars dictating
        // a query) and `CategoryResolver.resolveFromAX` is a single sync
        // AX read on the system-wide focused element (~5–10 ms).
        let stored = instructionsFrozen.cachedCategoryForBundle(appInfo.bundleID) ?? .uncategorized
        let resolvedCategory = CategoryResolver.resolveFromAX(stored: stored)
        let categoryInstruction = instructionsFrozen.promptForCategory(resolvedCategory)

        // Insertion target — prefer the cache (mirror may have completed
        // ahead of us even on quick-release), else synchronous capture.
        let target = cachedContext?.insertionTarget ?? InsertionTarget.captureSync()

        return ContextSnapshot(
            activeApp: appInfo,
            category: resolvedCategory,
            userInstruction: instructionsFrozen.userInstruction,
            categoryInstruction: categoryInstruction,
            dictionary: dictionaryFrozen.activeEntries,
            replacements: dictionaryFrozen.replacements,
            userLanguages: userLanguagesFrozen,
            tree: RedactedAXSnapshot(apps: []),
            insertionTarget: target,
            screenText: nil
        )
    }

    private func markFailure(_ error: Error) {
        if failure == nil { failure = error }
        // Terminal abort is a SESSION-wide fact, not a per-batch one
        // (R4). Once any error has latched, this session is going to
        // throw out of `stop()`, and nothing it captured is retryable —
        // including audio an *earlier* batch already accumulated. The
        // `!didFail` guard at the `processBatch` retain site only
        // suppresses the batch it runs in; a session that lost chunk 0
        // to a 5xx and then hit a rejected key on chunk 3 would keep
        // chunk 0's audio without this line, and `AppState`'s catch arm
        // (KTD3) reads `retained != nil` as "this session lost chunks in
        // the recoverable class". Writing a broken row with a live retry
        // button for a session killed by a bad key is the shape AE1
        // forbids. Unconditional (not inside the `failure == nil` guard)
        // because it is idempotent and must hold on every latch.
        retained = nil
    }

    // MARK: - Context-task helpers

    /// Run `work` with a millisecond wall-clock cap. Returns the work's
    /// result if it finishes first, `nil` if the cap fires first. The
    /// work task is cooperatively cancelled when the cap fires — work
    /// must check `Task.isCancelled` to actually short-circuit, otherwise
    /// it keeps running until natural completion but its result is
    /// discarded. AX walks already poll cancellation; Vision OCR can't be
    /// interrupted mid-pipeline but typically completes well under cap.
    private static func withDeadline<T: Sendable>(
        ms: Int,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: Optional<T>.self) { group in
            group.addTask {
                let result: T? = await work()
                return result
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(ms))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// OCR sibling — returns nil immediately when the feature is off
    /// (Screen Recording not granted), otherwise runs the capture under
    /// a 2500 ms safety cap. The cap is generous because the first audio
    /// chunk can't arrive until VAD detects a ≥1 s pause OR the user
    /// releases — so for realistic sessions OCR latency is masked by
    /// speech time. Quick-release sessions (<500 ms held) may wait up to
    /// the cap for paste; that's the trade-off vs. losing the whole
    /// snapshot to a joint deadline overrun.
    private static func runOCRIfEnabled(
        enabled: Bool,
        appInfo: AppInfo,
        pid: pid_t
    ) async -> RedactedScreenText? {
        guard enabled else { return nil }
        let result = await withDeadline(ms: 2500) {
            await ScreenCaptureContext.capture(activeApp: appInfo, pid: pid)
        }
        // `withDeadline` returns `T?` where T is itself `RedactedScreenText?`,
        // so this is `RedactedScreenText??`. Flatten: outer nil = deadline
        // hit, inner nil = capture-failed; either way result is nil.
        return result ?? nil
    }
}
