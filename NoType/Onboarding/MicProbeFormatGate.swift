import AVFoundation

/// Pure installability gate for `MicProbe`'s input tap.
///
/// **Why this exists.** `MicProbe.start()` pins the user's chosen input
/// device via `AudioDeviceManager.apply(_:to:)` →
/// `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`, which
/// is **asynchronous**: the HAL can still be switching when the next
/// line reads `engine.inputNode.outputFormat(forBus: 0)`. Handing
/// `installTap` a format that disagrees with the input node's live
/// hardware format makes AVFAudio raise an Objective-C
/// `com.apple.coreaudio.avfaudio` exception ("required condition is
/// false: format.sampleRate == hwFormat.sampleRate").
///
/// A raise there is worse than a failed tap. Both `MicProbe` paths that
/// can reach `installTap` after `start()` run inside a
/// `Task { @MainActor }` — the `.AVAudioEngineConfigurationChange`
/// observer and the device-observation loop — and an Objective-C
/// exception unwinding out of a main-actor Swift-concurrency job orphans
/// the thread's `ExecutorTrackingInfo`, so the *next* "am I on the main
/// executor?" check SIGSEGVs somewhere unrelated. See
/// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
///
/// **Residual window — do not overclaim this gate.** The device switch is
/// asynchronous, so a shape validated immediately before `installTap` can
/// in principle still be stale by the time the call lands. The gate
/// shrinks the window from several object constructions wide to one call
/// wide; it does not close it to zero, and it validates *format* only —
/// not every condition under which `installTap` can raise. `MicProbe` is
/// therefore exonerated by an absent `com.apple.coreaudio.avfaudio`
/// record in the `ExceptionBreadcrumb` log, not by the absence of a
/// crash.
///
/// Pure function namespace: deterministic, no I/O, no `AVAudioEngine`.
/// Pinned by `NoTypeTests/MicProbeFormatGateTests.swift`.
enum MicProbeFormatGate {

    /// The two dimensions of an input format that a mid-session device
    /// switch actually changes — sample rate (44.1 kHz built-in → 48 kHz
    /// USB) and channel count (mono built-in → stereo interface).
    ///
    /// Deliberately *not* full `AVAudioFormat` equality: the candidate is
    /// itself a read of the same node property, so the sample format and
    /// interleaving cannot differ, while a channel-layout-only difference
    /// would fail the gate and leave the user with a permanently dead
    /// spectrum meter for no safety gain.
    struct Shape: Equatable, Sendable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount

        init(sampleRate: Double, channelCount: AVAudioChannelCount) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
        }

        init(_ format: AVAudioFormat) {
            self.init(sampleRate: format.sampleRate, channelCount: format.channelCount)
        }
    }

    /// Why a candidate shape is not installable.
    ///
    /// `CaseIterable` exists for the exhaustiveness test — it asserts
    /// every case is produced by at least one shape pair, so adding a
    /// case without a *predicate-level* input goes red instead of
    /// shipping dead classification. Production reachability is a
    /// separate question and is what `positivityRejection(_:)` exists
    /// to keep true for the two non-positive cases: run only from
    /// `rejection(candidate:live:)`, they would be shadowed at the call
    /// site by `AVAudioConverter(from:to:)` returning nil first, and a
    /// diagnostic log would name the wrong reason.
    enum Rejection: Hashable, Sendable, CaseIterable, CustomStringConvertible {
        /// Node reports 0 Hz — typically no input device, or microphone
        /// permission not granted.
        case nonPositiveSampleRate
        /// Node reports 0 channels — same family as above.
        case nonPositiveChannelCount
        /// The device switch landed between the read and the call.
        case sampleRateMismatch
        /// Ditto, across a mono → multichannel device change.
        case channelCountMismatch

        var description: String {
            switch self {
            case .nonPositiveSampleRate:  "input reports a zero sample rate"
            case .nonPositiveChannelCount: "input reports zero channels"
            case .sampleRateMismatch:     "input sample rate changed mid-setup"
            case .channelCountMismatch:   "input channel count changed mid-setup"
            }
        }
    }

    /// Returns `nil` when `shape` describes a live input node, otherwise
    /// the reason it does not.
    ///
    /// Split out of `rejection(candidate:live:)` so the caller can run it
    /// **before** constructing an `AVAudioConverter`. A 0 Hz / 0 ch shape
    /// is a dead node (no input device, or microphone permission not
    /// granted); handing it to `AVAudioConverter(from:to:)` — an
    /// Objective-C initializer, called from inside a main-actor `Task` —
    /// with only "verified empirically that it returns nil" behind it is
    /// the same unvalidated-argument shape this gate exists to remove.
    /// Checking first also keeps both non-positive cases reachable in
    /// production, so the diagnostic log names the dead node rather than
    /// a downstream converter failure.
    static func positivityRejection(_ shape: Shape) -> Rejection? {
        guard shape.sampleRate > 0 else { return .nonPositiveSampleRate }
        guard shape.channelCount > 0 else { return .nonPositiveChannelCount }
        return nil
    }

    /// Returns `nil` when `candidate` is safe to hand to `installTap`,
    /// otherwise the first reason it is not.
    ///
    /// - Parameters:
    ///   - candidate: the shape the converter was built from and the tap
    ///     would be installed with.
    ///   - live: the input node's shape read immediately before the call.
    ///
    /// `live` positivity needs no separate limb: a device that vanished
    /// (0 Hz) fails the sample-rate comparison against a positive
    /// candidate.
    static func rejection(candidate: Shape, live: Shape) -> Rejection? {
        if let rejection = positivityRejection(candidate) { return rejection }
        guard candidate.sampleRate == live.sampleRate else { return .sampleRateMismatch }
        guard candidate.channelCount == live.channelCount else { return .channelCountMismatch }
        return nil
    }
}
