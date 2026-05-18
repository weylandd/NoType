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
    nonisolated static func shouldUseLitePath(
        isFinalBatch: Bool,
        priorTranscriptCount: Int,
        totalBatchSamples: Int
    ) -> Bool {
        isFinalBatch
            && priorTranscriptCount == 0
            && totalBatchSamples < shortSessionMaxSamples
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
        /// Total chunks dispatched to Gemini (excludes sub-150 ms
        /// drops). `failedChunkCount <= dispatchedChunkCount`.
        let dispatchedChunkCount: Int

        var hasFailures: Bool { failedChunkCount > 0 }
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
    /// empty) is treated as a transient gap — paste what we have,
    /// mark the gap, let the user decide whether to re-dictate.
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
            case .empty, .decoding:
                return false
            }
        }
        return true
    }

    private let recorder: AudioRecorder
    private let vad:      SileroVAD
    private let gemini:   GeminiClient
    private let history:  HistoryStore

    private var startedAt: Date?
    private var sourceApp: NSRunningApplication?
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
    private struct ChunkResponse: Sendable {
        let chunkIndices: [Int]
        let text: String?
    }

    /// Outputs of completed Gemini calls, in dispatch order (also
    /// chunk-index order: the sender drains serially and we never
    /// dispatch out-of-order). Stitched at `stop()` — each entry's
    /// `text ?? Self.failureMarker` becomes one piece of the output.
    private var responses: [ChunkResponse] = []
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
    func start(
        apiKey: String,
        instructions: InstructionsContext,
        dictionary: DictionaryContext
    ) throws {
        self.apiKey = apiKey
        self.replacementsFrozen = dictionary.replacements
        self.instructionsFrozen = instructions
        self.dictionaryFrozen = dictionary
        let frontmost = NSWorkspace.shared.frontmostApplication
        sourceApp = frontmost
        startedAt = Date()

        let appInfo = AppInfo(
            name: frontmost?.localizedName ?? "Unknown",
            bundleID: frontmost?.bundleIdentifier ?? "unknown.bundle"
        )
        let pid: pid_t = frontmost?.processIdentifier ?? 0

        // OCR fallback is opt-in via Screen Recording permission. When
        // granted, run it in parallel with the AX walk; the snapshot is
        // built once all three subtasks settle. When not granted, the
        // OCR limb is not spawned (returns nil immediately).
        let ocrEnabled = (ScreenRecordingPermission.current() == .granted) && pid > 0

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
                tree: resolvedTree,
                insertionTarget: target,
                screenText: shouldAttachOCR ? ocr : nil
            )

            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let ocrTag: String
            if !ocrEnabled {
                ocrTag = "ocr=off (no-permission)"
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

    /// Localised name of the app that was frontmost at session start —
    /// used as the paste target label in the transcribing HUD.
    var sourceAppName: String? {
        sourceApp?.localizedName
    }

    /// Best-effort cancel: stop capturing, drop any in-flight sender,
    /// and discard accumulated responses. Pasting is skipped.
    func cancel() async {
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
        // Mark a synthetic failure so `stop()` (if it's racing this
        // call) sees a cancelled state rather than trying to paste.
        if failure == nil {
            failure = CancellationError()
        }
    }

    /// Post-session diagnostics — read by `AppState.finalizeRecording`
    /// after `stop()` returns to decide whether to nudge the user with
    /// a "some parts didn't transcribe" HUD. Cheap to compute (loops
    /// over `responses` once); safe to call from the main actor.
    var summary: SessionSummary {
        var failed = 0
        var total = 0
        for r in responses {
            total += r.chunkIndices.count
            if r.text == nil { failed += r.chunkIndices.count }
        }
        return SessionSummary(
            failedChunkCount: failed,
            dispatchedChunkCount: total
        )
    }

    /// Stops capture, awaits the sender draining the pending queue,
    /// pastes the concatenated transcript, and writes a history entry.
    func stop() async throws -> HistoryEntry {
        let t0 = Date()
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
        let pieces = responses.map { $0.text ?? Self.failureMarker }
        let stitched = TextInjector.stitchChunks(pieces)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let target = cachedContext?.insertionTarget ?? .unknown
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

        await TextInjector.paste(final)
        let tPaste = Date()

        // Duration = hotkey press → release. `t0` is captured at the
        // very top of `stop()`, which runs once the user has already
        // released, so it's the best proxy we have for release time.
        // Drives WPM / Time saved on the Home tab.
        let durationSeconds = max(0, t0.timeIntervalSince(startedAt ?? t0))
        let entry = HistoryEntry(
            id: UUID(),
            text: final,
            sourceAppName: sourceApp?.localizedName ?? "Unknown",
            sourceBundleID: sourceApp?.bundleIdentifier ?? "",
            timestamp: startedAt ?? Date(),
            durationSeconds: durationSeconds
        )
        await history.append(entry)

        Self.log.info(
            "session timing: drain=\(Int(tStream.timeIntervalSince(t0)*1000))ms gemini=\(Int(tGemini.timeIntervalSince(tStream)*1000))ms paste=\(Int(tPaste.timeIntervalSince(tGemini)*1000))ms total=\(Int(Date().timeIntervalSince(t0)*1000))ms chunks=\(self.chunkCounter)"
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
        // Batches containing the **final** chunk come from a user release.
        // For those we don't wait on the context task — if AX / OCR
        // happened to finish already we use the cached value; otherwise
        // we fall back to a minimal snapshot. Rationale: a fast tap-and-
        // release session shouldn't sit blocked behind the 2.5 s OCR cap.
        // Mid-session batches (pause-triggered) keep the awaiting path
        // since the user is clearly speaking and we have time to spare.
        //
        // Additionally: when the final batch is short (<2 s) AND this is
        // the only batch of the session, route through the lite path —
        // a synchronous trimmed snapshot (no AX, no OCR) + a smaller
        // system prompt at the Gemini layer. Reduces prompt by ~70% on
        // single-word sessions where context never helps anyway.
        let isFinalBatch = batch.contains { $0.isFinal }
        let totalBatchSamples = batch.reduce(0) { $0 + ($1.pcmEnd - $1.pcmStart) }
        // Lite path requires no prior transcript text to ship in the
        // `Prior chunks (this session):` section. Recoverable failures
        // (markers) don't produce text, so they don't disqualify the
        // lite path — if every prior call failed, the prompt's prior
        // section would be `(none yet)` anyway and the trimmed shape
        // still fits. Use `currentPriors().count` rather than
        // `responses.count` for this reason.
        let isShortFinalOnly = Self.shouldUseLitePath(
            isFinalBatch: isFinalBatch,
            priorTranscriptCount: currentPriors().count,
            totalBatchSamples: totalBatchSamples
        )
        guard let snap = await snapshotForChunk(
            allowMinimalFallback: isFinalBatch,
            forceLite: isShortFinalOnly
        ) else { return }

        let recorder = self.recorder
        let gemini = self.gemini

        // Encode + drop sub-150 ms chunks (Silero false starts on breath
        // / lip clicks would otherwise produce empty Gemini calls).
        var encoded: [(idx: Int, isFinal: Bool, audio: Data)] = []
        for pc in batch {
            let pcm = recorder.samples(from: pc.pcmStart, to: pc.pcmEnd)
            if pcm.count < 2_400 {
                Self.log.info("chunk_\(pc.index) too short (\(pcm.count) samples) — skipping")
                continue
            }
            do {
                let aac = try ChunkBuilder.encodeAAC(pcm)
                encoded.append((pc.index, pc.isFinal, aac))
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

        do {
            let text: String
            if snap.isLite {
                // Lite path is reachable only via the discriminator in
                // `processBatch` — guaranteed `encoded.count == 1` and
                // `containsFinal == true` by construction (final-only
                // batch, no successful priors, audio < 2 s).
                let one = encoded[0]
                text = try await gemini.transcribeShort(
                    audio: one.audio,
                    mimeType: "audio/mp4",
                    context: snap.context,
                    apiKey: snap.apiKey
                )
            } else if encoded.count == 1 {
                let one = encoded[0]
                text = try await gemini.transcribe(
                    audio: one.audio,
                    mimeType: "audio/mp4",
                    context: snap.context,
                    priorTranscripts: snap.priors,
                    chunkIndex: one.idx,
                    isFinal: one.isFinal,
                    apiKey: snap.apiKey
                )
            } else {
                Self.log.info("batching \(encoded.count) chunks (\(encoded.first?.idx ?? -1)..\(encoded.last?.idx ?? -1)) final=\(containsFinal)")
                text = try await gemini.transcribeBatch(
                    audios: encoded.map { ($0.audio, "audio/mp4") },
                    context: snap.context,
                    priorTranscripts: snap.priors,
                    chunkIndices: encoded.map { $0.idx },
                    isFinal: containsFinal,
                    apiKey: snap.apiKey
                )
            }
            responses.append(ChunkResponse(
                chunkIndices: encoded.map { $0.idx },
                text: text
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
                await splitRetry(encoded: encoded, snap: snap)
            } else {
                let c = encoded[0]
                Self.log.error("\(label) failed: \(error.localizedDescription, privacy: .public) — inserting marker")
                recordRecoverableFailure(error: error, indices: [c.idx])
            }
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
    private func splitRetry(
        encoded: [(idx: Int, isFinal: Bool, audio: Data)],
        snap: ChunkSnapshot
    ) async {
        for (offset, chunk) in encoded.enumerated() {
            if didFail { return }
            // Re-query priors each iteration so a chunk that just
            // succeeded becomes context for the next one.
            let priors = currentPriors()
            do {
                let text = try await gemini.transcribe(
                    audio: chunk.audio,
                    mimeType: "audio/mp4",
                    context: snap.context,
                    priorTranscripts: priors,
                    chunkIndex: chunk.idx,
                    isFinal: chunk.isFinal,
                    apiKey: snap.apiKey
                )
                responses.append(ChunkResponse(
                    chunkIndices: [chunk.idx],
                    text: text
                ))
            } catch {
                if Self.isTerminal(error) {
                    Self.log.error("chunk_\(chunk.idx) split-retry failed terminally: \(error.localizedDescription, privacy: .public)")
                    markFailure(error)
                    return
                }
                Self.log.error("chunk_\(chunk.idx) split-retry failed: \(error.localizedDescription, privacy: .public) — inserting marker")
                recordRecoverableFailure(error: error, indices: [chunk.idx])
                // Brief pause before the next sub-call so we don't
                // burst-fire against a rate-limited API. Skip the
                // sleep when we're already on the last chunk —
                // nothing comes after.
                if offset < encoded.count - 1 {
                    try? await Task.sleep(for: Self.splitRetryBackoff)
                }
            }
        }
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
                context = ContextSnapshot.minimal(activeApp: AppInfo(
                    name: sourceApp?.localizedName ?? "Unknown",
                    bundleID: sourceApp?.bundleIdentifier ?? "unknown.bundle"
                ))
                Self.log.info("final batch: context not ready, using minimal fallback")
            }
            isLite = false
        } else if let task = contextTask {
            context = await task.value
            isLite = false
        } else {
            context = ContextSnapshot.minimal(activeApp: AppInfo(
                name: sourceApp?.localizedName ?? "Unknown",
                bundleID: sourceApp?.bundleIdentifier ?? "unknown.bundle"
            ))
            isLite = false
        }
        return ChunkSnapshot(context: context, priors: currentPriors(), apiKey: apiKey, isLite: isLite)
    }

    /// Successful transcript texts from completed Gemini calls, in
    /// dispatch order. Used as the `priorTranscripts` argument to the
    /// next request and for the lite-path discriminator. Failed
    /// chunks (`text == nil`) contribute nothing — they exist as
    /// `failureMarker` placeholders only in the final pasted text,
    /// never in the Gemini-facing prior list. Sending markers as
    /// priors would teach the model to emit them.
    private func currentPriors() -> [String] {
        responses.compactMap { $0.text }
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
            tree: RedactedAXSnapshot(apps: []),
            insertionTarget: target,
            screenText: nil
        )
    }

    private func markFailure(_ error: Error) {
        if failure == nil { failure = error }
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
