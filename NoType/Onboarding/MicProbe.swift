@preconcurrency import AVFoundation
import Observation
import OSLog

/// Lightweight microphone tap used by the onboarding mic-check screen.
///
/// Owns its own `AVAudioEngine`, resamples to 16 kHz mono float32, and
/// keeps the trailing `AudioSpectrum.fftLength` samples in a ring buffer
/// for the live spectrum meter. No VAD, no chunking, no Gemini, no
/// `RecordingSession` — strictly mic in → ring buffer → spectrum.
///
/// Production recording uses `AudioRecorder` + `RecordingSession`; this
/// is a stand-alone probe so the mic-check screen doesn't need (and
/// can't accidentally trigger) the full transcription pipeline.
///
/// Re-applies the user's pinned input device on **every** tap install
/// (`installTapAndStart()`), and restarts the engine when
/// `AudioDeviceManager.shared.selectedUID` changes mid-session, so the
/// picker on the same screen feels live. The pin used to sit on the
/// `start()` path alone, which is why the picker restarted the engine on
/// the old microphone — issue #86.
///
/// `@unchecked Sendable` (no `@MainActor`) by design — `AVAudioEngine`
/// invokes the `installTap` callback on its own realtime thread; if the
/// owning class were main-actor-isolated, Swift 6's runtime isolation
/// check would `dispatch_assert_queue_fail` the moment audio starts
/// flowing. Same shape as `AudioRecorder`.
///
/// **Two different disciplines keep that sound, and neither is "every
/// field takes `lock`".** `pcm` and `tapInstalled` are genuinely
/// concurrent — the realtime thread appends to one, `deinit` on an
/// arbitrary thread test-and-clears the other — so both take `lock`.
/// `converter` and `outputFormat` do not: they are written only between
/// `removeTapIfInstalled()` and `installTap(onBus:…)`, i.e. only while no
/// tap block exists to read them, and `installTap` itself publishes the
/// write to the realtime thread. Keep them inside that window or they
/// need the lock too.
final class MicProbe: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.notype", category: "onboarding.mic")

    /// MicProbe-local error namespace. Lives here (not on
    /// `AudioRecorder.AudioError`) because the probe rides on
    /// `AVAudioEngine` for the onboarding spectrum meter while the
    /// production recorder is pure HAL — the two surface different
    /// failure modes and one shared enum would be a misleading
    /// "tagged union of unrelated paths".
    enum Error: Swift.Error, LocalizedError {
        case engineStartFailed(Swift.Error)
        case converterCreateFailed
        /// The input node's live format wasn't installable as a tap
        /// format — see `MicProbeFormatGate`. Surfaces as a flat
        /// spectrum meter, this screen's documented failure mode, in
        /// place of an Objective-C raise out of a main-actor `Task`.
        case inputFormatNotInstallable(MicProbeFormatGate.Rejection)

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let e): "Couldn't start audio engine: \(e.localizedDescription)"
            case .converterCreateFailed:    "Couldn't create audio converter."
            case .inputFormatNotInstallable(let reason): "Couldn't tap the microphone: \(reason)."
            }
        }
    }

    private let engine = AVAudioEngine()
    /// Guards `pcm` and `tapInstalled`.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var pcm: [Float] = []
    /// 4 × AudioSpectrum.fftLength (1024) — hardcoded because reading
    /// the main-actor-isolated `AudioSpectrum.fftLength` from this
    /// non-isolated class's stored-property initializer is rejected
    /// under strict concurrency.
    private let bufferCapacity = 4096
    /// Sole gate on every `removeTap` call. Guarded by `lock` because
    /// `deinit` runs nonisolated on whatever thread drops the last
    /// reference — see `removeTapIfInstalled()`.
    private var tapInstalled = false
    private var deviceObservationTask: Task<Void, Never>?
    private var configChangeObserver: NSObjectProtocol?
    /// Set by `stop()`, cleared by `start()`. **Main-actor only** — like
    /// `deviceObservationTask` and `configChangeObserver`, it is touched from
    /// `@MainActor` methods and never from the realtime tap thread.
    ///
    /// `rebuild()` is reached from three `Task { @MainActor }` bodies, and a
    /// task already enqueued when the user leaves the mic-check step still
    /// runs after `stop()` — re-opening the microphone on a screen nobody is
    /// looking at, and (because `start()` early-returns on a running engine)
    /// leaving a probe whose observers were torn down and cannot be re-armed.
    /// The observation loop already had `Task.isCancelled` for this; the
    /// notification path had nothing, and the decline retry below would have
    /// widened the window. One latch closes all three.
    private var isStopped = false
    /// Bounded recovery for a declined install. See `scheduleDeclineRetry`.
    private var declineRetryTask: Task<Void, Never>?
    private var declineRetriesUsed = 0

    /// Begin capture. Idempotent: calling on an already-running probe is
    /// a no-op. Failures are logged and swallowed — the spectrum meter
    /// just stays flat (the screen makes the user's intent clear: if the
    /// wave doesn't move, mic isn't reaching us).
    @MainActor
    func start() {
        guard !engine.isRunning else { return }
        isStopped = false
        declineRetriesUsed = 0
        lock.lock(); pcm = []; lock.unlock()

        // **Both observers are installed BEFORE the tap goes in, and the
        // ordering is load-bearing.** The device pin inside
        // `installTapAndStart()` is asynchronous, so the very first
        // install is the most likely moment for `MicProbeFormatGate` to
        // reject — and `.AVAudioEngineConfigurationChange` is precisely
        // the notification that fires when that switch finally lands.
        // Wiring the observers only on the success path meant a rejected
        // first install threw away its own recovery signal and left the
        // user a dead spectrum meter for the rest of the screen, with
        // even the device picker unable to revive it. Both are
        // idempotent-guarded because a failed `start()` leaves the engine
        // stopped, so a retry re-enters here.
        //
        // Note the observers are now armed *ahead of* the first pin
        // rather than after it, which strictly widens their coverage: the
        // configuration change the pin itself provokes is observed too.
        if configChangeObserver == nil {
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.rebuild() }
            }
        }

        // Restart the engine when the user picks a different input device
        // from the picker on the same screen. `AudioDeviceManager` is
        // `@Observable`, so we watch `selectedUID` via a
        // `withObservationTracking` loop instead of a Combine sink.
        if deviceObservationTask == nil {
            deviceObservationTask = Task { @MainActor [weak self] in
                // Skip the initial value (matches the prior `.dropFirst()`).
                _ = AudioDeviceManager.shared.selectedUID
                while !Task.isCancelled {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        withObservationTracking {
                            _ = AudioDeviceManager.shared.selectedUID
                        } onChange: {
                            cont.resume()
                        }
                    }
                    if Task.isCancelled { return }
                    self?.rebuild()
                }
            }
        }

        do {
            try installTapAndStart(pinning: AudioDeviceManager.shared.effectiveDevice)
        } catch {
            // Deliberately not a teardown: the observers above stay armed
            // so the next config change or device pick retries.
            Self.log.error("mic probe start failed: \(error.localizedDescription, privacy: .public)")
            return
        }
    }

    @MainActor
    func stop() {
        isStopped = true
        declineRetryTask?.cancel()
        declineRetryTask = nil
        deviceObservationTask?.cancel()
        deviceObservationTask = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        removeTapIfInstalled()
        if engine.isRunning {
            engine.stop()
        }
        lock.lock(); pcm = []; lock.unlock()
    }

    /// Safety net for the mic (R20). The normal teardown is `.onDisappear`
    /// → `stop()`, but if that never fires — window torn down out of order,
    /// SwiftUI view reuse, an early-return error path — the probe can be
    /// released with the engine still running, leaving the input light on.
    /// Mirror `stop()`'s teardown here so the mic is always released once
    /// the probe deallocs.
    ///
    /// `deinit` runs nonisolated (MicProbe is `@unchecked Sendable`, not
    /// `@MainActor`), so it can't call the `@MainActor stop()`; it repeats
    /// the same steps inline against this now-unreferenced instance.
    /// `Task.cancel()` and `NotificationCenter.removeObserver` are
    /// thread-safe. Idempotent after `stop()` — every field is already
    /// cleared, so each branch is a no-op on the normal path, which is
    /// also the only path this net is *expected* to run on.
    ///
    /// **Known pre-existing hazard, unchanged by the R10 fix.** The tap
    /// block's `self?` upgrade is the one strong reference the realtime
    /// thread ever holds, so if the main thread drops the `@State` box
    /// while a tap callback is in flight, the realtime thread performs the
    /// last release and `deinit` — hence `removeTap` and `engine.stop()` —
    /// runs there. Reaching that needs a probe released *without* `stop()`
    /// while audio is flowing; on the normal `.onDisappear` path `stop()`
    /// has already cleared the gate and this is all no-ops. Do not "fix"
    /// it by hopping to the main queue: that is KTD5's rejected
    /// containment shape, and a deinit cannot outlive itself to await one.
    ///
    /// **The tap gate goes through `removeTapIfInstalled()`, which takes
    /// `lock` (R10).** Dealloc can land on any thread — SwiftUI holds the
    /// probe in `@State`, so `OnboardingMicCheckStep` allocates and drops
    /// throwaway instances on body passes — and reading `tapInstalled`
    /// without the lock has no acquire edge against the main thread's
    /// write. A stale `false` leaks the tap and leaves the mic light on; a
    /// stale `true` double-removes and raises out of AVFAudio. The other
    /// two fields read here are not lock-guarded state: they are written
    /// on the main actor only and, with no live reference left, nothing
    /// can be writing them concurrently.
    ///
    /// We deliberately do NOT resume the device-observation continuation
    /// from here: the `Task` captures `self` weakly and holds no mic, so a
    /// still-parked continuation is a benign leak that resolves on the next
    /// `selectedUID` change — cheaper than the double-resume guard a
    /// `withTaskCancellationHandler` would need.
    deinit {
        deviceObservationTask?.cancel()
        declineRetryTask?.cancel()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        removeTapIfInstalled()
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Trailing PCM samples for `AudioSpectrum.bands(from:bandCount:)`.
    /// Returns an empty array if fewer than `count` samples have arrived.
    /// Safe to call from any thread — guarded by `lock`.
    func recentSamples(count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard pcm.count >= count else { return [] }
        return Array(pcm.suffix(count))
    }

    // MARK: - Internals

    /// Pin the selected input device, build the converter, install the
    /// tap, start the engine.
    ///
    /// **The pin lives here, and that placement is the fix for issue
    /// #86.** It used to sit in `start()` only, so `rebuild()` — the path
    /// the device picker and the configuration-change observer both take
    /// — tore the tap down and re-installed it against whatever device
    /// the engine already had. The meter kept moving, so the switch
    /// looked like it worked while the user watched the *previous*
    /// microphone. Two functions each doing half of "set up capture" is
    /// what let them drift; one function that cannot install a tap
    /// without pinning first is what stops it recurring.
    ///
    /// **Statement order is load-bearing.** `AudioDeviceManager.apply`'s
    /// `AudioUnitSetProperty(CurrentDevice)` is asynchronous, so the node's
    /// format can change under us mid-setup; `installTap` with a format the
    /// node no longer reports raises an Objective-C exception, and this
    /// method is reachable from two `Task { @MainActor }` bodies where such
    /// a raise corrupts the thread's executor identity (see
    /// `MicProbeFormatGate`). So: the pin goes first, everything
    /// device-independent is built next — which doubles as settle time
    /// the switch gets for free — the node format is read **once**, both
    /// the converter and the tap are derived from that one read, and the
    /// read is re-validated against the live node immediately before the
    /// tap goes in.
    ///
    /// **The accepted trade, stated precisely — it is a change in *kind*,
    /// not only in frequency.** `start()` runs from `.onAppear`, a
    /// synchronous main-actor callback; `rebuild()` runs from two
    /// `Task { @MainActor }` bodies. So while the pin lived in `start()`
    /// alone, the switch it provokes never overlapped a *concurrency-job*
    /// install — which is §1 of the executor-identity mechanism. It does
    /// now. What bounds it is `apply`'s idempotence: a set happens only
    /// when the device genuinely differs, so the overlap is **one racing
    /// install per real user device change**, and not on the
    /// configuration-change rebuild that follows (device already current,
    /// nothing re-set). One racing install per switch is the irreducible
    /// cost of switching the microphone at all.
    ///
    /// The residual is the few instructions between the gate's `live` read
    /// and `installTap`; a switch landing anywhere earlier makes the gate
    /// *decline* instead — a moment of flat meter, not a dead screen.
    ///
    /// **What makes that second half true is `scheduleDeclineRetry`, and it
    /// is worth knowing why the obvious answer was wrong.** An earlier
    /// revision of this comment credited the recovery to the
    /// `.AVAudioEngineConfigurationChange` observer. That was false on the
    /// path that matters: `rebuild()` stops the engine *before* calling in, a
    /// declined install throws before `engine.start()`, and a stopped engine
    /// posts no further configuration change — so the promised signal was
    /// precisely the one that could not arrive, and a single unlucky picker
    /// switch left a dead meter for the rest of the screen. The observer still
    /// covers `start()`'s own first install, where the engine is not stopped
    /// by us; the ladder covers the rebuild path.
    ///
    /// Verify by hand against a Bluetooth headset, where the switch is
    /// slowest. If a reporter's `OBJC THROW` ever names
    /// `com.apple.coreaudio.avfaudio` on a build ≥ 0.1.14, the fix is to make
    /// the install **wait** for the switch — not to move the pin back, which
    /// restores the silent-wrong-device bug.
    ///
    /// **This method is `nonisolated`, and that is not an oversight — it is
    /// the reason the class is `@unchecked Sendable` rather than
    /// `@MainActor`.** An earlier revision marked it `@MainActor` so it could
    /// read the main-actor-isolated `AudioDeviceManager.shared` directly. That
    /// shipped a launch crash: the `installTap` closure is a literal *created
    /// inside this body*, so under SE-0420 it inherited the method's
    /// isolation, and `AVAudioEngine` calls that block on its realtime audio
    /// thread — `dispatch_assert_queue` fails the moment audio starts flowing.
    /// The crash is `BUG IN CLIENT OF LIBDISPATCH: Block was expected to
    /// execute on queue [com.apple.main-thread]`, and it is the same defect
    /// already written up in
    /// `docs/solutions/runtime-errors/audio-ioproc-mainactor-inheritance-crash-2026-05-19.md`
    /// — **not** the macOS 26 executor-identity family, which never reaches
    /// libdispatch's queue check.
    ///
    /// So the effective device is resolved by the caller, both of which are
    /// already `@MainActor`, and handed in. The `apply` call itself stays
    /// here, which is what the issue-#86 guard pins and what actually stops a
    /// rebuild from re-arming on the wrong microphone.
    private func installTapAndStart(pinning device: AudioDeviceManager.Device?) throws {
        if let device {
            // **The outcome is logged, not discarded.** A pin that fails
            // leaves the meter running on the previous microphone — which
            // is visually identical to issue #86 itself, so without a
            // record there is no way to tell a fix that works from one
            // that is being refused. `apply` logs its own
            // `AudioUnitSetProperty` failure; what it cannot log is the
            // caller's view, which is the one that matters here: which
            // device we asked for, and whether we got it.
            //
            // Device names are `.private` — they routinely carry the
            // user's name via Continuity ("Alex's AirPods"), the same rule
            // `AudioRecorder.resolveEffectiveDevice` follows.
            let pinned = AudioDeviceManager.apply(device, to: engine)
            if pinned {
                Self.log.info("mic probe pinned input device \"\(device.name, privacy: .private)\"")
            } else {
                Self.log.error("mic probe could NOT pin input device \"\(device.name, privacy: .private)\" — meter will run on whatever the engine already had")
            }
        } else {
            Self.log.info("mic probe has no effective input device to pin; using the engine default")
        }

        let input = engine.inputNode

        // Device-independent — built before the node-format read so it
        // isn't work sitting between that read and the tap install.
        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw MicProbe.Error.converterCreateFailed
        }

        // THE single read. Both the converter and the tap are built from
        // this exact value: re-reading for one of them would trade the
        // crash for a permanently dead meter, because `handleTap` feeds
        // every buffer through `converter`.
        let inFmt = input.outputFormat(forBus: 0)
        let candidate = MicProbeFormatGate.Shape(inFmt)

        // Positivity is validated BEFORE the converter, not after. A dead
        // node (0 Hz / 0 ch — no input device, or microphone permission
        // not granted) handed to `AVAudioConverter(from:to:)` is an
        // Objective-C initializer called with an unvalidated argument
        // from inside a main-actor `Task` — the exact shape this fix
        // exists to remove, and "verified empirically that it returns
        // nil" is an observation, not a precondition. Checking here also
        // keeps the two non-positive rejections reachable in production,
        // so the log names the dead node instead of a downstream
        // converter failure.
        if let rejection = MicProbeFormatGate.positivityRejection(candidate) {
            throw Self.notInstallable(rejection, candidate: candidate, live: candidate)
        }

        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw MicProbe.Error.converterCreateFailed
        }

        // Re-validated as late as possible: a device switch may have
        // landed while the converter above was being built. This shrinks
        // the race window to one call; it does not close it (see
        // `MicProbeFormatGate`).
        let live = MicProbeFormatGate.Shape(input.outputFormat(forBus: 0))
        if let rejection = MicProbeFormatGate.rejection(candidate: candidate, live: live) {
            throw Self.notInstallable(rejection, candidate: candidate, live: live)
        }

        // **Nothing above this line mutates the tap.** Every throw path
        // so far leaves an already-running probe exactly as it was, which
        // is what makes a rejection recoverable: `rebuild()` stops the
        // engine before calling in, and a stopped engine posts no further
        // `.AVAudioEngineConfigurationChange`, so tearing the old tap down
        // first would strand the meter on the one signal that could not
        // arrive. A stale tap still has to come off before a new one goes
        // on, and `removeTap` on an untapped bus is its own raise site —
        // hence the gate rather than a bare call.
        removeTapIfInstalled()

        // Written between `removeTap` and `installTap`, so the realtime
        // tap callback can never observe a half-updated converter /
        // output-format pair.
        self.outputFormat = outFmt
        self.converter = conv

        // `@Sendable` strips any isolation this literal would otherwise
        // inherit from the enclosing scope (SE-0420). Belt to the braces of
        // this method being `nonisolated`: the block runs on `AVAudioEngine`'s
        // realtime thread, so an inherited `@MainActor` turns the first buffer
        // into a `dispatch_assert_queue` crash. Keeping the annotation means
        // re-adding an actor annotation to this method fails to compile
        // against `handleTap` instead of shipping a launch crash. Same shape
        // as `dsOnHover` and `AudioRecorder`'s IOProc block.
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { @Sendable [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        lock.lock(); tapInstalled = true; lock.unlock()

        do {
            engine.prepare()
            try engine.start()
        } catch {
            removeTapIfInstalled()
            throw MicProbe.Error.engineStartFailed(error)
        }
    }

    /// Log the rejection with the numbers behind it, then hand back the
    /// error to throw. One shape of log line for both gate call sites —
    /// the `errorDescription` the caller logs carries the reason but not
    /// the rates, and the rates are what a Step 9 diagnostic read needs.
    private static func notInstallable(
        _ rejection: MicProbeFormatGate.Rejection,
        candidate: MicProbeFormatGate.Shape,
        live: MicProbeFormatGate.Shape
    ) -> MicProbe.Error {
        log.error(
            """
            mic probe tap skipped: \(rejection.description, privacy: .public) \
            (candidate \(candidate.sampleRate, privacy: .public) Hz / \
            \(candidate.channelCount, privacy: .public) ch, live \
            \(live.sampleRate, privacy: .public) Hz / \
            \(live.channelCount, privacy: .public) ch)
            """
        )
        return .inputFormatNotInstallable(rejection)
    }

    /// Test-and-clear the tap gate, then remove the tap iff one was
    /// installed. **The only place `removeTap` is called** — mutating a
    /// bus that carries no tap is its own AVFAudio raise site, so the
    /// gate has to be structural rather than local reasoning about the
    /// two lines above the call (which is what the `engine.start()`
    /// failure path used to rely on).
    ///
    /// `tapInstalled` is read and cleared in a single `lock` acquisition
    /// so two callers can't both decide to remove, and so `deinit` —
    /// which runs nonisolated on whatever thread drops the last
    /// reference — never reads it unguarded (R10). `engine.inputNode` is
    /// touched only after the gate opens, i.e. only on a probe that
    /// already reached it once.
    private func removeTapIfInstalled() {
        lock.lock()
        let wasInstalled = tapInstalled
        tapInstalled = false
        lock.unlock()
        guard wasInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Stop and re-arm capture. Reached from the device-observation loop
    /// (the picker), from the `.AVAudioEngineConfigurationChange` observer,
    /// and from the decline retry below.
    ///
    /// It deliberately does **not** pin the device itself: that belongs
    /// to `installTapAndStart()`, where no caller can forget it. This
    /// method having its own half of the setup is the shape that
    /// produced issue #86.
    ///
    /// **It stops the engine before it re-installs, and that is what makes a
    /// decline terminal without the retry below.** A declined install throws
    /// before `engine.start()`, so this method's own `engine.stop()` is the
    /// last thing that ran — and a stopped engine posts no further
    /// `.AVAudioEngineConfigurationChange` (see `installTapAndStart`), so the
    /// notification that would have re-armed it is exactly the one that
    /// cannot arrive. Nothing else is watching: the observation loop only
    /// wakes on the *next* `selectedUID` change, which means a user who
    /// switched microphone once would sit in front of a dead meter until they
    /// switched again.
    @MainActor
    private func rebuild() {
        guard !isStopped else { return }
        engine.stop()
        do {
            try installTapAndStart(pinning: AudioDeviceManager.shared.effectiveDevice)
            declineRetriesUsed = 0
        } catch {
            Self.log.error("mic probe rebuild failed: \(error.localizedDescription, privacy: .public)")
            scheduleDeclineRetry(after: error)
        }
    }

    /// Re-attempt an install the format gate declined, on a short bounded
    /// ladder. **The recovery for this path, because the notification is not.**
    ///
    /// A decline means the node's format changed between the gate's two reads
    /// — i.e. the device switch this install provoked is still landing. That is
    /// a wait, not a failure, so the answer is to look again shortly rather
    /// than to surface anything to the user.
    ///
    /// **The ladder is bounded and the delays are chosen, not arbitrary.**
    /// Three attempts at 150 / 400 / 900 ms: the first covers a built-in or USB
    /// switch, the last covers a Bluetooth headset, which is the slowest switch
    /// this screen sees and the one the hand-verification protocol names. It
    /// gives up after that rather than retrying forever — a switch still not
    /// landed after ~1.5 s is a different problem, and the user can always pick
    /// again, which re-enters through the observation loop with a fresh budget.
    /// The counter resets on any successful install and on `start()`.
    ///
    /// Only `.inputFormatNotInstallable` retries. An engine-start failure or a
    /// converter failure will not fix itself by waiting, and spinning on one
    /// would be the retry storm this bound exists to avoid.
    @MainActor
    private func scheduleDeclineRetry(after error: Swift.Error) {
        guard case MicProbe.Error.inputFormatNotInstallable = error else { return }
        guard !isStopped, declineRetriesUsed < Self.declineRetryDelaysMs.count else { return }
        let delay = Self.declineRetryDelaysMs[declineRetriesUsed]
        declineRetriesUsed += 1

        declineRetryTask?.cancel()
        declineRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            self.declineRetryTask = nil
            self.rebuild()
        }
    }

    /// Backoff for `scheduleDeclineRetry`, in milliseconds. Length is the
    /// attempt budget.
    private static let declineRetryDelaysMs = [150, 400, 900]

    private func handleTap(_ inBuffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }
        let inFrames = Int(inBuffer.frameLength)
        let ratio = outputFormat.sampleRate / inBuffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(inFrames) * ratio + 256)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCap) else {
            return
        }

        // Reference-typed feed: input-block returns the buffer once then
        // reports `.noDataNow` for the lifetime of this conversion call.
        // Mirrors `AudioRecorder.ConverterFeed` so strict-concurrency
        // captured-var checks pass.
        let feed = MicProbeConverterFeed(buffer: inBuffer)
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, statusPtr in
            feed.next(status: statusPtr)
        }

        if status == .error || convError != nil { return }
        let outFrames = Int(outBuffer.frameLength)
        guard outFrames > 0, let chData = outBuffer.floatChannelData?[0] else { return }
        let arr = Array(UnsafeBufferPointer(start: chData, count: outFrames))

        lock.lock()
        pcm.append(contentsOf: arr)
        if pcm.count > bufferCapacity {
            pcm.removeFirst(pcm.count - bufferCapacity)
        }
        lock.unlock()
    }
}

/// Reference type wrapping the per-conversion `consumed` flag — keeps
/// strict-concurrency captured-var rules happy while preserving filter
/// state across taps. Same pattern as `AudioRecorder.ConverterFeed`.
private final class MicProbeConverterFeed: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
}
