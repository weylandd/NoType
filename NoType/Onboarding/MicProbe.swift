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
/// Re-applies the user's pinned input device on `start()` and restarts
/// the engine when `AudioDeviceManager.shared.selectedUID` changes mid-
/// session, so the picker on the same screen feels live.
///
/// `@unchecked Sendable` (no `@MainActor`) by design — `AVAudioEngine`
/// invokes the `installTap` callback on its own realtime thread; if the
/// owning class were main-actor-isolated, Swift 6's runtime isolation
/// check would `dispatch_assert_queue_fail` the moment audio starts
/// flowing. Same shape as `AudioRecorder`. All mutable state is guarded
/// by `lock`.
final class MicProbe: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.notype", category: "onboarding.mic")

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var pcm: [Float] = []
    /// 4 × AudioSpectrum.fftLength (1024) — hardcoded because reading
    /// the main-actor-isolated `AudioSpectrum.fftLength` from this
    /// non-isolated class's stored-property initializer is rejected
    /// under strict concurrency.
    private let bufferCapacity = 4096
    private var tapInstalled = false
    private var deviceObservationTask: Task<Void, Never>?
    private var configChangeObserver: NSObjectProtocol?

    /// Begin capture. Idempotent: calling on an already-running probe is
    /// a no-op. Failures are logged and swallowed — the spectrum meter
    /// just stays flat (the screen makes the user's intent clear: if the
    /// wave doesn't move, mic isn't reaching us).
    @MainActor
    func start() {
        guard !engine.isRunning else { return }
        lock.lock(); pcm = []; lock.unlock()

        let device = AudioDeviceManager.shared.effectiveDevice
        if let device {
            _ = AudioDeviceManager.apply(device, to: engine)
        }

        do {
            try installTapAndStart()
        } catch {
            Self.log.error("mic probe start failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuild() }
        }

        // Restart the engine when the user picks a different input device
        // from the picker on the same screen. `AudioDeviceManager` is
        // `@Observable`, so we watch `selectedUID` via a
        // `withObservationTracking` loop instead of a Combine sink.
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

    @MainActor
    func stop() {
        deviceObservationTask?.cancel()
        deviceObservationTask = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        lock.lock(); pcm = []; lock.unlock()
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

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            throw AudioRecorder.AudioError.converterCreateFailed
        }
        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorder.AudioError.converterCreateFailed
        }
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw AudioRecorder.AudioError.converterCreateFailed
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
            throw AudioRecorder.AudioError.engineStartFailed(error)
        }
    }

    @MainActor
    private func rebuild() {
        engine.stop()
        do {
            try installTapAndStart()
        } catch {
            Self.log.error("mic probe rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

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
