import XCTest
@testable import NoType

/// Pins the `MusicInterruption.Mode` enum's pure surface — picker
/// labels, subtitle copy, RawRepresentable round-trip used by
/// UserDefaults persistence. The actual mute side effects (CoreAudio
/// property writes) are system-level and covered by manual hardware
/// smoke per `NoType/Recording/CLAUDE.md`'s "Don't write tests against
/// live mic input" sibling rule for audio output: the OS side of
/// `kAudioDevicePropertyMute` is opaque to unit tests.
final class MusicInterruptionModeTests: XCTestCase {

    func test_allCases_orderingIsNoneMute() {
        // Segmented picker reads left-to-right; this is the order the
        // user sees. None first (default / opt-out), then the single
        // active mode. The `.pause` toggle mode was removed (it started
        // stopped/paused media) — see `MusicInterruption`.
        XCTAssertEqual(MusicInterruption.Mode.allCases, [.none, .mute])
    }

    func test_rawValuesArePersistable() {
        // Persisted in UserDefaults via raw-value string. Pin the
        // strings so a future refactor that renames a case can't
        // silently strand existing users on `.none` (the
        // init(rawValue:) of the unknown string).
        XCTAssertEqual(MusicInterruption.Mode.none.rawValue, "none")
        XCTAssertEqual(MusicInterruption.Mode.mute.rawValue, "mute")
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
        // Migration: the removed `.pause` mode's stored rawValue must
        // no longer decode, so users who had it selected fall back to
        // `.none` (instead of resurrecting the media-key toggle that
        // started their paused music).
        XCTAssertNil(MusicInterruption.Mode(rawValue: "pause"))
    }

    func test_labels_areUserVisible() {
        // Pin the picker copy — Settings → Recording renders these.
        XCTAssertEqual(MusicInterruption.Mode.none.label, "None")
        XCTAssertEqual(MusicInterruption.Mode.mute.label, "Mute")
    }

    func test_subtitle_noneExplainsNoOp() {
        let s = MusicInterruption.Mode.subtitle(for: .none)
        XCTAssertTrue(s.contains("Keep") || s.contains("without"), "got: \(s)")
    }

    func test_subtitle_muteMentionsMute() {
        let s = MusicInterruption.Mode.subtitle(for: .mute)
        XCTAssertTrue(s.localizedCaseInsensitiveContains("mute"), "got: \(s)")
    }

    func test_userDefaultsKey_isStableAcrossRefactors() {
        // Renaming the storage key would silently strand every
        // existing user on `.none`. Pinned.
        XCTAssertEqual(MusicInterruption.Mode.userDefaultsKey, "notype.musicInterruption")
    }

    // MARK: - MusicInterruption controller lifecycle
    //
    // These pin the *control-flow* shape only. The mute side effect
    // (CoreAudio property write) requires a live output device to
    // validate end-to-end — see the class doc-comment. What's
    // unit-testable here is the small surface around the `activeMode`
    // latch: a `.none` activation stays inactive, a double-activate
    // guard freezes the first mode, and a `.none` release is
    // idempotent.

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
    func test_lifecycle_doubleActivate_keepsFirstMode() throws {
        // The guard in `activate(mode:)` refuses a second activation
        // while one is already in flight. The only active mode left is
        // `.mute`, which only engages when there's a usable output
        // device — skip on headless machines where the first activate
        // cleanly aborts back to `.none`.
        let m = MusicInterruption()
        m.activate(mode: .mute)
        try XCTSkipUnless(m.activeMode == .mute, "no output device available to engage .mute")
        // Second activate must be refused by the in-flight guard.
        m.activate(mode: .mute)
        XCTAssertEqual(m.activeMode, .mute, "Second activate must not change activeMode")
        // Restore the system mute state we engaged so the test machine
        // isn't left muted.
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
