import AVFoundation
import XCTest
@testable import NoType

/// Pins `MicProbeFormatGate` — the pure predicate that decides whether a
/// format read off `AVAudioEngine`'s input node is safe to hand to
/// `installTap`.
///
/// Scope note: the predicate is the unit under test on purpose.
/// `MicProbe.installTapAndStart()` and `tapInstalled` are `private`
/// (`@testable import` reaches `internal`, not `private`) and exercising
/// them would mean driving a live `AVAudioEngine`, which
/// `NoType/Recording/CLAUDE.md` forbids in unit tests. "Every call site
/// is gated" is carried by source inspection + the manual onboarding
/// smoke, not by widening access to make a test reach.
final class MicProbeFormatGateTests: XCTestCase {

    // MARK: - Installable

    func test_installable_whenPositiveAndEqualToLiveNodeFormat() {
        // The steady state: no device switch landed mid-setup.
        let shape = MicProbeFormatGate.Shape(sampleRate: 48_000, channelCount: 1)
        XCTAssertNil(
            MicProbeFormatGate.rejection(candidate: shape, live: shape),
            "a positive shape matching the live node format must install"
        )
    }

    func test_installable_stereo() {
        // USB interface / aggregate device: 2 ch is as valid as 1 ch —
        // MicProbe's converter downmixes to 16 kHz mono.
        let shape = MicProbeFormatGate.Shape(sampleRate: 44_100, channelCount: 2)
        XCTAssertNil(MicProbeFormatGate.rejection(candidate: shape, live: shape))
    }

    // MARK: - Dead node (no input device / microphone not granted)

    func test_rejects_zeroSampleRate() {
        let dead = MicProbeFormatGate.Shape(sampleRate: 0, channelCount: 0)
        XCTAssertEqual(
            MicProbeFormatGate.rejection(candidate: dead, live: dead),
            .nonPositiveSampleRate,
            "a 0 Hz node format must never reach installTap"
        )
    }

    func test_rejects_zeroChannelCount() {
        // Rate resolved, channels didn't — the sample-rate limb passes and
        // the channel limb has to catch it.
        let candidate = MicProbeFormatGate.Shape(sampleRate: 48_000, channelCount: 0)
        XCTAssertEqual(
            MicProbeFormatGate.rejection(candidate: candidate, live: candidate),
            .nonPositiveChannelCount
        )
    }

    func test_rejects_negativeSampleRate_defensive() {
        // `outputFormat(forBus:)` shouldn't produce this; the limb is
        // written as `> 0` rather than `!= 0` so it can't.
        let candidate = MicProbeFormatGate.Shape(sampleRate: -48_000, channelCount: 1)
        XCTAssertEqual(
            MicProbeFormatGate.rejection(candidate: candidate, live: candidate),
            .nonPositiveSampleRate
        )
    }

    // MARK: - The device-switch race

    func test_rejects_sampleRateMismatch() {
        // `AudioDeviceManager.apply` is asynchronous: the built-in mic's
        // 44.1 kHz was read, then the 48 kHz USB device landed.
        XCTAssertEqual(
            MicProbeFormatGate.rejection(
                candidate: .init(sampleRate: 44_100, channelCount: 1),
                live: .init(sampleRate: 48_000, channelCount: 1)
            ),
            .sampleRateMismatch
        )
    }

    func test_rejects_channelCountMismatch() {
        // Built-in mono → USB stereo at the same rate.
        XCTAssertEqual(
            MicProbeFormatGate.rejection(
                candidate: .init(sampleRate: 48_000, channelCount: 1),
                live: .init(sampleRate: 48_000, channelCount: 2)
            ),
            .channelCountMismatch
        )
    }

    func test_rejects_whenLiveNodeWentDead() {
        // Device unplugged mid-setup: live reads 0 Hz, so the mismatch
        // limb covers it — `live` needs no positivity limb of its own.
        XCTAssertEqual(
            MicProbeFormatGate.rejection(
                candidate: .init(sampleRate: 48_000, channelCount: 1),
                live: .init(sampleRate: 0, channelCount: 0)
            ),
            .sampleRateMismatch
        )
    }

    // MARK: - Exhaustiveness

    func test_everyRejectionCase_isProducedBySomeShapePair() {
        // Guards the classification against rot: a case added without a
        // reachable input fails here instead of shipping dead.
        let producers: [MicProbeFormatGate.Rejection: (MicProbeFormatGate.Shape, MicProbeFormatGate.Shape)] = [
            .nonPositiveSampleRate: (.init(sampleRate: 0, channelCount: 1),
                                     .init(sampleRate: 48_000, channelCount: 1)),
            .nonPositiveChannelCount: (.init(sampleRate: 48_000, channelCount: 0),
                                       .init(sampleRate: 48_000, channelCount: 1)),
            .sampleRateMismatch: (.init(sampleRate: 44_100, channelCount: 1),
                                  .init(sampleRate: 48_000, channelCount: 1)),
            .channelCountMismatch: (.init(sampleRate: 48_000, channelCount: 1),
                                    .init(sampleRate: 48_000, channelCount: 2))
        ]

        for expected in MicProbeFormatGate.Rejection.allCases {
            guard let (candidate, live) = producers[expected] else {
                XCTFail("no shape pair produces \(expected) — add one or drop the case")
                continue
            }
            XCTAssertEqual(
                MicProbeFormatGate.rejection(candidate: candidate, live: live),
                expected,
                "\(expected) is not produced by its documented shape pair"
            )
        }
    }

    func test_rejectionOrder_positivityBeatsMismatch() {
        // Both limbs could fire; the dead-node reason is the useful one to
        // log, so it must win.
        XCTAssertEqual(
            MicProbeFormatGate.rejection(
                candidate: .init(sampleRate: 0, channelCount: 0),
                live: .init(sampleRate: 48_000, channelCount: 2)
            ),
            .nonPositiveSampleRate
        )
    }

    // MARK: - AVAudioFormat bridge

    func test_shape_readsSampleRateAndChannelCount_fromAVAudioFormat() {
        // Pins the field mapping so a future edit can't silently swap
        // rate and channel count. No engine, no mic — just a format.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ) else {
            return XCTFail("could not construct the reference AVAudioFormat")
        }
        XCTAssertEqual(
            MicProbeFormatGate.Shape(format),
            MicProbeFormatGate.Shape(sampleRate: 44_100, channelCount: 2)
        )
    }
}
