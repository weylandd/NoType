import XCTest
@testable import NoType

/// Surface-level tests for `AudioRecorder`'s public seams. Live mic
/// behaviour is documented as a hardware smoke (see plan
/// 2026-05-18-001 §73–88) and the `NoType/Recording/CLAUDE.md` "Don't
/// write tests against live mic input" hard rule — what *is*
/// unit-testable is the `AudioError` LocalizedError contract that
/// `AppState.surfaceError` reads when the HAL refuses.
///
/// The format-conversion / stream-format helpers themselves live on
/// `AudioDeviceManager` (`avAudioFormat(from:)` / `inputStreamFormat`)
/// and are covered by `AudioDeviceManagerTests`.
final class AudioRecorderHALTests: XCTestCase {

    func test_audioError_noInputDevice_hasUserFacingDescription() {
        let err = AudioRecorder.AudioError.noInputDevice
        XCTAssertEqual(err.errorDescription, "Couldn't find an audio input device.")
    }

    func test_audioError_streamFormatUnavailable_hasUserFacingDescription() {
        let err = AudioRecorder.AudioError.streamFormatUnavailable
        XCTAssertEqual(err.errorDescription, "Couldn't read the input device's audio format.")
    }

    func test_audioError_converterCreateFailed_hasUserFacingDescription() {
        let err = AudioRecorder.AudioError.converterCreateFailed
        XCTAssertEqual(err.errorDescription, "Couldn't create audio converter.")
    }

    /// HAL OSStatus codes are surfaced in the message so a support
    /// report can quote the exact code (e.g. `-10851` for
    /// `kAudioUnitErr_InvalidElement`, `1852797029` for `'!run'`).
    /// Pinning the prefix protects the "log shows the status" contract;
    /// the numeric body is variable across machines.
    func test_audioError_ioProcCreateFailed_includesOSStatusInMessage() {
        let err = AudioRecorder.AudioError.ioProcCreateFailed(-10851)
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("Couldn't open audio capture"), "got: \(msg)")
        XCTAssertTrue(msg.contains("-10851"), "OSStatus should be in the message: \(msg)")
    }

    func test_audioError_ioProcStartFailed_includesOSStatusInMessage() {
        let err = AudioRecorder.AudioError.ioProcStartFailed(560226676)  // 'who?'
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("Couldn't start audio capture"), "got: \(msg)")
        XCTAssertTrue(msg.contains("560226676"), "OSStatus should be in the message: \(msg)")
    }

    /// `MicProbe.Error.engineStartFailed(Error)` is the MicProbe-only
    /// case — split out of `AudioRecorder.AudioError` because the
    /// production recorder is pure HAL while the onboarding probe
    /// still rides `AVAudioEngine`. Pin the message template so a
    /// future rename doesn't silently change the onboarding error
    /// HUD copy.
    func test_micProbeError_engineStartFailed_wrapsUnderlyingDescription() {
        struct FakeUnderlying: LocalizedError {
            var errorDescription: String? { "couldn't connect" }
        }
        let err = MicProbe.Error.engineStartFailed(FakeUnderlying())
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("Couldn't start audio engine"), "got: \(msg)")
        XCTAssertTrue(msg.contains("couldn't connect"), "underlying description must surface: \(msg)")
    }

    /// `MicProbe.Error.inputFormatNotInstallable` is the only case whose
    /// message is assembled from a payload's `CustomStringConvertible`
    /// rather than a literal. Two ways that breaks silently: dropping the
    /// `Rejection: CustomStringConvertible` conformance makes the
    /// interpolation fall back to the bare case name (`sampleRateMismatch`
    /// instead of a sentence), and a blank `description` makes the message
    /// collapse to punctuation. Pin every case's rendered text — these
    /// same strings are what the `mic probe tap skipped:` log line carries
    /// into a diagnostic read.
    func test_micProbeError_inputFormatNotInstallable_rendersEachRejectionReason() {
        let expected: [MicProbeFormatGate.Rejection: String] = [
            .nonPositiveSampleRate: "input reports a zero sample rate",
            .nonPositiveChannelCount: "input reports zero channels",
            .sampleRateMismatch: "input sample rate changed mid-setup",
            .channelCountMismatch: "input channel count changed mid-setup"
        ]

        for rejection in MicProbeFormatGate.Rejection.allCases {
            guard let reason = expected[rejection] else {
                XCTFail("no expected copy for \(rejection) — add it or drop the case")
                continue
            }
            XCTAssertEqual(rejection.description, reason)

            // `reason` is a literal, so this equality also catches the
            // dropped-conformance case: the message would render the raw
            // case name and stop matching.
            let msg = MicProbe.Error.inputFormatNotInstallable(rejection).errorDescription ?? ""
            XCTAssertEqual(msg, "Couldn't tap the microphone: \(reason).")
        }
    }

    func test_outputSampleRate_is16kHz() {
        // Non-negotiable per `Recording/CLAUDE.md` invariant 1 (Silero
        // requires 16 kHz). If a refactor ever changes this constant,
        // the VAD breaks silently — pin it.
        XCTAssertEqual(AudioRecorder.outputSampleRate, 16_000)
    }

    func test_frameSize_matchesVADWindow() {
        // 4096 samples @ 16 kHz = 256 ms = Silero v6 unified `chunkSize`.
        // Pinned together with `PauseDetectorTests` so a sample-rate or
        // window-size change has to fix both fixtures + this contract.
        XCTAssertEqual(AudioRecorder.frameSize, 4_096)
    }
}
