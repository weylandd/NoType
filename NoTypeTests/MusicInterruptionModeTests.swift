import XCTest
@testable import NoType

/// Pins the `MusicInterruption.Mode` enum's pure surface — picker
/// labels, subtitle copy, RawRepresentable round-trip used by
/// UserDefaults persistence. The actual mute / pause side effects
/// (CoreAudio property writes, NSEvent posts) are system-level and
/// covered by manual hardware smoke per `NoType/Recording/CLAUDE.md`'s
/// "Don't write tests against live mic input" sibling rule for audio
/// output: the OS side of `kAudioDevicePropertyMute` / system-defined
/// NX events is opaque to unit tests.
final class MusicInterruptionModeTests: XCTestCase {

    func test_allCases_orderingIsNoneMutePause() {
        // Segmented picker reads left-to-right; this is the order the
        // user sees. None first (default / opt-out), then the two
        // active modes.
        XCTAssertEqual(MusicInterruption.Mode.allCases, [.none, .mute, .pause])
    }

    func test_rawValuesArePersistable() {
        // Persisted in UserDefaults via raw-value string. Pin the
        // strings so a future refactor that renames a case can't
        // silently strand existing users on `.none` (the
        // init(rawValue:) of the unknown string).
        XCTAssertEqual(MusicInterruption.Mode.none.rawValue, "none")
        XCTAssertEqual(MusicInterruption.Mode.mute.rawValue, "mute")
        XCTAssertEqual(MusicInterruption.Mode.pause.rawValue, "pause")
    }

    func test_initFromRawValue_roundTrip() {
        for mode in MusicInterruption.Mode.allCases {
            XCTAssertEqual(MusicInterruption.Mode(rawValue: mode.rawValue), mode)
        }
    }

    func test_initFromRawValue_unknownReturnsNil() {
        // AppState.init falls back to `.none` when the rawValue cast
        // fails, so unknown stored values land on the safe default.
        XCTAssertNil(MusicInterruption.Mode(rawValue: "duck"))
        XCTAssertNil(MusicInterruption.Mode(rawValue: ""))
    }

    func test_labels_areUserVisible() {
        // Pin the picker copy — Settings → Audio renders these.
        XCTAssertEqual(MusicInterruption.Mode.none.label, "None")
        XCTAssertEqual(MusicInterruption.Mode.mute.label, "Mute")
        XCTAssertEqual(MusicInterruption.Mode.pause.label, "Pause")
    }

    func test_subtitle_noneExplainsNoOp() {
        let s = MusicInterruption.Mode.subtitle(for: .none)
        XCTAssertTrue(s.contains("Keep") || s.contains("without"), "got: \(s)")
    }

    func test_subtitle_muteMentionsMute() {
        let s = MusicInterruption.Mode.subtitle(for: .mute)
        XCTAssertTrue(s.localizedCaseInsensitiveContains("mute"), "got: \(s)")
    }

    func test_subtitle_pauseMentionsMediaApps() {
        // Subtitle should name examples so the user knows what
        // "Pause" actually controls.
        let s = MusicInterruption.Mode.subtitle(for: .pause)
        XCTAssertTrue(s.localizedCaseInsensitiveContains("play"), "got: \(s)")
    }

    func test_userDefaultsKey_isStableAcrossRefactors() {
        // Renaming the storage key would silently strand every
        // existing user on `.none`. Pinned.
        XCTAssertEqual(MusicInterruption.Mode.userDefaultsKey, "notype.musicInterruption")
    }

    // MARK: - MusicInterruption controller lifecycle
    //
    // These pin the *control-flow* shape only. The mute / pause side
    // effects (CoreAudio property writes, NSEvent posts) require live
    // hardware to validate end-to-end — see the class doc-comment.
    // What unit-testable here is the small surface around the
    // `activeMode` latch: a `.none` activation stays inactive, a
    // double-activate guard freezes the first mode, and a `.none`
    // release is idempotent. A future test seam (injectable mute /
    // media-key adapters) would let us cover the side-effect paths
    // without hardware.

    @MainActor
    func test_lifecycle_initialActiveModeIsNone() {
        let m = MusicInterruption()
        XCTAssertEqual(m.activeMode, .none)
    }

    @MainActor
    func test_lifecycle_activateNone_isNoOp() {
        let m = MusicInterruption()
        m.activate(mode: .none)
        XCTAssertEqual(m.activeMode, .none, "Activating .none should not flip activeMode")
    }

    @MainActor
    func test_lifecycle_doubleActivate_keepsFirstMode() {
        // The guard in `activate(mode:)` refuses a second activation
        // while one is already in flight. Without hardware we can't
        // *force* the first mute path to succeed — but on developer
        // machines with a built-in output device the .mute activate
        // does succeed, so we use .pause as the first mode (no
        // pre-condition: NSEvent posting always "succeeds" from the
        // controller's perspective; whether any media app responds is
        // out of scope).
        let m = MusicInterruption()
        m.activate(mode: .pause)
        XCTAssertEqual(m.activeMode, .pause)
        m.activate(mode: .mute)
        XCTAssertEqual(m.activeMode, .pause, "Second activate must not change activeMode")
        // Clean up the pause toggle we engaged so the test machine
        // isn't left with a media-app side-effect.
        m.release()
    }

    @MainActor
    func test_lifecycle_releaseFromNone_isIdempotent() {
        let m = MusicInterruption()
        m.release()
        m.release()
        XCTAssertEqual(m.activeMode, .none)
    }
}
