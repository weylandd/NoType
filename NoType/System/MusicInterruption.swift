import AppKit
import CoreAudio
import OSLog

/// Mutes outside audio for the duration of a recording session so
/// background music doesn't bleed into the mic when the user is
/// recording without headphones.
///
/// **Two modes:**
///  - `.none` — no-op. Music continues; mic picks up the speakers.
///  - `.mute` — toggles `kAudioDevicePropertyMute` on the system
///    default *output* device. macOS silences every running app's
///    output (the volume slider stays where it was). On stop we
///    restore the prior mute state, so a user who was already on
///    mute before recording stays on mute after.
///
/// **Removed: `.pause`.** An earlier build (the U4 Core-Audio-HAL
/// commit) shipped a `.pause` mode that synthesised an
/// `NX_KEYTYPE_PLAY` system-defined media key on start and again on
/// stop. `NX_KEYTYPE_PLAY` is a *toggle*, not a directional "pause":
/// it carries no playback state, so when the user's media app was
/// paused or stopped, the start toggle *started* playback — Apple
/// Music kicking on during/after a recording the user never wanted.
/// There is no public API that pauses-only without starting stopped
/// media (reading the system playback state needs the private
/// `MediaRemote` framework, which Apple has progressively locked down),
/// so the mode was removed rather than shipped doing the opposite of
/// its label. `.mute` covers the same "don't let music bleed into the
/// mic" goal without ever changing *what* is playing. A stored
/// `"pause"` rawValue from an older build now fails `Mode(rawValue:)`
/// and falls back to `.none` in `AppState.init` — pinned by
/// `MusicInterruptionModeTests`.
///
/// **Shape parallels `SleepAssertion`'s RAII intent** — `@MainActor`
/// `final class`, owned by `AppState`, RAII-deinit safety net for the
/// mute-restore path so a missed `release()` doesn't strand the user's
/// system on mute forever. Acquired in `AppState.handleHotkeyPress`
/// after `session.start()` succeeds.
///
/// **Released the moment recording ends, NOT at session end.** Unlike
/// `SleepAssertion` (which is held through the Gemini transcription
/// window so the Mac can't sleep mid-call), the mute is lifted as soon
/// as the mic stops capturing — at the top of `AppState.finalizeRecording`
/// (before the `await session.stop()`) and in `cancelRecording`. The
/// mute only exists to keep speaker audio out of the *mic*; once the
/// user releases the hotkey there's nothing left to record, so holding
/// the mute through transcription would just silence the user's music
/// for no reason while the transcribing HUD spins.
///
/// Construction and activation are intentionally split (vs.
/// `SleepAssertion`'s `init(reason:) throws` shape) because
/// `Mode.none` is a valid no-op state — a throwing init would force
/// the caller to skip construction entirely when the user has the
/// toggle off, which complicates the `AppState` ownership pattern
/// (the optional `activeMusicInterruption` reference has to mean
/// "we're holding an active mute" rather than "we have an object").
/// Keeping `init()` cheap and pushing the side-effect into
/// `activate(mode:)` lets the optional carry the real semantics.
///
/// **Restore targets a snapshotted device.** Activation captures the
/// `AudioDeviceID` of the default output at the moment we mute it and
/// the release path restores that *specific* device, even if the user
/// has since changed the system default output. Without this, the
/// original muted device would stay muted indefinitely. See the
/// `savedOutputDeviceID` doc-comment.
///
/// **Limitation: manual mute toggle during the session.** We snapshot
/// the mute state at activate-time. If the user manually toggles mute
/// via the menu bar / Control Centre during the session, our release
/// re-applies the snapshotted state, which can briefly contradict
/// their intent. Acceptable given short session windows; a more
/// sophisticated implementation would diff against the current state
/// at release-time but the cost-benefit doesn't justify the added
/// complexity.
@MainActor
final class MusicInterruption {

    enum Mode: String, CaseIterable, Sendable, Codable {
        case none
        case mute

        /// UserDefaults storage key.
        static let userDefaultsKey: String = "notype.musicInterruption"

        /// Picker label rendered in Settings → Recording.
        var label: String {
            switch self {
            case .none: return "None"
            case .mute: return "Mute"
            }
        }

        /// Settings row subtitle reflects what the current selection
        /// will do to the user's audio. Pure / static so the Settings
        /// pane stays declarative.
        static func subtitle(for mode: Mode) -> String {
            switch mode {
            case .none:
                return "Keep other audio playing without interruption."
            case .mute:
                return "Mute system output while recording, then restore the previous mute state."
            }
        }
    }

    nonisolated private static let log = Logger(subsystem: "app.notype", category: "music")

    /// Mode the controller is currently "holding" — `.none` when
    /// inactive. Reads as the user-visible mode of the in-flight
    /// session even if the user has since changed
    /// `AppState.musicInterruptionMode` to something else (the policy
    /// is frozen at session start, like every other configurable).
    nonisolated(unsafe) private(set) var activeMode: Mode = .none

    /// Snapshotted mute state of the system output before we engaged
    /// `.mute`. `nil` when we don't currently hold the assertion.
    /// `nonisolated(unsafe)` for the same `deinit` safety-net reason
    /// as `SleepAssertion.assertionID`.
    nonisolated(unsafe) private var savedMuteState: Bool? = nil

    /// `AudioDeviceID` of the output device we muted at activate-time.
    /// `nil` when we don't currently hold the assertion. The release
    /// path targets *this* device, not whatever the current system
    /// default is — if the user changes default output mid-session,
    /// the originally-muted device stays muted unless we restore it
    /// by its captured ID. Same `nonisolated(unsafe)` rationale as
    /// `savedMuteState`.
    nonisolated(unsafe) private var savedOutputDeviceID: AudioDeviceID? = nil

    init() {}

    /// Engage the interruption. No-op when `mode == .none` or when an
    /// activation is already in flight (defends against `handleHotkeyPress`
    /// arriving twice if the press-handler is ever re-entered).
    func activate(mode: Mode) {
        guard activeMode == .none else { return }
        guard mode != .none else { return }
        activeMode = mode
        switch mode {
        case .none:
            break
        case .mute:
            // Snapshot the device ID *before* mutating so the release
            // path targets the same device even if the user changes
            // default output mid-session. If we can't resolve a
            // device, abort the activation cleanly so we don't leave
            // a phantom `activeMode == .mute` with nothing to restore.
            guard let outputID = Self.defaultOutputDevice() else {
                Self.log.warning("music: activate(.mute) — no default output device")
                activeMode = .none
                return
            }
            // Apply the mute. If the HAL set call failed, fall back
            // to `.none` rather than booking a release for a mute we
            // never engaged.
            guard let previous = Self.applyMute(true, on: outputID) else {
                Self.log.warning("music: activate(.mute) — applyMute failed, activation aborted")
                activeMode = .none
                return
            }
            savedOutputDeviceID = outputID
            savedMuteState = previous
        }
    }

    /// Restore whatever we changed. Idempotent — repeated calls after
    /// the first are no-ops. Safe to call from `deinit`.
    func release() {
        defer { activeMode = .none; savedMuteState = nil; savedOutputDeviceID = nil }
        switch activeMode {
        case .none:
            return
        case .mute:
            // Restore the pre-session mute state on the *same* device
            // we muted. Targeting the snapshotted device ID survives
            // a mid-session default-output change. Nil saved state
            // means we never managed to read the original — leave the
            // captured device unmuted so the user isn't trapped on
            // mute. Nil device ID means activation aborted partway
            // through; nothing to restore.
            if let deviceID = savedOutputDeviceID {
                _ = Self.applyMute(savedMuteState ?? false, on: deviceID)
            }
        }
    }

    deinit {
        // Safety net only — production code paths always call release()
        // explicitly. Catches programmer mistakes so the user's system
        // isn't trapped on mute after a thrown error somewhere in the
        // session-end pipeline.
        if activeMode == .mute,
           let prev = savedMuteState,
           let deviceID = savedOutputDeviceID {
            _ = Self.applyMute(prev, on: deviceID)
        }
    }

    // MARK: - CoreAudio output mute

    /// Apply `desired` as the `kAudioDevicePropertyMute` value of the
    /// given output device. Returns the *previous* mute state on
    /// success, or `nil` if the HAL Set call failed (no point in the
    /// caller booking a release for a mute we never engaged) or if
    /// the device doesn't expose the property at all (external
    /// interfaces sometimes don't — built-in speakers always do).
    ///
    /// Returning `nil` on Set failure (vs. surfacing the
    /// pre-read state) is load-bearing: `activate(.mute)` uses the
    /// `nil` signal to abort the activation rather than holding a
    /// phantom assertion that would later restore a state we never
    /// changed.
    @discardableResult
    nonisolated private static func applyMute(_ desired: Bool, on deviceID: AudioDeviceID) -> Bool? {
        let previous = readMute(deviceID)
        let value: UInt32 = desired ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var v = value
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &v
        )
        if status != noErr {
            Self.log.warning("music: AudioObjectSetPropertyData(Mute=\(desired, privacy: .public)) status=\(status, privacy: .public)")
            return nil
        }
        return previous
    }

    nonisolated private static func readMute(_ deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteValue: UInt32 = 0
        var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muteValue)
        guard status == noErr else { return nil }
        return muteValue == 1
    }

    nonisolated private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }
}
