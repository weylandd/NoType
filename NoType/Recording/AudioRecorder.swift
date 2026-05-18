@preconcurrency import AVFoundation
import CoreAudio
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
/// **Capture path.** This recorder talks to Core Audio's HAL directly —
/// `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` against the
/// effective input device. The earlier `AVAudioEngine.installTap` path
/// implicitly created an aggregate input+output device that kicked the
/// output side on `engine.start()` and stuttered Bluetooth-headphone
/// playback for ~1 s every time the user pressed the hotkey. There is
/// no public API to disable AVAudioEngine's output side, so the HAL
/// bypass is the only fix for the "music glitches when recording starts"
/// report. Background:
/// <https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/>
///
/// **Resampling.** Native input frames arrive in the device's stream
/// format (typically 44.1 or 48 kHz, float32). We feed each one through
/// a session-scoped `AVAudioConverter` to get 16 kHz / mono / float32
/// output. The converter callback signals `noDataNow` (not `endOfStream`)
/// on subsequent calls so the converter's internal filter state is
/// preserved across IOProc invocations — signalling end-of-stream per
/// buffer corrupts audio (we hit this bug in a prior iteration).
///
/// **Device switching mid-session.** A HAL property listener on
/// `kAudioHardwarePropertyDefaultInputDevice` rebuilds the IOProc + the
/// converter against the new effective device without dropping the
/// session's accumulated PCM. Triggered when the user unplugs Bluetooth
/// headphones, swaps default input in System Settings → Sound, or yanks a
/// USB mic. The user keeps dictating; the splice is a few ms of silence.
///
/// **Threading.** The IOProc runs on a dedicated serial dispatch queue
/// (`ioQueue`). The `lock` protects every shared field (`continuation`,
/// `converter`, `pcm`, `leftover`); `start` / `stop` /
/// `handleConfigurationChange` are all `@MainActor` and serialise against
/// each other via the lock when touching shared state. The HAL property
/// listener dispatches on `DispatchQueue.main`, which is the AppKit main
/// run-loop — the listener block bridges into `@MainActor` via
/// `MainActor.assumeIsolated`.
final class AudioRecorder: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.notype", category: "recording")

    enum AudioError: Error, LocalizedError {
        case noInputDevice
        case streamFormatUnavailable
        case converterCreateFailed
        case ioProcCreateFailed(OSStatus)
        case ioProcStartFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:                 "Couldn't find an audio input device."
            case .streamFormatUnavailable:       "Couldn't read the input device's audio format."
            case .converterCreateFailed:         "Couldn't create audio converter."
            case .ioProcCreateFailed(let s):     "Couldn't open audio capture (HAL \(s))."
            case .ioProcStartFailed(let s):      "Couldn't start audio capture (HAL \(s))."
            }
        }
    }

    /// Sample rate we feed to Silero. Non-negotiable.
    static let outputSampleRate: Double = 16_000

    /// Frames per VAD window. Matches `SileroVAD.chunkSize`.
    static let frameSize: Int = 4_096

    private let lock = NSLock()

    /// Serial queue the HAL IOProc dispatches onto. Lets us use NSLock
    /// safely (vs the real-time render thread, where NSLock can call
    /// into mach syscalls under contention). Latency cost is a handful
    /// of ms — irrelevant for batched chunk uploads.
    private let ioQueue = DispatchQueue(
        label: "app.notype.recording.ioproc",
        qos: .userInteractive
    )

    // HAL session state (all touched only under `lock` except inside the
    // IOProc itself — which is the sole writer that runs off `ioQueue`).
    private var deviceID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    /// Held only while the default-input listener is installed.
    /// `AudioObjectRemovePropertyListenerBlock` matches listeners by the
    /// exact block reference we registered with — storing the block is
    /// the only way to deregister precisely.
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    /// Pre-allocated output buffer reused across every IOProc
    /// invocation — avoids the per-tap `AVAudioPCMBuffer(...)` heap
    /// allocation on the real-time path. Sized for an upper-bound 16
    /// kHz output capacity that comfortably covers every input
    /// configuration we see in practice (≤192 kHz sample rate × ~50
    /// ms hardware buffer ≈ ~10 k input frames downsampled to 16 kHz
    /// = ~3 k output frames). The 16 kHz output rate is fixed, so
    /// `outputCapacityFrames` is constant once allocated; we only
    /// rebuild the buffer when `outputFormat` changes
    /// (`openAndStartHAL` swaps to a new converter for a new device).
    private var outputBuffer: AVAudioPCMBuffer?

    /// Upper bound on a single IOProc output write. 16 kHz × 0.5 s =
    /// 8 000 frames — generous slack vs. the typical ~50 ms hardware
    /// buffer (which yields ~800 16 kHz frames after downsample). Any
    /// IOProc that delivers more than this hits a defensive guard and
    /// drops the tail.
    private static let outputCapacityFrames: AVAudioFrameCount = 8_192

    /// Latch flipped to `true` by `stop()` so a HAL listener block
    /// already queued on `DispatchQueue.main` can short-circuit before
    /// `handleConfigurationChange` re-opens a fresh IOProc against the
    /// new default input. Without this, a late property-change
    /// callback that lands after `stop()` would spawn an orphaned
    /// IOProc whose first `handleIOProc` call has no consumer.
    /// Guarded by `lock` for the same reason as `continuation`.
    private var stopped: Bool = false

    /// Resampled PCM held in memory. Wrap-around ring with absolute
    /// indexing — see `PCMRingBuffer`. Capacity covers the
    /// `PauseDetector` 180 s force-cut limit (2 880 000 samples) plus the
    /// 300 ms pre-roll plus ~10 s of slack for in-flight IOProc dispatch
    /// that may pile up while the chunk-builder is busy on a slow Gemini
    /// call. ~12 MB at 16 kHz float32 — trivial vs. modern Mac RAM. The
    /// number itself isn't load-bearing — overshoots are silently
    /// dropped from the head, but with the force-cut in place this
    /// shouldn't happen in normal sessions.
    private static let pcmRingCapacity: Int = 190 * 16_000  // 190 s @ 16 kHz
    private let pcm = PCMRingBuffer(capacity: pcmRingCapacity)

    /// Bytes that haven't yet been chunked into a `frameSize` VAD window.
    /// Held inside the lock together with `pcm`.
    ///
    /// Drained via an advancing `leftoverStart` cursor rather than
    /// `removeFirst(frameSize)` so the on-lock path stays O(1) instead of
    /// O(N) (shifting all remaining floats left after each emit). We
    /// compact (`leftover = Array(leftover[leftoverStart...])`) once the
    /// cursor passes the half-way point to keep memory growth bounded.
    private var leftover: [Float] = []
    private var leftoverStart: Int = 0

    /// **Always touched under `lock`.** The IOProc reads this in
    /// `handleTap` to yield frames; `start` / `stop` /
    /// `handleConfigurationChange` (all on `@MainActor`) write it.
    /// Without the lock, `stop()` could nil it out between
    /// `handleTap`'s lock-unlock and its yield call — not a crash (the
    /// optional read survives), but a data race under Swift 6 strict
    /// concurrency. Guard explicitly.
    private var continuation: AsyncStream<[Float]>.Continuation?

    /// Total samples ever captured this session, in absolute indexing.
    /// Safe to call from any actor.
    var totalSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return pcm.totalSamples
    }

    /// Begin capture. Returns an async stream that yields one
    /// `[frameSize]`-Float array per VAD window. The stream finishes when
    /// `stop()` is called.
    @MainActor
    func start() throws -> AsyncStream<[Float]> {
        lock.lock()
        self.pcm.reset()
        self.leftover = []
        self.leftoverStart = 0
        self.stopped = false
        lock.unlock()

        let stream = AsyncStream<[Float]> { cont in
            self.lock.lock()
            self.continuation = cont
            self.lock.unlock()
            cont.onTermination = { @Sendable _ in }
        }

        try openAndStartHAL()
        installDefaultInputListener()

        return stream
    }

    /// Resolve the effective input device, query its native stream
    /// format, build the converter, and start the HAL IOProc. Used by
    /// `start()` AND the device-change handler. Caller must guarantee
    /// the previous IOProc (if any) was torn down beforehand.
    @MainActor
    private func openAndStartHAL() throws {
        guard let device = resolveEffectiveDevice() else {
            throw AudioError.noInputDevice
        }
        guard let asbd = AudioDeviceManager.inputStreamFormat(for: device.id),
              let inFmt = AudioDeviceManager.avAudioFormat(from: asbd)
        else {
            throw AudioError.streamFormatUnavailable
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
        // Pre-allocate the reusable output buffer for this device's
        // format. Size is a constant upper bound — see
        // `outputCapacityFrames` doc-comment. Fail closed if the
        // allocation refuses (extremely unusual; would mean OOM).
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: Self.outputCapacityFrames) else {
            throw AudioError.converterCreateFailed
        }

        lock.lock()
        self.deviceID = device.id
        self.inputFormat = inFmt
        self.outputFormat = outFmt
        self.converter = conv
        self.outputBuffer = outBuf
        lock.unlock()

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            device.id,
            ioQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleIOProc(inputData: inInputData)
        }
        guard createStatus == noErr, let proc = procID else {
            throw AudioError.ioProcCreateFailed(createStatus)
        }
        self.ioProcID = proc

        let startStatus = AudioDeviceStart(device.id, proc)
        guard startStatus == noErr else {
            // Best-effort teardown on the half-built proc so we don't
            // leak the HAL handle.
            AudioDeviceDestroyIOProcID(device.id, proc)
            self.ioProcID = nil
            throw AudioError.ioProcStartFailed(startStatus)
        }

        let inputRate = Int(inFmt.sampleRate)
        let channelCount = Int(inFmt.channelCount)
        let deviceName = device.name
        Self.log.info("recording running on \"\(deviceName, privacy: .private)\" (\(inputRate)Hz x\(channelCount) → 16kHz mono)")
    }

    /// Stop + destroy the current IOProc (idempotent / no-op when
    /// nothing is running). Does NOT touch `pcm` or `continuation` —
    /// the session is allowed to keep going after a config-change
    /// rebuild.
    ///
    /// **Drain `ioQueue` between Stop and Destroy.** `AudioDeviceStop`
    /// halts new dispatches into the queue, but blocks already enqueued
    /// may still be waiting to run. If we destroyed the IOProc and
    /// then immediately swapped `inputFormat` (config-change path), a
    /// late block would read the new format but reference the OLD
    /// device's bytes — `AVAudioPCMBuffer(bufferListNoCopy:)` would
    /// alias bytes that the HAL may have already reclaimed. `sync` on
    /// the serial `ioQueue` from `@MainActor` is deadlock-free (the
    /// IOProc body never bounces back to main).
    ///
    /// The drain time is instrumented — a sync that takes longer than
    /// 5 ms means the IOProc body was holding the queue significantly
    /// past the AudioDeviceStop return, which would surface as a UI
    /// hitch on `stop()`. Production reports of "Esc-cancel hangs" are
    /// the first thing to look for here.
    @MainActor
    private func teardownHAL() {
        guard let proc = ioProcID else { return }
        let dev = deviceID
        AudioDeviceStop(dev, proc)
        let drainStart = DispatchTime.now()
        ioQueue.sync {}
        let drainMs = Double(DispatchTime.now().uptimeNanoseconds - drainStart.uptimeNanoseconds) / 1_000_000
        if drainMs > 5 {
            Self.log.warning("ioQueue drain took \(drainMs, format: .fixed(precision: 1), privacy: .public)ms — investigate IOProc body for long work")
        }
        AudioDeviceDestroyIOProcID(dev, proc)
        ioProcID = nil
        // Release the reusable output buffer alongside the IOProc — a
        // subsequent `openAndStartHAL` rebuilds one for the new
        // device's `outputFormat`.
        lock.lock()
        outputBuffer = nil
        lock.unlock()
    }

    /// Resolve the effective input device. Reads `AudioDeviceManager`
    /// from `@MainActor` synchronously — `start()` and
    /// `handleConfigurationChange` both originate on `@MainActor`.
    /// Logs a one-line note when the BT-avoidance fallback engages so
    /// `log show` can correlate "music got louder" reports against the
    /// session's effective device.
    ///
    /// Device names are logged at `.privacy(.private)` — they routinely
    /// include the user's name ("John's AirPods") via Continuity. The
    /// log still surfaces locally with `--info --debug` for developer
    /// debugging; shared `log collect` dumps redact them.
    @MainActor
    private func resolveEffectiveDevice() -> AudioDeviceManager.Device? {
        let mgr = AudioDeviceManager.shared
        let pick = mgr.effectiveDevice
        if let pick,
           mgr.preferBuiltInOverBluetooth,
           mgr.selectedUID == nil,
           let sysDef = mgr.systemDefault,
           sysDef.isBluetooth,
           pick.isBuiltIn {
            Self.log.info("BT input avoidance: system default \"\(sysDef.name, privacy: .private)\" is Bluetooth — using built-in mic \"\(pick.name, privacy: .private)\" to keep A2DP music quality / ducking")
        }
        return pick
    }

    // MARK: - HAL property listener (device-change handling)

    /// Install a HAL listener for `kAudioHardwarePropertyDefaultInputDevice`
    /// scoped to this session. Mirrors the broader listener
    /// `AudioDeviceManager` runs at app startup, but the recorder needs
    /// its own callback to rebuild the IOProc on top of the new device.
    /// We could subscribe to `AudioDeviceManager.shared` via
    /// `withObservationTracking`, but a direct HAL listener keeps
    /// `AudioRecorder` free of `MainActor` plumbing and matches the
    /// session lifetime exactly.
    ///
    /// The listener dispatches on `DispatchQueue.main` so the
    /// rebuild path can read `AudioDeviceManager` (which is
    /// `@MainActor`-isolated) without an extra hop.
    ///
    /// **Listener ordering note.** `AudioDeviceManager.shared` also
    /// listens for the same property at app-startup. Both dispatch on
    /// `DispatchQueue.main` so ordering is serialised —
    /// `AudioDeviceManager` refreshes its `inputs` / `systemDefault`
    /// mirrors first, then this listener fires and reads them via
    /// `resolveEffectiveDevice()`. A future refactor that delays
    /// `AudioDeviceManager`'s init could break this ordering and the
    /// BT-avoidance fallback would reference stale state — keep the
    /// startup ordering or audit both listeners together.
    ///
    /// **Failure mode is silent-by-design.** If `AudioObjectAddPropertyListenerBlock`
    /// returns non-noErr we log `.error` and continue without a
    /// listener — the session still works with the device it started
    /// on, just won't rebuild on mid-session device changes. The
    /// escalation cost (new error case, new HUD copy, new permission-
    /// adjacent user-facing message) outweighs the rare benefit: by
    /// the time the user notices a missing mid-session swap they've
    /// typically already release-cycled the hotkey, which fully tears
    /// down and re-creates the recorder on the next press.
    @MainActor
    private func installDefaultInputListener() {
        guard defaultInputListenerBlock == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The HAL dispatches this block on `DispatchQueue.main`, which
        // is the AppKit main run-loop. `MainActor.assumeIsolated`
        // bridges into our `@MainActor`-isolated rebuild path.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            defaultInputListenerBlock = block
        } else {
            Self.log.error("failed to register default-input HAL listener: \(status)")
        }
    }

    @MainActor
    private func removeDefaultInputListener() {
        guard let block = defaultInputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultInputListenerBlock = nil
    }

    /// HAL signalled the default input changed. Tear down the IOProc,
    /// rebuild the converter for the new input format, and restart —
    /// without dropping the session's accumulated PCM. The user keeps
    /// dictating; the splice is a few ms of silence.
    ///
    /// `resolveEffectiveDevice()` inside `openAndStartHAL` re-applies the
    /// BT-avoidance policy against the now-current system default.
    /// Without that, a mid-session AirPods connect would let the
    /// recorder pick up the BT mic and silently undo the avoidance,
    /// downgrading the user's music from A2DP to HFP/SCO mid-recording
    /// — the regression the BT-avoidance feature exists to fix.
    ///
    /// **Late-callback guard.** `AudioObjectRemovePropertyListenerBlock`
    /// halts future dispatches but a block already queued on
    /// `DispatchQueue.main` still runs. The `stopped` latch lets us
    /// drop a callback that lands after `stop()` so we don't spawn an
    /// orphaned IOProc whose first `handleIOProc` has no consumer.
    @MainActor
    private func handleConfigurationChange() {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        if isStopped {
            Self.log.info("HAL default-input change — ignored (recorder is stopped)")
            return
        }
        Self.log.info("HAL default-input change — rebuilding IOProc")
        teardownHAL()
        do {
            try openAndStartHAL()
        } catch {
            Self.log.error("config-change rebuild failed: \(error.localizedDescription, privacy: .public)")
            // Best-effort: finish the stream so the session sees the
            // tail and can paste what we already have. Swap the
            // continuation reference out under `lock` so a concurrent
            // IOProc dispatch observes a coherent old-or-nil value.
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.finish()
        }
    }

    /// Halt capture. Finishes the async stream and tears down the IOProc.
    @MainActor
    func stop() {
        // Latch first — a HAL property-change callback already queued
        // on `DispatchQueue.main` reads this and short-circuits in
        // `handleConfigurationChange` instead of spawning an orphan
        // IOProc against the new default input.
        lock.lock()
        stopped = true
        lock.unlock()
        removeDefaultInputListener()
        teardownHAL()
        // Flush any partial frame? We don't — partial means <256 ms of audio,
        // not enough for a VAD window. Let the recording session handle the
        // final tail via `samples(from:to:)`. Swap the continuation
        // reference out under `lock` so a concurrent IOProc dispatch that
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

    // MARK: - IOProc → resample → fan out

    /// Adapter: wrap the HAL's `inInputData` (which is a non-owning
    /// `UnsafePointer<AudioBufferList>` valid only for the lifetime of
    /// this IOProc call) as an `AVAudioPCMBuffer` and feed it through
    /// the existing converter path. `bufferListNoCopy` does NOT copy —
    /// the buffer view aliases HAL memory. We synchronously consume it
    /// inside `handleTap`'s `converter.convert` call (which copies into
    /// its own output buffer), so by the time the IOProc returns the
    /// alias is no longer held.
    private func handleIOProc(inputData: UnsafePointer<AudioBufferList>) {
        // Snapshot every shared state we need in ONE lock-acquire so
        // a concurrent `handleConfigurationChange` can't swap any
        // of these out from under us mid-call. Reading-after-snapshot
        // is safe — `AVAudioFormat`, `AVAudioConverter`, and
        // `AVAudioPCMBuffer` are Obj-C reference types with no
        // internal mutation between calls. Skip the dispatch if any
        // critical piece is missing (tear-down in progress).
        lock.lock()
        let inFmt = inputFormat
        let conv = converter
        let outFmt = outputFormat
        let outBuf = outputBuffer
        lock.unlock()
        guard let inFmt, let conv, let outFmt, let outBuf else { return }

        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: inFmt,
            bufferListNoCopy: inputData,
            deallocator: nil
        ) else { return }

        handleTap(inBuffer, converter: conv, outputFormat: outFmt, outputBuffer: outBuf)
    }

    private func handleTap(
        _ inBuffer: AVAudioPCMBuffer,
        converter conv: AVAudioConverter,
        outputFormat outFmt: AVAudioFormat,
        outputBuffer outBuf: AVAudioPCMBuffer
    ) {
        let inFrames = Int(inBuffer.frameLength)
        guard inFrames > 0 else { return }
        let ratio = outFmt.sampleRate / inBuffer.format.sampleRate
        let neededOutFrames = AVAudioFrameCount(Double(inFrames) * ratio + 256)
        if neededOutFrames > outBuf.frameCapacity {
            // Sanity guard — should not fire in normal hardware paths
            // (see `outputCapacityFrames` doc-comment). If it does,
            // drop the call rather than risk a buffer overrun.
            Self.log.error("output capacity \(outBuf.frameCapacity) too small for \(neededOutFrames) frames — input is unexpectedly large")
            return
        }
        // Reset the reusable buffer for this conversion. Setting
        // `frameLength = 0` is the documented way to "rewind" an
        // AVAudioPCMBuffer for re-use.
        outBuf.frameLength = 0

        // Single-shot input-block: provide the buffer once, then return
        // .noDataNow so the converter preserves filter state for the next
        // IOProc invocation. Returning .endOfStream here would corrupt
        // audio — see the class doc-comment.
        let feed = ConverterFeed(buffer: inBuffer)
        var convError: NSError?
        let status = conv.convert(to: outBuf, error: &convError) { _, statusPtr in
            feed.next(status: statusPtr)
        }

        if status == .error || convError != nil {
            Self.log.error("converter error: \(convError?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }

        let outFrames = Int(outBuf.frameLength)
        guard outFrames > 0,
              let chData = outBuf.floatChannelData?[0]
        else { return }

        let arr = Array(UnsafeBufferPointer(start: chData, count: outFrames))

        // One lock acquire for the entire append + drain + snapshot
        // cycle. Yielding to the continuation happens outside the
        // lock — `AsyncStream.Continuation` is documented as
        // concurrency-safe; we just can't race the pointer load
        // against a nil store from `stop()`.
        var emit: [[Float]] = []
        lock.lock()
        pcm.append(arr)
        leftover.append(contentsOf: arr)

        // Drain full VAD windows via the advancing `leftoverStart`
        // cursor rather than `removeFirst(frameSize)` — the cursor is
        // O(1) per emit; `removeFirst` shifts the remaining tail and
        // is O(N). Compact once the cursor passes the half-way point
        // so backing storage stays bounded.
        while leftover.count - leftoverStart >= Self.frameSize {
            let end = leftoverStart + Self.frameSize
            let frame = Array(leftover[leftoverStart..<end])
            leftoverStart = end
            emit.append(frame)
        }
        if leftoverStart > 0, leftoverStart >= leftover.count / 2 {
            leftover = Array(leftover[leftoverStart...])
            leftoverStart = 0
        }
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
