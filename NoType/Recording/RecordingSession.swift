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

    /// Outputs of completed Gemini calls, in dispatch order. A single
    /// call may have transcribed one chunk or several (batched) — we
    /// don't split the response back out into per-chunk strings here,
    /// because the model's contract is "produce one contiguous text".
    /// Concatenated at session end.
    private var transcripts: [String] = []
    private var chunkCounter: Int = 0
    private var failure: Error?
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
        contextTask = Task.detached(priority: .userInitiated) {
            let t0 = Date()
            async let treeOpt: RedactedAXSnapshot? = Self.withDeadline(ms: 1500) {
                await AccessibilityTree.snapshot()
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
    /// and discard accumulated transcripts. Pasting is skipped.
    func cancel() async {
        recorder.stop()
        senderTask?.cancel()
        vadTask?.cancel()
        await senderTask?.value
        await vadTask?.value
        transcripts.removeAll()
        pending.removeAll()
        // Mark a synthetic failure so `stop()` (if it's racing this
        // call) sees a cancelled state rather than trying to paste.
        if failure == nil {
            failure = CancellationError()
        }
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

        await senderTask?.value         // wait for sender to drain pending
        let tGemini = Date()

        if let err = failure {
            throw err
        }

        // The model is supposed to emit a leading space when its chunk
        // starts a new word after the prior chunk ended non-whitespace,
        // but with `thinkingLevel: .minimal` it occasionally forgets and
        // we get seams like `"What's up.I'm fine."`. `stitchChunks` is a
        // deterministic conservative fix: it inserts a single space
        // between a sentence-internal terminal (`.`, `!`, `?`, `,`, `:`,
        // `;`, `…`) and a word-starter on the next chunk. Trim outer
        // whitespace so a fully blank session returns "".
        let stitched = TextInjector.stitchChunks(transcripts)
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
            // to ANE contention without guessing.
            var slowInferences = 0
            var totalInferences = 0
            for await frame in stream {
                let frameEnd = frameStart + frame.count
                let inferenceStart = Date()
                let prob: Float
                do {
                    prob = try await vad.probability(for: frame)
                } catch {
                    Self.log.error("vad inference failed: \(error.localizedDescription, privacy: .public)")
                    frameStart = frameEnd
                    continue
                }
                let inferenceMs = Date().timeIntervalSince(inferenceStart) * 1000
                totalInferences += 1
                if inferenceMs > 50 { slowInferences += 1 }

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
                    "VAD lag: \(slowInferences)/\(totalInferences) inferences > 50 ms (ANE likely contended)"
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
    /// batched Gemini request. One transcripts entry per request — we
    /// don't try to split a batched response back into per-chunk strings.
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
        let isShortFinalOnly = Self.shouldUseLitePath(
            isFinalBatch: isFinalBatch,
            priorTranscriptCount: transcripts.count,
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

        do {
            let text: String
            if snap.isLite {
                // Lite path is reachable only via the discriminator in
                // `processBatch` — guaranteed `encoded.count == 1` and
                // `containsFinal == true` by construction (final-only
                // batch, transcripts empty, audio < 2 s).
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
            appendTranscript(text)

            // Free PCM that's no longer needed. Anything before the last
            // non-final chunk's `end` is safe to drop. If the batch
            // contained the final chunk we leave the buffer alone — the
            // recorder is about to be torn down anyway.
            if !containsFinal {
                if let lastEnd = batch.last(where: { !$0.isFinal })?.pcmEnd {
                    recorder.discardSamples(beforeAbsolute: lastEnd)
                }
            }
        } catch {
            let label = encoded.count == 1
                ? "chunk_\(encoded[0].idx)"
                : "chunks_\(encoded.first?.idx ?? -1)..\(encoded.last?.idx ?? -1)"
            Self.log.error("\(label) failed: \(error.localizedDescription, privacy: .public)")
            markFailure(error)
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
        return ChunkSnapshot(context: context, priors: transcripts, apiKey: apiKey, isLite: isLite)
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

    private func appendTranscript(_ text: String) {
        transcripts.append(text)
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
