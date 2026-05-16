@preconcurrency import AVFoundation
import OSLog

/// Captures microphone audio between `start()` and `stop()`, resamples it to
/// **16 kHz mono float32** to match Silero VAD's expected input, and exposes
/// two surfaces:
///
/// 1. An `AsyncStream<[Float]>` of fixed-size frames (one per VAD inference
///    window). The recording session drives `SileroVAD` from this stream.
/// 2. A by-index slice API (`samples(from:to:)`) so `ChunkBuilder` can cut
///    out PCM ranges for AAC encoding when the pause detector emits a
///    boundary.
///
/// **Memory bounding.** Sample indices passed in / out of `samples(from:to:)`
/// are *absolute* (counted from `start()` so callers like `PauseDetector`
/// can hold on to them across chunk boundaries), but storage is bounded:
/// once `discardSamples(beforeAbsolute:)` is called, anything strictly
/// older than that index is freed. Recorder maintains a `baseOffset` so
/// callers' absolute indices keep working seamlessly. This keeps RAM use
/// at ~"current chunk + pre-roll" rather than "entire session".
///
/// **Resampling.** AVAudioEngine input nodes hand us hardware-rate buffers
/// (typically 44.1 or 48 kHz). We feed each one through a session-scoped
/// `AVAudioConverter` to get 16 kHz / mono / float32 output. The converter
/// callback signals `noDataNow` (not `endOfStream`) on subsequent calls so
/// the converter's internal filter state is preserved across taps —
/// signalling end-of-stream per buffer corrupts audio (we hit this bug in a
/// prior iteration).
///
/// **Device switching mid-session.** The recorder listens for
/// `AVAudioEngineConfigurationChange` and rebuilds the tap + converter
/// without dropping the in-progress session. Triggered when the user
/// unplugs Bluetooth headphones, swaps default input in System Settings,
/// or yanks a USB mic. The accumulated PCM buffer is preserved.
final class AudioRecorder: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.notype", category: "recording")

    enum AudioError: Error, LocalizedError {
        case engineStartFailed(Error)
        case converterCreateFailed
        case bufferAllocFailed

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let e): "Couldn't start audio engine: \(e.localizedDescription)"
            case .converterCreateFailed:    "Couldn't create audio converter."
            case .bufferAllocFailed:        "Couldn't allocate audio buffer."
            }
        }
    }

    /// Sample rate we feed to Silero. Non-negotiable.
    static let outputSampleRate: Double = 16_000

    /// Frames per VAD window. Matches `SileroVAD.chunkSize`.
    static let frameSize: Int = 4_096

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    /// Resampled PCM held in memory. Wrap-around ring with absolute
    /// indexing — see `PCMRingBuffer`. Capacity covers the
    /// `PauseDetector` 180 s force-cut limit (2 880 000 samples) plus the
    /// 300 ms pre-roll plus ~10 s of slack for in-flight tap callbacks
    /// that may pile up while the chunk-builder is busy on a slow Gemini
    /// call. ~12 MB at 16 kHz float32 — trivial vs. modern Mac RAM. The
    /// number itself isn't load-bearing — overshoots are silently
    /// dropped from the head, but with the force-cut in place this
    /// shouldn't happen in normal sessions.
    private static let pcmRingCapacity: Int = 190 * 16_000  // 190 s @ 16 kHz
    private let pcm = PCMRingBuffer(capacity: pcmRingCapacity)

    /// Bytes that haven't yet been chunked into a `frameSize` VAD window.
    /// Held inside the lock together with `pcm`.
    private var leftover: [Float] = []

    /// **Always touched under `lock`.** The audio tap thread reads this
    /// in `handleTap` to yield frames; `start`/`stop`/`handleConfigurationChange`
    /// (all on `@MainActor`) write it. Without the lock, `stop()` could
    /// nil it out between `handleTap`'s lock-unlock and its yield call —
    /// not a crash (the optional read survives), but a data race under
    /// Swift 6 strict concurrency. Guard explicitly.
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var tapInstalled = false
    private var configChangeObserver: NSObjectProtocol?

    /// Total samples ever captured this session, in absolute indexing.
    /// Safe to call from any actor.
    var totalSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return pcm.totalSamples
    }

    /// Begin capture. Returns an async stream that yields one
    /// `[frameSize]`-Float array per VAD window. The stream finishes when
    /// `stop()` is called.
    func start() throws -> AsyncStream<[Float]> {
        // Apply the user-pinned input device (if any) before the engine
        // is prepared. Must run on `MainActor` because that's where
        // `AudioDeviceManager` lives — `start()` is called from
        // `RecordingSession` which is `@MainActor`, so this is in scope.
        let device = MainActor.assumeIsolated { AudioDeviceManager.shared.effectiveDevice }
        if let device {
            _ = AudioDeviceManager.apply(device, to: engine)
        }

        lock.lock()
        self.pcm.reset()
        self.leftover = []
        lock.unlock()

        let stream = AsyncStream<[Float]> { cont in
            self.lock.lock()
            self.continuation = cont
            self.lock.unlock()
            cont.onTermination = { @Sendable _ in }
        }

        try installTapAndStart()

        // Watch for device-list / format changes (BT disconnect, USB
        // unplug, default-input swap). On each event we rebuild the tap
        // + converter without ending the session.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        return stream
    }

    /// Install (or re-install) the input-node tap with a freshly-built
    /// converter, then start the engine. Used both by `start()` and the
    /// configuration-change handler. Caller must guarantee the engine is
    /// stopped beforehand.
    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            // Configuration changed mid-rebuild and the input node has
            // no valid format yet — try again on the next change event.
            throw AudioError.converterCreateFailed
        }
        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioError.converterCreateFailed
        }
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw AudioError.converterCreateFailed
        }
        self.inputFormat = inFmt
        self.outputFormat = outFmt
        self.converter = conv

        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw AudioError.engineStartFailed(error)
        }

        Self.log.info("recording running (\(Int(inFmt.sampleRate))Hz x\(inFmt.channelCount) → 16kHz mono)")
    }

    /// Called when AVAudioEngine signals the input device or format
    /// changed. We tear down the tap, rebuild the converter for the new
    /// input format, and restart — without dropping the session's
    /// accumulated PCM. The user keeps dictating; the splice is
    /// invisible (a few ms gap at most).
    private func handleConfigurationChange() {
        Self.log.info("AVAudioEngineConfigurationChange — rebuilding tap")
        engine.stop()
        do {
            try installTapAndStart()
        } catch {
            Self.log.error("config-change rebuild failed: \(error.localizedDescription, privacy: .public)")
            // Best-effort: finish the stream so the session sees the
            // tail and can paste what we already have. Swap the
            // continuation reference out under `lock` so a concurrent
            // tap callback observes a coherent old-or-nil value.
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.finish()
        }
    }

    /// Halt capture. Finishes the async stream and stops the engine.
    func stop() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        // Flush any partial frame? We don't — partial means <256 ms of audio,
        // not enough for a VAD window. Let the recording session handle the
        // final tail via `samples(from:to:)`. Swap the continuation
        // reference out under `lock` so a concurrent tap callback that
        // already passed our earlier checks observes a coherent nil.
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
        Self.log.info("recording stopped (\(self.totalSamples) samples / \(Int(Double(self.totalSamples) / Self.outputSampleRate * 1000))ms)")
    }

    /// Return the half-open range `[from, to)` of resampled PCM samples.
    /// `from` and `to` are *absolute* indices (counted from session
    /// start). Out-of-range indices are clamped silently — this is a
    /// slicing helper, not a contract enforcer.
    func samples(from: Int, to: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return pcm.samples(from: from, to: to)
    }

    /// Drop everything strictly older than `absoluteIndex`, freeing the
    /// memory. Indices into samples we still hold remain valid because
    /// the ring's `head` advances accordingly. Called by the recording
    /// session each time a chunk has been encoded — keeps the buffer
    /// bounded to "in-flight chunk + pre-roll" rather than the whole
    /// session. O(1) on `PCMRingBuffer`.
    func discardSamples(beforeAbsolute absoluteIndex: Int) {
        lock.lock(); defer { lock.unlock() }
        pcm.discard(beforeAbsolute: absoluteIndex)
    }

    /// Return the trailing `count` samples from the buffer, or an empty
    /// array if fewer than `count` samples have been captured yet.
    /// Cheap — copies `count * 4` bytes per call. Used by the recording
    /// HUD's live spectrum meter.
    func recentSamples(count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return pcm.recentSamples(count: count)
    }

    // MARK: - Tap → resample → fan out

    private func handleTap(_ inBuffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }

        // Allocate an output buffer big enough for the worst case.
        let inFrames = Int(inBuffer.frameLength)
        let ratio = outputFormat.sampleRate / inBuffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(inFrames) * ratio + 256)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCap) else {
            Self.log.error("output buffer alloc failed")
            return
        }

        // Single-shot input-block: provide the buffer once, then return
        // .noDataNow so the converter preserves filter state for the next
        // tap. Returning .endOfStream here would corrupt audio — see the
        // class doc-comment.
        let feed = ConverterFeed(buffer: inBuffer)
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, statusPtr in
            feed.next(status: statusPtr)
        }

        if status == .error || convError != nil {
            Self.log.error("converter error: \(convError?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }

        let outFrames = Int(outBuffer.frameLength)
        guard outFrames > 0,
              let chData = outBuffer.floatChannelData?[0]
        else { return }

        let arr = Array(UnsafeBufferPointer(start: chData, count: outFrames))

        lock.lock()
        pcm.append(arr)
        leftover.append(contentsOf: arr)

        // Cut off as many full VAD windows as we have pending. Each window
        // is yielded to the consumer, partial tail stays in `leftover`.
        var emit: [[Float]] = []
        while leftover.count >= Self.frameSize {
            let frame = Array(leftover.prefix(Self.frameSize))
            leftover.removeFirst(Self.frameSize)
            emit.append(frame)
        }
        // Snapshot the continuation under the same lock that `stop()` and
        // `handleConfigurationChange` use to swap it. Yielding outside
        // the lock is safe — `AsyncStream.Continuation` is itself
        // documented as concurrency-safe; we just can't race the
        // pointer load against a nil store.
        let cont = continuation
        lock.unlock()

        guard let cont else { return }
        for frame in emit {
            cont.yield(frame)
        }
    }
}

/// Reference-typed feed for `AVAudioConverter`. Holds the input buffer and
/// flips a `consumed` flag so the input-block returns the buffer once and
/// then signals `noDataNow` for the lifetime of this conversion call.
/// Reference type lets us mutate the flag without tripping Swift 6's
/// strict-concurrency checks on captured `var`.
private final class ConverterFeed: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if consumed {
            status.pointee = .noDataNow
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
}
